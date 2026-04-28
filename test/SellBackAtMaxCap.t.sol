// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {CampaignFactory} from "../src/CampaignFactory.sol";
import {Campaign} from "../src/Campaign.sol";
import {CampaignToken} from "../src/CampaignToken.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {Deployer} from "./helpers/Deployer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title SellBackAtMaxCap — regression for the "queue blocked when full" bug
/// @notice The original `buy()` reverted with MaxCapReached as soon as
///         `currentSupply >= maxCap`, which made the sell-back queue
///         unreachable once the campaign was fully funded. Since a queue
///         fill burns+mints (supply-neutral), new buyers should still be
///         able to consume the queue at cap. This suite pins that down.
contract SellBackAtMaxCapTest is Test {
    CampaignFactory factory;
    MockERC20 usdc;

    Campaign campaign;
    CampaignToken campaignToken;

    address producer = makeAddr("producer");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant PRICE = 0.144e18;
    uint256 constant MIN_CAP = 500e18;
    uint256 constant MAX_CAP = 1_000e18;
    uint256 constant USDC_FIXED_RATE = 144_000; // 1 OLIVE = 0.144 USDC (6-dec)

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        factory = Deployer.deployProtocol(address(this), feeRecipient, address(usdc), address(0));

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
                fundingDeadline: block.timestamp + 30 days,
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
        usdc.mint(bob, 10_000e6);
        usdc.mint(carol, 10_000e6);
        _approve(alice);
        _approve(bob);
        _approve(carol);
    }

    function _approve(address who) internal {
        vm.startPrank(who);
        usdc.approve(address(campaign), type(uint256).max);
        campaignToken.approve(address(campaign), type(uint256).max);
        vm.stopPrank();
    }

    /// Fill the campaign to exactly maxCap, then verify a new buyer can
    /// still consume an existing sell-back order without hitting MaxCapReached.
    /// This is the regression for the reported bug.
    function test_buyFromQueueAtMaxCap_doesNotRevert() public {
        // Alice buys the full maxCap → campaign auto-activates.
        uint256 aliceSpend = (MAX_CAP * USDC_FIXED_RATE) / 1e18; // 1000 * 144_000 = 144_000_000 (144 USDC)
        vm.prank(alice);
        campaign.buy(address(usdc), aliceSpend);
        assertEq(uint8(campaign.state()), uint8(Campaign.State.Active), "must be Active");
        assertEq(campaign.currentSupply(), MAX_CAP, "supply == maxCap");

        // Alice queues 100 OLIVE for sell-back.
        vm.prank(alice);
        campaign.sellBack(100e18);

        // Bob tries to buy 100 OLIVE from the queue. Pre-fix this reverted
        // with MaxCapReached at `if (currentSupply >= maxCap)`.
        uint256 bobSpend = (100e18 * USDC_FIXED_RATE) / 1e18; // 14_400_000
        uint256 bobBalBefore = campaignToken.balanceOf(bob);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(bob);
        campaign.buy(address(usdc), bobSpend);

        // Bob got 100 OLIVE from the queue.
        assertEq(campaignToken.balanceOf(bob) - bobBalBefore, 100e18, "bob receives 100 OLIVE from queue");
        // Alice received the USDC proportionally — NET of the 3% funding fee.
        // The seller paid the same fee on her original entry, so this evens out
        // in USDC terms across the full entry/exit cycle.
        uint256 bobFee = bobSpend * 300 / 10_000;
        assertEq(
            usdc.balanceOf(alice) - aliceUsdcBefore,
            bobSpend - bobFee,
            "alice paid out from queue fill (net of funding fee)"
        );
        // Supply stayed at cap — no new mint.
        assertEq(campaign.currentSupply(), MAX_CAP, "supply unchanged (burn+mint)");
        // Queue drained.
        assertEq(campaign.getSellBackQueueDepth(), 0, "queue fully consumed");
    }

    /// Mixed fill: queue has 50, buyer wants 100, cap has 0 room → buyer
    /// gets 50 from queue and the rest refunded (clamped by buyableMax).
    function test_buyAtMaxCap_clampsToQueueSize() public {
        uint256 aliceSpend = (MAX_CAP * USDC_FIXED_RATE) / 1e18;
        vm.prank(alice);
        campaign.buy(address(usdc), aliceSpend);

        vm.prank(alice);
        campaign.sellBack(50e18); // 50 OLIVE in queue

        // Bob tries to buy 100 OLIVE worth. Should only get 50 from queue.
        uint256 bobSpend = (100e18 * USDC_FIXED_RATE) / 1e18; // 14_400_000
        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        campaign.buy(address(usdc), bobSpend);

        // Bob's OLIVE balance: exactly 50 (clamped).
        assertEq(campaignToken.balanceOf(bob), 50e18, "clamped to queue size");
        // Bob spent half the USDC; the contract only pulled `bobSpend / 2`.
        assertEq(bobUsdcBefore - usdc.balanceOf(bob), bobSpend / 2, "bob charged only for what was available");
        // Cap unchanged.
        assertEq(campaign.currentSupply(), MAX_CAP);
        assertEq(campaign.getSellBackQueueDepth(), 0);
    }

    /// Below maxCap + queue present: queue fills first, then remainder mints.
    function test_buyBelowCapWithQueue_fillsQueueThenMints() public {
        // Alice buys 600 OLIVE (hits min cap, activates).
        uint256 aliceSpend = (600e18 * USDC_FIXED_RATE) / 1e18;
        vm.prank(alice);
        campaign.buy(address(usdc), aliceSpend);
        assertEq(uint8(campaign.state()), uint8(Campaign.State.Active));

        // Alice queues 100 for sell-back. supply=600, queue=100, room=400.
        vm.prank(alice);
        campaign.sellBack(100e18);

        // Bob buys 200 OLIVE → expects 100 from queue + 100 fresh mint.
        uint256 bobSpend = (200e18 * USDC_FIXED_RATE) / 1e18;
        vm.prank(bob);
        campaign.buy(address(usdc), bobSpend);

        assertEq(campaignToken.balanceOf(bob), 200e18, "bob got 200 total");
        assertEq(campaign.currentSupply(), 700e18, "supply grew by only 100 (queue absorbed the other 100)");
        assertEq(campaign.getSellBackQueueDepth(), 0);
    }

    /// Queue empty + at maxCap: revert MaxCapReached — unchanged from before.
    function test_buyAtMaxCapEmptyQueue_stillReverts() public {
        uint256 aliceSpend = (MAX_CAP * USDC_FIXED_RATE) / 1e18;
        vm.prank(alice);
        campaign.buy(address(usdc), aliceSpend);

        uint256 carolSpend = 144_000;
        vm.prank(carol);
        vm.expectRevert(Campaign.MaxCapReached.selector);
        campaign.buy(address(usdc), carolSpend);
    }
}
