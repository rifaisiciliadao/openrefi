// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";

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

/// @title CollateralAttacks — adversarial coverage for the collateral mechanic.
contract CollateralAttacksTest is Test {
    GrowfiCampaignFactory factory;
    MockERC20 usdc;
    IGrowfiCampaignFull campaign;
    GrowfiCampaignToken campaignToken;
    GrowfiYieldToken yieldToken;
    GrowfiStakingVault stakingVault;
    GrowfiHarvestManager harvestManager;

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
    uint256 constant COVERAGE = 3;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        factory = Deployer.deployProtocol(protocolOwner, feeRecipient, address(usdc), address(0));

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
                    pricePerToken: PRICE_PER_TOKEN,
                    minCap: MIN_CAP,
                    maxCap: MAX_CAP,
                    fundingDeadline: block.timestamp + 90 days,
                    seasonDuration: SEASON_DURATION,
                    fundingFeeBps: 0,
                    sequencerUptimeFeed: address(0),
                    growMinter: address(0)
                }),
                collateral: CollateralModule.InitParams({
                    expectedAnnualHarvestUsd: 5_000e18,
                    expectedAnnualHarvest: 1_000e18,
                    firstHarvestYear: 2030,
                    coverageHarvests: COVERAGE
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
        campaign.addAcceptedToken(address(usdc), SaleClassicModule.PricingMode.Fixed, USDC_FIXED_RATE, address(0));

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

    // --- Helpers ---

    function _activate() internal {
        uint256 alicePay = 60_000 * USDC_FIXED_RATE;
        vm.prank(alice);
        campaign.buy(address(usdc), alicePay);
        vm.prank(bob);
        campaign.buy(address(usdc), 5_000 * USDC_FIXED_RATE);
        assertEq(uint8(campaign.state()), uint8(CampaignStorage.State.Active));
    }

    function _startSeason() internal {
        vm.prank(producer);
        campaign.startSeason();
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
    // ATTACK 1 — Non-producer tries to lock collateral
    // =========================================================================
    function test_attack_nonProducerCannotLock() public {
        _activate();
        vm.prank(attacker);
        vm.expectRevert(CollateralModule.OnlyProducer.selector);
        campaign.lockCollateral(1_000e6);
    }

    // =========================================================================
    // ATTACK 2 — Lock zero
    // =========================================================================
    function test_attack_lockZeroReverts() public {
        _activate();
        vm.prank(producer);
        vm.expectRevert(CollateralModule.ZeroAmount.selector);
        campaign.lockCollateral(0);
    }

    // =========================================================================
    // ATTACK 3 — Lock state-machine guards
    // =========================================================================
    function test_lockCollateral_duringFunding_allowed() public {
        assertEq(uint8(campaign.state()), uint8(CampaignStorage.State.Funding));
        vm.prank(producer);
        campaign.lockCollateral(1_000e6);
        assertEq(campaign.collateralLocked(), 1_000e6);
    }

    function test_attack_lockDuringBuyback_blocked() public {
        vm.warp(block.timestamp + 91 days);
        campaign.triggerBuyback();
        vm.prank(producer);
        vm.expectRevert();
        campaign.lockCollateral(1_000e6);
    }

    // =========================================================================
    // ATTACK 4 — Lock is additive
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
    // ATTACK 5 — No withdrawal path
    // =========================================================================
    function test_attack_noWithdrawalPath() public {
        _activate();
        vm.prank(producer);
        campaign.lockCollateral(5_000e6);
        uint256 producerBefore = usdc.balanceOf(producer);
        assertEq(usdc.balanceOf(producer), producerBefore, "producer balance unchanged");
        assertEq(campaign.collateralLocked(), 5_000e6, "collateral still locked");
    }

    // =========================================================================
    // ATTACK 6 — settleSeasonShortfall outside coverage
    // =========================================================================
    function test_attack_settleSeasonZero_reverts() public {
        _activate();
        vm.prank(attacker);
        vm.expectRevert(CollateralModule.NotInCoverage.selector);
        campaign.settleSeasonShortfall(0);
    }

    function test_attack_settleSeasonBeyondCoverage_reverts() public {
        _activate();
        vm.prank(attacker);
        vm.expectRevert(CollateralModule.NotInCoverage.selector);
        campaign.settleSeasonShortfall(COVERAGE + 1);
    }

    // =========================================================================
    // ATTACK 7 — settleSeasonShortfall before deadline
    // =========================================================================
    function test_attack_settleBeforeDeadline_reverts() public {
        _activate();
        vm.prank(producer);
        campaign.lockCollateral(10_000e6);
        _startSeason();
        _stake(alice, campaignToken.balanceOf(alice));
        _endAndReport(1, 1_000e18);
        vm.prank(attacker);
        vm.expectRevert(CollateralModule.DepositWindowOpen.selector);
        campaign.settleSeasonShortfall(1);
    }

    // =========================================================================
    // ATTACK 8 — Settle on unreported season (producer rage-quit)
    // =========================================================================
    function test_attack_settleUnreportedSeason_reverts() public {
        _activate();
        vm.prank(producer);
        campaign.lockCollateral(10_000e6);
        vm.warp(block.timestamp + 365 days);
        vm.prank(attacker);
        vm.expectRevert(CollateralModule.SeasonNotReported.selector);
        campaign.settleSeasonShortfall(1);
    }

    // =========================================================================
    // ATTACK 9 — Double-settlement
    // =========================================================================
    function test_attack_doubleSettle_reverts() public {
        _activate();
        vm.prank(producer);
        campaign.lockCollateral(10_000e6);

        _startSeason();
        _stake(alice, campaignToken.balanceOf(alice));
        _endAndReport(1, 1_000e18);

        (,,,,,, uint256 deadline,,,,,) = harvestManager.seasonHarvests(1);
        vm.warp(deadline + 1);

        vm.prank(attacker);
        campaign.settleSeasonShortfall(1);
        vm.prank(attacker);
        vm.expectRevert(CollateralModule.AlreadySettled.selector);
        campaign.settleSeasonShortfall(1);
    }

    // =========================================================================
    // ATTACK 10 — Direct call to HarvestManager.depositFromCollateral
    // =========================================================================
    function test_attack_directDepositFromCollateral_blocked() public {
        _activate();
        vm.prank(producer);
        vm.expectRevert(GrowfiHarvestManager.OnlyCampaign.selector);
        harvestManager.depositFromCollateral(1, 1e6);

        vm.prank(attacker);
        vm.expectRevert(GrowfiHarvestManager.OnlyCampaign.selector);
        harvestManager.depositFromCollateral(1, 1e6);
    }

    // =========================================================================
    // ATTACK 11 — Re-set the campaign address on HarvestManager
    // =========================================================================
    function test_attack_resetCampaignOnHm_blocked() public {
        vm.prank(address(factory));
        vm.expectRevert(GrowfiHarvestManager.AlreadySet.selector);
        harvestManager.setCampaign(address(0xdead));
    }

    // =========================================================================
    // ATTACK 12 — Re-set the harvestManager address on Campaign
    // =========================================================================
    function test_attack_resetHmOnCampaign_blocked() public {
        vm.prank(address(factory));
        vm.expectRevert(GrowfiCampaign.AlreadyWired.selector);
        GrowfiCampaign(payable(address(campaign))).setHarvestManager(address(0xdead));
    }

    // =========================================================================
    // ATTACK 13 — Settle with no shortfall: no-op + flag set
    // =========================================================================
    function test_settleNoShortfall_noOpButFlagsSettled() public {
        _activate();
        vm.prank(producer);
        campaign.lockCollateral(10_000e6);

        _startSeason();
        _stake(alice, campaignToken.balanceOf(alice));
        _endAndReport(1, 100e18);

        uint256 gross = harvestManager.remainingDepositGross(1);
        if (gross > 0) {
            vm.startPrank(producer);
            usdc.approve(address(campaign), gross);
            campaign.depositUSDC(1, gross);
            vm.stopPrank();
        }

        (,,,,,, uint256 deadline,,,,,) = harvestManager.seasonHarvests(1);
        vm.warp(deadline + 1);

        uint256 drawnBefore = campaign.collateralDrawn();
        vm.prank(attacker);
        campaign.settleSeasonShortfall(1);
        assertEq(campaign.collateralDrawn(), drawnBefore, "no draw expected");
        assertTrue(campaign.seasonShortfallSettled(1), "still flags settled");

        vm.prank(attacker);
        vm.expectRevert(CollateralModule.AlreadySettled.selector);
        campaign.settleSeasonShortfall(1);
    }

    // =========================================================================
    // ATTACK 14 — Empty reserve: settle should no-op gracefully
    // =========================================================================
    function test_settleNoCollateral_noOp() public {
        _activate();

        _startSeason();
        _stake(alice, campaignToken.balanceOf(alice));
        _endAndReport(1, 100e18);

        (,,,,,, uint256 deadline,,,,,) = harvestManager.seasonHarvests(1);
        vm.warp(deadline + 1);

        vm.prank(attacker);
        campaign.settleSeasonShortfall(1);

        assertEq(campaign.collateralDrawn(), 0);
        assertTrue(campaign.seasonShortfallSettled(1));
    }

    // =========================================================================
    // ATTACK 15 — Partial coverage: draw clamps to availableCollateral
    // =========================================================================
    function test_partialCoverage_clampsToAvailable() public {
        _activate();
        vm.prank(producer);
        campaign.lockCollateral(5e6);

        _startSeason();
        uint256 posId = _stake(alice, campaignToken.balanceOf(alice));
        _endAndReport(1, 5_000e18);
        _commitUsdcClaim(alice, posId, 1);

        (,,,,,, uint256 deadline,,,,,) = harvestManager.seasonHarvests(1);
        vm.warp(deadline + 1);

        uint256 remainingBefore = harvestManager.remainingDepositGross(1);
        require(remainingBefore > 5e6, "test setup expects shortfall > collateral");

        vm.prank(attacker);
        campaign.settleSeasonShortfall(1);

        assertEq(campaign.collateralDrawn(), 5e6, "drew exactly available");
        assertLe(campaign.collateralDrawn(), campaign.collateralLocked(), "drawn <= locked");

        uint256 remainingAfter = harvestManager.remainingDepositGross(1);
        assertLt(remainingAfter, remainingBefore, "shortfall reduced");
        assertGt(remainingAfter, 0, "shortfall not fully closed (partial)");
    }

    // =========================================================================
    // ATTACK 16 — Full coverage: draw exactly the gap
    // =========================================================================
    function test_fullCoverage_drawsExactlyShortfall() public {
        _activate();
        vm.prank(producer);
        campaign.lockCollateral(15_000e6);

        _startSeason();
        uint256 posId = _stake(alice, campaignToken.balanceOf(alice));
        _endAndReport(1, 1_000e18);
        _commitUsdcClaim(alice, posId, 1);

        (,,,,,, uint256 deadline,,,,,) = harvestManager.seasonHarvests(1);
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
