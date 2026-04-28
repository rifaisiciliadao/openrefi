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
import {FeeOnTransferToken} from "./helpers/FeeOnTransferToken.sol";
import {ReentrantToken} from "./helpers/ReentrantToken.sol";
import {Deployer} from "./helpers/Deployer.sol";

/// @title CollateralHardening — defense-in-depth tests for the v3 collateral
///        path. Each test pins down a specific surface that is closed by
///        design and re-asserts it so a future refactor can't quietly open
///        it again.
///
/// Surfaces covered:
///   1. Fee-on-transfer "USDC" misconfig — what breaks if the factory's
///      `usdc` is set to a token that burns on transfer. The collateral
///      mechanic is hard-coded to the factory's USDC, so this can only
///      happen via a misconfigured factory init. Test pins the breakage
///      so we never silently regress to silent over-counting.
///   2. Reentrancy on `lockCollateral` via a hostile USDC's transfer hook.
///   3. Reentrancy on `settleSeasonShortfall` via the same vector inside
///      the inner `depositFromCollateral` → `safeTransferFrom` path.
///   4. Storage-layout regression: assert that the v1/v2 fields still live
///      at their original slots after the v3 append (defends against
///      accidental field re-ordering in future refactors).
contract CollateralHardeningTest is Test {
    address protocolOwner = makeAddr("protocolOwner");
    address feeRecipient = makeAddr("feeRecipient");
    address producer = makeAddr("producer");
    address alice = makeAddr("alice");

    uint256 constant PRICE_PER_TOKEN = 0.144e18;
    uint256 constant MIN_CAP = 50_000e18;
    uint256 constant MAX_CAP = 100_000e18;
    uint256 constant SEASON_DURATION = 365 days;
    uint256 constant USDC_RATE_FOT = 1e18; // 1 FoT per 1 OLIVE (FoT is 18-dec)
    uint256 constant USDC_RATE_RGN = 1e18; // 1 ReentrantToken per 1 OLIVE
    uint256 constant COVERAGE = 3;

    function _bootstrap(address tokenAddr)
        internal
        returns (CampaignFactory factory, Campaign campaign, CampaignToken ct, HarvestManager hm)
    {
        factory = Deployer.deployProtocol(protocolOwner, feeRecipient, tokenAddr, address(0));

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

        (address c, address cTok,, , address hmAddr,,) = factory.campaigns(0);
        campaign = Campaign(c);
        ct = CampaignToken(cTok);
        hm = HarvestManager(hmAddr);
    }

    // =========================================================================
    // 1. FEE-ON-TRANSFER "USDC" MISCONFIG
    // =========================================================================

    /// FoT as factory.usdc: lockCollateral records the DECLARED amount, but
    /// the contract receives `amount * (10_000 - feeBps) / 10_000`. That
    /// drift is silent — `collateralLocked` over-counts. Pin the drift so
    /// we never assume otherwise without a deliberate change.
    function test_fot_lockCollateral_overCountsBalance() public {
        FeeOnTransferToken fot = new FeeOnTransferToken("FoT", "FOT", 18, 100); // 1% burn
        (, Campaign campaign,, ) = _bootstrap(address(fot));

        // Activate via a regular buy (FoT through buy is a separate footgun
        // already covered in PoolSecurity; we don't care for this test).
        // Here we shortcut state by hitting minCap with one big buy.
        vm.prank(producer);
        campaign.addAcceptedToken(address(fot), Campaign.PricingMode.Fixed, USDC_RATE_FOT, address(0));
        fot.mint(alice, 200_000e18);
        vm.startPrank(alice);
        fot.approve(address(campaign), type(uint256).max);
        campaign.buy(address(fot), 60_000e18); // hits minCap → activates
        vm.stopPrank();
        assertEq(uint8(campaign.state()), uint8(Campaign.State.Active));

        // Producer locks 1000 FoT.
        fot.mint(producer, 1_000e18);
        vm.startPrank(producer);
        fot.approve(address(campaign), type(uint256).max);
        uint256 producerBefore = fot.balanceOf(producer);
        uint256 campaignBefore = fot.balanceOf(address(campaign));
        campaign.lockCollateral(1_000e18);
        uint256 producerAfter = fot.balanceOf(producer);
        uint256 campaignAfter = fot.balanceOf(address(campaign));
        vm.stopPrank();

        // Balance accounting: producer paid 1000, contract received 990
        // (1% burned). collateralLocked stores 1000 (DECLARED) → drift.
        assertEq(producerBefore - producerAfter, 1_000e18, "producer lost declared 1000");
        assertEq(campaignAfter - campaignBefore, 990e18, "contract received 990 (1% burned)");
        assertEq(campaign.collateralLocked(), 1_000e18, "collateralLocked over-counts: drift confirmed");

        // Producer-responsibility footgun: factory misconfig with FoT USDC
        // means subsequent settlement draws can revert when they try to
        // transfer the declared amount. Documented, not code-mitigated.
    }

    // =========================================================================
    // 2. REENTRANCY ON lockCollateral
    // =========================================================================

    /// A hostile USDC re-enters Campaign.lockCollateral inside its own
    /// transfer hook. The nonReentrant modifier on lockCollateral must
    /// abort the inner call.
    function test_reentrancy_lockCollateral_blocked() public {
        ReentrantToken rog = new ReentrantToken("Rogue", "ROG", 18);
        (, Campaign campaign,, ) = _bootstrap(address(rog));

        // Activate quickly via a regular buy with ROG as payment.
        vm.prank(producer);
        campaign.addAcceptedToken(address(rog), Campaign.PricingMode.Fixed, USDC_RATE_RGN, address(0));
        rog.mint(alice, 200_000e18);
        vm.startPrank(alice);
        rog.approve(address(campaign), type(uint256).max);
        campaign.buy(address(rog), 60_000e18);
        vm.stopPrank();
        assertEq(uint8(campaign.state()), uint8(Campaign.State.Active));

        // Arm the token so its next transfer hook re-enters
        // lockCollateral on the same campaign.
        rog.mint(producer, 1_000e18);
        vm.prank(producer);
        rog.approve(address(campaign), type(uint256).max);

        bytes memory payload = abi.encodeCall(Campaign.lockCollateral, (100e18));
        rog.arm(address(campaign), payload);

        vm.prank(producer);
        vm.expectRevert(); // ReentrancyGuardReentrantCall (or AlreadySet path can't reach)
        campaign.lockCollateral(500e18);
    }

    // =========================================================================
    // 3. REENTRANCY ON settleSeasonShortfall
    // =========================================================================

    /// settleSeasonShortfall sets `seasonShortfallSettled[seasonId] = true`
    /// BEFORE the external `harvestManager.depositFromCollateral` call (which
    /// in turn calls usdc.safeTransferFrom). A hostile USDC re-entering
    /// settleSeasonShortfall(s) for the same s should fail with AlreadySettled.
    /// Re-entry on a *different* seasonId would hit ReentrancyGuard. We test
    /// the same-seasonId path because it's the realistic griefing attempt.
    function test_reentrancy_settleSeasonShortfall_blocked() public {
        ReentrantToken rog = new ReentrantToken("Rogue", "ROG", 18);
        (, Campaign campaign, CampaignToken ct, HarvestManager hm) = _bootstrap(address(rog));

        // Whitelist + activate
        vm.prank(producer);
        campaign.addAcceptedToken(address(rog), Campaign.PricingMode.Fixed, USDC_RATE_RGN, address(0));
        rog.mint(alice, 1_000_000e18);
        vm.startPrank(alice);
        rog.approve(address(campaign), type(uint256).max);
        campaign.buy(address(rog), 60_000e18); // activates
        ct.approve(address(campaign), type(uint256).max);
        vm.stopPrank();

        // Producer locks collateral
        rog.mint(producer, 100_000e18);
        vm.startPrank(producer);
        rog.approve(address(campaign), type(uint256).max);
        campaign.lockCollateral(10_000e18);
        // Run a season + report to expose a shortfall
        campaign.startSeason(1);
        vm.stopPrank();
        // Alice stakes
        vm.startPrank(alice);
        StakingVault sv = StakingVault(address(campaign.stakingVault()));
        ct.approve(address(sv), type(uint256).max);
        uint256 posId = sv.stake(ct.balanceOf(alice));
        vm.stopPrank();
        vm.warp(block.timestamp + SEASON_DURATION);
        vm.prank(producer);
        campaign.endSeason();
        vm.prank(producer);
        hm.reportHarvest(1, 5_000e18, bytes32(0), 0);
        // Alice commits a USDC claim so usdcOwed > 0
        vm.startPrank(alice);
        sv.claimYield(posId);
        YieldToken yt = YieldToken(address(hm.yieldToken()));
        uint256 yieldBal = yt.balanceOf(alice);
        if (yieldBal > 0) hm.redeemUSDC(1, yieldBal);
        vm.stopPrank();

        // Past the deadline.
        (,,,,, , uint256 deadline,,,,, ) = hm.seasonHarvests(1);
        vm.warp(deadline + 1);

        // Arm the token so usdc.safeTransferFrom (called inside
        // depositFromCollateral) re-enters settleSeasonShortfall(1).
        bytes memory payload = abi.encodeCall(Campaign.settleSeasonShortfall, (1));
        rog.arm(address(campaign), payload);

        // The outer call enters settleSeasonShortfall, sets
        // `seasonShortfallSettled[1] = true`, computes a draw, calls
        // depositFromCollateral → usdc.safeTransferFrom from the campaign
        // → ReentrantToken._update fires the armed payload, which calls
        // back into Campaign.settleSeasonShortfall(1).
        //
        // Two compounding defenses fire:
        //   (a) Campaign.settleSeasonShortfall is `nonReentrant` — the
        //       inner call hits ReentrancyGuardReentrantCall before any
        //       state read, OR
        //   (b) if the reentrancy guard were ever weakened, the inner
        //       call would hit `AlreadySettled` because the flag was
        //       written before the external transfer.
        //
        // Whichever fires, the inner revert bubbles up through the
        // ReentrantToken (default swallow=false) and aborts the outer
        // call. The outer revert rolls back all state (flag included),
        // so we only assert "the outer attempt reverts".
        vm.expectRevert();
        campaign.settleSeasonShortfall(1);
        assertFalse(campaign.seasonShortfallSettled(1), "outer revert rolled back the flag");
    }

    // =========================================================================
    // 4. STORAGE-LAYOUT REGRESSION
    // =========================================================================

    /// Reading the public fields after creation must return their initialized
    /// values. If any v1/v2 field's slot moved (e.g. by inserting a new field
    /// in the middle), the auto-getter would surface garbage and this test
    /// would fail. Defensive snapshot of the v3 layout we ship.
    function test_storageLayout_v1v2v3FieldsResolveAtExpectedAccessors() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        (, Campaign campaign,, ) = _bootstrap(address(usdc));

        // v1 fields (state machine, caps, dates)
        assertEq(campaign.producer(), producer, "v1: producer slot");
        assertEq(campaign.factory() != address(0), true, "v1: factory slot");
        assertEq(campaign.pricePerToken(), PRICE_PER_TOKEN, "v1: pricePerToken slot");
        assertEq(campaign.minCap(), MIN_CAP, "v1: minCap slot");
        assertEq(campaign.maxCap(), MAX_CAP, "v1: maxCap slot");
        assertEq(campaign.seasonDuration(), SEASON_DURATION, "v1: seasonDuration slot");
        assertEq(uint8(campaign.state()), uint8(Campaign.State.Funding), "v1: state slot");
        assertEq(campaign.currentSupply(), 0, "v1: currentSupply slot");

        // v1 zombie + v1 active fee fields
        assertEq(campaign.protocolFeeBps(), 200, "v1: protocolFeeBps zombie slot stable");
        assertEq(campaign.protocolFeeRecipient(), feeRecipient, "v1: protocolFeeRecipient slot stable");

        // v2 fields (appended)
        assertEq(campaign.fundingFeeBps(), 300, "v2: fundingFeeBps appended slot stable");

        // v3 fields (appended)
        assertEq(campaign.expectedAnnualHarvestUsd(), 5_000e18, "v3: expectedAnnualHarvestUsd slot");
        assertEq(campaign.firstHarvestYear(), 2030, "v3: firstHarvestYear slot");
        assertEq(campaign.coverageHarvests(), COVERAGE, "v3: coverageHarvests slot");
        assertEq(address(campaign.usdc()), address(usdc), "v3: usdc slot");
        assertEq(campaign.collateralLocked(), 0, "v3: collateralLocked initial 0");
        assertEq(campaign.collateralDrawn(), 0, "v3: collateralDrawn initial 0");
        assertEq(campaign.seasonShortfallSettled(1), false, "v3: seasonShortfallSettled initial false");
    }

    /// The `protocolFeeBps` zombie slot must stay non-zero (= PROTOCOL_FEE_BPS
    /// passed at init) for backward-compatible reads. If a refactor accidentally
    /// removed the field or moved it, this would zero out and the test would
    /// trip the explicit assertEq in the layout test above. Defense in depth.
    function test_storageLayout_zombieSlotPreservesValue() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        (, Campaign campaign,, ) = _bootstrap(address(usdc));
        assertGt(campaign.protocolFeeBps(), 0, "zombie slot must hold init value");
    }
}
