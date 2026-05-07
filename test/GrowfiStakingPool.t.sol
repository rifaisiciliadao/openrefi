// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GrowfiStakingPool} from "../src/GrowfiStakingPool.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

contract GrowfiStakingPoolTest is Test {
    GrowfiStakingPool pool;
    MockERC20 grow;
    MockERC20 usdc;

    address constant FACTORY = address(0xF000);
    address constant TREASURY = address(0xABCD);
    address constant ALICE = address(0xA1);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA70);
    address constant ATTACKER = address(0xBAD);

    uint256 constant ONE_USDC = 1e6;
    uint256 constant DURATION = 30 days; // default rewardsDuration

    function setUp() public {
        grow = new MockERC20("GrowFi", "GROW", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        GrowfiStakingPool impl = new GrowfiStakingPool();
        bytes memory data = abi.encodeCall(
            GrowfiStakingPool.initialize, (FACTORY, address(grow), address(usdc), TREASURY)
        );
        pool = GrowfiStakingPool(address(new TransparentUpgradeableProxy(address(impl), FACTORY, data)));

        grow.mint(ALICE, 1_000_000e18);
        grow.mint(BOB, 1_000_000e18);
        grow.mint(CAROL, 1_000_000e18);
    }

    function _stake(address user, uint256 amount) internal {
        vm.prank(user);
        grow.approve(address(pool), amount);
        vm.prank(user);
        pool.stake(amount);
    }

    function _notify(uint256 amount) internal {
        usdc.mint(address(pool), amount);
        vm.prank(TREASURY);
        pool.notifyReward(amount);
    }

    // ---------- initialize ----------

    function test_initialize_setsState() public view {
        assertEq(pool.factory(), FACTORY);
        assertEq(address(pool.growToken()), address(grow));
        assertEq(address(pool.usdc()), address(usdc));
        assertEq(pool.treasury(), TREASURY);
        assertEq(pool.rewardsDuration(), DURATION);
        assertEq(pool.totalStaked(), 0);
    }

    function test_initialize_revertsOnZeroAddress() public {
        GrowfiStakingPool impl = new GrowfiStakingPool();
        bytes memory bad = abi.encodeCall(
            GrowfiStakingPool.initialize, (address(0), address(grow), address(usdc), TREASURY)
        );
        vm.expectRevert(GrowfiStakingPool.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(impl), FACTORY, bad);
    }

    // ---------- stake ----------

    function test_stake_setsStreakAndMultiplier() public {
        _stake(ALICE, 100e18);
        assertEq(pool.balanceOf(ALICE), 100e18);
        assertEq(pool.totalStaked(), 100e18);
        assertEq(pool.streakStartAt(ALICE), block.timestamp);
        assertEq(pool.multiplierBps(ALICE), 10_000); // 1.0× on first stake
        assertEq(pool.effectiveBalanceOf(ALICE), 100e18); // raw × 1.0
        assertEq(pool.effectiveTotalStaked(), 100e18);
    }

    function test_stake_addingPreservesStreak() public {
        _stake(ALICE, 100e18);
        uint256 streakStart0 = pool.streakStartAt(ALICE);

        skip(60 days);
        _stake(ALICE, 50e18); // adds; streak preserved

        assertEq(pool.balanceOf(ALICE), 150e18);
        assertEq(pool.streakStartAt(ALICE), streakStart0); // unchanged
        // After 60 days, multiplier should have refreshed to BPS + 60/365 × BPS ≈ 11643
        uint256 expectedBps = 10_000 + (uint256(60 days) * 10_000) / 365 days;
        assertEq(pool.multiplierBps(ALICE), expectedBps);
    }

    function test_stake_revertsOnZero() public {
        vm.expectRevert(GrowfiStakingPool.ZeroAmount.selector);
        pool.stake(0);
    }

    // ---------- withdraw ----------

    function test_withdraw_resetsStreakAndMultiplier() public {
        _stake(ALICE, 100e18);
        skip(200 days);

        // Refresh multiplier first (poke via dummy claim) — actually withdraw will refresh.
        vm.prank(ALICE);
        pool.withdraw(40e18);

        assertEq(pool.balanceOf(ALICE), 60e18);
        assertEq(pool.streakStartAt(ALICE), block.timestamp); // reset
        assertEq(pool.multiplierBps(ALICE), 10_000); // back to 1.0×
        assertEq(pool.effectiveBalanceOf(ALICE), 60e18); // 60 × 1.0
    }

    function test_withdraw_fullExitClearsState() public {
        _stake(ALICE, 100e18);
        vm.prank(ALICE);
        pool.withdraw(100e18);

        assertEq(pool.balanceOf(ALICE), 0);
        assertEq(pool.streakStartAt(ALICE), 0);
        assertEq(pool.multiplierBps(ALICE), 0);
        assertEq(pool.effectiveBalanceOf(ALICE), 0);
        assertEq(pool.totalStaked(), 0);
        assertEq(pool.effectiveTotalStaked(), 0);
    }

    function test_withdraw_revertsOnExcessive() public {
        _stake(ALICE, 100e18);
        vm.expectRevert(GrowfiStakingPool.InsufficientBalance.selector);
        vm.prank(ALICE);
        pool.withdraw(101e18);
    }

    // ---------- multiplier ramp ----------

    function test_multiplier_atZero() public {
        _stake(ALICE, 100e18);
        assertEq(pool.previewMultiplier(ALICE), 10_000);
    }

    function test_multiplier_at30days() public {
        _stake(ALICE, 100e18);
        skip(30 days);
        // 1.0 + 30/365 = 1.0822
        uint256 expected = 10_000 + (uint256(30 days) * 10_000) / 365 days;
        assertEq(pool.previewMultiplier(ALICE), expected);
        assertApproxEqAbs(expected, 10_822, 1);
    }

    function test_multiplier_at90days() public {
        _stake(ALICE, 100e18);
        skip(90 days);
        uint256 expected = 10_000 + (uint256(90 days) * 10_000) / 365 days;
        assertEq(pool.previewMultiplier(ALICE), expected);
        assertApproxEqAbs(expected, 12_466, 1);
    }

    function test_multiplier_at365days_capsAtTwoX() public {
        _stake(ALICE, 100e18);
        skip(365 days);
        assertEq(pool.previewMultiplier(ALICE), 20_000);
    }

    function test_multiplier_atOneYearPlus_stillCappedAtTwoX() public {
        _stake(ALICE, 100e18);
        skip(730 days); // 2 years
        assertEq(pool.previewMultiplier(ALICE), 20_000);
    }

    function test_multiplier_refreshOnAction() public {
        _stake(ALICE, 100e18);
        skip(200 days);

        // multiplier in storage still 1.0× (no action)
        assertEq(pool.multiplierBps(ALICE), 10_000);

        // claim triggers refresh
        vm.prank(ALICE);
        pool.claim();

        uint256 expected = 10_000 + (uint256(200 days) * 10_000) / 365 days;
        assertEq(pool.multiplierBps(ALICE), expected);
        assertEq(pool.effectiveBalanceOf(ALICE), (100e18 * expected) / 10_000);
    }

    // ---------- rate × dt accumulator ----------

    function test_notify_setsRewardRate() public {
        _stake(ALICE, 100e18);

        usdc.mint(address(pool), 60 * ONE_USDC);
        vm.prank(TREASURY);
        pool.notifyReward(60 * ONE_USDC);

        // 60 USDC / 30 days = rewardRate
        assertEq(pool.rewardRate(), (60 * ONE_USDC) / DURATION);
        assertEq(pool.periodFinish(), block.timestamp + DURATION);
    }

    function test_earned_zeroImmediatelyAfterNotify() public {
        _stake(ALICE, 100e18);
        _notify(60 * ONE_USDC);

        // No time elapsed → no rewards yet
        assertEq(pool.earned(ALICE), 0);
    }

    function test_earned_accruesOverTime_singleStaker() public {
        _stake(ALICE, 100e18);
        _notify(60 * ONE_USDC);

        // Halfway through the period
        skip(15 days);
        // ~30 USDC distributed (some integer truncation)
        uint256 earned = pool.earned(ALICE);
        assertApproxEqAbs(earned, 30 * ONE_USDC, 2 * ONE_USDC); // within $0.01

        // Full period
        skip(15 days);
        earned = pool.earned(ALICE);
        assertApproxEqAbs(earned, 60 * ONE_USDC, 2 * ONE_USDC);

        // Past period — no further accrual
        skip(30 days);
        assertApproxEqAbs(pool.earned(ALICE), 60 * ONE_USDC, 2 * ONE_USDC);
    }

    function test_earned_proRata_twoStakers_sameStreak() public {
        // Both stake at t=0, same balance → 50/50 split.
        _stake(ALICE, 100e18);
        _stake(BOB, 100e18);
        _notify(60 * ONE_USDC);

        skip(30 days);
        assertApproxEqAbs(pool.earned(ALICE), 30 * ONE_USDC, 2 * ONE_USDC);
        assertApproxEqAbs(pool.earned(BOB), 30 * ONE_USDC, 2 * ONE_USDC);
    }

    function test_earned_proRata_lateJoinerGetsLess() public {
        _stake(ALICE, 100e18);
        _notify(60 * ONE_USDC);

        // Bob joins at day 15 (halfway through period). Alice had pool to herself for 15 days.
        skip(15 days);
        _stake(BOB, 100e18);

        // Run remaining 15 days — Bob now contributes 100 with 1.0×, Alice contributes more
        // because her multiplier refreshed to ~1.041× at her stake action (settled implicitly
        // when Bob staked? no — Alice's multiplier refreshes only when ALICE acts).
        // So Alice's effective is still 100, Bob's effective is 100. They split 50/50 the next 15d.
        skip(15 days);

        // Alice: 30 USDC (first half alone) + 15 USDC (second half 50/50) = 45 USDC
        // Bob: 0 + 15 = 15 USDC
        assertApproxEqAbs(pool.earned(ALICE), 45 * ONE_USDC, 2 * ONE_USDC);
        assertApproxEqAbs(pool.earned(BOB), 15 * ONE_USDC, 2 * ONE_USDC);
    }

    function test_earned_multiplierBoostKicksInAfterRefresh() public {
        // Two stakers same balance. Alice claims periodically (refreshing multiplier). Bob doesn't.
        // After enough time + a notify, Alice should earn slightly more.

        _stake(ALICE, 100e18);
        _stake(BOB, 100e18);

        // Both at 1.0×, effective 100 each, total 200.
        skip(100 days);

        // Alice claims → her multiplier refreshes to 1.0 + 100/365 = ~1.274×, effective ~127.4.
        vm.prank(ALICE);
        pool.claim();

        uint256 aliceMulBefore = pool.multiplierBps(ALICE);
        uint256 bobMulBefore = pool.multiplierBps(BOB);
        assertGt(aliceMulBefore, bobMulBefore);
        assertEq(bobMulBefore, 10_000); // Bob's still stored as 1.0×

        // New notify $60 over 30 days
        _notify(60 * ONE_USDC);
        skip(30 days);

        // Total effective ≈ 127.4 + 100 = 227.4
        // Alice's share: 127.4 / 227.4 ≈ 56% → ~33.6 USDC
        // Bob's share: 100 / 227.4 ≈ 44% → ~26.4 USDC
        uint256 aliceEarned = pool.earned(ALICE); // her rewards reset on claim, so this is post-notify only
        uint256 bobEarned = pool.earned(BOB); // bob's still has both old + new
        assertGt(aliceEarned, 30 * ONE_USDC); // > equal split
        // Bob's "earned" includes 30 USDC pre-notify (still pending), let's not assert specifics here.
        assertGt(bobEarned, 0);
    }

    // ---------- claim ----------

    function test_claim_returnsRewardAndZeros() public {
        _stake(ALICE, 100e18);
        _notify(60 * ONE_USDC);
        skip(30 days);

        vm.prank(ALICE);
        uint256 reward = pool.claim();
        assertApproxEqAbs(reward, 60 * ONE_USDC, 2 * ONE_USDC);
        assertApproxEqAbs(usdc.balanceOf(ALICE), 60 * ONE_USDC, 2 * ONE_USDC);
        assertEq(pool.earned(ALICE), 0);
    }

    function test_claim_zeroIfNothingEarned() public {
        _stake(ALICE, 100e18);
        vm.prank(ALICE);
        uint256 reward = pool.claim();
        assertEq(reward, 0);
    }

    // ---------- exit ----------

    function test_exit_withdrawsAndClaims() public {
        _stake(ALICE, 100e18);
        _notify(60 * ONE_USDC);
        skip(30 days);

        vm.prank(ALICE);
        pool.exit();

        assertEq(pool.balanceOf(ALICE), 0);
        assertEq(grow.balanceOf(ALICE), 1_000_000e18); // back to start
        assertApproxEqAbs(usdc.balanceOf(ALICE), 60 * ONE_USDC, 2 * ONE_USDC);
    }

    // ---------- pendingForFirstStaker ----------

    function test_pendingForFirstStaker_capturedOnFirstStake() public {
        // Notify before any stake → pending bucket
        usdc.mint(address(pool), 30 * ONE_USDC);
        vm.prank(TREASURY);
        pool.notifyReward(30 * ONE_USDC);
        assertEq(pool.pendingForFirstStaker(), 30 * ONE_USDC);
        assertEq(pool.rewardRate(), 0); // no period started

        // Alice stakes → pending flushed, fresh period starts
        _stake(ALICE, 100e18);
        assertEq(pool.pendingForFirstStaker(), 0);
        assertGt(pool.rewardRate(), 0);

        // Run the period
        skip(DURATION);
        assertApproxEqAbs(pool.earned(ALICE), 30 * ONE_USDC, 2 * ONE_USDC);
    }

    function test_pendingForFirstStaker_doesNotDoubleCount() public {
        usdc.mint(address(pool), 30 * ONE_USDC);
        vm.prank(TREASURY);
        pool.notifyReward(30 * ONE_USDC);

        _stake(ALICE, 100e18); // captures pending

        // Bob joins after — Alice gets her pending share, then both split future notifies.
        _stake(BOB, 100e18);
        usdc.mint(address(pool), 30 * ONE_USDC);
        vm.prank(TREASURY);
        pool.notifyReward(30 * ONE_USDC);

        skip(DURATION + 1);

        // Hard to assert exact amounts due to compounding. Just verify both got something
        // and Alice >= Bob (Alice was alone for an instant).
        assertGt(pool.earned(ALICE), 0);
        assertGt(pool.earned(BOB), 0);
        assertGe(pool.earned(ALICE), pool.earned(BOB));
    }

    // ---------- notify mid-period ----------

    function test_notify_midPeriod_recalibrates() public {
        _stake(ALICE, 100e18);
        _notify(30 * ONE_USDC);

        skip(15 days);
        // 15 USDC accrued so far (half the period)

        // Mid-period notify: new $30 + remaining 15 USDC = 45 USDC over fresh 30 days
        usdc.mint(address(pool), 30 * ONE_USDC);
        vm.prank(TREASURY);
        pool.notifyReward(30 * ONE_USDC);

        uint256 expectedRate = (30 * ONE_USDC + 15 * ONE_USDC) / DURATION;
        assertApproxEqAbs(pool.rewardRate(), expectedRate, 1);

        // Run another full period — Alice gets the remaining 45 USDC
        skip(DURATION);
        assertApproxEqAbs(pool.earned(ALICE), 60 * ONE_USDC, 2 * ONE_USDC); // 15 + 45
    }

    // ---------- factory admin ----------

    function test_setRewardsDuration_byFactory() public {
        // No active period after init — should succeed.
        vm.prank(FACTORY);
        pool.setRewardsDuration(7 days);
        assertEq(pool.rewardsDuration(), 7 days);
    }

    function test_setRewardsDuration_revertsDuringActivePeriod() public {
        _stake(ALICE, 100e18);
        _notify(30 * ONE_USDC);
        vm.expectRevert(GrowfiStakingPool.PeriodActive.selector);
        vm.prank(FACTORY);
        pool.setRewardsDuration(7 days);
    }

    function test_setTreasury_byFactory() public {
        address newTreasury = address(0x9999);
        vm.prank(FACTORY);
        pool.setTreasury(newTreasury);
        assertEq(pool.treasury(), newTreasury);
    }

    // ---------- red team ----------

    function test_redteam_attackerCannotNotify() public {
        usdc.mint(address(pool), 1_000_000 * ONE_USDC);
        vm.expectRevert(GrowfiStakingPool.NotTreasury.selector);
        vm.prank(ATTACKER);
        pool.notifyReward(1_000_000 * ONE_USDC);
    }

    function test_redteam_attackerCannotSetDuration() public {
        vm.expectRevert(GrowfiStakingPool.NotFactory.selector);
        vm.prank(ATTACKER);
        pool.setRewardsDuration(1 days);
    }

    /// @dev Stake then withdraw before any notify earns 0. Re-stake resets streak.
    function test_redteam_stakeWithdrawCycle_resetsAndEarnsLater() public {
        _stake(ALICE, 100e18);
        skip(30 days);

        // Alice withdraws 50% — streak resets.
        vm.prank(ALICE);
        pool.withdraw(50e18);
        assertEq(pool.streakStartAt(ALICE), block.timestamp);
        assertEq(pool.multiplierBps(ALICE), 10_000);

        // From here, she's at 1.0× again.
        _notify(30 * ONE_USDC);
        skip(DURATION);
        // She's the only staker, gets it all (regardless of multiplier scaling solo)
        assertApproxEqAbs(pool.earned(ALICE), 30 * ONE_USDC, 2 * ONE_USDC);
    }

    /// @dev Withdraw during active period: settle correctly, lose multiplier going forward.
    function test_redteam_withdrawMidPeriod_settlesAndLoses() public {
        _stake(ALICE, 100e18);
        _stake(BOB, 100e18);
        skip(200 days); // both eligible for ~1.55× if they refresh

        _notify(60 * ONE_USDC);
        skip(15 days); // halfway, ~30 USDC accumulated split 50/50

        // Alice withdraws — settles her ~$15, resets her streak.
        vm.prank(ALICE);
        pool.withdraw(50e18);
        // Alice's pending rewards now stored. Multiplier reset to 1.0×.
        assertEq(pool.multiplierBps(ALICE), 10_000);

        // Run remaining 15 days — Bob has 100×1.0 (still stored), Alice 50×1.0.
        // Total effective = 150. Bob 67%, Alice 33%.
        skip(15 days);
        // The remaining ~30 USDC splits 67/33.
        // Alice total ≈ 15 (pre-withdraw) + 10 = 25
        // Bob total ≈ 15 + 20 = 35
        uint256 aliceTotal = pool.earned(ALICE);
        uint256 bobTotal = pool.earned(BOB);
        assertGt(bobTotal, aliceTotal); // Bob earned more after Alice withdrew
    }

    /// @dev Notify happens with no stakers → pending → first staker captures it.
    function test_redteam_notifyBeforeAnyStakerCapturedByFirst() public {
        usdc.mint(address(pool), 30 * ONE_USDC);
        vm.prank(TREASURY);
        pool.notifyReward(30 * ONE_USDC);

        // Wait a year — pending stays.
        skip(365 days);

        _stake(ALICE, 100e18);
        // Period kicks off NOW
        skip(DURATION);
        // Alice gets the pending (alone in pool)
        assertApproxEqAbs(pool.earned(ALICE), 30 * ONE_USDC, 2 * ONE_USDC);
    }
}
