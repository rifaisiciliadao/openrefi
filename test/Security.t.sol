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

contract SecurityTest is Test {
    GrowfiCampaignFactory factory;
    MockERC20 usdc;
    MockERC20 weth;

    address owner = address(this);
    address producer = makeAddr("producer");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    IGrowfiCampaignFull campaign;
    GrowfiCampaignToken campaignToken;
    GrowfiStakingVault stakingVault;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
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

        (address ca, address ct,, address sv,,,) = factory.campaigns(0);
        campaign = IGrowfiCampaignFull(payable(ca));
        campaignToken = GrowfiCampaignToken(ct);
        stakingVault = GrowfiStakingVault(sv);

        vm.prank(producer);
        campaign.addAcceptedToken(address(usdc), SaleClassicModule.PricingMode.Fixed, 144000, address(0));

        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        vm.prank(alice);
        usdc.approve(address(campaign), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(campaign), type(uint256).max);
    }

    // --- Season management via producer ---

    function test_producerCanStartSeason() public {
        vm.prank(alice);
        campaign.buy(address(usdc), 8_640_000_000);

        vm.prank(producer);
        campaign.startSeason();

        (,,,,, bool active,) = stakingVault.seasons(1);
        assertTrue(active);
    }

    function test_producerCanEndSeason() public {
        vm.prank(alice);
        campaign.buy(address(usdc), 8_640_000_000);

        vm.prank(producer);
        campaign.startSeason();

        vm.prank(producer);
        campaign.endSeason();

        (,,,,, bool active,) = stakingVault.seasons(1);
        assertFalse(active);
    }

    function test_nonProducerCannotStartSeason() public {
        vm.prank(alice);
        campaign.buy(address(usdc), 8_640_000_000);

        vm.prank(alice);
        vm.expectRevert(GrowfiCampaign.OnlyProducer.selector);
        campaign.startSeason();
    }

    function test_cannotStartSeasonInFunding() public {
        vm.prank(producer);
        vm.expectRevert(GrowfiCampaign.InvalidState.selector);
        campaign.startSeason();
    }

    // --- Multi-token buyback ---

    function test_multiTokenBuyback() public {
        vm.prank(producer);
        campaign.addAcceptedToken(address(weth), SaleClassicModule.PricingMode.Fixed, 0.001e18, address(0));

        vm.prank(alice);
        campaign.buy(address(usdc), 2_880_000_000);

        weth.mint(alice, 10e18);
        vm.prank(alice);
        weth.approve(address(campaign), type(uint256).max);
        vm.prank(alice);
        campaign.buy(address(weth), 10e18);

        vm.warp(block.timestamp + 91 days);
        campaign.triggerBuyback();

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceWethBefore = weth.balanceOf(alice);

        uint256 usdcFee = 2_880_000_000 * 300 / 10_000;
        vm.prank(alice);
        campaign.buyback(address(usdc));
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + 2_880_000_000 - usdcFee);

        uint256 wethFee = 10e18 * 300 / 10_000;
        vm.prank(alice);
        campaign.buyback(address(weth));
        assertEq(weth.balanceOf(alice), aliceWethBefore + 10e18 - wethFee);

        assertEq(campaignToken.balanceOf(alice), 0);
    }

    // --- Emergency pause from factory ---

    function test_factoryCanPauseCampaign() public {
        factory.pauseCampaign(0);

        vm.prank(alice);
        vm.expectRevert();
        campaign.buy(address(usdc), 1_000_000);
    }

    function test_factoryCanUnpauseCampaign() public {
        factory.pauseCampaign(0);
        factory.unpauseCampaign(0);

        vm.prank(alice);
        campaign.buy(address(usdc), 1_440_000);
        assertGt(campaignToken.balanceOf(alice), 0);
    }

    function test_nonOwnerCannotPause() public {
        vm.prank(alice);
        vm.expectRevert();
        factory.pauseCampaign(0);
    }

    // --- Input validation ---

    function test_cannotCreateCampaignWithZeroPrice() public {
        vm.prank(producer);
        vm.expectRevert("Zero price");
        factory.createCampaign(_paramsOverride(0, 1000e18, 10000e18, block.timestamp + 30 days, 365 days));
    }

    function test_cannotCreateCampaignMinGtMax() public {
        vm.prank(producer);
        vm.expectRevert("minCap > maxCap");
        factory.createCampaign(_paramsOverride(1e18, 10000e18, 1000e18, block.timestamp + 30 days, 365 days));
    }

    function test_cannotCreateCampaignPastDeadline() public {
        vm.prank(producer);
        vm.expectRevert("Deadline in past");
        factory.createCampaign(_paramsOverride(1e18, 1000e18, 10000e18, block.timestamp, 365 days));
    }

    function test_cannotCreateCampaignShortSeason() public {
        vm.prank(producer);
        vm.expectRevert("Season too short");
        factory.createCampaign(_paramsOverride(1e18, 1000e18, 10000e18, block.timestamp + 30 days, 1 days));
    }

    // --- fixedRate / oracle validation ---

    function test_cannotAddTokenWithZeroFixedRate() public {
        vm.prank(producer);
        vm.expectRevert("Zero fixedRate");
        campaign.addAcceptedToken(address(weth), SaleClassicModule.PricingMode.Fixed, 0, address(0));
    }

    function test_cannotAddTokenWithZeroOracleAddress() public {
        vm.prank(producer);
        vm.expectRevert(SaleClassicModule.ZeroAddress.selector);
        campaign.addAcceptedToken(address(weth), SaleClassicModule.PricingMode.Oracle, 0, address(0));
    }

    // --- No purchases tracked in Active state ---

    function test_noPurchaseTrackingInActiveState() public {
        vm.prank(alice);
        campaign.buy(address(usdc), 8_640_000_000);
        assertEq(uint8(campaign.state()), uint8(CampaignStorage.State.Active));

        vm.prank(bob);
        campaign.buy(address(usdc), 1_440_000);

        assertEq(campaign.purchases(bob, address(usdc)), 0);
    }

    // --- Helpers ---

    function _paramsOverride(
        uint256 price,
        uint256 minC,
        uint256 maxC,
        uint256 deadline,
        uint256 seasonDur
    ) internal view returns (GrowfiCampaignFactory.CreateCampaignParams memory) {
        return GrowfiCampaignFactory.CreateCampaignParams({
            producer: producer,
            campaignTokenName: "T",
            campaignTokenSymbol: "T",
            yieldTokenName: "Y",
            yieldTokenSymbol: "Y",
            minProductClaim: 1e18,
            sale: SaleClassicModule.InitParams({
                pricePerToken: price,
                minCap: minC,
                maxCap: maxC,
                fundingDeadline: deadline,
                seasonDuration: seasonDur,
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
        });
    }
}
