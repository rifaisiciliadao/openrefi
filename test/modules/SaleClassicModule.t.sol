// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GrowfiCampaign} from "../../src/GrowfiCampaign.sol";
import {CampaignStorage} from "../../src/host/CampaignStorage.sol";
import {SaleClassicModule} from "../../src/modules/SaleClassicModule.sol";
import {GrowfiCampaignToken} from "../../src/GrowfiCampaignToken.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

import {TestModuleRegistry} from "../host/TestModuleRegistry.sol";
import {SaleClassicHelper} from "./SaleClassicHelper.sol";

contract SaleClassicModuleTest is Test {
    bytes32 internal constant SALE_KIND = keccak256("growfi.sale.classic.v1");
    bytes32 internal constant SALE_TYPE = keccak256("growfi.type.sale");

    address internal protocolOwner = makeAddr("protocolOwner");
    address internal producer = makeAddr("producer");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    TestModuleRegistry internal registry;
    GrowfiCampaign internal campaign;
    GrowfiCampaignToken internal campaignToken;
    SaleClassicModule internal saleImpl;
    MockUSDC internal usdc;

    // Sale params
    uint256 internal constant PRICE = 0.144e18; // $0.144 per CT
    uint256 internal constant MIN_CAP = 100e18;
    uint256 internal constant MAX_CAP = 1_000e18;
    uint256 internal constant FUNDING_DURATION = 7 days;
    uint256 internal constant SEASON_DURATION = 365 days;
    uint256 internal constant FUNDING_FEE_BPS = 300; // 3%
    uint256 internal constant FIXED_RATE = 0.144e6; // 0.144 USDC per CT (6-dec)

    function setUp() public {
        // ---- mocks ----
        usdc = new MockUSDC();

        // ---- registry ----
        TestModuleRegistry registryImpl = new TestModuleRegistry();
        bytes memory initData = abi.encodeCall(TestModuleRegistry.initialize, (protocolOwner));
        TransparentUpgradeableProxy registryProxy =
            new TransparentUpgradeableProxy(address(registryImpl), protocolOwner, initData);
        registry = TestModuleRegistry(address(registryProxy));

        // ---- sale module impl + whitelist ----
        saleImpl = new SaleClassicModule();
        vm.startPrank(protocolOwner);
        registry.setModuleKindSelectors(SALE_KIND, SaleClassicHelper.selectors());
        registry.approveModuleImpl(SALE_KIND, address(saleImpl), true);
        vm.stopPrank();

        // ---- predict campaign address so we can pre-deploy CT pointing to it ----
        // The trick: we deploy campaign proxy AFTER the CT, so we need the CT
        // to know the campaign's address ahead of time. Simpler workaround:
        // deploy a CT impl first, then deploy the Campaign proxy, then deploy
        // a CT proxy initialized with the Campaign proxy address.
        GrowfiCampaignToken ctImpl = new GrowfiCampaignToken();
        // Compute campaign proxy address by simulating a fresh TUP deploy.
        // Forge runs deterministically — the next deployed contract is the
        // Campaign proxy at this nonce.
        // Instead of computing, just deploy in the right order:
        // 1) deploy Campaign proxy with a placeholder CT, 2) deploy CT proxy
        // with the Campaign address, 3) ignore the placeholder write inside
        // the host (the host doesn't validate campaignToken behaviorally).
        // Easiest: use a dummy CT address in Campaign init, then deploy real
        // CT pointing at Campaign, then wire it in via test-only setter.
        // But our v4 host has no such setter. So: deploy Campaign first,
        // then deploy CT proxy with Campaign's address, then... the host
        // already stored the placeholder. We need to either pre-compute the
        // CT proxy address or do it differently.
        //
        // Approach: deploy CT proxy FIRST with a placeholder Campaign
        // address (zero), then re-initialize it later via... no, initialize
        // is single-shot. The CT contract has no setter for `campaign` either.
        //
        // Cleanest: deploy Campaign proxy, then deploy CT proxy with Campaign
        // address, then the Campaign was initialized with a stale CT
        // placeholder. For the v4 tests this is fine because we ALSO need
        // the host's `campaignToken` field to point at the real CT.
        //
        // Final approach: use `vm.computeCreateAddress` to predict the
        // Campaign proxy address, then deploy CT first.

        // Predict the campaign proxy address (next create from this test contract,
        // accounting for the campaign impl deploy that happens just before).
        GrowfiCampaign campImpl = new GrowfiCampaign();
        uint64 testNonce = vm.getNonce(address(this));
        // After the next deployment the nonce will be testNonce, so the address
        // is computeCreateAddress(this, testNonce + 0) for the CT proxy then
        // testNonce + 1 for the Campaign proxy. We want the Campaign proxy
        // address up-front:
        address predictedCampaign = vm.computeCreateAddress(address(this), testNonce + 1);

        // Deploy CT proxy with the predicted Campaign address
        bytes memory ctInit =
            abi.encodeCall(GrowfiCampaignToken.initialize, ("Olive Sicily", "OLIVE", predictedCampaign));
        TransparentUpgradeableProxy ctProxy =
            new TransparentUpgradeableProxy(address(ctImpl), protocolOwner, ctInit);
        campaignToken = GrowfiCampaignToken(address(ctProxy));

        // Now deploy the Campaign proxy (this should land at predictedCampaign)
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

        // Wire satellites (test stand-in for factory deploy)
        vm.startPrank(address(registry));
        campaign.setCampaignToken(address(campaignToken));
        campaign.setYieldToken(address(0xCa2));
        campaign.setStakingVault(address(0xCa3));
        campaign.setHarvestManager(address(0xCa4));
        vm.stopPrank();

        // ---- attach sale module + initialize via fallback ----
        vm.prank(address(registry));
        campaign.attachModuleAsFactory(SALE_TYPE, SALE_KIND, address(saleImpl), "ipfs://sale.json");

        // Call initializeSaleClassic via fallback as the factory (bootstrap window open)
        SaleClassicModule.InitParams memory sp = SaleClassicModule.InitParams({
            pricePerToken: PRICE,
            minCap: MIN_CAP,
            maxCap: MAX_CAP,
            fundingDeadline: block.timestamp + FUNDING_DURATION,
            seasonDuration: SEASON_DURATION,
            fundingFeeBps: FUNDING_FEE_BPS,
            sequencerUptimeFeed: address(0),
            growMinter: address(0)
        });
        vm.prank(address(registry));
        SaleClassicModule(payable(address(campaign))).initializeSaleClassic(sp);

        // Close bootstrap
        vm.prank(address(registry));
        campaign.closeBootstrap();

        // Producer registers USDC as an accepted payment token (fixed-rate)
        vm.prank(producer);
        SaleClassicModule(payable(address(campaign))).addAcceptedToken(
            address(usdc), SaleClassicModule.PricingMode.Fixed, FIXED_RATE, address(0)
        );

        // Mint some USDC to buyers
        usdc.mint(alice, 10_000e6);
        usdc.mint(bob, 10_000e6);
    }

    // ------------------------------------------------------------------
    // Sanity
    // ------------------------------------------------------------------

    function test_state_initialFunding() public view {
        assertEq(uint8(campaign.state()), uint8(CampaignStorage.State.Funding));
        assertEq(SaleClassicModule(payable(address(campaign))).pricePerToken(), PRICE);
        assertEq(SaleClassicModule(payable(address(campaign))).minCap(), MIN_CAP);
        assertEq(SaleClassicModule(payable(address(campaign))).maxCap(), MAX_CAP);
        assertEq(SaleClassicModule(payable(address(campaign))).fundingFeeBps(), FUNDING_FEE_BPS);
        assertEq(SaleClassicModule(payable(address(campaign))).currentSupply(), 0);
    }

    function test_acceptedTokens_listsUsdc() public view {
        address[] memory tokens = SaleClassicModule(payable(address(campaign))).getAcceptedTokens();
        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(usdc));
    }

    // ------------------------------------------------------------------
    // Buy in Funding state
    // ------------------------------------------------------------------

    function test_buy_fundingState_mintsAndEscrows() public {
        // Buy under minCap so the Campaign stays in Funding (escrow remains held).
        uint256 payment = 7.2e6; // $7.20 → 50 CT (minCap is 100 CT)

        vm.startPrank(alice);
        usdc.approve(address(campaign), payment);
        SaleClassicModule(payable(address(campaign))).buy(address(usdc), payment);
        vm.stopPrank();

        uint256 expectedFee = payment * FUNDING_FEE_BPS / 10_000;
        uint256 expectedNet = payment - expectedFee;

        assertEq(usdc.balanceOf(feeRecipient), expectedFee, "fee not forwarded");
        assertEq(usdc.balanceOf(address(campaign)), expectedNet, "escrow not held");
        assertEq(usdc.balanceOf(producer), 0, "escrow leaked to producer pre-activate");

        assertEq(campaignToken.balanceOf(alice), 50e18);
        assertEq(SaleClassicModule(payable(address(campaign))).currentSupply(), 50e18);
        assertEq(uint8(campaign.state()), uint8(CampaignStorage.State.Funding));
    }

    function test_buy_autoActivates_releasesEscrowToProducer() public {
        // Buy exactly minCap in a single tx
        uint256 payment = 14.4e6; // $14.40 → 100 CT

        vm.startPrank(alice);
        usdc.approve(address(campaign), payment);
        SaleClassicModule(payable(address(campaign))).buy(address(usdc), payment);
        vm.stopPrank();

        uint256 expectedFee = payment * FUNDING_FEE_BPS / 10_000;
        uint256 expectedNet = payment - expectedFee;

        // Auto-activate fired during buy()
        assertEq(uint8(campaign.state()), uint8(CampaignStorage.State.Active));
        // The buy hit minCap exactly — the net payment is split: the
        // queue fill loop is empty (no queue yet), so the full net goes
        // to the producer via the direct mint path during the SAME buy
        // that triggered activation (producer receives the live payment;
        // the `_activate` escrow-drain loop sees zero balance).
        assertEq(usdc.balanceOf(producer), expectedNet, "producer didn't receive net payment");
        assertEq(usdc.balanceOf(address(campaign)), 0, "no escrow expected post-activate");
        assertEq(usdc.balanceOf(feeRecipient), expectedFee);
        assertEq(campaignToken.balanceOf(alice), 100e18);
    }

    function test_buy_belowMinCap_staysFunding() public {
        uint256 payment = 7.2e6; // → 50 CT
        vm.startPrank(alice);
        usdc.approve(address(campaign), payment);
        SaleClassicModule(payable(address(campaign))).buy(address(usdc), payment);
        vm.stopPrank();

        assertEq(uint8(campaign.state()), uint8(CampaignStorage.State.Funding));
        assertEq(usdc.balanceOf(address(campaign)), payment - payment * FUNDING_FEE_BPS / 10_000);
    }

    function test_previewBuy_matchesActualMint() public {
        uint256 payment = 14.4e6;
        (uint256 tokensOut, uint256 effectivePayment,, uint256 fee) =
            SaleClassicModule(payable(address(campaign))).previewBuy(address(usdc), payment);
        assertEq(tokensOut, 100e18);
        assertEq(effectivePayment, payment);
        assertEq(fee, payment * FUNDING_FEE_BPS / 10_000);
    }

    // ------------------------------------------------------------------
    // Sellback queue
    // ------------------------------------------------------------------

    function test_sellBack_queuedAndFilledByNextBuyer() public {
        // 1. Alice buys past minCap → auto-activate
        uint256 alicePayment = 14.4e6;
        vm.startPrank(alice);
        usdc.approve(address(campaign), alicePayment);
        SaleClassicModule(payable(address(campaign))).buy(address(usdc), alicePayment);
        vm.stopPrank();
        assertEq(uint8(campaign.state()), uint8(CampaignStorage.State.Active));

        // 2. Alice requests sellback of 50 CT
        vm.startPrank(alice);
        campaignToken.approve(address(campaign), 50e18);
        SaleClassicModule(payable(address(campaign))).sellBack(50e18);
        vm.stopPrank();

        assertEq(SaleClassicModule(payable(address(campaign))).getSellBackQueueDepth(), 50e18);
        // Alice's CT is now custodial in Campaign
        assertEq(campaignToken.balanceOf(alice), 50e18);
        assertEq(campaignToken.balanceOf(address(campaign)), 50e18);

        // 3. Bob buys 50 CT → fills Alice's order
        uint256 bobPayment = 7.2e6;
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.startPrank(bob);
        usdc.approve(address(campaign), bobPayment);
        SaleClassicModule(payable(address(campaign))).buy(address(usdc), bobPayment);
        vm.stopPrank();

        // Queue drained
        assertEq(SaleClassicModule(payable(address(campaign))).getSellBackQueueDepth(), 0);
        // Bob has 50 CT (minted fresh after burn from custody)
        assertEq(campaignToken.balanceOf(bob), 50e18);
        // Alice received net payment from Bob's buy (3% skimmed to feeRecipient on the way)
        uint256 netToAlice = bobPayment - bobPayment * FUNDING_FEE_BPS / 10_000;
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + netToAlice);
        // Supply is unchanged (burn + mint)
        assertEq(SaleClassicModule(payable(address(campaign))).currentSupply(), 100e18);
    }

    function test_cancelSellBack_returnsTokens() public {
        // activate then queue 50 CT
        vm.startPrank(alice);
        usdc.approve(address(campaign), 14.4e6);
        SaleClassicModule(payable(address(campaign))).buy(address(usdc), 14.4e6);
        campaignToken.approve(address(campaign), 50e18);
        SaleClassicModule(payable(address(campaign))).sellBack(50e18);
        SaleClassicModule(payable(address(campaign))).cancelSellBack();
        vm.stopPrank();

        assertEq(SaleClassicModule(payable(address(campaign))).getSellBackQueueDepth(), 0);
        assertEq(campaignToken.balanceOf(alice), 100e18);
    }

    // ------------------------------------------------------------------
    // Buyback (failed campaign)
    // ------------------------------------------------------------------

    function test_triggerBuyback_failedFunding() public {
        // Alice buys 50 CT (below minCap of 100)
        vm.startPrank(alice);
        usdc.approve(address(campaign), 7.2e6);
        SaleClassicModule(payable(address(campaign))).buy(address(usdc), 7.2e6);
        vm.stopPrank();
        assertEq(uint8(campaign.state()), uint8(CampaignStorage.State.Funding));

        // Past deadline
        vm.warp(block.timestamp + FUNDING_DURATION + 1);
        SaleClassicModule(payable(address(campaign))).triggerBuyback();
        assertEq(uint8(campaign.state()), uint8(CampaignStorage.State.Buyback));
    }

    function test_buyback_refundsNetPaymentBurnsTokens() public {
        // Alice buys 50 CT → Funding state preserved
        uint256 payment = 7.2e6;
        uint256 expectedFee = payment * FUNDING_FEE_BPS / 10_000;
        uint256 expectedNet = payment - expectedFee;

        vm.startPrank(alice);
        usdc.approve(address(campaign), payment);
        SaleClassicModule(payable(address(campaign))).buy(address(usdc), payment);
        vm.stopPrank();

        // Funding fails
        vm.warp(block.timestamp + FUNDING_DURATION + 1);
        SaleClassicModule(payable(address(campaign))).triggerBuyback();

        // Alice claims buyback
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceCtBefore = campaignToken.balanceOf(alice);

        vm.prank(alice);
        SaleClassicModule(payable(address(campaign))).buyback(address(usdc));

        // Refund is NET (funding fee non-refundable)
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + expectedNet);
        assertEq(campaignToken.balanceOf(alice), 0);
        assertEq(aliceCtBefore, 50e18);
        // Fee stays with the protocol recipient regardless of outcome
        assertEq(usdc.balanceOf(feeRecipient), expectedFee);
    }

    // ------------------------------------------------------------------
    // Edge cases
    // ------------------------------------------------------------------

    function test_buy_revertsIfTokenNotAccepted() public {
        MockUSDC fake = new MockUSDC();
        fake.mint(alice, 100e6);
        vm.startPrank(alice);
        fake.approve(address(campaign), 100e6);
        vm.expectRevert(SaleClassicModule.TokenNotAccepted.selector);
        SaleClassicModule(payable(address(campaign))).buy(address(fake), 100e6);
        vm.stopPrank();
    }

    function test_buy_revertsWhenMaxCapReached() public {
        // Push past maxCap with one giant buy
        uint256 paymentToFill = MAX_CAP * FIXED_RATE / 1e18; // exact USDC needed
        // adjust for funding fee: gross input ≥ paymentToFill / (1 - fee)
        // simpler: mint enough USDC and just check it caps out
        usdc.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdc.approve(address(campaign), type(uint256).max);
        SaleClassicModule(payable(address(campaign))).buy(address(usdc), paymentToFill * 2);
        // After this, currentSupply should be at maxCap exactly
        assertEq(SaleClassicModule(payable(address(campaign))).currentSupply(), MAX_CAP);

        // Another buy with no sellback queue should revert
        vm.expectRevert(SaleClassicModule.MaxCapReached.selector);
        SaleClassicModule(payable(address(campaign))).buy(address(usdc), 100e6);
        vm.stopPrank();
    }
}
