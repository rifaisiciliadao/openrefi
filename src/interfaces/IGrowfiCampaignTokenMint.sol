// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interface to the GrowfiCampaignToken mint/burn surface.
///         Both functions are gated `onlyCampaign` / `onlyCampaignOrVault`
///         on the token side; modules invoke them from delegatecall
///         context where `msg.sender` to the token is the Campaign.
interface IGrowfiCampaignTokenMint {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}
