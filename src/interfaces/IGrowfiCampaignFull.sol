// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CampaignStorage} from "../host/CampaignStorage.sol";
import {SaleClassicModule} from "../modules/SaleClassicModule.sol";
import {CollateralModule} from "../modules/CollateralModule.sol";

/// @title  IGrowfiCampaignFull
/// @notice Aggregate Solidity interface exposing the union of host
///         functions + default-module (sale + collateral) entrypoints.
///         The on-chain Campaign address routes module selectors through
///         its fallback into `delegatecall`. Casting an address to this
///         interface lets tests/clients call any function declared here
///         without per-call boilerplate.
interface IGrowfiCampaignFull {
    // --- Host: views ---
    function producer() external view returns (address);
    function factory() external view returns (address);
    function state() external view returns (CampaignStorage.State);
    function paused() external view returns (bool);
    function factoryBootstrap() external view returns (bool);
    function currentSeasonId() external view returns (uint256);
    function moduleTypeCount() external view returns (uint256);
    function moduleTypeAt(uint256) external view returns (bytes32);
    function selectorToType(bytes4) external view returns (bytes32);
    function moduleSlot(bytes32 moduleType)
        external
        view
        returns (address impl, bytes32 kind, string memory metadataURI, uint64 attachedAt, bool enabled);
    function campaignToken() external view returns (address);
    function yieldToken() external view returns (address);
    function stakingVault() external view returns (address);
    function harvestManager() external view returns (address);
    function usdc() external view returns (address);
    function protocolFeeRecipient() external view returns (address);

    // --- Host: producer admin ---
    function attachModule(bytes32 moduleType, bytes32 kind, address impl, string calldata metadataURI) external;
    function detachModule(bytes32 moduleType) external;
    function setModuleEnabled(bytes32 moduleType, bool enabled) external;
    function setPaused(bool paused_) external;
    function endCampaign() external;
    function startSeason() external;
    function endSeason() external;

    // --- SaleClassicModule: views ---
    function pricePerToken() external view returns (uint256);
    function minCap() external view returns (uint256);
    function maxCap() external view returns (uint256);
    function fundingDeadline() external view returns (uint256);
    function seasonDuration() external view returns (uint256);
    function fundingFeeBps() external view returns (uint256);
    function currentSupply() external view returns (uint256);
    function purchases(address user, address token) external view returns (uint256);
    function purchasedTokens(address user, address token) external view returns (uint256);
    function pendingSellBack(address user) external view returns (uint256);
    function growMinter() external view returns (address);
    function getAcceptedTokens() external view returns (address[] memory);
    function getSellBackQueueDepth() external view returns (uint256);
    function getPrice(address paymentToken, uint256 campaignAmount) external view returns (uint256);
    function previewBuy(address paymentToken, uint256 paymentAmount)
        external
        view
        returns (uint256 tokensOut, uint256 effectivePayment, uint256 oraclePrice, uint256 fundingFee);
    function tokenConfig(address token) external view returns (SaleClassicModule.TokenConfig memory);

    // --- SaleClassicModule: producer + buyer entrypoints ---
    function addAcceptedToken(
        address token,
        SaleClassicModule.PricingMode mode,
        uint256 fixedRate,
        address oracleFeed
    ) external;
    function removeAcceptedToken(address token) external;
    function buy(address paymentToken, uint256 paymentAmount) external;
    function sellBack(uint256 amount) external;
    function cancelSellBack() external;
    function triggerBuyback() external;
    function buyback(address paymentToken) external;
    function activateCampaign() external;
    function setFundingDeadline(uint256 newDeadline) external;
    function setMinCap(uint256 newMinCap) external;
    function setMaxCap(uint256 newMaxCap) external;

    // --- CollateralModule: views ---
    function expectedAnnualHarvestUsd() external view returns (uint256);
    function expectedAnnualHarvest() external view returns (uint256);
    function firstHarvestYear() external view returns (uint256);
    function coverageHarvests() external view returns (uint256);
    function collateralLocked() external view returns (uint256);
    function collateralDrawn() external view returns (uint256);
    function seasonShortfallSettled(uint256 seasonId) external view returns (bool);
    function maxCollateral() external view returns (uint256);
    function availableCollateral() external view returns (uint256);

    // --- CollateralModule: producer entrypoints ---
    function lockCollateral(uint256 amount) external;
    function depositUSDC(uint256 seasonId, uint256 walletCap) external;
    function settleSeasonShortfall(uint256 seasonId) external;
}
