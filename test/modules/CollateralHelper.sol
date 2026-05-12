// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CollateralModule} from "../../src/modules/CollateralModule.sol";

library CollateralHelper {
    function selectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](13);
        uint256 i;
        s[i++] = CollateralModule.initializeCollateral.selector;
        s[i++] = CollateralModule.lockCollateral.selector;
        s[i++] = CollateralModule.depositUSDC.selector;
        s[i++] = CollateralModule.settleSeasonShortfall.selector;
        s[i++] = CollateralModule.maxCollateral.selector;
        s[i++] = CollateralModule.availableCollateral.selector;
        s[i++] = CollateralModule.expectedAnnualHarvestUsd.selector;
        s[i++] = CollateralModule.expectedAnnualHarvest.selector;
        s[i++] = CollateralModule.firstHarvestYear.selector;
        s[i++] = CollateralModule.coverageHarvests.selector;
        s[i++] = CollateralModule.collateralLocked.selector;
        s[i++] = CollateralModule.collateralDrawn.selector;
        s[i++] = CollateralModule.seasonShortfallSettled.selector;
    }
}
