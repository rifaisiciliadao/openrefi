// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * IGrowfiCampaignView — surface of GrowfiCampaign that other protocol contracts need.
 *
 * Used by:
 * - GrowfiTreasury (campaignToken/pricePerToken for floor; stakingVault/harvestManager for
 *   harvest claim; state/currentSupply/maxCap for auto-allocation rules; buy() to invest)
 * - GrowfiMinter (pricePerToken/minCap/maxCap for bonding curve)
 */
interface IGrowfiCampaignView {
    function campaignToken() external view returns (address);
    function pricePerToken() external view returns (uint256);
    function minCap() external view returns (uint256);
    function maxCap() external view returns (uint256);
    function currentSupply() external view returns (uint256);
    function stakingVault() external view returns (address);
    function harvestManager() external view returns (address);
    /// 0 = Funding, 1 = Active, 2 = Buyback, 3 = Ended
    function state() external view returns (uint8);
    function buy(address paymentToken, uint256 paymentAmount) external;
}
