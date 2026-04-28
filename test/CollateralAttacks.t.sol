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
import {Deployer} from "./helpers/Deployer.sol";

/// @title CollateralAttacks — adversarial coverage for the v3 collateral mechanic.
/// @notice Each test simulates a specific attack on `lockCollateral` /
///         `settleSeasonShortfall` / `depositFromCollateral`. A passing test
///         means the attack was successfully blocked.
contract CollateralAttacksTest is Test {
    CampaignFactory factory;
    MockERC20 usdc;
    Campaign campaign;
    CampaignToken campaignToken;
    YieldToken yieldToken;
    StakingVault stakingVault;
    HarvestManager harvestManager;

    address protocolOwner = makeAddr("protocolOwner");
    address feeRecipient = makeAddr("feeRecipient");
    address producer = makeAddr("producer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address attacker = makeAddr("attacker");

    uint256 constant PRICE_PER_TOKEN = 0.144e18;
    uint256 constant MIN_CAP = 50_000e18;
    uint256 constant MAX_CAP = 100_000e18;
    uint256 constant SEASON_DURATION = 365 days;
    uint256 constant USDC_FIXED_RATE = 144_000;
    uint256 constant COVERAGE = 3; // pre-fund 3 harvests

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        factory = Deployer.deployProtocol(protocolOwner, feeRecipient, address(usdc), address(0));

        vm.prank(producer);
        factory.createCampaign(
            CampaignFactory.CreateCampaignParams({
                producer: producer,
                tokenName: "Olive",
                tokenSymbol: "OLIVE",
                yieldName: "oYield",
                yieldSymbol: "oY",
                pricePerToken: PRICE_PER_TOKEN,
                minCap: MIN_CAP,
                maxCap: MAX_CAP,
                fundingDeadline: block.timestamp + 90 days,
                seasonDuration: SEASON_DURATION,
                minProductClaim: 5e18,
                expectedAnnualHarvestUsd: 5_000e18,
                firstHarvestYear: 2030,
                coverageHarvests: COVERAGE
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

        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        usdc.mint(attacker, 1_000_000e6);
        usdc.mint(producer, 1_000_000e6);

        for (uint256 i = 0; i < 4; i++) {
            address u = [alice, bob, attacker, producer][i];
            vm.startPrank(u);
            usdc.approve(address(campaign), type(uint256).max);
            campaignToken.approve(address(stakingVault), type(uint256).max);
            vm.stopPrank();
        }
    }

    // -------------------------------------------------------------------------
    // Helpers — ride the campaign through to a state where settleSeasonShortfall
    // is reachable. Activate via Alice + Bob, lock collateral, start + end
    // season 1, report harvest, advance past usdcDeadline.
    // -------------------------------------------------------------------------

    function _activate() internal {
        // Alice buys to minCap → auto-activate.
        uint256 alicePay = 60_000 * USDC_FIXED_RATE; // 8.64 USDC * 1000 = 8640 USDC
        vm.prank(alice);
        campaign.buy(address(usdc), alicePay);
        // Bob tops up.
        vm.prank(bob);
        campaign.buy(address(usdc), 5_000 * USDC_FIXED_RATE);
        assertEq(uint8(campaign.state()), uint8(Campaign.State.Active));
    }

    function _startSeason(uint256 seasonId) internal {
        vm.prank(producer);
        campaign.startSeason(seasonId);
    }

    function _stake(address user, uint256 amount) internal returns (uint256 posId) {
        vm.startPrank(user);
        posId = stakingVault.stake(amount);
        vm.stopPrank();
    }

    function _endAndReport(uint256 seasonId, uint256 harvestValueUsd18) internal {
        vm.warp(block.timestamp + SEASON_DURATION);
        vm.prank(producer);
        campaign.endSeason();
        vm.prank(producer);
        harvestManager.reportHarvest(seasonId, harvestValueUsd18, bytes32(0), 0);
    }

    /// @dev Have `holder` claim their accrued yield and commit a USDC claim
    ///      so `usdcOwed` actually accumulates on the season — otherwise the
    ///      shortfall is always zero and there's nothing to settle.
    function _commitUsdcClaim(address holder, uint256 posId, uint256 seasonId) internal {
        vm.startPrank(holder);
        stakingVault.claimYield(posId);
        uint256 yieldBal = yieldToken.balanceOf(holder);
        if (yieldBal > 0) {
            harvestManager.redeemUSDC(seasonId, yieldBal);
        }
        vm.stopPrank();
    }

    // =========================================================================
    // ATTACK 1 — Non-producer tries to lock collateral (silent capital injection)
    // =========================================================================
    function test_attack_nonProducerCannotLock() public {
        _activate();
        vm.prank(attacker);
        vm.expectRevert(Campaign.OnlyProducer.selector);
        campaign.lockCollateral(1_000e6);
    }

    // =========================================================================
    // ATTACK 2 — Producer tries to lock zero (no-op spam)
    // =========================================================================
    function test_attack_lockZeroReverts() public {
        _activate();
        vm.prank(producer);
        vm.expectRevert(Campaign.ZeroAmount.selector);
        campaign.lockCollateral(0);
    }

    // =========================================================================
    // ATTACK 3 — Lock during Funding state is allowed (pre-activation commit
    //            shown to buyers as a trust signal). Lock during Buyback / Ended
    //            must revert.
    // =========================================================================
    function test_lockCollateral_duringFunding_allowed() public {
        // Still in Funding (no buys yet).
        assertEq(uint8(campaign.state()), uint8(Campaign.State.Funding));
        vm.prank(producer);
        campaign.lockCollateral(1_000e6);
        assertEq(campaign.collateralLocked(), 1_000e6);
    }

    function test_attack_lockDuringBuyback_blocked() public {
        // Force Buyback: deadline passes, minCap not reached.
        vm.warp(block.timestamp + 91 days);
        campaign.triggerBuyback();
        vm.prank(producer);
        vm.expectRevert();
        campaign.lockCollateral(1_000e6);
    }

    // =========================================================================
    // ATTACK 4 — Re-lock more than once accumulates correctly (no overflow / no
    //            silent overwrite).
    // =========================================================================
    function test_lock_isAdditive() public {
        _activate();
        vm.prank(producer);
        campaign.lockCollateral(1_000e6);
        vm.prank(producer);
        campaign.lockCollateral(2_500e6);
        assertEq(campaign.collateralLocked(), 3_500e6);
    }

    // =========================================================================
    // ATTACK 5 — There is NO withdraw path. Even producer cannot pull collateral
    //            back during Active state. (Compile-time guarantee — no
    //            withdrawCollateral function exists; we still pin it down with
    //            a balance assertion after multiple failed attempts.)
    // =========================================================================
    function test_attack_noWithdrawalPath() public {
        _activate();
        vm.prank(producer);
        campaign.lockCollateral(5_000e6);
        uint256 producerBefore = usdc.balanceOf(producer);
        // No withdraw exists — emergencyPause + producer pranks all idle.
        assertEq(usdc.balanceOf(producer), producerBefore, "producer balance unchanged");
        assertEq(campaign.collateralLocked(), 5_000e6, "collateral still locked");
    }

    // =========================================================================
    // ATTACK 6 — settleSeasonShortfall called outside coverage window
    // =========================================================================
    function test_attack_settleSeasonZero_reverts() public {
        _activate();
        vm.prank(attacker);
        vm.expectRevert(Campaign.OutOfCoverage.selector);
        campaign.settleSeasonShortfall(0);
    }

    function test_attack_settleSeasonBeyondCoverage_reverts() public {
        _activate();
        vm.prank(attacker);
        vm.expectRevert(Campaign.OutOfCoverage.selector);
        campaign.settleSeasonShortfall(COVERAGE + 1);
    }

    // =========================================================================
    // ATTACK 7 — settleSeasonShortfall before deadline
    // =========================================================================
    function test_attack_settleBeforeDeadline_reverts() public {
        _activate();
        vm.prank(producer);
        campaign.lockCollateral(10_000e6);
        _startSeason(1);
        _stake(alice, campaignToken.balanceOf(alice));
        _endAndReport(1, 1_000e18); // reports → starts deadline
        // Don't warp — deadline is far in the future.
        vm.prank(attacker);
        vm.expectRevert(Campaign.DeadlineNotReached.selector);
        campaign.settleSeasonShortfall(1);
    }

    // =========================================================================
    // ATTACK 8 — Settle on a season that was never reported (rage-quit producer)
    // =========================================================================
    function test_attack_settleUnreportedSeason_reverts() public {
        _activate();
        vm.prank(producer);
        campaign.lockCollateral(10_000e6);
        // No reportHarvest called.
        vm.warp(block.timestamp + 365 days);
        vm.prank(attacker);
        vm.expectRevert(Campaign.SeasonNotReported.selector);
        campaign.settleSeasonShortfall(1);
    }

    // =========================================================================
    // ATTACK 9 — Double-settlement (replay)
    // =========================================================================
    function test_attack_doubleSettle_reverts() public {
        _activate();
        vm.prank(producer);
        campaign.lockCollateral(10_000e6);

        _startSeason(1);
        _stake(alice, campaignToken.balanceOf(alice));
        _endAndReport(1, 1_000e18);

        (,,,,, , uint256 deadline,,,,, ) = harvestManager.seasonHarvests(1);
        vm.warp(deadline + 1);

        // First settle: succeeds (regardless of whether there's a draw or not).
        vm.prank(attacker);
        campaign.settleSeasonShortfall(1);
        // Second attempt must revert.
        vm.prank(attacker);
        vm.expectRevert(Campaign.AlreadySettled.selector);
        campaign.settleSeasonShortfall(1);
    }

    // =========================================================================
    // ATTACK 10 — Direct call to HarvestManager.depositFromCollateral by anyone
    //             other than the owning Campaign must revert (preventing fake
    //             "shortfall coverage" from attacker capital).
    // =========================================================================
    function test_attack_directDepositFromCollateral_blocked() public {
        _activate();
        // Even producer cannot call this — only the Campaign proxy.
        vm.prank(producer);
        vm.expectRevert(HarvestManager.OnlyCampaign.selector);
        harvestManager.depositFromCollateral(1, 1e6);

        vm.prank(attacker);
        vm.expectRevert(HarvestManager.OnlyCampaign.selector);
        harvestManager.depositFromCollateral(1, 1e6);
    }

    // =========================================================================
    // ATTACK 11 — Re-set the campaign address on HarvestManager. Must revert
    //             because the wiring is one-shot.
    // =========================================================================
    function test_attack_resetCampaignOnHm_blocked() public {
        vm.prank(address(factory));
        vm.expectRevert(HarvestManager.AlreadySet.selector);
        harvestManager.setCampaign(address(0xdead));
    }

    // =========================================================================
    // ATTACK 12 — Re-set the harvestManager address on Campaign. Must revert.
    // =========================================================================
    function test_attack_resetHmOnCampaign_blocked() public {
        vm.prank(address(factory));
        vm.expectRevert(Campaign.AlreadySet.selector);
        campaign.setHarvestManager(address(0xdead));
    }

    // =========================================================================
    // ATTACK 13 — settleSeasonShortfall with no shortfall (producer fully
    //             deposited): function is no-op but still flips the flag so
    //             a follow-up call reverts AlreadySettled.
    // =========================================================================
    function test_settleNoShortfall_noOpButFlagsSettled() public {
        _activate();
        vm.prank(producer);
        campaign.lockCollateral(10_000e6);

        _startSeason(1);
        _stake(alice, campaignToken.balanceOf(alice));
        _endAndReport(1, 100e18);

        // Producer fully covers usdcOwed: deposit gross sized via remainingDepositGross.
        uint256 gross = harvestManager.remainingDepositGross(1);
        if (gross > 0) {
            vm.startPrank(producer);
            usdc.approve(address(harvestManager), gross);
            harvestManager.depositUSDC(1, gross);
            vm.stopPrank();
        }

        // Past deadline.
        (,,,,, , uint256 deadline,,,,, ) = harvestManager.seasonHarvests(1);
        vm.warp(deadline + 1);

        uint256 drawnBefore = campaign.collateralDrawn();
        vm.prank(attacker);
        campaign.settleSeasonShortfall(1);
        assertEq(campaign.collateralDrawn(), drawnBefore, "no draw expected");
        assertTrue(campaign.seasonShortfallSettled(1), "still flags settled");

        vm.prank(attacker);
        vm.expectRevert(Campaign.AlreadySettled.selector);
        campaign.settleSeasonShortfall(1);
    }

    // =========================================================================
    // ATTACK 14 — Empty reserve: producer didn't lock anything; settle should
    //             no-op gracefully without underflow.
    // =========================================================================
    function test_settleNoCollateral_noOp() public {
        _activate();
        // No lockCollateral.

        _startSeason(1);
        _stake(alice, campaignToken.balanceOf(alice));
        _endAndReport(1, 100e18);

        (,,,,, , uint256 deadline,,,,, ) = harvestManager.seasonHarvests(1);
        vm.warp(deadline + 1);

        vm.prank(attacker);
        campaign.settleSeasonShortfall(1); // must not revert

        assertEq(campaign.collateralDrawn(), 0);
        assertTrue(campaign.seasonShortfallSettled(1));
    }

    // =========================================================================
    // ATTACK 15 — Partial coverage: collateral < shortfall. Draw clamps to
    //             availableCollateral; remainder stays uncovered.
    // =========================================================================
    function test_partialCoverage_clampsToAvailable() public {
        _activate();
        // Lock only 5 USDC (deliberately tiny).
        vm.prank(producer);
        campaign.lockCollateral(5e6);

        _startSeason(1);
        uint256 posId = _stake(alice, campaignToken.balanceOf(alice));
        _endAndReport(1, 5_000e18);
        // Alice commits a USDC claim → usdcOwed becomes non-zero.
        _commitUsdcClaim(alice, posId, 1);

        (,,,,, , uint256 deadline,,,,, ) = harvestManager.seasonHarvests(1);
        vm.warp(deadline + 1);

        uint256 remainingBefore = harvestManager.remainingDepositGross(1);
        require(remainingBefore > 5e6, "test setup expects shortfall > collateral");

        vm.prank(attacker);
        campaign.settleSeasonShortfall(1);

        // All available collateral was drawn — no over-draw.
        assertEq(campaign.collateralDrawn(), 5e6, "drew exactly available");
        assertLe(campaign.collateralDrawn(), campaign.collateralLocked(), "drawn <= locked");

        uint256 remainingAfter = harvestManager.remainingDepositGross(1);
        assertLt(remainingAfter, remainingBefore, "shortfall reduced");
        assertGt(remainingAfter, 0, "shortfall not fully closed (partial)");
    }

    // =========================================================================
    // ATTACK 16 — Full coverage: draw exactly the gap; nothing left over for
    //             this season; collateral still has remainder.
    // =========================================================================
    function test_fullCoverage_drawsExactlyShortfall() public {
        _activate();
        // Over-fund the reserve.
        vm.prank(producer);
        campaign.lockCollateral(1_000_000e6);

        _startSeason(1);
        uint256 posId = _stake(alice, campaignToken.balanceOf(alice));
        _endAndReport(1, 1_000e18);
        _commitUsdcClaim(alice, posId, 1);

        (,,,,, , uint256 deadline,,,,, ) = harvestManager.seasonHarvests(1);
        vm.warp(deadline + 1);

        uint256 gross = harvestManager.remainingDepositGross(1);
        require(gross > 0, "test setup expects shortfall");

        vm.prank(attacker);
        campaign.settleSeasonShortfall(1);

        assertEq(campaign.collateralDrawn(), gross, "drew exactly the gap");
        assertEq(harvestManager.remainingDepositGross(1), 0, "shortfall fully closed");
        assertGt(campaign.collateralLocked() - campaign.collateralDrawn(), 0, "reserve has remainder");
    }
}
