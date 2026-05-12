// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {CampaignStorage} from "./host/CampaignStorage.sol";
import {IGrowfiCampaignFactoryV4} from "./interfaces/IGrowfiCampaignFactoryV4.sol";

/// @dev Local interface — CampaignToken's `setStakingVault` is gated
///      onlyCampaign and is called from the host during satellite wiring.
interface ICampaignTokenStakingSet {
    function setStakingVault(address) external;
}

/// @dev Local interface for the StakingVault lifecycle wrappers
///      (startSeason / endSeason) the host forwards to.
interface IStakingVaultLifecycle {
    function startSeason(uint256 seasonId) external;
    function endSeason() external;
}

/// @dev Local interface for cross-wiring the yield token on the vault.
interface IStakingVaultYieldSet {
    function setYieldToken(address yieldToken) external;
}

/// @title  GrowfiCampaign — module host
/// @notice The Campaign contract is intentionally minimal. It owns:
///
///         1. The campaign state machine (Funding → Active → Buyback → Ended)
///         2. The module registry and selector router
///         3. The physical USDC escrow address (USDC literally sits at
///            `address(this)` during the Funding phase; modules read it
///            via the standard ERC20 balance)
///
///         All buy / sellback / collateral / harvest / future logic lives
///         in modules that the host `delegatecall`s through its fallback.
///
///         Storage discipline: this contract declares NO sequential
///         state variables. Everything lives in `CampaignStorage.Layout`
///         at the namespaced slot, so modules running in delegatecall
///         context can read and write the same layout via the library.
contract GrowfiCampaign is Initializable {
    using CampaignStorage for CampaignStorage.Layout;

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error OnlyProducer();
    error OnlyFactory();
    error BootstrapClosed();
    error BootstrapStillOpen();
    error ImplNotApproved();
    error KindHasNoSelectors();
    error TypeAlreadyAttached();
    error TypeNotAttached();
    error SelectorAlreadyTaken(bytes4 selector);
    error UnknownSelector(bytes4 selector);
    error ModuleDisabled();
    error InvalidState();
    error ZeroAddress();

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event ModuleAttached(
        bytes32 indexed moduleType, address indexed impl, bytes32 indexed kind, string metadataURI
    );
    event ModuleDetached(bytes32 indexed moduleType, address indexed previousImpl);
    event ModuleEnabledSet(bytes32 indexed moduleType, bool enabled);
    event ModuleSelectorRegistered(bytes4 indexed selector, bytes32 indexed moduleType);
    event ModuleSelectorCleared(bytes4 indexed selector, bytes32 indexed moduleType);
    event BootstrapClosedEvent();
    event PausedSet(bool paused);
    event CampaignEnded(uint256 timestamp);

    // ------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------

    modifier onlyProducer() {
        if (msg.sender != CampaignStorage.layout().producer) revert OnlyProducer();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != CampaignStorage.layout().factory) revert OnlyFactory();
        _;
    }

    // ------------------------------------------------------------------
    // Initializer
    // ------------------------------------------------------------------

    /// @notice Minimal initial parameters set at deploy. Satellites
    ///         (campaignToken, yieldToken, stakingVault, harvestManager)
    ///         are wired post-init via factory-only setters because the
    ///         Campaign address must be known to those satellites at
    ///         their own init time — chicken-and-egg solved with one-
    ///         shot setters mirroring the v3 deploy pattern.
    struct InitParams {
        address producer;
        address factory;
        address usdc;
        address protocolFeeRecipient;
    }

    error AlreadyWired();

    constructor() {
        _disableInitializers();
    }

    /// @notice Called by the factory at deploy time. Sets the immutable
    ///         bindings and opens the `factoryBootstrap` window so the
    ///         factory can wire satellites + auto-inject default modules.
    function initialize(InitParams calldata p) external initializer {
        if (
            p.producer == address(0) || p.factory == address(0) || p.usdc == address(0)
                || p.protocolFeeRecipient == address(0)
        ) revert ZeroAddress();

        CampaignStorage.Layout storage s = CampaignStorage.layout();
        s.producer = p.producer;
        s.factory = p.factory;
        s.usdc = p.usdc;
        s.protocolFeeRecipient = p.protocolFeeRecipient;
        s.state = uint8(CampaignStorage.State.Funding);
        s.factoryBootstrap = true;
    }

    /// @notice Factory wires the satellite addresses post-init, one-shot.
    function setCampaignToken(address campaignToken_) external onlyFactory {
        if (campaignToken_ == address(0)) revert ZeroAddress();
        CampaignStorage.Layout storage s = CampaignStorage.layout();
        if (s.campaignToken != address(0)) revert AlreadyWired();
        s.campaignToken = campaignToken_;
    }

    function setYieldToken(address yieldToken_) external onlyFactory {
        if (yieldToken_ == address(0)) revert ZeroAddress();
        CampaignStorage.Layout storage s = CampaignStorage.layout();
        if (s.yieldToken != address(0)) revert AlreadyWired();
        s.yieldToken = yieldToken_;
        // Cross-wire on the StakingVault side — its setYieldToken is
        // `onlyCampaign`, so calling it from the host satisfies the gate.
        if (s.stakingVault != address(0)) {
            IStakingVaultYieldSet(s.stakingVault).setYieldToken(yieldToken_);
        }
    }

    function setStakingVault(address stakingVault_) external onlyFactory {
        if (stakingVault_ == address(0)) revert ZeroAddress();
        CampaignStorage.Layout storage s = CampaignStorage.layout();
        if (s.stakingVault != address(0)) revert AlreadyWired();
        s.stakingVault = stakingVault_;
        // Cross-wire on the CampaignToken side too — its setStakingVault
        // is gated `onlyCampaign`, so calling it from the host satisfies
        // the gate (msg.sender = address(this) = Campaign).
        if (s.campaignToken != address(0)) {
            ICampaignTokenStakingSet(s.campaignToken).setStakingVault(stakingVault_);
        }
    }

    function setHarvestManager(address harvestManager_) external onlyFactory {
        if (harvestManager_ == address(0)) revert ZeroAddress();
        CampaignStorage.Layout storage s = CampaignStorage.layout();
        if (s.harvestManager != address(0)) revert AlreadyWired();
        s.harvestManager = harvestManager_;
    }

    // ------------------------------------------------------------------
    // Module attach / detach (producer path + factory bootstrap path)
    // ------------------------------------------------------------------

    /// @notice Producer attaches a module to this Campaign. The factory
    ///         whitelist gate runs inside `_attachModule`.
    function attachModule(bytes32 moduleType, bytes32 kind, address impl, string calldata metadataURI)
        external
        onlyProducer
    {
        _attachModule(moduleType, kind, impl, metadataURI);
    }

    /// @notice Factory bootstrap path. Used during `createCampaign` to
    ///         inject the `defaultModules[]` list before the Campaign is
    ///         turned over to the producer. After the factory calls
    ///         `closeBootstrap()` this path reverts.
    function attachModuleAsFactory(bytes32 moduleType, bytes32 kind, address impl, string calldata metadataURI)
        external
        onlyFactory
    {
        if (!CampaignStorage.layout().factoryBootstrap) revert BootstrapClosed();
        _attachModule(moduleType, kind, impl, metadataURI);
    }

    function _attachModule(bytes32 moduleType, bytes32 kind, address impl, string memory metadataURI) internal {
        if (impl == address(0)) revert ZeroAddress();

        CampaignStorage.Layout storage s = CampaignStorage.layout();
        IGrowfiCampaignFactoryV4 factory_ = IGrowfiCampaignFactoryV4(s.factory);

        if (!factory_.isModuleImplApproved(kind, impl)) revert ImplNotApproved();

        bytes4[] memory selectors = factory_.moduleKindSelectors(kind);
        if (selectors.length == 0) revert KindHasNoSelectors();

        CampaignStorage.ModuleSlot storage slot = s.moduleSlot[moduleType];
        if (slot.impl != address(0)) revert TypeAlreadyAttached();

        for (uint256 i; i < selectors.length;) {
            bytes4 sel = selectors[i];
            if (s.selectorToType[sel] != bytes32(0)) revert SelectorAlreadyTaken(sel);
            s.selectorToType[sel] = moduleType;
            emit ModuleSelectorRegistered(sel, moduleType);
            unchecked {
                ++i;
            }
        }

        slot.impl = impl;
        slot.kind = kind;
        slot.metadataURI = metadataURI;
        slot.attachedAt = uint64(block.timestamp);
        slot.enabled = true;
        s.moduleTypeList.push(moduleType);

        emit ModuleAttached(moduleType, impl, kind, metadataURI);
    }

    /// @notice Detach a module. All its selectors are cleared from the
    ///         router map so the same slot can be re-attached later
    ///         (possibly with a different impl).
    function detachModule(bytes32 moduleType) external onlyProducer {
        CampaignStorage.Layout storage s = CampaignStorage.layout();
        CampaignStorage.ModuleSlot storage slot = s.moduleSlot[moduleType];
        address previous = slot.impl;
        if (previous == address(0)) revert TypeNotAttached();

        bytes4[] memory selectors =
            IGrowfiCampaignFactoryV4(s.factory).moduleKindSelectors(slot.kind);
        for (uint256 i; i < selectors.length;) {
            bytes4 sel = selectors[i];
            if (s.selectorToType[sel] == moduleType) {
                delete s.selectorToType[sel];
                emit ModuleSelectorCleared(sel, moduleType);
            }
            unchecked {
                ++i;
            }
        }

        delete s.moduleSlot[moduleType];
        _removeTypeFromList(moduleType);

        emit ModuleDetached(moduleType, previous);
    }

    function _removeTypeFromList(bytes32 moduleType) internal {
        bytes32[] storage list = CampaignStorage.layout().moduleTypeList;
        uint256 n = list.length;
        for (uint256 i; i < n;) {
            if (list[i] == moduleType) {
                list[i] = list[n - 1];
                list.pop();
                return;
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Toggle a module on/off without detaching. Fast emergency
    ///         disable controlled by the producer.
    function setModuleEnabled(bytes32 moduleType, bool enabled) external onlyProducer {
        CampaignStorage.Layout storage s = CampaignStorage.layout();
        CampaignStorage.ModuleSlot storage slot = s.moduleSlot[moduleType];
        if (slot.impl == address(0)) revert TypeNotAttached();
        slot.enabled = enabled;
        emit ModuleEnabledSet(moduleType, enabled);
    }

    /// @notice Factory closes the bootstrap window after auto-attaching
    ///         every default module. Past this point, only the producer
    ///         can attach further modules.
    function closeBootstrap() external onlyFactory {
        CampaignStorage.Layout storage s = CampaignStorage.layout();
        if (!s.factoryBootstrap) revert BootstrapClosed();
        s.factoryBootstrap = false;
        emit BootstrapClosedEvent();
    }

    // ------------------------------------------------------------------
    // Host-owned lifecycle
    // ------------------------------------------------------------------

    /// @notice Producer pauses the Campaign. Modules MAY consult
    ///         `paused` to gate write operations; the host does not
    ///         enforce it (modules carry the responsibility, since the
    ///         host never sees user-facing entrypoints anymore).
    function setPaused(bool paused_) external onlyProducer {
        CampaignStorage.layout().paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Factory-level emergency pause. Mirrors the v3 path where
    ///         the factory owner could force-pause a misbehaving Campaign
    ///         without involving the producer.
    function factorySetPaused(bool paused_) external onlyFactory {
        CampaignStorage.layout().paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Producer terminates the Campaign permanently. Once in
    ///         `Ended`, modules SHOULD refuse new write operations.
    function endCampaign() external onlyProducer {
        CampaignStorage.Layout storage s = CampaignStorage.layout();
        if (s.state == uint8(CampaignStorage.State.Ended)) revert InvalidState();
        s.state = uint8(CampaignStorage.State.Ended);
        emit CampaignEnded(block.timestamp);
    }

    /// @notice Start a new staking season. Forwards to the StakingVault;
    ///         caller must be the producer. Increments the host's
    ///         `currentSeasonId` so modules can read the current season
    ///         without a cross-contract hop.
    function startSeason() external onlyProducer {
        CampaignStorage.Layout storage s = CampaignStorage.layout();
        if (s.state != uint8(CampaignStorage.State.Active)) revert InvalidState();
        s.currentSeasonId += 1;
        IStakingVaultLifecycle(s.stakingVault).startSeason(s.currentSeasonId);
    }

    /// @notice End the current staking season. Mirrors the v3 wrapper.
    function endSeason() external onlyProducer {
        CampaignStorage.Layout storage s = CampaignStorage.layout();
        IStakingVaultLifecycle(s.stakingVault).endSeason();
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function producer() external view returns (address) {
        return CampaignStorage.layout().producer;
    }

    function factory() external view returns (address) {
        return CampaignStorage.layout().factory;
    }

    function state() external view returns (CampaignStorage.State) {
        return CampaignStorage.State(CampaignStorage.layout().state);
    }

    function paused() external view returns (bool) {
        return CampaignStorage.layout().paused;
    }

    function factoryBootstrap() external view returns (bool) {
        return CampaignStorage.layout().factoryBootstrap;
    }

    function currentSeasonId() external view returns (uint256) {
        return CampaignStorage.layout().currentSeasonId;
    }

    function moduleSlot(bytes32 moduleType)
        external
        view
        returns (
            address impl,
            bytes32 kind,
            string memory metadataURI,
            uint64 attachedAt,
            bool enabled
        )
    {
        CampaignStorage.ModuleSlot storage slot = CampaignStorage.layout().moduleSlot[moduleType];
        return (slot.impl, slot.kind, slot.metadataURI, slot.attachedAt, slot.enabled);
    }

    function moduleTypeAt(uint256 i) external view returns (bytes32) {
        return CampaignStorage.layout().moduleTypeList[i];
    }

    function moduleTypeCount() external view returns (uint256) {
        return CampaignStorage.layout().moduleTypeList.length;
    }

    function selectorToType(bytes4 selector) external view returns (bytes32) {
        return CampaignStorage.layout().selectorToType[selector];
    }

    function campaignToken() external view returns (address) {
        return CampaignStorage.layout().campaignToken;
    }

    function yieldToken() external view returns (address) {
        return CampaignStorage.layout().yieldToken;
    }

    function stakingVault() external view returns (address) {
        return CampaignStorage.layout().stakingVault;
    }

    function harvestManager() external view returns (address) {
        return CampaignStorage.layout().harvestManager;
    }

    function usdc() external view returns (address) {
        return CampaignStorage.layout().usdc;
    }

    function protocolFeeRecipient() external view returns (address) {
        return CampaignStorage.layout().protocolFeeRecipient;
    }

    // ------------------------------------------------------------------
    // Fallback router
    // ------------------------------------------------------------------

    /// @notice Resolves an unknown selector to a module via the registry
    ///         and `delegatecall`s into the impl. Reverts on unknown
    ///         selector, disabled module, or detached slot.
    /// @dev    Native EVM dispatch picks up the explicit functions above
    ///         before reaching the fallback, so core selectors are
    ///         intrinsically protected from shadowing — `attachModule`
    ///         additionally refuses to register any selector that's
    ///         already claimed in `selectorToType`.
    fallback() external payable {
        CampaignStorage.Layout storage s = CampaignStorage.layout();
        bytes32 moduleType = s.selectorToType[msg.sig];
        if (moduleType == bytes32(0)) revert UnknownSelector(msg.sig);

        CampaignStorage.ModuleSlot storage slot = s.moduleSlot[moduleType];
        if (!slot.enabled) revert ModuleDisabled();
        address impl = slot.impl;
        if (impl == address(0)) revert TypeNotAttached();

        assembly {
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch success
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    /// @notice Accept ETH for forwarding by modules (escrow is normally
    ///         in USDC, but plain ETH receipt is allowed so future
    ///         payment modules can take native gas as a payment token).
    receive() external payable {}
}
