// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CampaignFactory} from "../src/CampaignFactory.sol";
import {Campaign} from "../src/Campaign.sol";
import {CampaignToken} from "../src/CampaignToken.sol";
import {StakingVault} from "../src/StakingVault.sol";

/// @title SmokeTest1h — creates a 1-hour-season campaign, activates, stakes
/// @notice After this runs, user waits ≥1 hour and can then call:
///         - campaign.endSeason() (as producer)
///         - harvestManager.reportHarvest(1, valueUSD, merkleRoot, units)
///         - stakingVault.claimYield(positionId)
///         to complete the full lifecycle.
///
/// Env required:
///   PRIVATE_KEY      — producer/buyer/staker (single wallet for smoke)
///   FACTORY_ADDRESS  — deployed factory proxy (V2)
///   USDC_ADDRESS     — MockUSDC
contract SmokeTest1h is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        CampaignFactory factory = CampaignFactory(vm.envAddress("FACTORY_ADDRESS"));
        IERC20 usdc = IERC20(vm.envAddress("USDC_ADDRESS"));
        address me = vm.addr(pk);

        console.log("--- SmokeTest1h ---");
        console.log("actor            :", me);
        console.log("factory          :", address(factory));
        console.log("minSeasonDuration:", factory.minSeasonDuration());

        vm.startBroadcast(pk);

        // 1. Create campaign with seasonDuration = 1 hour. minCap deliberately low so a single
        //    buy triggers auto-activation.
        address campaignAddr = factory.createCampaign(
            CampaignFactory.CreateCampaignParams({
                producer: me,
                tokenName: "Fast Olive",
                tokenSymbol: "FAST",
                yieldName: "Fast Yield",
                yieldSymbol: "fY",
                pricePerToken: 0.144e18,
                minCap: 100e18, // 100 FAST
                maxCap: 1_000e18,
                fundingDeadline: block.timestamp + 1 days,
                seasonDuration: 1 hours,
                minProductClaim: 1e18,
                expectedAnnualHarvestUsd: 5_000e18,
                firstHarvestYear: 2030,
                coverageHarvests: 0
            })
        );
        console.log("campaign         :", campaignAddr);
        Campaign campaign = Campaign(campaignAddr);

        // 2. Add USDC as accepted token.
        campaign.addAcceptedToken(address(usdc), Campaign.PricingMode.Fixed, 144_000, address(0));

        // 3. Buy enough to reach minCap (auto-activates). minCap = 100e18 FAST.
        //    payment = 100e18 * 144000 / 1e18 = 14_400_000 (= 14.4 USDC, 6-dec)
        usdc.approve(address(campaign), type(uint256).max);
        uint256 payment = 15_000_000; // 15 USDC, safely over minCap
        campaign.buy(address(usdc), payment);
        require(uint8(campaign.state()) == uint8(Campaign.State.Active), "not activated");
        console.log("state=Active     : OK");

        // 4. Start season 1.
        campaign.startSeason(1);
        console.log("season 1 started :", block.timestamp);

        // 5. Stake all FAST tokens.
        CampaignToken ct = CampaignToken(campaign.campaignToken());
        StakingVault sv = StakingVault(address(campaign.stakingVault()));
        uint256 fastBalance = ct.balanceOf(me);
        ct.approve(address(sv), type(uint256).max);
        uint256 positionId = sv.stake(fastBalance);

        vm.stopBroadcast();

        console.log("staked           :", fastBalance, "FAST wei");
        console.log("positionId       :", positionId);
        console.log("stakingVault     :", address(sv));
        console.log("campaignToken    :", address(ct));
        console.log("--- done ---");
        console.log("Wait >=1 hour, then (as producer):");
        console.log("  campaign.endSeason()");
        console.log("  harvestManager.reportHarvest(1, valueUSD, root, units)");
        console.log("Then (as staker) claim:");
        console.log("  stakingVault.claimYield(positionId)");
    }
}
