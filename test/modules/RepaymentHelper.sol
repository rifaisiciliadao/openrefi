// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RepaymentModule} from "../../src/modules/RepaymentModule.sol";

library RepaymentHelper {
    function selectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](12);
        uint256 i;
        s[i++] = RepaymentModule.initializeRepayment.selector;
        s[i++] = RepaymentModule.initializeRepaymentByProducer.selector;
        s[i++] = RepaymentModule.fundPool.selector;
        s[i++] = RepaymentModule.withdrawUnusedPool.selector;
        s[i++] = RepaymentModule.setBonusPerCt.selector;
        s[i++] = RepaymentModule.redeem.selector;
        s[i++] = RepaymentModule.poolBalance.selector;
        s[i++] = RepaymentModule.bonusPerCt.selector;
        s[i++] = RepaymentModule.principalPerCt.selector;
        s[i++] = RepaymentModule.payoutPerCt.selector;
        s[i++] = RepaymentModule.claimedByUser.selector;
        s[i++] = RepaymentModule.quoteRepayment.selector;
    }
}
