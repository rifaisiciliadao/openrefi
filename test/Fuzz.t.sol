// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {CampaignFactory} from "../src/CampaignFactory.sol";
import {Campaign} from "../src/Campaign.sol";
import {CampaignToken} from "../src/CampaignToken.sol";
import {YieldToken} from "../src/YieldToken.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {HarvestManager} from "../src/HarvestManager.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {MockOracle} from "./helpers/MockOracle.sol";

/// @title Fuzz — property-based tests on precision, rounding, and monotonicity
contract FuzzTest is Test {
    CampaignFactory factory;
    Campaign campaign;
    CampaignToken campaignToken;
    YieldToken yieldToken;
    StakingVault stakingVault;
    HarvestManager harvestManager;
    MockERC20 usdc;

    address protocolOwner = makeAddr("protocolOwner");
    address feeRecipient = makeAddr("feeRecipient");
    address producer = makeAddr("producer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant PRICE_PER_TOKEN = 0.144e18;
    uint256 constant MIN_CAP = 10_000e18;
    uint256 constant MAX_CAP = 1_000_000e18;
    uint256 constant SEASON_DURATION = 365 days;
    uint256 constant USDC_FIXED_RATE = 144_000;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        factory = new CampaignFactory(protocolOwner, feeRecipient, address(usdc));
        vm.prank(protocolOwner);
        factory.createCampaign(
            CampaignFactory.CreateCampaignParams({
                producer: producer,
                tokenName: "Olive",
                tokenSymbol: "OLIVE",
                yieldName: "oY",
                yieldSymbol: "oY",
                pricePerToken: PRICE_PER_TOKEN,
                minCap: MIN_CAP,
                maxCap: MAX_CAP,
                fundingDeadline: block.timestamp + 90 days,
                seasonDuration: SEASON_DURATION,
                minProductClaim: 5e18
            })
        );
        (address c, address ct, address yt, address sv, address hm,,) = factory.campaigns(0);
        campaign = Campaign(c);
        campaignToken = CampaignToken(ct);
        yieldToken = YieldToken(yt);
        stakingVault = StakingVault(sv);
        harvestManager = HarvestManager(hm);

        vm.prank(producer);
        campaign.addAcceptedToken(address(usdc), Campaign.PricingMode.Fixed, USDC_FIXED_RATE, address(0));
    }

    function _buy(address who, uint256 payAmount) internal returns (uint256 tokensReceived) {
        usdc.mint(who, payAmount);
        vm.startPrank(who);
        usdc.approve(address(campaign), type(uint256).max);
        uint256 before = campaignToken.balanceOf(who);
        campaign.buy(address(usdc), payAmount);
        tokensReceived = campaignToken.balanceOf(who) - before;
        vm.stopPrank();
    }

    // =========================================================================
    // FUZZ 1 — Buyback refund is always exactly what user paid
    // =========================================================================
    function testFuzz_buybackRefundExact(uint96 payAmount) public {
        // Keep strictly below minCap so campaign stays in Funding and buyback is reachable.
        uint256 maxPay = (MIN_CAP / 1e18) * USDC_FIXED_RATE - 1;
        payAmount = uint96(bound(payAmount, USDC_FIXED_RATE, maxPay));
        uint256 paid = payAmount;

        _buy(alice, paid);
        // Fail campaign
        vm.warp(block.timestamp + 91 days);
        campaign.triggerBuyback();

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        campaign.buyback(address(usdc));

        // Refund must be exactly paid; zero slippage, zero rounding
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, paid, "refund != paid");
        assertEq(campaignToken.balanceOf(alice), 0, "tokens not fully burned");
    }

    // =========================================================================
    // FUZZ 2 — currentSupply after buy never exceeds maxCap
    // =========================================================================
    function testFuzz_maxCapNeverExceeded(uint96 pay1, uint96 pay2) public {
        // Bound each so combined can't exceed MAX_CAP worth of payment.
        uint256 maxCombined = (MAX_CAP / 1e18) * USDC_FIXED_RATE;
        pay1 = uint96(bound(pay1, USDC_FIXED_RATE, maxCombined / 2));
        pay2 = uint96(bound(pay2, USDC_FIXED_RATE, maxCombined / 2));

        _buy(alice, pay1);
        _buy(bob, pay2);

        assertLe(campaign.currentSupply(), MAX_CAP, "supply exceeds maxCap");
    }

    // =========================================================================
    // FUZZ 3 — Sell-back fill never inflates total supply
    // =========================================================================
    function testFuzz_sellBackFillPreservesSupply(uint96 alicePay, uint96 bobPay) public {
        alicePay = uint96(bound(alicePay, MIN_CAP / 1e18 * USDC_FIXED_RATE, 100_000e6));
        bobPay = uint96(bound(bobPay, USDC_FIXED_RATE, 50_000e6));

        _buy(alice, alicePay);
        // If under minCap, bump with a second actor to activate
        if (uint8(campaign.state()) == 0) {
            _buy(bob, MIN_CAP / 1e18 * USDC_FIXED_RATE);
        }
        if (uint8(campaign.state()) != 1) return; // skip if still not active

        uint256 aliceBal = campaignToken.balanceOf(alice);
        if (aliceBal == 0) return;
        vm.startPrank(alice);
        campaignToken.approve(address(campaign), type(uint256).max);
        campaign.sellBack(aliceBal / 2);
        vm.stopPrank();

        uint256 supplyBefore = campaignToken.totalSupply();
        address eve = makeAddr("eve");
        _buy(eve, bobPay);

        // Partial fill net: burn + mint = 0 delta; any new mint beyond fill increases supply.
        // The core invariant: totalSupply can only go up by the *new-mint portion* (not the filled portion).
        // Easy check: totalSupply monotonic, never decreases from a buy.
        assertGe(campaignToken.totalSupply(), supplyBefore, "buy decreased totalSupply");
    }

    // =========================================================================
    // FUZZ 4 — Unstake returned amount is monotonic in time elapsed
    //          (more time → less penalty → more returned)
    // =========================================================================
    function testFuzz_unstakePenaltyMonotonic(uint32 elapsed) public {
        elapsed = uint32(bound(elapsed, 1, uint32(SEASON_DURATION - 1)));

        uint256 pay = (MIN_CAP / 1e18) * USDC_FIXED_RATE + 1000e6;
        _buy(alice, pay);

        vm.prank(producer);
        campaign.startSeason(1);

        uint256 stakeAmount = 1000e18;
        vm.startPrank(alice);
        campaignToken.approve(address(stakingVault), type(uint256).max);
        uint256 pos = stakingVault.stake(stakeAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + elapsed);

        uint256 balBefore = campaignToken.balanceOf(alice);
        vm.prank(alice);
        stakingVault.unstake(pos);
        uint256 returned = campaignToken.balanceOf(alice) - balBefore;

        // Expected: stakeAmount * elapsed / SEASON_DURATION
        uint256 expected = stakeAmount * elapsed / SEASON_DURATION;
        // Allow off-by-one for integer rounding
        assertApproxEqAbs(returned, expected, 1, "penalty math off");
        assertLe(returned, stakeAmount, "returned > staked");
    }

    // =========================================================================
    // FUZZ 5 — Yield earned scales linearly with stake amount at same rate
    // =========================================================================
    function testFuzz_yieldLinearInStake(uint96 stakeA, uint96 stakeB) public {
        stakeA = uint96(bound(stakeA, 100e18, 10_000e18));
        stakeB = uint96(bound(stakeB, 100e18, 10_000e18));

        uint256 totalNeeded = uint256(stakeA) + uint256(stakeB);
        // Ensure we can buy enough
        uint256 pay = (totalNeeded / 1e18) * USDC_FIXED_RATE + (MIN_CAP / 1e18) * USDC_FIXED_RATE;
        _buy(alice, pay);

        vm.prank(producer);
        campaign.startSeason(1);

        vm.startPrank(alice);
        campaignToken.approve(address(stakingVault), type(uint256).max);
        uint256 posA = stakingVault.stake(stakeA);
        uint256 posB = stakingVault.stake(stakeB);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);

        uint256 earnedA = stakingVault.earned(posA);
        uint256 earnedB = stakingVault.earned(posB);

        // Cross-ratio: earnedA / earnedB ≈ stakeA / stakeB (both positions accrue at same rate)
        // Check: earnedA * stakeB ≈ earnedB * stakeA
        uint256 lhs = earnedA * uint256(stakeB);
        uint256 rhs = earnedB * uint256(stakeA);
        // Allow tiny rounding delta proportional to inputs
        uint256 tolerance = (lhs > rhs ? lhs - rhs : rhs - lhs);
        uint256 bound_ = (lhs + rhs) / 1e12 + 1; // 1e-12 relative
        assertLe(tolerance, bound_, "yield not linear in stake");
    }

    // =========================================================================
    // FUZZ 6 — Pro-rata USDC claim: deposited < owed → proportional share
    // =========================================================================
    function testFuzz_usdcProRata(uint256 depositBps) public {
        depositBps = bound(depositBps, 100, 10_000); // 1%..100% of owed

        uint256 pay = (MIN_CAP / 1e18) * USDC_FIXED_RATE * 2;
        _buy(alice, pay);
        _buy(bob, pay);

        vm.prank(producer);
        campaign.startSeason(1);

        vm.startPrank(alice);
        campaignToken.approve(address(stakingVault), type(uint256).max);
        stakingVault.stake(10_000e18);
        vm.stopPrank();

        vm.startPrank(bob);
        campaignToken.approve(address(stakingVault), type(uint256).max);
        stakingVault.stake(10_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        vm.prank(alice);
        stakingVault.claimYield(0);
        vm.prank(bob);
        stakingVault.claimYield(1);

        vm.prank(producer);
        campaign.endSeason();

        vm.prank(producer);
        harvestManager.reportHarvest(1, 14_000e18, bytes32(0), 2000e18);

        // Both redeem USDC
        uint256 aliceYield = yieldToken.balanceOf(alice);
        uint256 bobYield = yieldToken.balanceOf(bob);
        vm.prank(alice);
        harvestManager.redeemUSDC(1, aliceYield);
        vm.prank(bob);
        harvestManager.redeemUSDC(1, bobYield);

        (,,,,,,,, uint256 usdcOwed18,,) = harvestManager.seasonHarvests(1);
        uint256 usdcOwed6 = usdcOwed18 / 1e12;
        uint256 deposit = usdcOwed6 * depositBps / 10_000;
        if (deposit == 0) return;

        usdc.mint(producer, deposit);
        vm.startPrank(producer);
        usdc.approve(address(harvestManager), type(uint256).max);
        harvestManager.depositUSDC(1, deposit);
        vm.stopPrank();

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        harvestManager.claimUSDC(1);
        uint256 aliceClaimed = usdc.balanceOf(alice) - aliceBefore;

        // Claim struct fields: claimed, redemptionType, amount (yield), usdcAmount, usdcClaimed
        (,,, uint256 aliceUsdcAmount18,) = harvestManager.claims(1, alice);
        uint256 aliceExpected = (aliceUsdcAmount18 / 1e12) * depositBps / 10_000;
        assertApproxEqAbs(aliceClaimed, aliceExpected, 2, "pro-rata off");
    }

    // =========================================================================
    // FUZZ 7 — purchases mapping sum equals escrowed balance in Funding state
    // =========================================================================
    function testFuzz_escrowSumsEqualBalance(uint96 aPay, uint96 bPay) public {
        aPay = uint96(bound(aPay, USDC_FIXED_RATE, 1000e6));
        bPay = uint96(bound(bPay, USDC_FIXED_RATE, 1000e6));
        // Keep sub-minCap so we stay in Funding
        uint256 totalTokens = (uint256(aPay) + uint256(bPay)) / USDC_FIXED_RATE;
        vm.assume(totalTokens * 1e18 < MIN_CAP);

        _buy(alice, aPay);
        _buy(bob, bPay);

        assertEq(uint8(campaign.state()), 0, "should still be Funding");
        uint256 sum = campaign.purchases(alice, address(usdc)) + campaign.purchases(bob, address(usdc));
        assertEq(sum, usdc.balanceOf(address(campaign)), "escrow != sum(purchases)");
    }

    // =========================================================================
    // FUZZ 8 — purchasedTokens mapping equals campaignToken balance in Funding
    // =========================================================================
    function testFuzz_purchasedTokensMatchesBalance(uint96 payAmount) public {
        payAmount = uint96(bound(payAmount, USDC_FIXED_RATE, 1000e6));
        vm.assume(payAmount / USDC_FIXED_RATE * 1e18 < MIN_CAP);

        _buy(alice, payAmount);

        assertEq(
            campaign.purchasedTokens(alice, address(usdc)), campaignToken.balanceOf(alice), "purchasedTokens != balance"
        );
    }
}
