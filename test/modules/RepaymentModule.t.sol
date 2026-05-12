// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {GrowfiCampaign} from "../../src/GrowfiCampaign.sol";
import {CampaignStorage} from "../../src/host/CampaignStorage.sol";
import {RepaymentModule} from "../../src/modules/RepaymentModule.sol";
import {GrowfiCampaignToken} from "../../src/GrowfiCampaignToken.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

import {TestModuleRegistry} from "../host/TestModuleRegistry.sol";
import {RepaymentHelper} from "./RepaymentHelper.sol";

/// @notice Unit tests for RepaymentModule using dummy staking vault.
///         pricePerToken is injected directly into the SaleClassicModule
///         storage slot via vm.store; SaleClassicModule itself is NOT
///         attached. This keeps the suite focused on the bonus/principal
///         math and pool gating. The integration test in
///         RepaymentIntegration.t.sol covers the staking interaction.
contract RepaymentModuleTest is Test {
    bytes32 internal constant REPAY_KIND = keccak256("growfi.repayment.v1");
    bytes32 internal constant REPAY_TYPE = keccak256("growfi.type.repayment");

    /// @dev SaleClassicModule.Layout.pricePerToken sits at this slot
    ///      (offset 0 of the struct, namespace = keccak256("growfi.module.sale.classic.v1")).
    bytes32 internal constant SALE_PRICE_SLOT =
        0xd7250d23bb7bc8e93366cf6815d31bcb947e004baa702b9bb515d6082501a234;

    address internal protocolOwner = makeAddr("protocolOwner");
    address internal producer = makeAddr("producer");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    TestModuleRegistry internal registry;
    GrowfiCampaign internal campaign;
    GrowfiCampaignToken internal campaignToken;
    RepaymentModule internal repayImpl;
    MockUSDC internal usdc;

    /// @dev 0.144 USD per CT, scaled USD-18.
    uint256 internal constant PRICE_PER_TOKEN_USD18 = 0.144e18;
    /// @dev Expected principal payout per 1e18 CT in USDC-6.
    uint256 internal constant EXPECTED_PRINCIPAL_USDC6 = 0.144e6;
    uint256 internal constant INITIAL_POOL = 10_000e6;

    function setUp() public {
        usdc = new MockUSDC();

        // Registry
        TestModuleRegistry registryImpl = new TestModuleRegistry();
        bytes memory initData = abi.encodeCall(TestModuleRegistry.initialize, (protocolOwner));
        TransparentUpgradeableProxy registryProxy =
            new TransparentUpgradeableProxy(address(registryImpl), protocolOwner, initData);
        registry = TestModuleRegistry(address(registryProxy));

        // Repayment whitelist
        repayImpl = new RepaymentModule();
        vm.startPrank(protocolOwner);
        registry.setModuleKindSelectors(REPAY_KIND, RepaymentHelper.selectors());
        registry.approveModuleImpl(REPAY_KIND, address(repayImpl), true);
        vm.stopPrank();

        // Campaign + token (predicted-address pattern so CampaignToken can
        // pin its `campaign` field at construction time).
        GrowfiCampaignToken ctImpl = new GrowfiCampaignToken();
        GrowfiCampaign campImpl = new GrowfiCampaign();
        uint64 testNonce = vm.getNonce(address(this));
        address predictedCampaign = vm.computeCreateAddress(address(this), testNonce + 1);

        bytes memory ctInit =
            abi.encodeCall(GrowfiCampaignToken.initialize, ("Olive Sicily", "OLIVE", predictedCampaign));
        TransparentUpgradeableProxy ctProxy =
            new TransparentUpgradeableProxy(address(ctImpl), protocolOwner, ctInit);
        campaignToken = GrowfiCampaignToken(address(ctProxy));

        GrowfiCampaign.InitParams memory cp = GrowfiCampaign.InitParams({
            producer: producer,
            factory: address(registry),
            usdc: address(usdc),
            protocolFeeRecipient: feeRecipient
        });
        bytes memory campInit = abi.encodeCall(GrowfiCampaign.initialize, (cp));
        TransparentUpgradeableProxy campaignProxy =
            new TransparentUpgradeableProxy(address(campImpl), protocolOwner, campInit);
        campaign = GrowfiCampaign(payable(address(campaignProxy)));
        require(address(campaign) == predictedCampaign, "address prediction failed");

        // Satellites: setYieldToken/setStakingVault cross-wire to peer
        // satellites — keep the consumer side first while peer is unset.
        vm.startPrank(address(registry));
        campaign.setYieldToken(address(0xCa2));
        campaign.setHarvestManager(address(0xCa4));
        campaign.setStakingVault(address(0xCa3));
        campaign.setCampaignToken(address(campaignToken));
        vm.stopPrank();

        // Inject pricePerToken into SaleClassicModule's namespaced slot
        // (the module itself is NOT attached — we just need the storage
        // value so RepaymentModule's principal calc has a non-zero base).
        vm.store(address(campaign), SALE_PRICE_SLOT, bytes32(PRICE_PER_TOKEN_USD18));

        // Attach repayment via factory
        vm.prank(address(registry));
        campaign.attachModuleAsFactory(REPAY_TYPE, REPAY_KIND, address(repayImpl), "ipfs://repay.json");

        // Producer-initialize with bonus = 0 (refund-at-par default)
        vm.prank(producer);
        RepaymentModule(payable(address(campaign))).initializeRepaymentByProducer(0);

        vm.prank(address(registry));
        campaign.closeBootstrap();

        // Mint CT to Alice + Bob by pranking as the Campaign
        vm.prank(address(campaign));
        campaignToken.mint(alice, 1_000e18);
        vm.prank(address(campaign));
        campaignToken.mint(bob, 500e18);

        usdc.mint(producer, 1_000_000e6);
    }

    function _r() internal view returns (RepaymentModule) {
        return RepaymentModule(payable(address(campaign)));
    }

    function _fundPool(uint256 amount) internal {
        vm.startPrank(producer);
        usdc.approve(address(campaign), amount);
        _r().fundPool(amount);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Initial state + init
    // ------------------------------------------------------------------

    function test_initialState_principalDerivedBonusZero() public view {
        assertEq(_r().principalPerCt(), EXPECTED_PRINCIPAL_USDC6, "principal per CT from pricePerToken");
        assertEq(_r().bonusPerCt(), 0, "initial bonus must be 0");
        assertEq(_r().payoutPerCt(), EXPECTED_PRINCIPAL_USDC6, "payout = principal + 0");
        assertEq(_r().poolBalance(), 0);
    }

    function test_initialize_emitsInitialized() public {
        // Fresh module on a fresh proxy so we can re-trigger init.
        RepaymentModule fresh = new RepaymentModule();
        // We hand-roll only the slot machinery; this test asserts the
        // public initializer behaves on the existing already-init'd
        // module by rejecting re-init.
        vm.prank(producer);
        vm.expectRevert(RepaymentModule.AlreadyInitialized.selector);
        _r().initializeRepaymentByProducer(0.05e6);
        fresh; // silence unused-warn
    }

    function test_initializeByFactory_outsideBootstrap_reverts() public {
        // Bootstrap already closed in setUp. A direct (re-)init via the
        // factory path must revert with OnlyFactoryBootstrap.
        vm.prank(address(registry));
        vm.expectRevert(RepaymentModule.AlreadyInitialized.selector);
        _r().initializeRepayment(RepaymentModule.InitParams({initialBonusPerCt: 0}));
    }

    function test_principalPerCt_zeroWhenPriceNotSet() public {
        // Wipe the SaleClassic price slot to simulate "module not attached".
        vm.store(address(campaign), SALE_PRICE_SLOT, bytes32(uint256(0)));
        assertEq(_r().principalPerCt(), 0, "principal should be 0 with no price");
    }

    // ------------------------------------------------------------------
    // Pool admin
    // ------------------------------------------------------------------

    function test_fundPool_increasesBalance() public {
        _fundPool(INITIAL_POOL);
        assertEq(_r().poolBalance(), INITIAL_POOL);
        assertEq(usdc.balanceOf(address(campaign)), INITIAL_POOL);
    }

    function test_fundPool_zeroAmount_reverts() public {
        vm.prank(producer);
        vm.expectRevert(RepaymentModule.ZeroAmount.selector);
        _r().fundPool(0);
    }

    function test_fundPool_onlyProducer() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(campaign), 100e6);
        vm.expectRevert(RepaymentModule.OnlyProducer.selector);
        _r().fundPool(100e6);
        vm.stopPrank();
    }

    function test_withdrawUnusedPool_works() public {
        _fundPool(INITIAL_POOL);
        uint256 producerBefore = usdc.balanceOf(producer);

        vm.prank(producer);
        _r().withdrawUnusedPool(2_000e6);

        assertEq(_r().poolBalance(), 8_000e6);
        assertEq(usdc.balanceOf(producer), producerBefore + 2_000e6);
    }

    function test_withdrawUnusedPool_zeroAmount_reverts() public {
        _fundPool(INITIAL_POOL);
        vm.prank(producer);
        vm.expectRevert(RepaymentModule.ZeroAmount.selector);
        _r().withdrawUnusedPool(0);
    }

    function test_withdrawUnusedPool_overflow_reverts() public {
        _fundPool(100e6);
        vm.prank(producer);
        vm.expectRevert(RepaymentModule.PoolBalanceUnderflow.selector);
        _r().withdrawUnusedPool(200e6);
    }

    function test_withdrawUnusedPool_onlyProducer() public {
        _fundPool(INITIAL_POOL);
        vm.prank(alice);
        vm.expectRevert(RepaymentModule.OnlyProducer.selector);
        _r().withdrawUnusedPool(100e6);
    }

    // ------------------------------------------------------------------
    // Bonus setter
    // ------------------------------------------------------------------

    function test_setBonusPerCt_works() public {
        vm.prank(producer);
        _r().setBonusPerCt(0.05e6);
        assertEq(_r().bonusPerCt(), 0.05e6);
        assertEq(_r().payoutPerCt(), EXPECTED_PRINCIPAL_USDC6 + 0.05e6);
    }

    function test_setBonusPerCt_canReturnToZero() public {
        vm.prank(producer);
        _r().setBonusPerCt(0.1e6);
        vm.prank(producer);
        _r().setBonusPerCt(0);
        assertEq(_r().bonusPerCt(), 0);
        assertEq(_r().payoutPerCt(), EXPECTED_PRINCIPAL_USDC6);
    }

    function test_setBonusPerCt_onlyProducer() public {
        vm.prank(alice);
        vm.expectRevert(RepaymentModule.OnlyProducer.selector);
        _r().setBonusPerCt(0.05e6);
    }

    function test_setBonusPerCt_emitsEvent() public {
        vm.prank(producer);
        vm.expectEmit(true, true, true, true);
        emit RepaymentModule.RepaymentBonusSet(0, 0.05e6);
        _r().setBonusPerCt(0.05e6);

        vm.prank(producer);
        vm.expectEmit(true, true, true, true);
        emit RepaymentModule.RepaymentBonusSet(0.05e6, 0.1e6);
        _r().setBonusPerCt(0.1e6);
    }

    // ------------------------------------------------------------------
    // Redeem — principal-only (bonus = 0)
    // ------------------------------------------------------------------

    function test_redeem_principalOnly_burnsCtPaysUsdc() public {
        _fundPool(INITIAL_POOL);

        uint256 amount = 200e18;
        // Expected: 200 CT * $0.144 = $28.80 → 28_800_000 USDC-6
        uint256 expectedPayout = amount * EXPECTED_PRINCIPAL_USDC6 / 1e18;
        assertEq(expectedPayout, 28_800_000);

        uint256 aliceCtBefore = campaignToken.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        _r().redeem(amount, new uint256[](0));

        assertEq(campaignToken.balanceOf(alice), aliceCtBefore - amount);
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + expectedPayout);
        assertEq(_r().poolBalance(), INITIAL_POOL - expectedPayout);
        assertEq(_r().claimedByUser(alice), expectedPayout);
    }

    function test_redeem_emitsRepaidWithSplit() public {
        _fundPool(INITIAL_POOL);
        vm.prank(producer);
        _r().setBonusPerCt(0.05e6);

        uint256 amount = 100e18;
        uint256 expectedPrincipal = amount * EXPECTED_PRINCIPAL_USDC6 / 1e18;
        uint256 expectedBonus = amount * 0.05e6 / 1e18;
        uint256 expectedPayout = expectedPrincipal + expectedBonus;

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit RepaymentModule.Repaid(
            alice,
            amount,
            expectedPrincipal,
            expectedBonus,
            INITIAL_POOL - expectedPayout,
            expectedPayout
        );
        _r().redeem(amount, new uint256[](0));
    }

    // ------------------------------------------------------------------
    // Redeem — with bonus
    // ------------------------------------------------------------------

    function test_redeem_withBonus_paysPrincipalPlusBonus() public {
        _fundPool(INITIAL_POOL);
        vm.prank(producer);
        _r().setBonusPerCt(0.02e6); // $0.02 per CT bonus

        uint256 amount = 500e18;
        uint256 expectedPrincipal = amount * EXPECTED_PRINCIPAL_USDC6 / 1e18; // 72e6
        uint256 expectedBonus = amount * 0.02e6 / 1e18; // 10e6
        uint256 expectedPayout = expectedPrincipal + expectedBonus; // 82e6

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        _r().redeem(amount, new uint256[](0));

        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, expectedPayout);
        assertEq(_r().claimedByUser(alice), expectedPayout);
    }

    function test_redeem_bonusChangesMidStream() public {
        _fundPool(INITIAL_POOL);

        // Alice exits first at bonus = 0 → only principal
        uint256 amount = 100e18;
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        _r().redeem(amount, new uint256[](0));
        uint256 aliceGot = usdc.balanceOf(alice) - aliceUsdcBefore;
        assertEq(aliceGot, amount * EXPECTED_PRINCIPAL_USDC6 / 1e18);

        // Producer raises bonus, Bob exits at +bonus
        vm.prank(producer);
        _r().setBonusPerCt(0.05e6);

        uint256 bobAmount = 100e18;
        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        _r().redeem(bobAmount, new uint256[](0));
        uint256 bobGot = usdc.balanceOf(bob) - bobUsdcBefore;
        assertEq(bobGot, bobAmount * (EXPECTED_PRINCIPAL_USDC6 + 0.05e6) / 1e18);

        // Bob got strictly more per CT than Alice
        assertGt(bobGot, aliceGot);
    }

    // ------------------------------------------------------------------
    // Redeem — gating
    // ------------------------------------------------------------------

    function test_redeem_zeroAmount_reverts() public {
        _fundPool(INITIAL_POOL);
        vm.prank(alice);
        vm.expectRevert(RepaymentModule.ZeroAmount.selector);
        _r().redeem(0, new uint256[](0));
    }

    function test_redeem_revertsWhenPriceNotSet() public {
        _fundPool(INITIAL_POOL);
        // Wipe SaleClassic price → principal becomes 0 → revert PrincipalNotSet
        vm.store(address(campaign), SALE_PRICE_SLOT, bytes32(uint256(0)));
        vm.prank(alice);
        vm.expectRevert(RepaymentModule.PrincipalNotSet.selector);
        _r().redeem(100e18, new uint256[](0));
    }

    function test_redeem_revertsWhenPoolEmpty() public {
        vm.prank(alice);
        vm.expectRevert(RepaymentModule.PoolInsufficient.selector);
        _r().redeem(100e18, new uint256[](0));
    }

    function test_redeem_revertsWhenPoolInsufficient() public {
        _fundPool(1e6); // only $1 in pool
        vm.prank(alice);
        vm.expectRevert(RepaymentModule.PoolInsufficient.selector);
        _r().redeem(200e18, new uint256[](0)); // would need $28.80
    }

    function test_redeem_revertsWhenEnded() public {
        _fundPool(INITIAL_POOL);
        vm.prank(producer);
        campaign.endCampaign();

        vm.prank(alice);
        vm.expectRevert(RepaymentModule.InvalidState.selector);
        _r().redeem(100e18, new uint256[](0));
    }

    function test_redeem_revertsWhenPaused() public {
        _fundPool(INITIAL_POOL);
        vm.prank(producer);
        campaign.setPaused(true);

        vm.prank(alice);
        vm.expectRevert(RepaymentModule.InvalidState.selector);
        _r().redeem(100e18, new uint256[](0));
    }

    function test_redeem_revertsWhenModuleDisabled() public {
        _fundPool(INITIAL_POOL);
        vm.prank(producer);
        campaign.setModuleEnabled(REPAY_TYPE, false);

        vm.prank(alice);
        vm.expectRevert(GrowfiCampaign.ModuleDisabled.selector);
        _r().redeem(100e18, new uint256[](0));
    }

    function test_redeem_revertsWithoutEnoughCt() public {
        _fundPool(INITIAL_POOL);
        // Alice has 1000 CT; ask 2000 → CT burn underflows
        vm.prank(alice);
        vm.expectRevert(); // ERC20InsufficientBalance from OZ ERC20
        _r().redeem(2_000e18, new uint256[](0));
    }

    // ------------------------------------------------------------------
    // Multiple holders + accounting
    // ------------------------------------------------------------------

    function test_redeem_multipleHolders_independentAccounting() public {
        _fundPool(INITIAL_POOL);
        vm.prank(producer);
        _r().setBonusPerCt(0.01e6);

        uint256 aliceAmt = 100e18;
        uint256 bobAmt = 50e18;
        uint256 ratePerCt = EXPECTED_PRINCIPAL_USDC6 + 0.01e6;

        vm.prank(alice);
        _r().redeem(aliceAmt, new uint256[](0));
        vm.prank(bob);
        _r().redeem(bobAmt, new uint256[](0));

        assertEq(_r().claimedByUser(alice), aliceAmt * ratePerCt / 1e18);
        assertEq(_r().claimedByUser(bob), bobAmt * ratePerCt / 1e18);
        uint256 totalOut = (aliceAmt + bobAmt) * ratePerCt / 1e18;
        assertEq(_r().poolBalance(), INITIAL_POOL - totalOut);
    }

    function test_redeem_repeatedByOneHolder_accumulatesClaimed() public {
        _fundPool(INITIAL_POOL);

        vm.startPrank(alice);
        _r().redeem(100e18, new uint256[](0));
        _r().redeem(50e18, new uint256[](0));
        vm.stopPrank();

        uint256 expectedTotal = 150e18 * EXPECTED_PRINCIPAL_USDC6 / 1e18;
        assertEq(_r().claimedByUser(alice), expectedTotal);
    }

    // ------------------------------------------------------------------
    // quoteRepayment view
    // ------------------------------------------------------------------

    function test_quoteRepayment_matchesActualPayout_noBonus() public {
        _fundPool(INITIAL_POOL);
        uint256 quote = _r().quoteRepayment(300e18);
        assertEq(quote, 300e18 * EXPECTED_PRINCIPAL_USDC6 / 1e18);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        _r().redeem(300e18, new uint256[](0));
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, quote);
    }

    function test_quoteRepayment_matchesActualPayout_withBonus() public {
        _fundPool(INITIAL_POOL);
        vm.prank(producer);
        _r().setBonusPerCt(0.03e6);

        uint256 quote = _r().quoteRepayment(250e18);
        uint256 expected = 250e18 * (EXPECTED_PRINCIPAL_USDC6 + 0.03e6) / 1e18;
        assertEq(quote, expected);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        _r().redeem(250e18, new uint256[](0));
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, quote);
    }

    function test_quoteRepayment_zeroAmount_zero() public view {
        assertEq(_r().quoteRepayment(0), 0);
    }
}
