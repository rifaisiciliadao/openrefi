// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * IGrowfiTreasury — the minimum surface the GrowfiToken needs from the Treasury.
 *
 * The full Treasury contract has many more functions (allocation, redemption, staking, etc.),
 * but this interface only declares what is consumed by the token's primary-sale path.
 */
interface IGrowfiTreasury {
    /// @notice Floor price in USD-18-dec per 1e18 GROW. Returns 0 if treasury is empty
    ///         or has no circulating-supply context (deploy time, drained, etc.).
    ///         Stablecoin balances priced at LIVE Chainlink USD value (not 1:1 assumption);
    ///         depegged/stale entries are excluded conservatively. CampaignToken balances
    ///         only count if the owning campaign is in `Active` state.
    function intrinsicFloorPrice() external view returns (uint256);

    /// @notice Whether `token` is in the multisig-controlled allowlist of accepted stablecoins.
    function isAcceptedStablecoin(address token) external view returns (bool);

    /// @notice Scale factor to convert this stablecoin's raw amount to USD-18-dec.
    ///         e.g., 1e12 for 6-dec USDC/USDT, 1 for 18-dec DAI. 0 if not accepted.
    function stablecoinScale(address token) external view returns (uint256);

    /// @notice Live USD price of an accepted stablecoin in 1e18 fixed-point (e.g. $1.00 = 1e18).
    ///         Reverts if the stablecoin isn't allowlisted, or its Chainlink feed is stale,
    ///         negative, or outside the configured depeg bands.
    function getStablecoinPriceUsd18(address token) external view returns (uint256);

    /// @notice Spread `totalAmount` of `paymentToken` across all tracked Active campaigns.
    ///         Auto-fired by `GrowfiToken.buy` when the multisig has automation enabled.
    function allocateAcrossTracked(address paymentToken, uint256 totalAmount) external;
}
