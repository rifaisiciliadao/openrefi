// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2StepUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/// @title  ModuleRegistry
/// @notice Factory-side registry of module implementations and default
///         modules to inject into every new Campaign at deploy time.
///
///         The Campaign host calls `isModuleImplApproved(kind, impl)` and
///         `moduleKindSelectors(kind)` during `attachModule` to gate the
///         attach against a vetted set. Only the registry owner (i.e. the
///         protocol multisig) can mutate the whitelist or the defaults.
///
///         Designed to be inherited by the full `GrowfiCampaignFactory` —
///         carved out as a separate contract so the module surface can be
///         unit-tested in isolation and so the storage layout stays
///         contained to a single, focused concern.
abstract contract ModuleRegistry is Ownable2StepUpgradeable {
    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    /// @notice Default module to auto-inject into every newly deployed
    ///         Campaign during the factory bootstrap window.
    /// @param  moduleType   Logical slot inside the Campaign module map
    ///                      (e.g. `keccak256("growfi.type.sale")`). One
    ///                      module per type per Campaign.
    /// @param  kind         Module class (e.g. `keccak256("growfi.sale.classic.v1")`).
    ///                      Must match a whitelist entry.
    /// @param  impl         Concrete implementation address (whitelisted).
    /// @param  metadataURI  Off-chain JSON describing the module.
    struct DefaultModule {
        bytes32 moduleType;
        bytes32 kind;
        address impl;
        string metadataURI;
    }

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    /// @dev kind => impl => approved?
    mapping(bytes32 => mapping(address => bool)) public approvedModuleImpls;

    /// @dev kind => external selectors that the module class claims
    mapping(bytes32 => bytes4[]) private _moduleKindSelectors;

    /// @dev List of modules auto-injected at Campaign deploy time. Ordered;
    ///      attach happens in array order.
    DefaultModule[] private _defaultModules;

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error ZeroAddress();
    error EmptySelectorSet();
    error SelectorAlreadyUsedInKind(bytes4 selector);
    error DuplicateSelectorInList(bytes4 selector);
    error ImplNotApproved();
    error KindHasNoSelectors();
    error IndexOutOfBounds();

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event ModuleImplApproved(bytes32 indexed kind, address indexed impl, bool approved);
    event ModuleKindSelectorsSet(bytes32 indexed kind, bytes4[] selectors);
    event DefaultModulesUpdated(uint256 count);

    // ------------------------------------------------------------------
    // Initializer (called by the inheriting factory)
    // ------------------------------------------------------------------

    function __ModuleRegistry_init(address owner_) internal onlyInitializing {
        __Ownable_init(owner_);
        __Ownable2Step_init();
    }

    // ------------------------------------------------------------------
    // Owner — whitelist
    // ------------------------------------------------------------------

    /// @notice Approve / revoke an implementation for a given module
    ///         kind. Approval lets Campaign producers attach it; revoke
    ///         blocks NEW attaches but does NOT break existing attached
    ///         instances (those remain producer-sovereign).
    function approveModuleImpl(bytes32 kind, address impl, bool approved) external onlyOwner {
        if (impl == address(0)) revert ZeroAddress();
        approvedModuleImpls[kind][impl] = approved;
        emit ModuleImplApproved(kind, impl, approved);
    }

    /// @notice Define the external selectors that the module class
    ///         `kind` claims. Replaces the previous set entirely.
    ///         The Campaign uses this list during `attachModule` to
    ///         populate its `selectorToType` map.
    function setModuleKindSelectors(bytes32 kind, bytes4[] calldata selectors) external onlyOwner {
        if (selectors.length == 0) revert EmptySelectorSet();
        // Guard against duplicates in the input — the Campaign would
        // otherwise revert on the second registration, but flagging it
        // here yields a clearer error path.
        for (uint256 i; i < selectors.length;) {
            for (uint256 j = i + 1; j < selectors.length;) {
                if (selectors[i] == selectors[j]) revert DuplicateSelectorInList(selectors[i]);
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
        _moduleKindSelectors[kind] = selectors;
        emit ModuleKindSelectorsSet(kind, selectors);
    }

    /// @notice Replace the default modules list. New Campaigns deployed
    ///         after this call will attach exactly this list at bootstrap;
    ///         already-deployed Campaigns keep whatever they had.
    function setDefaultModules(DefaultModule[] calldata list) external onlyOwner {
        // Validate each entry against the current whitelist + selectors
        for (uint256 i; i < list.length;) {
            DefaultModule calldata m = list[i];
            if (m.impl == address(0)) revert ZeroAddress();
            if (!approvedModuleImpls[m.kind][m.impl]) revert ImplNotApproved();
            if (_moduleKindSelectors[m.kind].length == 0) revert KindHasNoSelectors();
            unchecked {
                ++i;
            }
        }
        delete _defaultModules;
        for (uint256 i; i < list.length;) {
            _defaultModules.push(list[i]);
            unchecked {
                ++i;
            }
        }
        emit DefaultModulesUpdated(list.length);
    }

    // ------------------------------------------------------------------
    // Views (called by the Campaign host)
    // ------------------------------------------------------------------

    function isModuleImplApproved(bytes32 kind, address impl) external view returns (bool) {
        return approvedModuleImpls[kind][impl];
    }

    function moduleKindSelectors(bytes32 kind) external view returns (bytes4[] memory) {
        return _moduleKindSelectors[kind];
    }

    function defaultModulesLength() public view returns (uint256) {
        return _defaultModules.length;
    }

    function defaultModuleAt(uint256 i) public view returns (DefaultModule memory) {
        if (i >= _defaultModules.length) revert IndexOutOfBounds();
        return _defaultModules[i];
    }

    /// @dev Storage gap for future fields when this is inherited by the
    ///      full GrowfiCampaignFactory. Sized generously so we can add
    ///      module-tracking metadata later without breaking layout.
    uint256[42] private __gap;
}
