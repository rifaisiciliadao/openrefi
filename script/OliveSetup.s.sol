// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CampaignFactory} from "../src/CampaignFactory.sol";
import {Campaign} from "../src/Campaign.sol";
import {CampaignToken} from "../src/CampaignToken.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @title OliveSetup — Phase 1 of the full 2-actor lifecycle smoke on Base Sepolia
/// @notice Creates an "Olive IGP Sicily" campaign with a 30-minute season.
///         Alice (deployer/producer) buys + activates + stakes 70% of minted supply.
///         Bob buys (with a fresh 50 mUSDC mint) + stakes 30%. Both positions run
///         until Phase 2 (OliveFinish) is executed 30 minutes later.
///
/// Env required:
///   PRIVATE_KEY        — Alice (factory owner, campaign producer, staker A)
///   BOB_PRIVATE_KEY    — Bob (staker B)
///   FACTORY_ADDRESS    — upgraded factory proxy (V2)
///   USDC_ADDRESS       — MockUSDC (public mint enabled)
contract OliveSetup is Script {
    function run() external {
        uint256 alicePK = vm.envUint("PRIVATE_KEY");
        uint256 bobPK = vm.envUint("BOB_PRIVATE_KEY");
        CampaignFactory factory = CampaignFactory(vm.envAddress("FACTORY_ADDRESS"));
        MockUSDC usdc = MockUSDC(vm.envAddress("USDC_ADDRESS"));
        address alice = vm.addr(alicePK);
        address bob = vm.addr(bobPK);

        console.log("--- OliveSetup (30min season) ---");
        console.log("alice (producer) :", alice);
        console.log("bob (staker B)   :", bob);

        // ------------------------------------------------------------
        // Alice: relax floor, create campaign, buy to activate, stake.
        // ------------------------------------------------------------
        vm.startBroadcast(alicePK);

        if (factory.minSeasonDuration() > 30 minutes) {
            factory.setMinSeasonDuration(30 minutes);
            console.log("min season       : reduced to 30 min");
        }

        address campaignAddr = factory.createCampaign(
            CampaignFactory.CreateCampaignParams({
                producer: alice,
                tokenName: "Olive IGP Sicily",
                tokenSymbol: "OLIVE",
                yieldName: "Olive Yield",
                yieldSymbol: "oYIELD",
                // $0.144/token × 350k maxCap = $50,400 max raise
                // 10% yearly bps × 350k × $0.144 = $5,040 / yr at full raise
                pricePerToken: 0.144e18,
                minCap: 100_000e18,
                maxCap: 350_000e18,
                fundingDeadline: block.timestamp + 1 days,
                seasonDuration: 30 minutes,
                minProductClaim: 1e18,
                expectedAnnualHarvestUsd: 5_000e18,
                firstHarvestYear: 2030,
                coverageHarvests: 3
            })
        );
        Campaign campaign = Campaign(campaignAddr);

        // Fetch the 5 proxy addresses in one shot.
        uint256 idx = factory.getCampaignCount() - 1;
        (
            address cAddr,
            address ctAddr,
            address ytAddr,
            address svAddr,
            address hmAddr,
            /*producer*/
            ,
            /*createdAt*/
        ) = factory.campaigns(idx);

        console.log("campaign         :", cAddr);
        console.log("campaignToken    :", ctAddr);
        console.log("yieldToken       :", ytAddr);
        console.log("stakingVault     :", svAddr);
        console.log("harvestManager   :", hmAddr);

        // Accept USDC at 0.144 USDC per 1 OLIVE.
        campaign.addAcceptedToken(address(usdc), Campaign.PricingMode.Fixed, 144_000, address(0));

        // Alice buys 120,000 OLIVE → activates (>100k minCap).
        // 120_000 * 0.144 = 17,280 USDC = 17_280_000_000 (6-dec).
        usdc.approve(address(campaign), type(uint256).max);
        campaign.buy(address(usdc), 17_280_000_000);
        require(uint8(campaign.state()) == uint8(Campaign.State.Active), "Alice buy didn't activate");
        console.log("alice bought     : 120,000 OLIVE (state=Active, ~$17,280)");

        // v3 — Lock USDC as a 3-harvest yield reserve.
        // Sized for the FULL maxCap raise ($50,400 × 10% × 3 = $15,120) so
        // the coverage stays valid even after the campaign tops up. Locks
        // 15,000 USDC to round nicely; UI will show ~99% guarantee ratio
        // against current totalRaised.
        campaign.lockCollateral(15_000_000_000);
        console.log("collateral lock  : 15,000 mUSDC for 3 harvests");

        // Start season.
        campaign.startSeason(1);
        console.log("season 1 started :", block.timestamp);

        // Alice stakes all her OLIVE.
        CampaignToken ct = CampaignToken(ctAddr);
        StakingVault sv = StakingVault(svAddr);
        ct.approve(address(sv), type(uint256).max);
        uint256 alicePos = sv.stake(ct.balanceOf(alice));
        console.log("alice stake pos  :", alicePos);

        // Mint 10,000 mUSDC to Bob so he can buy.
        usdc.mint(bob, 10_000_000_000);
        console.log("minted 10,000 mUSDC to bob");

        vm.stopBroadcast();

        // ------------------------------------------------------------
        // Bob: buy 50,000 OLIVE (7,200 USDC) + stake.
        // ------------------------------------------------------------
        vm.startBroadcast(bobPK);

        IERC20(address(usdc)).approve(address(campaign), type(uint256).max);
        campaign.buy(address(usdc), 7_200_000_000);
        console.log("bob bought       : 50,000 OLIVE (~$7,200)");

        IERC20(address(ct)).approve(address(sv), type(uint256).max);
        uint256 bobPos = sv.stake(ct.balanceOf(bob));
        console.log("bob stake pos    :", bobPos);

        vm.stopBroadcast();

        console.log("--- setup done ---");
        console.log("Wait 30 min, then run OliveFinish / cast sequence");
        console.log("alice posId = 0, bob posId = 1");
    }
}
