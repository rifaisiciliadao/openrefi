// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal HarvestManager mock used by CollateralModule tests.
///         Implements the surface (`seasonHarvests`, `remainingDepositGross`,
///         `depositFromCollateral`) without the full v3 logic.
contract MockHarvestManager {
    using SafeERC20 for IERC20;

    struct SeasonHarvest {
        bytes32 merkleRoot;
        uint256 totalHarvestValueUSD;
        uint256 totalYieldSupply;
        uint256 totalProductUnits;
        uint256 claimStart;
        uint256 claimEnd;
        uint256 usdcDeadline;
        uint256 usdcDeposited; // 18-dec internal scale
        uint256 usdcOwed; // 18-dec internal scale
        uint256 protocolFeeCollected;
        uint256 protocolFeeTransferred;
        bool reported;
    }

    mapping(uint256 => SeasonHarvest) public seasonHarvests;
    address public campaign;
    IERC20 public immutable usdc;
    uint256 public constant FEE_BPS = 200; // 2%

    error OnlyCampaign();

    constructor(address usdc_) {
        usdc = IERC20(usdc_);
    }

    function setCampaign(address c) external {
        campaign = c;
    }

    /// @notice Test helper: pre-set a reported season with a given USDC obligation.
    function reportSeason(uint256 seasonId, uint256 usdcOwed18, uint256 deadline) external {
        SeasonHarvest storage h = seasonHarvests[seasonId];
        h.reported = true;
        h.usdcOwed = usdcOwed18;
        h.usdcDeadline = deadline;
        h.claimEnd = deadline;
    }

    function remainingDepositGross(uint256 seasonId) external view returns (uint256) {
        SeasonHarvest storage h = seasonHarvests[seasonId];
        if (h.usdcDeposited >= h.usdcOwed) return 0;
        uint256 netBps = 10_000 - FEE_BPS;
        uint256 poolMax6 = (h.usdcOwed - h.usdcDeposited) / 1e12;
        return poolMax6 * 10_000 / netBps;
    }

    function depositFromCollateral(uint256 seasonId, uint256 amount) external {
        if (msg.sender != campaign) revert OnlyCampaign();
        SeasonHarvest storage h = seasonHarvests[seasonId];
        require(h.reported, "Not reported");
        require(amount > 0, "Zero");
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        uint256 feePortion = amount * FEE_BPS / 10_000;
        uint256 poolPortion = amount - feePortion;
        h.usdcDeposited += poolPortion * 1e12;
        h.protocolFeeTransferred += feePortion;
    }
}
