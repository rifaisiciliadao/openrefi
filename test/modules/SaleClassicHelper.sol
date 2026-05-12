// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SaleClassicModule} from "../../src/modules/SaleClassicModule.sol";

/// @notice Lists every external selector exposed by SaleClassicModule.
///         Used by the test setup when registering the module's `kind`
///         in the registry. Must stay in sync with the module's external
///         surface — Solidity will silently route unregistered selectors
///         to the host fallback which then reverts with UnknownSelector.
library SaleClassicHelper {
    function selectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](28);
        uint256 i;
        // Init / admin
        s[i++] = SaleClassicModule.initializeSaleClassic.selector;
        s[i++] = SaleClassicModule.addAcceptedToken.selector;
        s[i++] = SaleClassicModule.removeAcceptedToken.selector;
        // Buy / sell-back / buyback
        s[i++] = SaleClassicModule.buy.selector;
        s[i++] = SaleClassicModule.sellBack.selector;
        s[i++] = SaleClassicModule.cancelSellBack.selector;
        s[i++] = SaleClassicModule.triggerBuyback.selector;
        s[i++] = SaleClassicModule.buyback.selector;
        s[i++] = SaleClassicModule.activateCampaign.selector;
        // Producer setters
        s[i++] = SaleClassicModule.setFundingDeadline.selector;
        s[i++] = SaleClassicModule.setMinCap.selector;
        s[i++] = SaleClassicModule.setMaxCap.selector;
        // Views
        s[i++] = SaleClassicModule.previewBuy.selector;
        s[i++] = SaleClassicModule.getPrice.selector;
        s[i++] = SaleClassicModule.getAcceptedTokens.selector;
        s[i++] = SaleClassicModule.getSellBackQueueDepth.selector;
        s[i++] = SaleClassicModule.tokenConfig.selector;
        s[i++] = SaleClassicModule.pricePerToken.selector;
        s[i++] = SaleClassicModule.minCap.selector;
        s[i++] = SaleClassicModule.maxCap.selector;
        s[i++] = SaleClassicModule.fundingDeadline.selector;
        s[i++] = SaleClassicModule.seasonDuration.selector;
        s[i++] = SaleClassicModule.fundingFeeBps.selector;
        s[i++] = SaleClassicModule.currentSupply.selector;
        s[i++] = SaleClassicModule.purchases.selector;
        s[i++] = SaleClassicModule.purchasedTokens.selector;
        s[i++] = SaleClassicModule.pendingSellBack.selector;
        s[i++] = SaleClassicModule.growMinter.selector;
    }
}
