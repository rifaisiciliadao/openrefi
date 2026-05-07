// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IGrowfiHarvestManagerMin {
    function redeemUSDC(uint256 seasonId, uint256 yieldAmount) external;
    function claimUSDC(uint256 seasonId) external;
}
