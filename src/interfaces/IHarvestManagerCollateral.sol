// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal surface of GrowfiHarvestManager used by the
///         CollateralModule. Avoids importing the full HM contract.
interface IHarvestManagerCollateral {
    function depositFromCollateral(uint256 seasonId, uint256 amount) external;
    function remainingDepositGross(uint256 seasonId) external view returns (uint256);

    /// @notice Returns the SeasonHarvest fields by index. The CollateralModule
    ///         reads `usdcDeadline` (index 6) and `reported` (index 11).
    function seasonHarvests(uint256 seasonId)
        external
        view
        returns (
            bytes32 merkleRoot,
            uint256 totalHarvestValueUSD,
            uint256 totalYieldSupply,
            uint256 totalProductUnits,
            uint256 claimStart,
            uint256 claimEnd,
            uint256 usdcDeadline,
            uint256 usdcDeposited,
            uint256 usdcOwed,
            uint256 protocolFeeCollected,
            uint256 protocolFeeTransferred,
            bool reported
        );
}
