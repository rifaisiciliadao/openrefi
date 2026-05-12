// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {GrowfiCampaignFactory} from "../src/GrowfiCampaignFactory.sol";
import {GrowfiCampaign} from "../src/GrowfiCampaign.sol";
import {CampaignStorage} from "../src/host/CampaignStorage.sol";
import {IGrowfiCampaignFull} from "../src/interfaces/IGrowfiCampaignFull.sol";
import {SaleClassicModule} from "../src/modules/SaleClassicModule.sol";
import {CollateralModule} from "../src/modules/CollateralModule.sol";
import {GrowfiCampaignToken} from "../src/GrowfiCampaignToken.sol";
import {GrowfiYieldToken} from "../src/GrowfiYieldToken.sol";
import {GrowfiStakingVault} from "../src/GrowfiStakingVault.sol";
import {GrowfiHarvestManager} from "../src/GrowfiHarvestManager.sol";

import {MockERC20} from "./helpers/MockERC20.sol";
import {Deployer} from "./helpers/Deployer.sol";

contract AuditTest is Test {
    GrowfiCampaignFactory factory;
    MockERC20 usdc;

    address owner = address(this);
    address producer = makeAddr("producer");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    IGrowfiCampaignFull campaign;
    GrowfiCampaignToken campaignToken;
    GrowfiYieldToken yieldToken;
    GrowfiStakingVault stakingVault;
    GrowfiHarvestManager harvestManager;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        factory = Deployer.deployProtocol(owner, feeRecipient, address(usdc), address(0));

        vm.prank(producer);
        factory.createCampaign(
            GrowfiCampaignFactory.CreateCampaignParams({
                producer: producer,
                campaignTokenName: "Olive",
                campaignTokenSymbol: "OLIVE",
                yieldTokenName: "oYield",
                yieldTokenSymbol: "oY",
                minProductClaim: 5e18,
                sale: SaleClassicModule.InitParams({
                    pricePerToken: 0.144e18,
                    minCap: 50_000e18,
                    maxCap: 100_000e18,
                    fundingDeadline: block.timestamp + 90 days,
                    seasonDuration: 365 days,
                    fundingFeeBps: 0,
                    sequencerUptimeFeed: address(0),
                    growMinter: address(0)
                }),
                collateral: CollateralModule.InitParams({
                    expectedAnnualHarvestUsd: 5_000e18,
                    expectedAnnualHarvest: 1_000e18,
                    firstHarvestYear: 2030,
                    coverageHarvests: 0
                })
            })
        );

        (address c, address ct, address yt, address sv, address hm,,) = factory.campaigns(0);
        campaign = IGrowfiCampaignFull(payable(c));
        campaignToken = GrowfiCampaignToken(ct);
        yieldToken = GrowfiYieldToken(yt);
        stakingVault = GrowfiStakingVault(sv);
        harvestManager = GrowfiHarvestManager(hm);

        vm.prank(producer);
        campaign.addAcceptedToken(address(usdc), SaleClassicModule.PricingMode.Fixed, 144000, address(0));

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
        campaign.startSeason();
    }

    // --- CRITICAL: Cross-season yield isolation ---

    function test_noYieldLeakAcrossSeasons() public {
        _activateAndStartSeason();

        vm.prank(alice);
        stakingVault.stake(10_000e18);

        vm.warp(block.timestamp + 180 days);

        uint256 yieldSeason1 = stakingVault.earned(0);
        assertGt(yieldSeason1, 0);

        vm.prank(producer);
        campaign.endSeason();

        vm.prank(producer);
        campaign.startSeason();

        vm.warp(block.timestamp + 180 days);

        uint256 yieldAfterSeason2 = stakingVault.earned(0);
        assertEq(yieldAfterSeason2, yieldSeason1, "Yield should not grow in season 2 without restake");
    }

    function test_restakeEnablesNewSeasonYield() public {
        _activateAndStartSeason();

        vm.prank(alice);
        stakingVault.stake(10_000e18);

        vm.warp(block.timestamp + 365 days);

        vm.prank(producer);
        campaign.endSeason();

        vm.prank(producer);
        campaign.startSeason();

        vm.prank(alice);
        stakingVault.restake(0);

        vm.warp(block.timestamp + 180 days);

        uint256 yieldInSeason2 = stakingVault.earned(0);
        assertGt(yieldInSeason2, 0, "Should earn yield after restake");
        assertGt(yieldToken.balanceOf(alice), 0, "Season 1 yield should be claimed on restake");
    }

    // --- HIGH: Season reuse prevention ---

    function test_cannotReuseSeasonId() public {
        _activateAndStartSeason();

        vm.prank(producer);
        campaign.endSeason();

        // The host auto-increments currentSeasonId, so it's impossible to
        // re-use a previous id. Starting the next season must yield id=2
        // (the StakingVault rejects re-use at its level too).
        vm.prank(producer);
        campaign.startSeason();
        assertEq(campaign.currentSeasonId(), 2);
    }

    // --- MEDIUM: Cannot restake in same season ---

    function test_cannotRestakeSameSeason() public {
        _activateAndStartSeason();

        vm.prank(alice);
        stakingVault.stake(10_000e18);

        vm.warp(block.timestamp + 30 days);

        vm.prank(alice);
        vm.expectRevert(GrowfiStakingVault.RestakeSameSeason.selector);
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

        vm.warp(block.timestamp + 365 days);

        vm.prank(alice);
        stakingVault.claimYield(0);
        uint256 aliceYield = yieldToken.balanceOf(alice);
        assertGt(aliceYield, 0);

        vm.prank(producer);
        campaign.endSeason();

        vm.prank(producer);
        harvestManager.reportHarvest(1, 4200e18, bytes32(0), 210e18);

        vm.prank(alice);
        harvestManager.redeemUSDC(1, aliceYield);

        uint256 halfDeposit = harvestManager.remainingDepositGross(1) / 2;
        usdc.mint(producer, halfDeposit * 2);
        vm.prank(producer);
        usdc.approve(address(campaign), type(uint256).max);
        vm.prank(producer);
        campaign.depositUSDC(1, halfDeposit);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        harvestManager.claimUSDC(1);
        uint256 firstClaim = usdc.balanceOf(alice) - aliceBefore;
        assertGt(firstClaim, 0);

        uint256 secondDeposit = harvestManager.remainingDepositGross(1);
        usdc.mint(producer, secondDeposit);
        vm.prank(producer);
        campaign.depositUSDC(1, secondDeposit);

        aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        harvestManager.claimUSDC(1);
        uint256 secondClaim = usdc.balanceOf(alice) - aliceBefore;
        assertGt(secondClaim, 0, "Should be able to claim remaining after second deposit");

        (,,,,,,,, uint256 owed,,,) = harvestManager.seasonHarvests(1);
        assertApproxEqRel(firstClaim + secondClaim, owed / 1e12, 0.01e18);
    }
}
