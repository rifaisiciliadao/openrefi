// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {GrowfiToken} from "../src/GrowfiToken.sol";
import {GrowfiMinter} from "../src/GrowfiMinter.sol";
import {IGrowfiMinter} from "../src/interfaces/IGrowfiMinter.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

/// @dev Test harness: a fake campaign that exposes the IGrowfiCampaignView surface and lets
///      tests trigger minter hooks from its address (so msg.sender == this campaign).
contract MintingHarness {
    address public campaignToken;
    uint256 public pricePerToken;
    uint256 public minCap;
    uint256 public maxCap;
    address public minter;

    function configure(address ct, uint256 price, uint256 min_, uint256 max_, address minter_) external {
        campaignToken = ct;
        pricePerToken = price;
        minCap = min_;
        maxCap = max_;
        minter = minter_;
    }

    function callRecordBuy(address buyer, uint256 supplyBefore, uint256 supplyAfter) external {
        IGrowfiMinter(minter).recordBuy(buyer, supplyBefore, supplyAfter);
    }

    function callOnSoftCapReached() external {
        IGrowfiMinter(minter).onSoftCapReached();
    }

    function callOnBuyback() external {
        IGrowfiMinter(minter).onBuyback();
    }

    /// @dev Stub for IGrowfiCampaignView compatibility (Treasury allocates via this signature).
    function buy(address, uint256) external pure {}
}

contract GrowfiMinterTest is Test {
    GrowfiToken token;
    GrowfiMinter minter;
    MintingHarness campaign;
    MockERC20 usdc;
    MockERC20 campaignTokenA;

    address constant FACTORY = address(0xF000);
    address constant DEPLOYER = address(0xD000);
    address constant ALICE = address(0xA1);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA70);
    address constant ATTACKER = address(0xBAD);

    uint256 constant GENESIS_AMOUNT = 1_000_000e18;

    // Campaign params (chosen for clean tier math):
    // pricePerToken = $1.00 per CampaignToken (1e18)
    // minCap = 100 → softcap USD = $100
    // maxCap = 200 → tier2to3 at 50% of (maxCap-minCap) = +$50 → tier 2 ends at $150
    uint256 constant PRICE = 1e18;
    uint256 constant MIN_CAP = 100e18;
    uint256 constant MAX_CAP = 200e18;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        campaignTokenA = new MockERC20("Campaign A", "CMP", 18);

        // Deploy GrowfiToken
        GrowfiToken tImpl = new GrowfiToken();
        bytes memory tInit = abi.encodeCall(
            GrowfiToken.initialize, ("GrowFi", "GROW", FACTORY, DEPLOYER, GENESIS_AMOUNT, 1_000, 1e17)
        );
        token = GrowfiToken(address(new TransparentUpgradeableProxy(address(tImpl), FACTORY, tInit)));

        // Deploy GrowfiMinter
        GrowfiMinter mImpl = new GrowfiMinter();
        GrowfiMinter.BondingCurveParams memory params = GrowfiMinter.BondingCurveParams({
            tier1RateBps: 10_000, // 1.0×
            tier2RateBps: 7_000, // 0.7×
            tier3RateBps: 4_000, // 0.4×
            tier2to3ThresholdBps: 5_000 // 50% of (maxCap - minCap)
        });
        bytes memory mInit = abi.encodeCall(GrowfiMinter.initialize, (FACTORY, address(token), params));
        minter = GrowfiMinter(address(new TransparentUpgradeableProxy(address(mImpl), FACTORY, mInit)));

        // Wire token's minter
        vm.prank(FACTORY);
        token.setMinter(address(minter));

        // Set up the harness campaign
        campaign = new MintingHarness();
        campaign.configure(address(campaignTokenA), PRICE, MIN_CAP, MAX_CAP, address(minter));

        // Register the campaign
        vm.prank(FACTORY);
        minter.registerCampaign(address(campaign));
    }

    // ---------- initialize ----------

    function test_initialize_setsState() public view {
        assertEq(minter.factory(), FACTORY);
        assertEq(address(minter.growToken()), address(token));
        (uint256 t1, uint256 t2, uint256 t3, uint256 thresh) = minter.params();
        assertEq(t1, 10_000);
        assertEq(t2, 7_000);
        assertEq(t3, 4_000);
        assertEq(thresh, 5_000);
    }

    function test_initialize_revertsOnInvalidParams() public {
        GrowfiMinter impl = new GrowfiMinter();
        GrowfiMinter.BondingCurveParams memory bad = GrowfiMinter.BondingCurveParams({
            tier1RateBps: 10_001, // > BPS
            tier2RateBps: 7_000,
            tier3RateBps: 4_000,
            tier2to3ThresholdBps: 5_000
        });
        bytes memory data = abi.encodeCall(GrowfiMinter.initialize, (FACTORY, address(token), bad));
        vm.expectRevert(GrowfiMinter.InvalidParams.selector);
        new TransparentUpgradeableProxy(address(impl), FACTORY, data);
    }

    function test_initialize_cannotBeCalledTwice() public {
        GrowfiMinter.BondingCurveParams memory p =
            GrowfiMinter.BondingCurveParams({tier1RateBps: 10_000, tier2RateBps: 7_000, tier3RateBps: 4_000, tier2to3ThresholdBps: 5_000});
        vm.expectRevert();
        minter.initialize(FACTORY, address(token), p);
    }

    // ---------- registerCampaign ----------

    function test_register_marksCampaignPending() public view {
        (GrowfiMinter.CampaignStatus status,,,) = minter.getCampaignState(address(campaign));
        assertEq(uint256(status), uint256(GrowfiMinter.CampaignStatus.Pending));
    }

    function test_register_revertsOnDuplicate() public {
        vm.expectRevert(GrowfiMinter.AlreadyRegistered.selector);
        vm.prank(FACTORY);
        minter.registerCampaign(address(campaign));
    }

    function test_register_revertsForNonFactory() public {
        MintingHarness c2 = new MintingHarness();
        vm.expectRevert(GrowfiMinter.NotFactory.selector);
        vm.prank(ATTACKER);
        minter.registerCampaign(address(c2));
    }

    function test_register_revertsOnZeroAddress() public {
        vm.expectRevert(GrowfiMinter.ZeroAddress.selector);
        vm.prank(FACTORY);
        minter.registerCampaign(address(0));
    }

    // ---------- recordBuy: Pending → escrow ----------

    function test_recordBuy_pendingEscrowsAtTier1() public {
        // Buy of 10 CampaignTokens at $1 each = $10 USD value, all in tier 1
        campaign.callRecordBuy(ALICE, 0, 10e18);

        // Tier 1 rate 1.0 → 10 GROW escrowed
        assertEq(minter.getEscrow(address(campaign), ALICE), 10e18);
        assertEq(token.balanceOf(ALICE), 0); // not in wallet — escrowed

        (, uint256 cumVol, uint256 totalEscrowed,) = minter.getCampaignState(address(campaign));
        assertEq(cumVol, 10e18);
        assertEq(totalEscrowed, 10e18);
    }

    function test_recordBuy_multipleBuyersAccumulate() public {
        campaign.callRecordBuy(ALICE, 0, 10e18); // $10
        campaign.callRecordBuy(BOB, 10e18, 30e18); // $20
        campaign.callRecordBuy(ALICE, 30e18, 50e18); // $20

        assertEq(minter.getEscrow(address(campaign), ALICE), 30e18); // 10 + 20
        assertEq(minter.getEscrow(address(campaign), BOB), 20e18);
        (, uint256 cumVol,,) = minter.getCampaignState(address(campaign));
        assertEq(cumVol, 50e18);
    }

    function test_recordBuy_excludedBuyerSkipsMint() public {
        vm.prank(FACTORY);
        minter.setExcludedFromMint(ALICE, true);

        campaign.callRecordBuy(ALICE, 0, 10e18);
        assertEq(minter.getEscrow(address(campaign), ALICE), 0);

        // Cumulative volume NOT advanced — excluded buys are invisible to curve
        (, uint256 cumVol,,) = minter.getCampaignState(address(campaign));
        assertEq(cumVol, 0);
    }

    function test_recordBuy_revertsForNonRegisteredCampaign() public {
        MintingHarness fake = new MintingHarness();
        fake.configure(address(campaignTokenA), PRICE, MIN_CAP, MAX_CAP, address(minter));

        vm.expectRevert(GrowfiMinter.NotCampaign.selector);
        fake.callRecordBuy(ALICE, 0, 10e18);
    }

    function test_recordBuy_revertsAfterBuyback() public {
        campaign.callRecordBuy(ALICE, 0, 10e18);
        campaign.callOnBuyback();

        vm.expectRevert(GrowfiMinter.CampaignAlreadyFailed.selector);
        campaign.callRecordBuy(BOB, 10e18, 20e18);
    }

    function test_recordBuy_zeroDeltaIsNoOp() public {
        campaign.callRecordBuy(ALICE, 50e18, 50e18);
        assertEq(minter.getEscrow(address(campaign), ALICE), 0);
    }

    // ---------- recordBuy: Active → direct mint ----------

    function test_recordBuy_activeMintsToWallet() public {
        // Activate campaign
        campaign.callOnSoftCapReached();

        campaign.callRecordBuy(ALICE, 0, 10e18); // tier 1 still (cumVol < $100)

        // GROW lands directly in Alice's wallet
        assertEq(token.balanceOf(ALICE), 10e18);
        assertEq(minter.getEscrow(address(campaign), ALICE), 0);
    }

    // ---------- onSoftCapReached / onBuyback ----------

    function test_onSoftCapReached_pendingToActive() public {
        campaign.callOnSoftCapReached();
        (GrowfiMinter.CampaignStatus status,,,) = minter.getCampaignState(address(campaign));
        assertEq(uint256(status), uint256(GrowfiMinter.CampaignStatus.Active));
    }

    function test_onSoftCapReached_idempotent() public {
        campaign.callOnSoftCapReached();
        campaign.callOnSoftCapReached(); // no-op
        (GrowfiMinter.CampaignStatus status,,,) = minter.getCampaignState(address(campaign));
        assertEq(uint256(status), uint256(GrowfiMinter.CampaignStatus.Active));
    }

    function test_onBuyback_pendingToFailed() public {
        campaign.callOnBuyback();
        (GrowfiMinter.CampaignStatus status,,,) = minter.getCampaignState(address(campaign));
        assertEq(uint256(status), uint256(GrowfiMinter.CampaignStatus.Failed));
    }

    function test_onBuyback_idempotent() public {
        campaign.callOnBuyback();
        campaign.callOnBuyback(); // no-op
        (GrowfiMinter.CampaignStatus status,,,) = minter.getCampaignState(address(campaign));
        assertEq(uint256(status), uint256(GrowfiMinter.CampaignStatus.Failed));
    }

    function test_onSoftCapReached_revertsForUnregistered() public {
        MintingHarness fake = new MintingHarness();
        fake.configure(address(campaignTokenA), PRICE, MIN_CAP, MAX_CAP, address(minter));

        vm.expectRevert(GrowfiMinter.NotCampaign.selector);
        fake.callOnSoftCapReached();
    }

    // ---------- claimEscrow ----------

    function test_claimEscrow_succeedsAfterActivation() public {
        campaign.callRecordBuy(ALICE, 0, 10e18);
        campaign.callOnSoftCapReached();

        vm.prank(ALICE);
        uint256 received = minter.claimEscrow(address(campaign));

        assertEq(received, 10e18);
        assertEq(token.balanceOf(ALICE), 10e18);
        assertEq(minter.getEscrow(address(campaign), ALICE), 0); // can't double-claim
    }

    function test_claimEscrow_revertsBeforeActivation() public {
        campaign.callRecordBuy(ALICE, 0, 10e18);

        vm.expectRevert(GrowfiMinter.NotActive.selector);
        vm.prank(ALICE);
        minter.claimEscrow(address(campaign));
    }

    function test_claimEscrow_revertsAfterBuyback() public {
        campaign.callRecordBuy(ALICE, 0, 10e18);
        campaign.callOnBuyback(); // status: Failed → escrow voided

        vm.expectRevert(GrowfiMinter.NotActive.selector);
        vm.prank(ALICE);
        minter.claimEscrow(address(campaign));

        // Escrow data still there but unusable — doesn't matter, status gates it
        assertEq(token.balanceOf(ALICE), 0);
    }

    function test_claimEscrow_revertsOnZeroEscrow() public {
        campaign.callOnSoftCapReached();

        vm.expectRevert(GrowfiMinter.NoEscrow.selector);
        vm.prank(ALICE);
        minter.claimEscrow(address(campaign));
    }

    function test_claimEscrow_isOneShot() public {
        campaign.callRecordBuy(ALICE, 0, 10e18);
        campaign.callOnSoftCapReached();

        vm.prank(ALICE);
        minter.claimEscrow(address(campaign));

        vm.expectRevert(GrowfiMinter.NoEscrow.selector);
        vm.prank(ALICE);
        minter.claimEscrow(address(campaign));
    }

    // ---------- bonding curve ----------

    /// @dev Tier 1 (cumVol $0 → $50, all under softcap $100): rate 1.0× → 50 GROW
    function test_curve_tier1Only() public {
        campaign.callRecordBuy(ALICE, 0, 50e18);
        assertEq(minter.getEscrow(address(campaign), ALICE), 50e18);
    }

    /// @dev Buy crossing tier 1 → tier 2 boundary
    /// $80 buy at cumVol $50 lands in $50 tier 1 + $30 tier 2:
    /// tier 1: $50 × 1.0 = 50 GROW
    /// tier 2: $30 × 0.7 = 21 GROW
    /// total = 71 GROW
    function test_curve_tier1ToTier2() public {
        campaign.callRecordBuy(BOB, 0, 50e18); // $50 cumVol prep
        campaign.callRecordBuy(ALICE, 50e18, 130e18); // ALICE buys $80
        assertEq(minter.getEscrow(address(campaign), ALICE), 71e18);
    }

    /// @dev Buy entirely in tier 2: cumVol $100 → $130, $30 × 0.7 = 21 GROW
    function test_curve_tier2Only() public {
        campaign.callRecordBuy(BOB, 0, 100e18); // $100 cumVol prep
        campaign.callRecordBuy(ALICE, 100e18, 130e18); // $30 in tier 2
        assertEq(minter.getEscrow(address(campaign), ALICE), 21e18);
    }

    /// @dev Buy spanning all 3 tiers: $200 buy at cumVol $0
    /// tier 1: $100 × 1.0 = 100 GROW
    /// tier 2: $50  × 0.7 = 35 GROW
    /// tier 3: $50  × 0.4 = 20 GROW
    /// total = 155 GROW
    function test_curve_allThreeTiers() public {
        campaign.callRecordBuy(ALICE, 0, 200e18); // $200 buy from 0
        assertEq(minter.getEscrow(address(campaign), ALICE), 155e18);
    }

    /// @dev Buy entirely in tier 3: cumVol $150 → $200, $50 × 0.4 = 20 GROW
    function test_curve_tier3Only() public {
        campaign.callRecordBuy(BOB, 0, 150e18); // $150 cumVol prep
        campaign.callRecordBuy(ALICE, 150e18, 200e18); // $50 in tier 3
        assertEq(minter.getEscrow(address(campaign), ALICE), 20e18);
    }

    /// @dev Sequential buys decay correctly: each buy starts at the previous cumVol
    function test_curve_monotonicDecay() public {
        campaign.callRecordBuy(ALICE, 0, 50e18); // tier 1: 50 GROW
        campaign.callRecordBuy(BOB, 50e18, 110e18); // $50 tier 1 + $10 tier 2 = 50 + 7 = 57
        campaign.callRecordBuy(CAROL, 110e18, 160e18); // $40 tier 2 + $10 tier 3 = 28 + 4 = 32

        assertEq(minter.getEscrow(address(campaign), ALICE), 50e18);
        assertEq(minter.getEscrow(address(campaign), BOB), 57e18);
        assertEq(minter.getEscrow(address(campaign), CAROL), 32e18);
    }

    // ---------- previewGrowForBuy ----------

    function test_previewGrowForBuy_matchesActualRate() public {
        uint256 preview = minter.previewGrowForBuy(address(campaign), 0, 50e18);
        campaign.callRecordBuy(ALICE, 0, 50e18);
        uint256 actual = minter.getEscrow(address(campaign), ALICE);
        assertEq(preview, actual);
    }

    function test_previewGrowForBuy_returnsZeroForFailedCampaign() public {
        campaign.callOnBuyback();
        uint256 preview = minter.previewGrowForBuy(address(campaign), 0, 50e18);
        assertEq(preview, 0);
    }

    function test_previewGrowForBuy_returnsZeroForUnregistered() public {
        MintingHarness fake = new MintingHarness();
        fake.configure(address(campaignTokenA), PRICE, MIN_CAP, MAX_CAP, address(minter));
        uint256 preview = minter.previewGrowForBuy(address(fake), 0, 50e18);
        assertEq(preview, 0);
    }

    // ---------- setBondingCurveParams ----------

    function test_setBondingCurve_byFactorySucceeds() public {
        GrowfiMinter.BondingCurveParams memory newParams = GrowfiMinter.BondingCurveParams({
            tier1RateBps: 8_000,
            tier2RateBps: 5_000,
            tier3RateBps: 2_000,
            tier2to3ThresholdBps: 6_000
        });
        vm.prank(FACTORY);
        minter.setBondingCurveParams(newParams);

        (uint256 t1,,,) = minter.params();
        assertEq(t1, 8_000);
    }

    function test_setBondingCurve_revertsForNonFactory() public {
        GrowfiMinter.BondingCurveParams memory p =
            GrowfiMinter.BondingCurveParams({tier1RateBps: 8_000, tier2RateBps: 5_000, tier3RateBps: 2_000, tier2to3ThresholdBps: 6_000});
        vm.expectRevert(GrowfiMinter.NotFactory.selector);
        vm.prank(ATTACKER);
        minter.setBondingCurveParams(p);
    }

    function test_setBondingCurve_revertsOnInvalidParams() public {
        GrowfiMinter.BondingCurveParams memory bad =
            GrowfiMinter.BondingCurveParams({tier1RateBps: 10_001, tier2RateBps: 5_000, tier3RateBps: 2_000, tier2to3ThresholdBps: 6_000});
        vm.expectRevert(GrowfiMinter.InvalidParams.selector);
        vm.prank(FACTORY);
        minter.setBondingCurveParams(bad);
    }

    // ---------- setExcludedFromMint ----------

    function test_setExcludedFromMint_byFactory() public {
        vm.prank(FACTORY);
        minter.setExcludedFromMint(ALICE, true);
        assertTrue(minter.excludedFromMint(ALICE));

        vm.prank(FACTORY);
        minter.setExcludedFromMint(ALICE, false);
        assertFalse(minter.excludedFromMint(ALICE));
    }

    function test_setExcludedFromMint_revertsForNonFactory() public {
        vm.expectRevert(GrowfiMinter.NotFactory.selector);
        vm.prank(ATTACKER);
        minter.setExcludedFromMint(ALICE, true);
    }

    // ---------- red team ----------

    /// @dev An attacker tries to buy → sellback → buy in a loop. Bonding curve is over
    ///      cumulative volume which only grows, so each iteration earns LESS GROW.
    function test_redteam_buyLoopFarmIsBoundedByMonotonicCurve() public {
        // Buy 1: $50 in tier 1 → 50 GROW
        campaign.callRecordBuy(ALICE, 0, 50e18);
        assertEq(minter.getEscrow(address(campaign), ALICE), 50e18);

        // Simulate sellback: supply drops back to 0. But cumVol stays at $50.
        // Buy 2: another $50, but now cumVol $50 → $100, still tier 1 → another 50 GROW
        campaign.callRecordBuy(ALICE, 0, 50e18); // supplyBefore=0, supplyAfter=50 → $50 added
        assertEq(minter.getEscrow(address(campaign), ALICE), 100e18);

        // Buy 3: $50 more, cumVol $100 → $150, all in tier 2 (rate 0.7) → 35 GROW
        campaign.callRecordBuy(ALICE, 0, 50e18);
        assertEq(minter.getEscrow(address(campaign), ALICE), 135e18);

        // Buy 4: $50 more, cumVol $150 → $200, all in tier 3 (rate 0.4) → 20 GROW
        campaign.callRecordBuy(ALICE, 0, 50e18);
        assertEq(minter.getEscrow(address(campaign), ALICE), 155e18);

        // Beyond this point each $50 buy earns $50 × 0.4 = 20 GROW indefinitely.
        // Curve has stepped through all tiers; further farm yields the floor rate.
    }

    /// @dev An attacker tries calling minter functions directly (not via campaign) — gated.
    function test_redteam_directRecordBuyBlocked() public {
        vm.expectRevert(GrowfiMinter.NotCampaign.selector);
        vm.prank(ATTACKER);
        minter.recordBuy(ATTACKER, 0, 10e18);
    }

    function test_redteam_directOnSoftCapBlocked() public {
        vm.expectRevert(GrowfiMinter.NotCampaign.selector);
        vm.prank(ATTACKER);
        minter.onSoftCapReached();
    }

    function test_redteam_directOnBuybackBlocked() public {
        vm.expectRevert(GrowfiMinter.NotCampaign.selector);
        vm.prank(ATTACKER);
        minter.onBuyback();
    }

    /// @dev Excluded buyer cannot accidentally advance the curve to dilute real participants.
    function test_redteam_excludedDoesNotAdvanceCurve() public {
        vm.prank(FACTORY);
        minter.setExcludedFromMint(BOB, true);

        // BOB is excluded — even a huge buy doesn't move the curve
        campaign.callRecordBuy(BOB, 0, 200e18); // $200 buy, but excluded

        // ALICE buys after — should still see tier 1 rate
        campaign.callRecordBuy(ALICE, 0, 50e18);
        assertEq(minter.getEscrow(address(campaign), ALICE), 50e18);
    }

    /// @dev Buyback voids escrow — even claimable mass GROW becomes unusable.
    function test_redteam_buybackVoidsEscrowEvenIfMassive() public {
        campaign.callRecordBuy(ALICE, 0, 90e18); // 90 GROW in tier 1
        assertEq(minter.getEscrow(address(campaign), ALICE), 90e18);

        campaign.callOnBuyback();

        vm.expectRevert(GrowfiMinter.NotActive.selector);
        vm.prank(ALICE);
        minter.claimEscrow(address(campaign));

        assertEq(token.balanceOf(ALICE), 0);
    }

    /// @dev If a Pending campaign reports activation MULTIPLE times (e.g. due to an upgrade
    ///      bug), the second call is a no-op.
    function test_redteam_doubleActivationIsIdempotent() public {
        campaign.callOnSoftCapReached();
        campaign.callOnSoftCapReached(); // no revert
        (GrowfiMinter.CampaignStatus s,,,) = minter.getCampaignState(address(campaign));
        assertEq(uint256(s), uint256(GrowfiMinter.CampaignStatus.Active));
    }

    /// @dev If onBuyback fires AFTER the campaign already reached Active (impossible in
    ///      protocol logic, but defensive), status stays Active. No state corruption.
    function test_redteam_buybackAfterActiveIsNoOp() public {
        campaign.callOnSoftCapReached();
        campaign.callOnBuyback(); // no revert, but does nothing
        (GrowfiMinter.CampaignStatus s,,,) = minter.getCampaignState(address(campaign));
        assertEq(uint256(s), uint256(GrowfiMinter.CampaignStatus.Active));
    }
}
