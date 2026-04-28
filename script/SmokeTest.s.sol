// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CampaignFactory} from "../src/CampaignFactory.sol";
import {Campaign} from "../src/Campaign.sol";
import {CampaignToken} from "../src/CampaignToken.sol";

/// @title SmokeTest — end-to-end happy-path check against a live deployment
/// @notice Creates a campaign, adds mUSDC as accepted token, buys a small
///         amount, asserts state. Exits non-zero on any mismatch.
///
/// Env required:
///   PRIVATE_KEY       — producer / buyer (same address for the smoke)
///   FACTORY_ADDRESS   — deployed CampaignFactory proxy
///   USDC_ADDRESS      — MockUSDC address
contract SmokeTest is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        CampaignFactory factory = CampaignFactory(vm.envAddress("FACTORY_ADDRESS"));
        IERC20 usdc = IERC20(vm.envAddress("USDC_ADDRESS"));
        address me = vm.addr(pk);

        console.log("--- Smoke Test ---");
        console.log("actor     :", me);
        console.log("factory   :", address(factory));
        console.log("usdc      :", address(usdc));

        vm.startBroadcast(pk);

        // 1. createCampaign
        address campaignAddr = factory.createCampaign(
            CampaignFactory.CreateCampaignParams({
                producer: me,
                tokenName: "Smoke Olive",
                tokenSymbol: "SMOKE",
                yieldName: "Smoke Yield",
                yieldSymbol: "sY",
                pricePerToken: 0.144e18,
                minCap: 10_000e18,
                maxCap: 100_000e18,
                fundingDeadline: block.timestamp + 90 days,
                seasonDuration: 180 days,
                minProductClaim: 5e18,
                expectedYearlyReturnBps: 1000,
                expectedFirstYearHarvest: 1e18,
                coverageHarvests: 0
            })
        );
        require(factory.isCampaign(campaignAddr), "factory: not registered");
        console.log("campaign  :", campaignAddr);

        Campaign campaign = Campaign(campaignAddr);

        // 2. addAcceptedToken (USDC fixed rate: 0.144 USDC per 1 $CAMPAIGN)
        campaign.addAcceptedToken(address(usdc), Campaign.PricingMode.Fixed, 144_000, address(0));

        // 3. approve + buy (1 USDC → ~6.944 SMOKE tokens)
        usdc.approve(address(campaign), type(uint256).max);
        uint256 paymentAmount = 1_000_000; // 1 USDC (6-dec)
        uint256 balanceBefore = CampaignToken(campaign.campaignToken()).balanceOf(me);
        campaign.buy(address(usdc), paymentAmount);
        uint256 balanceAfter = CampaignToken(campaign.campaignToken()).balanceOf(me);
        uint256 delta = balanceAfter - balanceBefore;
        console.log("bought    :", delta, "SMOKE (wei)");

        // Expected: paymentAmount * 1e18 / fixedRate = 1e6 * 1e18 / 144000 = 6.944e18
        require(delta > 6.9e18 && delta < 7.0e18, "buy: unexpected mint amount");

        vm.stopBroadcast();

        console.log("--- done ---");
        console.log("campaign       =", campaignAddr);
        console.log("campaignToken  =", address(CampaignToken(campaign.campaignToken())));
        console.log("stakingVault   =", address(campaign.stakingVault()));
    }
}
