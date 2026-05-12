// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal surface used by modules to force-unstake a position
///         on behalf of its owner. The Campaign (delegate-called by the
///         module) is the only authorized caller of the underlying
///         `forceUnstake`, gated `onlyCampaign` on the vault side.
interface IGrowfiStakingVaultMinV4 {
    function forceUnstake(uint256 positionId) external;
    function positions(uint256 positionId)
        external
        view
        returns (
            address owner,
            uint256 amount,
            uint256 startTime,
            uint256 rewardPerTokenPaid,
            uint256 seasonId,
            bool active
        );
}
