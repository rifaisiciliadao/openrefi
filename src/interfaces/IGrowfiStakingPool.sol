// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IGrowfiStakingPool {
    /// @notice Treasury notifies the pool that USDC rewards have been transferred in.
    ///         The pool updates its accumulator so stakers can claim their pro-rata share.
    function notifyReward(uint256 amount) external;
}
