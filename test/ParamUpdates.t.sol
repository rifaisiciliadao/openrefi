// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CampaignFactory} from "../src/CampaignFactory.sol";
import {Campaign} from "../src/Campaign.sol";
import {CampaignToken} from "../src/CampaignToken.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {Deployer} from "./helpers/Deployer.sol";

/// @title ParamUpdates — setFundingDeadline / setMinCap / setMaxCap regression
/// @notice Locks the guard-rails around the 3 new producer-only parameter
///         setters. They skip the impl-redeploy dance but keep the
///         invariants that make prior buyers whole.
contract ParamUpdatesTest is Test {
    CampaignFactory factory;
    MockERC20 usdc;

    Campaign campaign;
    CampaignToken campaignToken;

    address producer = makeAddr("producer");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");
    address attacker = makeAddr("attacker");

    uint256 constant PRICE = 0.144e18;
    uint256 constant MIN_CAP = 500e18;
    uint256 constant MAX_CAP = 1_000e18;
    uint256 constant USDC_FIXED_RATE = 144_000;
    uint256 initialDeadline;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        factory = Deployer.deployProtocol(address(this), feeRecipient, address(usdc), address(0));

        initialDeadline = block.timestamp + 30 days;

        vm.prank(producer);
        factory.createCampaign(
            CampaignFactory.CreateCampaignParams({
                producer: producer,
                tokenName: "Olive",
                tokenSymbol: "OLIVE",
                yieldName: "oY",
                yieldSymbol: "oY",
                pricePerToken: PRICE,
                minCap: MIN_CAP,
                maxCap: MAX_CAP,
                fundingDeadline: initialDeadline,
                seasonDuration: 365 days,
                minProductClaim: 1e18,
                expectedYearlyReturnBps: 1000,
                expectedFirstYearHarvest: 1e18,
                coverageHarvests: 0
            })
        );
        (address c, address ct,,,,,) = factory.campaigns(0);
        campaign = Campaign(c);
        campaignToken = CampaignToken(ct);

        vm.prank(producer);
        campaign.addAcceptedToken(address(usdc), Campaign.PricingMode.Fixed, USDC_FIXED_RATE, address(0));

        usdc.mint(alice, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(campaign), type(uint256).max);
    }

    // --- setFundingDeadline ----------------------------------------------

    function test_setFundingDeadline_extendsOnly_happy() public {
        uint256 newDl = initialDeadline + 10 days;
        vm.prank(producer);
        campaign.setFundingDeadline(newDl);
        assertEq(campaign.fundingDeadline(), newDl);
    }

    function test_setFundingDeadline_shortening_reverts() public {
        vm.prank(producer);
        vm.expectRevert(Campaign.DeadlineNotExtended.selector);
        campaign.setFundingDeadline(initialDeadline - 1);
    }

    function test_setFundingDeadline_pastTimestamp_reverts() public {
        vm.warp(initialDeadline + 1);
        vm.prank(producer);
        vm.expectRevert(Campaign.DeadlineInPast.selector);
        campaign.setFundingDeadline(block.timestamp - 1);
    }

    function test_setFundingDeadline_nonProducer_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(Campaign.OnlyProducer.selector);
        campaign.setFundingDeadline(initialDeadline + 1 days);
    }

    function test_setFundingDeadline_afterActivation_reverts() public {
        // Push the campaign into Active.
        uint256 spend = (MIN_CAP * USDC_FIXED_RATE) / 1e18;
        vm.prank(alice);
        campaign.buy(address(usdc), spend);
        assertEq(uint8(campaign.state()), uint8(Campaign.State.Active));

        vm.prank(producer);
        vm.expectRevert();
        campaign.setFundingDeadline(initialDeadline + 10 days);
    }

    // --- setMinCap -------------------------------------------------------

    function test_setMinCap_happy() public {
        vm.prank(producer);
        campaign.setMinCap(300e18);
        assertEq(campaign.minCap(), 300e18);
    }

    function test_setMinCap_belowSupply_reverts() public {
        // Alice buys 200 OLIVE.
        uint256 spend = (200e18 * USDC_FIXED_RATE) / 1e18;
        vm.prank(alice);
        campaign.buy(address(usdc), spend);

        vm.prank(producer);
        vm.expectRevert(Campaign.NewMinCapBelowSupply.selector);
        campaign.setMinCap(150e18);
    }

    function test_setMinCap_aboveMaxCap_reverts() public {
        vm.prank(producer);
        vm.expectRevert(Campaign.NewMinCapBelowSupply.selector);
        campaign.setMinCap(MAX_CAP + 1);
    }

    function test_setMinCap_afterActivation_reverts() public {
        uint256 spend = (MIN_CAP * USDC_FIXED_RATE) / 1e18;
        vm.prank(alice);
        campaign.buy(address(usdc), spend);

        vm.prank(producer);
        vm.expectRevert();
        campaign.setMinCap(100e18);
    }

    // --- setMaxCap -------------------------------------------------------

    function test_setMaxCap_raising_duringFunding_happy() public {
        vm.prank(producer);
        campaign.setMaxCap(5_000e18);
        assertEq(campaign.maxCap(), 5_000e18);
    }

    function test_setMaxCap_lowering_aboveCommitted_happy() public {
        uint256 spend = (200e18 * USDC_FIXED_RATE) / 1e18;
        vm.prank(alice);
        campaign.buy(address(usdc), spend);

        // During Funding the new maxCap must stay ≥ minCap; lower minCap first.
        vm.prank(producer);
        campaign.setMinCap(220e18);
        vm.prank(producer);
        campaign.setMaxCap(300e18); // > 200 already sold, > 220 minCap
        assertEq(campaign.maxCap(), 300e18);
    }

    function test_setMaxCap_belowCurrentSupply_reverts() public {
        uint256 spend = (400e18 * USDC_FIXED_RATE) / 1e18;
        vm.prank(alice);
        campaign.buy(address(usdc), spend);

        vm.prank(producer);
        vm.expectRevert(Campaign.NewMaxCapBelowCommitted.selector);
        campaign.setMaxCap(300e18);
    }

    function test_setMaxCap_belowQueueAndSupply_reverts() public {
        // Activate + queue a sellback.
        uint256 spend = (MIN_CAP * USDC_FIXED_RATE) / 1e18;
        vm.prank(alice);
        campaign.buy(address(usdc), spend);
        vm.prank(alice);
        campaignToken.approve(address(campaign), type(uint256).max);
        vm.prank(alice);
        campaign.sellBack(100e18);

        // currentSupply=500, queue=100 → committed=600
        vm.prank(producer);
        vm.expectRevert(Campaign.NewMaxCapBelowCommitted.selector);
        campaign.setMaxCap(550e18);
    }

    function test_setMaxCap_duringActive_happy() public {
        uint256 spend = (MIN_CAP * USDC_FIXED_RATE) / 1e18;
        vm.prank(alice);
        campaign.buy(address(usdc), spend);
        assertEq(uint8(campaign.state()), uint8(Campaign.State.Active));

        vm.prank(producer);
        campaign.setMaxCap(10_000e18);
        assertEq(campaign.maxCap(), 10_000e18);
    }

    function test_setMaxCap_duringBuyback_reverts() public {
        vm.warp(initialDeadline + 1);
        campaign.triggerBuyback();
        assertEq(uint8(campaign.state()), uint8(Campaign.State.Buyback));

        vm.prank(producer);
        vm.expectRevert();
        campaign.setMaxCap(MAX_CAP + 1);
    }

    function test_setMaxCap_belowMinCap_duringFunding_reverts() public {
        vm.prank(producer);
        vm.expectRevert(Campaign.NewMaxCapBelowCommitted.selector);
        campaign.setMaxCap(MIN_CAP - 1);
    }

    function test_setMaxCap_nonProducer_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(Campaign.OnlyProducer.selector);
        campaign.setMaxCap(5_000e18);
    }
}
