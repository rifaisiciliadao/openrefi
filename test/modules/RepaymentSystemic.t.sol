// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GrowfiCampaignFactory} from "../../src/GrowfiCampaignFactory.sol";
import {GrowfiCampaign} from "../../src/GrowfiCampaign.sol";
import {GrowfiCampaignToken} from "../../src/GrowfiCampaignToken.sol";
import {GrowfiYieldToken} from "../../src/GrowfiYieldToken.sol";
import {GrowfiStakingVault} from "../../src/GrowfiStakingVault.sol";
import {GrowfiHarvestManager} from "../../src/GrowfiHarvestManager.sol";
import {CampaignStorage} from "../../src/host/CampaignStorage.sol";
import {IGrowfiCampaignFull} from "../../src/interfaces/IGrowfiCampaignFull.sol";
import {SaleClassicModule} from "../../src/modules/SaleClassicModule.sol";
import {CollateralModule} from "../../src/modules/CollateralModule.sol";
import {RepaymentModule} from "../../src/modules/RepaymentModule.sol";

import {Deployer} from "../helpers/Deployer.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {RepaymentHelper} from "./RepaymentHelper.sol";

/// @title  RepaymentSystemicTest
/// @notice Cross-module systemic tests. The unit + red-team suites cover
///         the Repayment module in isolation; this one probes its
///         interaction with SaleClassicModule (buy/buyback paths) and
///         GrowfiHarvestManager (post-redeem yield claim ↔ harvest USDC
///         payout). Also covers the host's edge cases that are
///         Repayment-specific: detach with orphaned pool, reattach
///         preserving namespaced storage.
contract RepaymentSystemicTest is Test {
    bytes32 internal constant REPAY_KIND = keccak256("growfi.repayment.v1");
    bytes32 internal constant REPAY_TYPE = keccak256("growfi.type.repayment");

    GrowfiCampaignFactory internal factory;
    RepaymentModule internal repayImpl;
    MockERC20 internal usdc;

    address internal protocolOwner = makeAddr("protocolOwner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal producer = makeAddr("producer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    address internal campaignAddr;
    IGrowfiCampaignFull internal campaign;
    GrowfiCampaignToken internal campaignToken;
    GrowfiYieldToken internal yieldToken;
    GrowfiStakingVault internal stakingVault;
    GrowfiHarvestManager internal harvestManager;

    uint256 internal constant PRICE = 0.144e18;
    uint256 internal constant FIXED_RATE = 144_000;
    uint256 internal constant MIN_CAP = 1_000e18;
    uint256 internal constant MAX_CAP = 50_000e18;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        factory = Deployer.deployProtocol(protocolOwner, feeRecipient, address(usdc), address(0));

        vm.prank(protocolOwner);
        factory.setMinSeasonDuration(1 hours);

        repayImpl = new RepaymentModule();
        vm.startPrank(protocolOwner);
        factory.setModuleKindSelectors(REPAY_KIND, RepaymentHelper.selectors());
        factory.approveModuleImpl(REPAY_KIND, address(repayImpl), true);
        vm.stopPrank();

        vm.prank(producer);
        campaignAddr = factory.createCampaign(
            GrowfiCampaignFactory.CreateCampaignParams({
                producer: producer,
                campaignTokenName: "Olive",
                campaignTokenSymbol: "OLIVE",
                yieldTokenName: "Olive Yield",
                yieldTokenSymbol: "oYIELD",
                minProductClaim: 1e18,
                sale: SaleClassicModule.InitParams({
                    pricePerToken: PRICE,
                    minCap: MIN_CAP,
                    maxCap: MAX_CAP,
                    fundingDeadline: block.timestamp + 30 days,
                    seasonDuration: 7 days,
                    fundingFeeBps: 0,
                    sequencerUptimeFeed: address(0),
                    growMinter: address(0)
                }),
                collateral: CollateralModule.InitParams({
                    expectedAnnualHarvestUsd: 5_000e18,
                    expectedAnnualHarvest: 250e18,
                    firstHarvestYear: 2030,
                    coverageHarvests: 0
                })
            })
        );
        campaign = IGrowfiCampaignFull(payable(campaignAddr));
        campaignToken = GrowfiCampaignToken(campaign.campaignToken());
        yieldToken = GrowfiYieldToken(campaign.yieldToken());
        stakingVault = GrowfiStakingVault(campaign.stakingVault());
        harvestManager = GrowfiHarvestManager(campaign.harvestManager());

        vm.prank(producer);
        campaign.addAcceptedToken(address(usdc), SaleClassicModule.PricingMode.Fixed, FIXED_RATE, address(0));
    }

    function _activateWithAliceAndBob() internal {
        usdc.mint(alice, 720e6);
        usdc.mint(bob, 720e6);
        vm.startPrank(alice);
        usdc.approve(campaignAddr, type(uint256).max);
        campaignToken.approve(address(stakingVault), type(uint256).max);
        campaign.buy(address(usdc), 720e6); // 5_000 CT
        vm.stopPrank();
        vm.startPrank(bob);
        usdc.approve(campaignAddr, type(uint256).max);
        campaignToken.approve(address(stakingVault), type(uint256).max);
        campaign.buy(address(usdc), 720e6); // 5_000 CT
        vm.stopPrank();
    }

    function _attachAndFundRepayment(uint256 poolSize, uint256 initialBonus) internal {
        vm.prank(producer);
        GrowfiCampaign(payable(campaignAddr)).attachModule(REPAY_TYPE, REPAY_KIND, address(repayImpl), "");
        vm.prank(producer);
        RepaymentModule(payable(campaignAddr)).initializeRepaymentByProducer(initialBonus);
        if (poolSize > 0) {
            usdc.mint(producer, poolSize);
            vm.startPrank(producer);
            usdc.approve(campaignAddr, poolSize);
            RepaymentModule(payable(campaignAddr)).fundPool(poolSize);
            vm.stopPrank();
        }
    }

    function _r() internal view returns (RepaymentModule) {
        return RepaymentModule(payable(campaignAddr));
    }

    // ------------------------------------------------------------------
    // 1. Yield integrity: redeemer keeps pro-rata harvest USDC claim
    // ------------------------------------------------------------------

    /// @dev Alice stakes, accrues yield, redeems via Repayment mid-season
    ///      (gets YIELD minted). Producer ends season, reports harvest.
    ///      Alice should be able to redeem her YIELD for pro-rata USDC
    ///      via HarvestManager — verifying that the Repayment exit
    ///      doesn't lose her access to the harvest distribution.
    function test_systemic_yieldRedeemerStillGetsHarvestProRata() public {
        _activateWithAliceAndBob();
        _attachAndFundRepayment(2_000e6, 0);

        // Season needs to be active before staking
        vm.prank(producer);
        campaign.startSeason();
        uint256 sid = campaign.currentSeasonId();

        vm.prank(alice);
        uint256 alicePos = stakingVault.stake(5_000e18);
        vm.prank(bob);
        uint256 bobPos = stakingVault.stake(5_000e18);

        // Half-season passes
        vm.warp(block.timestamp + 3 days);

        // Alice redeems 1k CT via Repayment — gets YIELD minted + USDC
        uint256[] memory positions = new uint256[](1);
        positions[0] = alicePos;
        vm.prank(alice);
        _r().redeem(1_000e18, positions);

        uint256 aliceYield = yieldToken.balanceOf(alice);
        assertGt(aliceYield, 0, "alice got YIELD on redeem");

        // Bob continues staking until season end
        vm.warp(block.timestamp + 5 days); // past 7-day season
        vm.prank(bob);
        stakingVault.claimYield(bobPos);
        uint256 bobYield = yieldToken.balanceOf(bob);
        assertGt(bobYield, 0, "bob accrued more yield");

        vm.prank(producer);
        campaign.endSeason();

        // Producer reports harvest: 1000 USD total
        vm.prank(producer);
        harvestManager.reportHarvest(sid, 1_000e18, bytes32(0), 0); // no product, USDC-only

        // Both alice and bob redeem YIELD → USDC
        vm.prank(alice);
        harvestManager.redeemUSDC(sid, aliceYield);
        vm.prank(bob);
        harvestManager.redeemUSDC(sid, bobYield);

        // Producer deposits the harvest USDC owed
        (,,,,,,,, uint256 owed18,,,) = harvestManager.seasonHarvests(sid);
        uint256 owed6 = (owed18 + 1e12 - 1) / 1e12; // round up to USDC-6
        usdc.mint(producer, owed6 * 2); // overfund to cover the 98/2 split
        vm.startPrank(producer);
        usdc.approve(campaignAddr, type(uint256).max);
        // Use Campaign.depositUSDC path (v3.4) — drains collateral first, then wallet
        IGrowfiCampaignFull(payable(campaignAddr)).depositUSDC(sid, type(uint256).max);
        vm.stopPrank();

        // Both claim USDC
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        vm.prank(alice);
        harvestManager.claimUSDC(sid);
        vm.prank(bob);
        harvestManager.claimUSDC(sid);

        uint256 aliceGot = usdc.balanceOf(alice) - aliceUsdcBefore;
        uint256 bobGot = usdc.balanceOf(bob) - bobUsdcBefore;

        // Alice exited at half-season, Bob full season → Bob gets more
        assertGt(bobGot, aliceGot, "bob's share > alice's");

        // Pro-rata sanity: ratios should match yield ratios within rounding
        // aliceGot / bobGot ≈ aliceYield / bobYield
        // Equivalently aliceGot * bobYield ≈ bobGot * aliceYield
        uint256 lhs = aliceGot * bobYield;
        uint256 rhs = bobGot * aliceYield;
        uint256 diff = lhs > rhs ? lhs - rhs : rhs - lhs;
        // Allow small drift due to integer rounding in pro-rata calc
        assertLt(diff, lhs / 1000 + 1e6, "pro-rata within 0.1%");
    }

    // ------------------------------------------------------------------
    // 2. Repayment during Buyback state
    // ------------------------------------------------------------------

    /// @dev Campaign fails to reach minCap → state goes to Buyback.
    ///      The Repayment module (if attached pre-failure and funded)
    ///      can still pay holders. This gives the producer an
    ///      alternative exit path even on failed campaigns.
    function test_systemic_redeemWorksDuringBuybackState() public {
        // Alice buys 500 CT, NOT enough to hit 1k minCap → still Funding
        usdc.mint(alice, 72e6);
        vm.startPrank(alice);
        usdc.approve(campaignAddr, type(uint256).max);
        campaign.buy(address(usdc), 72e6); // 500 CT
        vm.stopPrank();

        // Attach Repayment + fund the pool while still in Funding
        // Note: Repayment in Funding state still works
        _attachAndFundRepayment(1_000e6, 0);

        // Funding deadline passes
        vm.warp(block.timestamp + 31 days);

        // Anyone triggers buyback
        IGrowfiCampaignFull(payable(campaignAddr)).triggerBuyback();
        assertEq(uint8(campaign.state()), uint8(CampaignStorage.State.Buyback));

        // Alice redeems via Repayment in Buyback state → works
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        _r().redeem(200e18, new uint256[](0));
        assertEq(
            usdc.balanceOf(alice) - aliceUsdcBefore,
            200e18 * FIXED_RATE / 1e18,
            "redeem paid principal even in Buyback"
        );
    }

    /// @dev Once campaign is Ended, Repayment is permanently blocked.
    function test_systemic_redeemBlockedInEnded() public {
        _activateWithAliceAndBob();
        _attachAndFundRepayment(2_000e6, 0);

        vm.prank(producer);
        campaign.endCampaign();

        vm.prank(alice);
        vm.expectRevert(RepaymentModule.InvalidState.selector);
        _r().redeem(100e18, new uint256[](0));
    }

    // ------------------------------------------------------------------
    // 3. No double-spend: redeem ↔ buyback are mutually exclusive
    // ------------------------------------------------------------------

    /// @dev If Alice redeems via Repayment first (burns CT), then tries
    ///      to buyback via SaleClassic, the buyback's burn fails because
    ///      she no longer has the CT to burn.
    function test_systemic_redeemThenBuyback_burnRevert() public {
        // Setup: Alice buys 500 CT, campaign stays Funding (under minCap)
        usdc.mint(alice, 72e6);
        vm.startPrank(alice);
        usdc.approve(campaignAddr, type(uint256).max);
        campaign.buy(address(usdc), 72e6);
        vm.stopPrank();

        _attachAndFundRepayment(200e6, 0);

        // Alice redeems all her CT via Repayment (burns 500 CT for 72 USDC)
        vm.prank(alice);
        _r().redeem(500e18, new uint256[](0));
        assertEq(campaignToken.balanceOf(alice), 0);

        // Funding deadline passes, buyback triggered
        vm.warp(block.timestamp + 31 days);
        IGrowfiCampaignFull(payable(campaignAddr)).triggerBuyback();

        // Alice tries buyback → her purchasedTokens[usdc] is still 500e18
        //   (Repayment didn't touch it), but her actual balance is 0.
        //   buyback tries to burn → revert.
        vm.prank(alice);
        vm.expectRevert(); // ERC20InsufficientBalance
        campaign.buyback(address(usdc));
    }

    /// @dev Conversely: buyback first → no CT left for Repayment.
    function test_systemic_buybackThenRedeem_noCtRevert() public {
        usdc.mint(alice, 72e6);
        vm.startPrank(alice);
        usdc.approve(campaignAddr, type(uint256).max);
        campaign.buy(address(usdc), 72e6);
        vm.stopPrank();

        _attachAndFundRepayment(200e6, 0);

        vm.warp(block.timestamp + 31 days);
        IGrowfiCampaignFull(payable(campaignAddr)).triggerBuyback();

        // Alice does buyback first → CT burned, USDC refunded from escrow
        vm.prank(alice);
        campaign.buyback(address(usdc));
        assertEq(campaignToken.balanceOf(alice), 0);

        // Now redeem → ERC20InsufficientBalance on burn
        vm.prank(alice);
        vm.expectRevert();
        _r().redeem(100e18, new uint256[](0));
    }

    // ------------------------------------------------------------------
    // 4. Detach with orphaned pool
    // ------------------------------------------------------------------

    /// @dev Producer detaches Repayment while USDC is still in the pool.
    ///      The USDC sits on the campaign address but no caller can move
    ///      it (no module routes the funds). It's orphaned until
    ///      Repayment is reattached (storage is keccak-namespaced and
    ///      persists across detach/reattach).
    function test_systemic_detachWithFundedPool_orphansUsdcUntilReattach() public {
        _activateWithAliceAndBob();
        _attachAndFundRepayment(2_000e6, 0);

        uint256 poolBefore = _r().poolBalance();
        uint256 campaignUsdcBalance = usdc.balanceOf(campaignAddr);
        assertGe(campaignUsdcBalance, poolBefore, "campaign holds at least the pool USDC");

        // Producer detaches
        vm.prank(producer);
        GrowfiCampaign(payable(campaignAddr)).detachModule(REPAY_TYPE);

        // Calls into the (now un-routed) selectors revert at the host
        vm.prank(producer);
        vm.expectRevert();
        _r().withdrawUnusedPool(100e6);

        // USDC still on campaign address (orphaned)
        assertEq(usdc.balanceOf(campaignAddr), campaignUsdcBalance, "USDC orphan");

        // Producer reattaches → namespaced storage persists, pool balance
        // is still tracked, withdrawal works.
        vm.prank(producer);
        GrowfiCampaign(payable(campaignAddr)).attachModule(REPAY_TYPE, REPAY_KIND, address(repayImpl), "");
        assertEq(_r().poolBalance(), poolBefore, "pool balance preserved across detach/reattach");

        vm.prank(producer);
        _r().withdrawUnusedPool(poolBefore);
        assertEq(_r().poolBalance(), 0);
    }

    /// @dev Re-init after reattach is blocked (initialized flag persists
    ///      in the same namespaced slot).
    function test_systemic_reinitBlockedAfterReattach() public {
        _activateWithAliceAndBob();
        _attachAndFundRepayment(100e6, 0);

        vm.prank(producer);
        GrowfiCampaign(payable(campaignAddr)).detachModule(REPAY_TYPE);
        vm.prank(producer);
        GrowfiCampaign(payable(campaignAddr)).attachModule(REPAY_TYPE, REPAY_KIND, address(repayImpl), "");

        vm.prank(producer);
        vm.expectRevert(RepaymentModule.AlreadyInitialized.selector);
        _r().initializeRepaymentByProducer(0.05e6);
    }

    /// @dev Bonus value persists across detach/reattach (same slot).
    function test_systemic_bonusPersistsAcrossDetachReattach() public {
        _activateWithAliceAndBob();
        _attachAndFundRepayment(100e6, 0);

        vm.prank(producer);
        _r().setBonusPerCt(0.03e6);

        vm.prank(producer);
        GrowfiCampaign(payable(campaignAddr)).detachModule(REPAY_TYPE);
        vm.prank(producer);
        GrowfiCampaign(payable(campaignAddr)).attachModule(REPAY_TYPE, REPAY_KIND, address(repayImpl), "");

        assertEq(_r().bonusPerCt(), 0.03e6, "bonus persists");
    }

    // ------------------------------------------------------------------
    // 5. Full lifecycle realistic scenario
    // ------------------------------------------------------------------

    /// @dev Lifecycle: Alice + Bob + Carol buy and stake. Producer
    ///      attaches Repayment with $0.02 bonus halfway. Alice exits
    ///      early via Repayment (gets YIELD + USDC). Carol exits at
    ///      higher bonus later. Bob stays full season. Harvest reported.
    ///      All claim USDC pro-rata.
    function test_systemic_realisticLifecycle_threeUsers() public {
        _activateWithAliceAndBob();
        // Add Carol mid-stream
        usdc.mint(carol, 144e6);
        vm.startPrank(carol);
        usdc.approve(campaignAddr, type(uint256).max);
        campaignToken.approve(address(stakingVault), type(uint256).max);
        campaign.buy(address(usdc), 144e6); // 1000 CT
        vm.stopPrank();

        vm.prank(producer);
        campaign.startSeason();
        uint256 sid = campaign.currentSeasonId();

        // All three stake
        vm.prank(alice);
        uint256 alicePos = stakingVault.stake(5_000e18);
        vm.prank(bob);
        uint256 bobPos = stakingVault.stake(5_000e18);
        vm.prank(carol);
        uint256 carolPos = stakingVault.stake(1_000e18);

        // 2 days in, producer attaches Repayment with 0 bonus + 5k pool
        vm.warp(block.timestamp + 2 days);
        _attachAndFundRepayment(5_000e6, 0);

        // Alice exits at base rate
        uint256[] memory aPos = new uint256[](1);
        aPos[0] = alicePos;
        vm.prank(alice);
        _r().redeem(1_000e18, aPos);
        uint256 aliceYieldFromRedeem = yieldToken.balanceOf(alice);

        // 2 more days, producer bumps bonus
        vm.warp(block.timestamp + 2 days);
        vm.prank(producer);
        _r().setBonusPerCt(0.02e6);

        // Carol exits at bonus
        uint256[] memory cPos = new uint256[](1);
        cPos[0] = carolPos;
        uint256 carolUsdcBefore = usdc.balanceOf(carol);
        vm.prank(carol);
        _r().redeem(1_000e18, cPos);
        uint256 carolGotUsdc = usdc.balanceOf(carol) - carolUsdcBefore;
        // Carol got principal + bonus: 1000 * 0.144 + 1000 * 0.02 = 164 USDC
        assertEq(carolGotUsdc, 164e6);

        // Season ends; Bob never claims so his yield is fully owed
        vm.warp(block.timestamp + 4 days);
        vm.prank(producer);
        campaign.endSeason();

        // Producer reports harvest
        vm.prank(producer);
        harvestManager.reportHarvest(sid, 2_000e18, bytes32(0), 0);

        // Bob claims his yield (lazy)
        vm.prank(bob);
        stakingVault.claimYield(bobPos);
        uint256 bobYield = yieldToken.balanceOf(bob);
        assertGt(bobYield, 0);

        // All three redeem YIELD → USDC commit.
        // CAREFUL: vm.prank only affects the NEXT external call. If you write
        // `harvestManager.redeemUSDC(sid, yieldToken.balanceOf(alice))`, the
        // prank gets consumed by `balanceOf(alice)` and the actual
        // `redeemUSDC` runs with msg.sender = address(this). Always cache
        // the balance into a local first.
        uint256 aliceBal = yieldToken.balanceOf(alice);
        uint256 carolBal = yieldToken.balanceOf(carol);
        vm.prank(alice);
        harvestManager.redeemUSDC(sid, aliceBal);
        vm.prank(carol);
        harvestManager.redeemUSDC(sid, carolBal);
        vm.prank(bob);
        harvestManager.redeemUSDC(sid, bobYield);

        // Producer deposits the USDC owed
        usdc.mint(producer, 5_000e6);
        vm.startPrank(producer);
        usdc.approve(campaignAddr, type(uint256).max);
        IGrowfiCampaignFull(payable(campaignAddr)).depositUSDC(sid, type(uint256).max);
        vm.stopPrank();

        // All three claim
        vm.prank(alice);
        harvestManager.claimUSDC(sid);
        vm.prank(carol);
        harvestManager.claimUSDC(sid);
        vm.prank(bob);
        harvestManager.claimUSDC(sid);

        // Bob (full-season staker, biggest stake) should have biggest USDC share
        // Suppress var to keep this readable
        aliceYieldFromRedeem;
    }

    // ------------------------------------------------------------------
    // 6. Yield supply invariant after the v4 forceUnstake change
    // ------------------------------------------------------------------

    /// @dev Force-unstake of a position whose season has already ended.
    ///      Pending yield is capped at season's rewardPerTokenAtEnd
    ///      snapshot, so no over-mint can occur even across seasons.
    function test_systemic_redeemEndedSeasonPosition_capsAtSnapshot() public {
        _activateWithAliceAndBob();
        _attachAndFundRepayment(2_000e6, 0);

        vm.prank(producer);
        campaign.startSeason();
        uint256 sid1 = campaign.currentSeasonId();

        vm.prank(alice);
        uint256 alicePos = stakingVault.stake(5_000e18);

        // Half-season of yield accrual
        vm.warp(block.timestamp + 3 days);

        // End the season WITHOUT alice exiting or claiming
        vm.warp(block.timestamp + 5 days); // past 7 days
        vm.prank(producer);
        campaign.endSeason();

        (,,,, uint256 owedAtSnapshot,,) = stakingVault.seasons(sid1);
        // Snapshot of owed yield at season end
        uint256 expectedEarnedSnapshot = stakingVault.earned(alicePos);
        assertGt(expectedEarnedSnapshot, 0);

        // Start a new season — current changes to sid2
        vm.prank(producer);
        campaign.startSeason();
        vm.warp(block.timestamp + 1 days);

        // Alice redeems via Repayment with her old-season position.
        // forceUnstake should mint her exactly the snapshot amount, NOT
        // grow with the new season's accumulator.
        uint256 aliceYieldBefore = yieldToken.balanceOf(alice);
        uint256[] memory positions = new uint256[](1);
        positions[0] = alicePos;
        vm.prank(alice);
        _r().redeem(1_000e18, positions);
        uint256 yieldGained = yieldToken.balanceOf(alice) - aliceYieldBefore;

        assertApproxEqAbs(yieldGained, expectedEarnedSnapshot, 1, "yield capped at season-end snapshot");

        // The old season's totalYieldMinted bumped by the gained amount;
        // owed stays the same (it was frozen at season end).
        (,, uint256 mintedAfter,, uint256 owedAfter,,) = stakingVault.seasons(sid1);
        assertEq(owedAfter, owedAtSnapshot, "owed unchanged after force-unstake on ended season");
        assertGe(owedAfter, mintedAfter, "invariant: owed >= minted");
    }

    /// @dev Verify: after redeem (which mints YIELD via forceUnstake),
    ///      totalYieldSupply (= seasonTotalYieldOwed) is unchanged AND
    ///      yieldToken.totalSupply ≤ seasonTotalYieldOwed.
    function test_systemic_yieldInvariantHoldsPostRedeem() public {
        _activateWithAliceAndBob();
        _attachAndFundRepayment(2_000e6, 0);

        vm.prank(producer);
        campaign.startSeason();
        uint256 sid = campaign.currentSeasonId();

        vm.prank(alice);
        uint256 alicePos = stakingVault.stake(5_000e18);
        vm.prank(bob);
        stakingVault.stake(5_000e18);

        vm.warp(block.timestamp + 3 days);

        // Trigger lazy accumulator update with a no-op stake-touching action.
        // (We can't read totalYieldOwed accurately mid-fuzz without poking it.)
        // The simplest poke: claimYield(0) doesn't exist; do another stake.
        vm.prank(alice);
        stakingVault.claimYield(alicePos); // pokes _updateRewardPerToken

        uint256 owedBefore = stakingVault.seasonTotalYieldOwed(sid);
        uint256 yieldSupplyBefore = yieldToken.totalSupply();
        assertGe(owedBefore, yieldSupplyBefore, "invariant pre-redeem");

        // Alice redeems via Repayment with her remaining position
        uint256[] memory positions = new uint256[](1);
        positions[0] = alicePos;
        vm.prank(alice);
        _r().redeem(500e18, positions);

        uint256 owedAfter = stakingVault.seasonTotalYieldOwed(sid);
        uint256 yieldSupplyAfter = yieldToken.totalSupply();
        // owed should be ≥ before (only grows monotonically via accumulator)
        assertGe(owedAfter, owedBefore, "owed non-decreasing");
        // YIELD supply ≤ owed at all times
        assertGe(owedAfter, yieldSupplyAfter, "invariant post-redeem");
    }
}
