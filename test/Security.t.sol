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

contract SecurityTest is Test {
    CampaignFactory factory;
    MockERC20 usdc;
    MockERC20 weth;

    address owner = address(this);
    address producer = makeAddr("producer");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    Campaign campaign;
    CampaignToken campaignToken;
    StakingVault stakingVault;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
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
                minProductClaim: 5e18
            })
        );

        (address ca, address ct,, address sv,,,) = factory.campaigns(0);
        campaign = Campaign(ca);
        campaignToken = CampaignToken(ct);
        stakingVault = StakingVault(sv);

        vm.prank(producer);
        campaign.addAcceptedToken(address(usdc), Campaign.PricingMode.Fixed, 144000, address(0));

        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        vm.prank(alice);
        usdc.approve(address(campaign), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(campaign), type(uint256).max);
    }

    // --- Fix #1: Season management via producer ---

    function test_producerCanStartSeason() public {
        // Activate campaign first
        vm.prank(alice);
        campaign.buy(address(usdc), 8_640_000_000);

        vm.prank(producer);
        campaign.startSeason(1);

        (,,,,, bool active,) = stakingVault.seasons(1);
        assertTrue(active);
    }

    function test_producerCanEndSeason() public {
        vm.prank(alice);
        campaign.buy(address(usdc), 8_640_000_000);

        vm.prank(producer);
        campaign.startSeason(1);

        vm.prank(producer);
        campaign.endSeason();

        (,,,,, bool active,) = stakingVault.seasons(1);
        assertFalse(active);
    }

    function test_nonProducerCannotStartSeason() public {
        vm.prank(alice);
        campaign.buy(address(usdc), 8_640_000_000);

        vm.prank(alice);
        vm.expectRevert(Campaign.OnlyProducer.selector);
        campaign.startSeason(1);
    }

    function test_cannotStartSeasonInFunding() public {
        vm.prank(producer);
        vm.expectRevert(
            abi.encodeWithSelector(Campaign.InvalidState.selector, Campaign.State.Active, Campaign.State.Funding)
        );
        campaign.startSeason(1);
    }

    // --- Fix #2: Multi-token buyback ---

    function test_multiTokenBuyback() public {
        // Add WETH as accepted token (1 WETH = 1000 $CAMPAIGN → fixedRate = 0.001e18)
        vm.prank(producer);
        campaign.addAcceptedToken(address(weth), Campaign.PricingMode.Fixed, 0.001e18, address(0));

        // Alice buys with USDC: 20k tokens (below 50k minCap)
        vm.prank(alice);
        campaign.buy(address(usdc), 2_880_000_000); // 20k tokens

        // Alice buys with WETH: 10k tokens (total 30k, still below minCap)
        weth.mint(alice, 10e18);
        vm.prank(alice);
        weth.approve(address(campaign), type(uint256).max);
        vm.prank(alice);
        campaign.buy(address(weth), 10e18); // 10k tokens

        // Deadline passes without reaching minCap
        vm.warp(block.timestamp + 91 days);
        campaign.triggerBuyback();

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceWethBefore = weth.balanceOf(alice);

        // Buyback USDC
        vm.prank(alice);
        campaign.buyback(address(usdc));
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + 2_880_000_000);

        // Buyback WETH — should still work and burn only WETH-purchased tokens
        vm.prank(alice);
        campaign.buyback(address(weth));
        assertEq(weth.balanceOf(alice), aliceWethBefore + 10e18);

        // All tokens should be burned
        assertEq(campaignToken.balanceOf(alice), 0);
    }

    // --- Fix #3: Emergency pause from factory ---

    function test_factoryCanPauseCampaign() public {
        factory.pauseCampaign(0);

        // Buy should revert when paused
        vm.prank(alice);
        vm.expectRevert();
        campaign.buy(address(usdc), 1_000_000);
    }

    function test_factoryCanUnpauseCampaign() public {
        factory.pauseCampaign(0);
        factory.unpauseCampaign(0);

        // Buy should work after unpause
        vm.prank(alice);
        campaign.buy(address(usdc), 1_440_000); // 10 tokens
        assertGt(campaignToken.balanceOf(alice), 0);
    }

    function test_nonOwnerCannotPause() public {
        vm.prank(alice);
        vm.expectRevert();
        factory.pauseCampaign(0);
    }

    // --- Fix #4: Input validation ---

    function test_cannotCreateCampaignWithZeroPrice() public {
        vm.prank(producer);
        vm.expectRevert("Zero price");
        factory.createCampaign(
            CampaignFactory.CreateCampaignParams({
                producer: producer,
                tokenName: "T",
                tokenSymbol: "T",
                yieldName: "Y",
                yieldSymbol: "Y",
                pricePerToken: 0,
                minCap: 1000e18,
                maxCap: 10000e18,
                fundingDeadline: block.timestamp + 30 days,
                seasonDuration: 365 days,
                minProductClaim: 1e18
            })
        );
    }

    function test_cannotCreateCampaignMinGtMax() public {
        vm.prank(producer);
        vm.expectRevert("minCap > maxCap");
        factory.createCampaign(
            CampaignFactory.CreateCampaignParams({
                producer: producer,
                tokenName: "T",
                tokenSymbol: "T",
                yieldName: "Y",
                yieldSymbol: "Y",
                pricePerToken: 1e18,
                minCap: 10000e18,
                maxCap: 1000e18,
                fundingDeadline: block.timestamp + 30 days,
                seasonDuration: 365 days,
                minProductClaim: 1e18
            })
        );
    }

    function test_cannotCreateCampaignPastDeadline() public {
        vm.prank(producer);
        vm.expectRevert("Deadline in past");
        factory.createCampaign(
            CampaignFactory.CreateCampaignParams({
                producer: producer,
                tokenName: "T",
                tokenSymbol: "T",
                yieldName: "Y",
                yieldSymbol: "Y",
                pricePerToken: 1e18,
                minCap: 1000e18,
                maxCap: 10000e18,
                fundingDeadline: block.timestamp - 1,
                seasonDuration: 365 days,
                minProductClaim: 1e18
            })
        );
    }

    function test_cannotCreateCampaignShortSeason() public {
        vm.prank(producer);
        vm.expectRevert("Season too short");
        factory.createCampaign(
            CampaignFactory.CreateCampaignParams({
                producer: producer,
                tokenName: "T",
                tokenSymbol: "T",
                yieldName: "Y",
                yieldSymbol: "Y",
                pricePerToken: 1e18,
                minCap: 1000e18,
                maxCap: 10000e18,
                fundingDeadline: block.timestamp + 30 days,
                seasonDuration: 1 days,
                minProductClaim: 1e18
            })
        );
    }

    // --- Fix #5: fixedRate validation ---

    function test_cannotAddTokenWithZeroFixedRate() public {
        vm.prank(producer);
        vm.expectRevert("Zero fixedRate");
        campaign.addAcceptedToken(address(weth), Campaign.PricingMode.Fixed, 0, address(0));
    }

    function test_cannotAddTokenWithZeroOracleAddress() public {
        vm.prank(producer);
        vm.expectRevert("Zero oracle address");
        campaign.addAcceptedToken(address(weth), Campaign.PricingMode.Oracle, 0, address(0));
    }

    // --- No purchases tracked in Active state ---

    function test_noPurchaseTrackingInActiveState() public {
        // Alice activates campaign
        vm.prank(alice);
        campaign.buy(address(usdc), 8_640_000_000);
        assertEq(uint8(campaign.state()), uint8(Campaign.State.Active));

        // Bob buys in Active state
        vm.prank(bob);
        campaign.buy(address(usdc), 1_440_000);

        // Bob's purchases should not be tracked (Active state)
        assertEq(campaign.purchases(bob, address(usdc)), 0);
    }
}
