// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CampaignFactory} from "../src/CampaignFactory.sol";
import {Campaign} from "../src/Campaign.sol";
import {CampaignToken} from "../src/CampaignToken.sol";
import {YieldToken} from "../src/YieldToken.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {HarvestManager} from "../src/HarvestManager.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {Deployer} from "./helpers/Deployer.sol";

contract AuditTest is Test {
    CampaignFactory factory;
    MockERC20 usdc;

    address owner = address(this);
    address producer = makeAddr("producer");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    Campaign campaign;
    CampaignToken campaignToken;
    YieldToken yieldToken;
    StakingVault stakingVault;
    HarvestManager harvestManager;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        factory = Deployer.deployProtocol(owner, feeRecipient, address(usdc), address(0));

        vm.prank(producer);
        factory.createCampaign(
            CampaignFactory.CreateCampaignParams({
                producer: producer,
                tokenName: "Olive",
                tokenSymbol: "OLIVE",
                yieldName: "oYield",
                yieldSymbol: "oY",
                pricePerToken: 0.144e18,
                minCap: 50_000e18,
                maxCap: 100_000e18,
                fundingDeadline: block.timestamp + 90 days,
                seasonDuration: 365 days,
                minProductClaim: 5e18,
                expectedAnnualHarvestUsd: 5_000e18,
                firstHarvestYear: 2030,
                coverageHarvests: 0
            })
        );

        (address c, address ct, address yt, address sv, address hm,,) = factory.campaigns(0);
        campaign = Campaign(c);
        campaignToken = CampaignToken(ct);
        yieldToken = YieldToken(yt);
        stakingVault = StakingVault(sv);
        harvestManager = HarvestManager(hm);

        vm.prank(producer);
        campaign.addAcceptedToken(address(usdc), Campaign.PricingMode.Fixed, 144000, address(0));

        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        vm.prank(alice);
        usdc.approve(address(campaign), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(campaign), type(uint256).max);
    }

    function _activateAndStartSeason() internal {
        vm.prank(alice);
        campaign.buy(address(usdc), 8_640_000_000); // 60k tokens → auto-activates
        vm.prank(alice);
        campaignToken.approve(address(stakingVault), type(uint256).max);
        vm.prank(producer);
        campaign.startSeason(1);
    }

    // --- CRITICAL: Cross-season yield isolation ---

    function test_noYieldLeakAcrossSeasons() public {
        _activateAndStartSeason();

        // Alice stakes in season 1
        vm.prank(alice);
        stakingVault.stake(10_000e18);

        // Pass 6 months
        vm.warp(block.timestamp + 180 days);

        // Alice earns yield in season 1
        uint256 yieldSeason1 = stakingVault.earned(0);
        assertGt(yieldSeason1, 0);

        // End season 1
        vm.prank(producer);
        campaign.endSeason();

        // Start season 2
        vm.prank(producer);
        campaign.startSeason(2);

        // Pass 6 more months in season 2
        vm.warp(block.timestamp + 180 days);

        // Alice's position is still in season 1 — she should NOT earn season 2 yield
        uint256 yieldAfterSeason2 = stakingVault.earned(0);
        assertEq(yieldAfterSeason2, yieldSeason1, "Yield should not grow in season 2 without restake");
    }

    function test_restakeEnablesNewSeasonYield() public {
        _activateAndStartSeason();

        vm.prank(alice);
        stakingVault.stake(10_000e18);

        vm.warp(block.timestamp + 365 days);

        // End season 1, start season 2
        vm.prank(producer);
        campaign.endSeason();

        uint256 yieldBeforeRestake = stakingVault.earned(0);

        vm.prank(producer);
        campaign.startSeason(2);

        // Restake into season 2
        vm.prank(alice);
        stakingVault.restake(0);

        // Pass time in season 2
        vm.warp(block.timestamp + 180 days);

        // Now should earn new yield
        uint256 yieldInSeason2 = stakingVault.earned(0);
        assertGt(yieldInSeason2, 0, "Should earn yield after restake");

        // And the season 1 yield was claimed during restake
        assertGt(yieldToken.balanceOf(alice), 0, "Season 1 yield should be claimed on restake");
    }

    // --- HIGH: Season reuse prevention ---

    function test_cannotReuseSeasonId() public {
        _activateAndStartSeason();

        vm.prank(producer);
        campaign.endSeason();

        // Try to reuse season 1
        vm.prank(producer);
        vm.expectRevert(StakingVault.SeasonAlreadyUsed.selector);
        campaign.startSeason(1);

        // Season 2 should work
        vm.prank(producer);
        campaign.startSeason(2);
    }

    // --- MEDIUM: Cannot restake in same season ---

    function test_cannotRestakeSameSeason() public {
        _activateAndStartSeason();

        vm.prank(alice);
        stakingVault.stake(10_000e18);

        vm.warp(block.timestamp + 30 days);

        // Try to restake in same season — should revert
        vm.prank(alice);
        vm.expectRevert(StakingVault.RestakeSameSeason.selector);
        stakingVault.restake(0);
    }

    // --- MEDIUM: setProtocolFeeRecipient validation ---

    function test_cannotSetZeroFeeRecipient() public {
        vm.expectRevert("Zero address");
        factory.setProtocolFeeRecipient(address(0));
    }

    // --- HIGH: USDC multi-claim ---

    function test_usdcMultiClaim() public {
        _activateAndStartSeason();

        vm.prank(alice);
        stakingVault.stake(10_000e18);

        // Pass full season
        vm.warp(block.timestamp + 365 days);

        // Claim yield
        vm.prank(alice);
        stakingVault.claimYield(0);
        uint256 aliceYield = yieldToken.balanceOf(alice);
        assertGt(aliceYield, 0);

        // End season
        vm.prank(producer);
        campaign.endSeason();

        // Report harvest
        vm.prank(producer);
        harvestManager.reportHarvest(1, 4200e18, bytes32(0), 210e18);

        // Alice redeems for USDC
        vm.prank(alice);
        harvestManager.redeemUSDC(1, aliceYield);

        // Producer deposits 50% of the remaining gross cap (2% of each deposit
        // is routed to feeRecipient → contract exposes `remainingDepositGross`).
        uint256 halfDeposit = harvestManager.remainingDepositGross(1) / 2;
        usdc.mint(producer, halfDeposit * 2);
        vm.prank(producer);
        usdc.approve(address(harvestManager), type(uint256).max);
        vm.prank(producer);
        harvestManager.depositUSDC(1, halfDeposit);

        // Alice claims partial
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        harvestManager.claimUSDC(1);
        uint256 firstClaim = usdc.balanceOf(alice) - aliceBefore;
        assertGt(firstClaim, 0);

        // Producer deposits the rest (up to remaining cap after first half)
        uint256 secondDeposit = harvestManager.remainingDepositGross(1);
        usdc.mint(producer, secondDeposit);
        vm.prank(producer);
        harvestManager.depositUSDC(1, secondDeposit);

        // Alice claims remainder
        aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        harvestManager.claimUSDC(1);
        uint256 secondClaim = usdc.balanceOf(alice) - aliceBefore;
        assertGt(secondClaim, 0, "Should be able to claim remaining after second deposit");

        // Total should approximately equal full amount
        (,,,,,,,, uint256 owed,,,) = harvestManager.seasonHarvests(1);
        assertApproxEqRel(firstClaim + secondClaim, owed / 1e12, 0.01e18);
    }
}
