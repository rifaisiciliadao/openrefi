// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
import {MockOracle} from "./helpers/MockOracle.sol";
import {Deployer} from "./helpers/Deployer.sol";

contract IntegrationTest is Test {
    GrowfiCampaignFactory factory;
    MockERC20 usdc;
    MockERC20 weth;
    MockOracle wethOracle;

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

    uint256 constant PRICE_PER_TOKEN = 0.144e18;
    uint256 constant MIN_CAP = 50_000e18;
    uint256 constant MAX_CAP = 100_000e18;
    uint256 constant SEASON_DURATION = 365 days;
    uint256 constant MIN_PRODUCT_CLAIM = 5e18;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped ETH", "WETH", 18);
        wethOracle = new MockOracle(2880e8, 8);

        factory = Deployer.deployProtocol(owner, feeRecipient, address(usdc), address(0));

        uint256 deadline = block.timestamp + 90 days;
        vm.prank(producer);
        factory.createCampaign(
            GrowfiCampaignFactory.CreateCampaignParams({
                producer: producer,
                campaignTokenName: "Olive Tree",
                campaignTokenSymbol: "OLIVE",
                yieldTokenName: "Olive Yield",
                yieldTokenSymbol: "oYIELD",
                minProductClaim: MIN_PRODUCT_CLAIM,
                sale: SaleClassicModule.InitParams({
                    pricePerToken: PRICE_PER_TOKEN,
                    minCap: MIN_CAP,
                    maxCap: MAX_CAP,
                    fundingDeadline: deadline,
                    seasonDuration: SEASON_DURATION,
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

    // --- Full Lifecycle Test ---

    function test_fullLifecycle() public {
        uint256 alicePayment = 8_640_000_000;
        vm.prank(alice);
        campaign.buy(address(usdc), alicePayment);

        assertEq(uint8(campaign.state()), uint8(CampaignStorage.State.Active));
        assertEq(campaignToken.balanceOf(alice), 60_000e18);

        vm.prank(alice);
        campaignToken.approve(address(stakingVault), type(uint256).max);

        vm.prank(producer);
        campaign.startSeason();

        vm.prank(alice);
        uint256 posId = stakingVault.stake(60_000e18);
        assertEq(posId, 0);
        assertEq(stakingVault.totalStaked(), 60_000e18);

        vm.warp(block.timestamp + 180 days);

        uint256 bobPayment = 2_880_000_000;
        vm.prank(bob);
        campaign.buy(address(usdc), bobPayment);
        assertEq(campaignToken.balanceOf(bob), 20_000e18);

        uint256 aliceYield = stakingVault.earned(posId);
        assertGt(aliceYield, 0, "Alice should have earned yield");

        vm.prank(alice);
        stakingVault.claimYield(posId);
        assertGt(yieldToken.balanceOf(alice), 0, "Alice should have $YIELD");

        vm.warp(block.timestamp + 185 days);

        vm.prank(producer);
        campaign.endSeason();

        vm.prank(alice);
        stakingVault.claimYield(posId);
        uint256 aliceTotalYield = yieldToken.balanceOf(alice);
        assertGt(aliceTotalYield, 0);
    }

    // --- Buyback Test (Failed Campaign) ---

    function test_buybackOnFailedCampaign() public {
        uint256 payment = 4_320_000_000;
        vm.prank(alice);
        campaign.buy(address(usdc), payment);

        assertEq(uint8(campaign.state()), uint8(CampaignStorage.State.Funding));
        assertEq(campaignToken.balanceOf(alice), 30_000e18);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.warp(block.timestamp + 91 days);

        campaign.triggerBuyback();
        assertEq(uint8(campaign.state()), uint8(CampaignStorage.State.Buyback));

        vm.prank(alice);
        campaign.buyback(address(usdc));

        uint256 fundingFee = payment * 300 / 10_000;
        assertEq(campaignToken.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + payment - fundingFee);
    }

    // --- Sell-Back Queue Test ---

    function test_sellBackQueue() public {
        uint256 alicePayment = 8_640_000_000;
        vm.prank(alice);
        campaign.buy(address(usdc), alicePayment);

        vm.prank(producer);
        campaign.startSeason();

        vm.prank(alice);
        campaignToken.approve(address(stakingVault), type(uint256).max);
        vm.prank(alice);
        stakingVault.stake(50_000e18);

        vm.warp(block.timestamp + 180 days);

        vm.prank(alice);
        stakingVault.unstake(0);
        uint256 aliceTokens = campaignToken.balanceOf(alice);
        assertGt(aliceTokens, 0);

        vm.prank(alice);
        campaignToken.approve(address(campaign), type(uint256).max);
        vm.prank(alice);
        campaign.sellBack(aliceTokens);

        assertEq(campaign.getSellBackQueueDepth(), aliceTokens);

        uint256 bobPayment = 2_880_000_000;
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(bob);
        campaign.buy(address(usdc), bobPayment);

        assertGt(usdc.balanceOf(alice), aliceUsdcBefore);
    }

    // --- Dynamic Yield Rate Test ---

    function test_dynamicYieldRate() public {
        assertEq(stakingVault.currentYieldRate(), 5e18);

        uint256 payment = 7_200_000_000; // 50k tokens
        vm.prank(alice);
        campaign.buy(address(usdc), payment);

        vm.prank(producer);
        campaign.startSeason();

        vm.prank(alice);
        campaignToken.approve(address(stakingVault), type(uint256).max);
        vm.prank(alice);
        stakingVault.stake(50_000e18);

        assertEq(stakingVault.currentYieldRate(), 3e18);
    }

    // --- Penalty Test ---

    function test_earlyUnstakePenalty() public {
        uint256 payment = 8_640_000_000;
        vm.prank(alice);
        campaign.buy(address(usdc), payment);

        vm.prank(producer);
        campaign.startSeason();

        vm.prank(alice);
        campaignToken.approve(address(stakingVault), type(uint256).max);
        vm.prank(alice);
        stakingVault.stake(10_000e18);

        vm.warp(block.timestamp + 91.25 days);
        vm.prank(alice);
        stakingVault.unstake(0);

        uint256 returned = campaignToken.balanceOf(alice);
        uint256 unstaked = returned - 50_000e18;
        assertApproxEqRel(unstaked, 2_500e18, 0.01e18);
    }
}
