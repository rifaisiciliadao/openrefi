// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CampaignStorage} from "../host/CampaignStorage.sol";
import {IHarvestManagerCollateral} from "../interfaces/IHarvestManagerCollateral.sol";

/// @title  CollateralModule
/// @notice Default module owning the producer's productive-asset
///         commitments plus the pre-paid yield reserve ("collateral").
///
///         - Producer locks USDC into the reserve up to `maxCollateral()`.
///         - Producer settles each season's USDC obligation via `depositUSDC`,
///           which drains collateral first and only pulls from the wallet
///           for the residual gap (capped per call).
///         - After `usdcDeadline`, anyone can call `settleSeasonShortfall`
///           to draw the remaining gap from collateral for that season.
///
///         Storage namespace: `keccak256("growfi.module.collateral.v1")`.
contract CollateralModule {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    struct Layout {
        // --- Productive-asset commitments (immutable post-init) ---
        uint256 expectedAnnualHarvestUsd; // USD-18 per year
        uint256 expectedAnnualHarvest; // product units (1e18 scale) per year
        uint256 firstHarvestYear;
        uint256 coverageHarvests; // number of seasons pre-funded
        // --- Collateral state (mutable) ---
        uint256 collateralLocked;
        uint256 collateralDrawn;
        mapping(uint256 => bool) seasonShortfallSettled;
        // --- guards ---
        uint256 reentrancyStatus;
        bool initialized;
    }

    bytes32 internal constant STORAGE_SLOT =
        0x1d5c7025e27f7f3a598a1ed3ef2f3b18a3b6b8f8025c5754e51904d497088646; // keccak256("growfi.module.collateral.v1")

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error AlreadyInitialized();
    error OnlyFactoryBootstrap();
    error OnlyProducer();
    error InvalidState();
    error ZeroAmount();
    error Reentrant();
    error CollateralCapExceeded();
    error SeasonNotReported();
    error DepositWindowClosed();
    error DepositWindowOpen();
    error AlreadyFunded();
    error AlreadySettled();
    error NotInCoverage();

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event CollateralInitialized(
        uint256 expectedAnnualHarvestUsd,
        uint256 expectedAnnualHarvest,
        uint256 firstHarvestYear,
        uint256 coverageHarvests
    );
    event CollateralLocked(address indexed producer, uint256 amount, uint256 newCollateralLocked);
    event CollateralShortfallSettled(uint256 indexed seasonId, uint256 amountDrawn, uint256 newCollateralDrawn);

    // ------------------------------------------------------------------
    // Storage accessor
    // ------------------------------------------------------------------

    function _s() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }

    // ------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------

    modifier onlyProducer() {
        if (msg.sender != CampaignStorage.layout().producer) revert OnlyProducer();
        _;
    }

    modifier nonReentrant() {
        Layout storage s = _s();
        if (s.reentrancyStatus == _ENTERED) revert Reentrant();
        s.reentrancyStatus = _ENTERED;
        _;
        s.reentrancyStatus = _NOT_ENTERED;
    }

    // ------------------------------------------------------------------
    // Bootstrap initializer
    // ------------------------------------------------------------------

    struct InitParams {
        uint256 expectedAnnualHarvestUsd;
        uint256 expectedAnnualHarvest;
        uint256 firstHarvestYear;
        uint256 coverageHarvests;
    }

    function initializeCollateral(InitParams calldata p) external {
        Layout storage s = _s();
        CampaignStorage.Layout storage cs = CampaignStorage.layout();
        if (s.initialized) revert AlreadyInitialized();
        if (msg.sender != cs.factory || !cs.factoryBootstrap) revert OnlyFactoryBootstrap();

        s.expectedAnnualHarvestUsd = p.expectedAnnualHarvestUsd;
        s.expectedAnnualHarvest = p.expectedAnnualHarvest;
        s.firstHarvestYear = p.firstHarvestYear;
        s.coverageHarvests = p.coverageHarvests;
        s.reentrancyStatus = _NOT_ENTERED;
        s.initialized = true;

        emit CollateralInitialized(
            p.expectedAnnualHarvestUsd, p.expectedAnnualHarvest, p.firstHarvestYear, p.coverageHarvests
        );
    }

    // ------------------------------------------------------------------
    // Producer — lock + per-season settlement
    // ------------------------------------------------------------------

    function lockCollateral(uint256 amount) external onlyProducer nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Layout storage s = _s();
        CampaignStorage.Layout storage cs = CampaignStorage.layout();
        if (cs.paused) revert InvalidState();
        if (
            cs.state != uint8(CampaignStorage.State.Funding)
                && cs.state != uint8(CampaignStorage.State.Active)
        ) revert InvalidState();
        if (s.collateralLocked + amount > maxCollateral()) revert CollateralCapExceeded();

        IERC20(cs.usdc).safeTransferFrom(msg.sender, address(this), amount);
        s.collateralLocked += amount;
        emit CollateralLocked(msg.sender, amount, s.collateralLocked);
    }

    function depositUSDC(uint256 seasonId, uint256 walletCap) external onlyProducer nonReentrant {
        Layout storage s = _s();
        CampaignStorage.Layout storage cs = CampaignStorage.layout();
        if (cs.paused) revert InvalidState();
        if (cs.harvestManager == address(0)) revert InvalidState();

        (,,,,,, uint256 deadline,,,,, bool reported) =
            IHarvestManagerCollateral(cs.harvestManager).seasonHarvests(seasonId);
        if (!reported) revert SeasonNotReported();
        if (block.timestamp > deadline) revert DepositWindowClosed();

        uint256 obligation = IHarvestManagerCollateral(cs.harvestManager).remainingDepositGross(seasonId);
        if (obligation == 0) revert AlreadyFunded();

        uint256 available = s.collateralLocked - s.collateralDrawn;
        uint256 fromCollateral = obligation < available ? obligation : available;
        uint256 gap = obligation - fromCollateral;
        uint256 fromWallet = gap < walletCap ? gap : walletCap;
        uint256 total = fromCollateral + fromWallet;
        if (total == 0) revert ZeroAmount();

        if (fromWallet > 0) {
            IERC20(cs.usdc).safeTransferFrom(msg.sender, address(this), fromWallet);
        }
        if (fromCollateral > 0) {
            s.collateralDrawn += fromCollateral;
            emit CollateralShortfallSettled(seasonId, fromCollateral, s.collateralDrawn);
        }

        IERC20(cs.usdc).safeIncreaseAllowance(cs.harvestManager, total);
        IHarvestManagerCollateral(cs.harvestManager).depositFromCollateral(seasonId, total);
    }

    /// @notice Permissionless settlement of a covered season's shortfall
    ///         after its `usdcDeadline` has passed. Pulls up to the gap
    ///         from `collateralLocked` and forwards it through the
    ///         HarvestManager so holders can claim normally.
    /// @dev    Not gated by pause — holder protection must remain
    ///         available even during an emergency.
    function settleSeasonShortfall(uint256 seasonId) external nonReentrant {
        Layout storage s = _s();
        CampaignStorage.Layout storage cs = CampaignStorage.layout();
        if (seasonId == 0 || seasonId > s.coverageHarvests) revert NotInCoverage();
        if (s.seasonShortfallSettled[seasonId]) revert AlreadySettled();
        if (cs.harvestManager == address(0)) revert InvalidState();

        (,,,,,, uint256 deadline,,,,, bool reported) =
            IHarvestManagerCollateral(cs.harvestManager).seasonHarvests(seasonId);
        if (!reported) revert SeasonNotReported();
        if (block.timestamp <= deadline) revert DepositWindowOpen();

        uint256 obligation = IHarvestManagerCollateral(cs.harvestManager).remainingDepositGross(seasonId);
        uint256 available = s.collateralLocked - s.collateralDrawn;
        uint256 draw = obligation < available ? obligation : available;

        // Always flip the flag so the call cannot be re-attempted forever.
        // No-op paths: either nothing owed (fully funded), or nothing to
        // draw (empty reserve while still owed). Both transition cleanly.
        s.seasonShortfallSettled[seasonId] = true;
        if (draw == 0) return;

        s.collateralDrawn += draw;
        emit CollateralShortfallSettled(seasonId, draw, s.collateralDrawn);

        IERC20(cs.usdc).safeIncreaseAllowance(cs.harvestManager, draw);
        IHarvestManagerCollateral(cs.harvestManager).depositFromCollateral(seasonId, draw);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function maxCollateral() public view returns (uint256) {
        Layout storage s = _s();
        // USD-18 → USDC-6: divide by 1e12.
        return (s.expectedAnnualHarvestUsd * s.coverageHarvests) / 1e12;
    }

    function availableCollateral() external view returns (uint256) {
        Layout storage s = _s();
        return s.collateralLocked - s.collateralDrawn;
    }

    function expectedAnnualHarvestUsd() external view returns (uint256) {
        return _s().expectedAnnualHarvestUsd;
    }

    function expectedAnnualHarvest() external view returns (uint256) {
        return _s().expectedAnnualHarvest;
    }

    function firstHarvestYear() external view returns (uint256) {
        return _s().firstHarvestYear;
    }

    function coverageHarvests() external view returns (uint256) {
        return _s().coverageHarvests;
    }

    function collateralLocked() external view returns (uint256) {
        return _s().collateralLocked;
    }

    function collateralDrawn() external view returns (uint256) {
        return _s().collateralDrawn;
    }

    function seasonShortfallSettled(uint256 seasonId) external view returns (bool) {
        return _s().seasonShortfallSettled[seasonId];
    }
}
