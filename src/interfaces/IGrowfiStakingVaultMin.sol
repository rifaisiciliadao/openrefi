// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IGrowfiStakingVaultMin {
    function stake(uint256 amount) external returns (uint256 positionId);
    function claimYield(uint256 positionId) external;
    function yieldToken() external view returns (address);
}
