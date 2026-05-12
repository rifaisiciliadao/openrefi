// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GrowfiCampaignFactory} from "../src/GrowfiCampaignFactory.sol";
import {GrowfiCampaign} from "../src/GrowfiCampaign.sol";
import {CampaignStorage} from "../src/host/CampaignStorage.sol";
import {IGrowfiCampaignFull} from "../src/interfaces/IGrowfiCampaignFull.sol";
import {SaleClassicModule} from "../src/modules/SaleClassicModule.sol";
import {CollateralModule} from "../src/modules/CollateralModule.sol";
import {GrowfiToken} from "../src/GrowfiToken.sol";
import {GrowfiTreasury} from "../src/GrowfiTreasury.sol";
import {GrowfiMinter} from "../src/GrowfiMinter.sol";
import {GrowfiFeeSplitter} from "../src/GrowfiFeeSplitter.sol";
import {Deployer} from "./helpers/Deployer.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {MockOracle} from "./helpers/MockOracle.sol";

/// @notice Auto-allocate hook coverage: when a user calls `GrowfiToken.buy()` while the
///         multisig has flipped automation ON, the freshly received USDC must spread to
///         tracked Active campaigns equally — capped at remaining mintable room — without
///         the buyer needing a second transaction.
contract GrowfiAutoAllocTest is Test {
    GrowfiCampaignFactory factory;
    GrowfiToken growToken;
    GrowfiTreasury growTreasury;
    GrowfiMinter growMinter;
    GrowfiFeeSplitter feeSplitter;
    MockERC20 usdc;
    MockOracle usdFeed;

    address constant OWNER = address(0xF000);
    address constant OPS = address(0x0123);
    address constant DEPLOYER = address(0xD000);
    address constant PRODUCER_A = address(0xA1);
    address constant PRODUCER_B = address(0xA2);
    address constant PRODUCER_C = address(0xA3);
    address constant PRODUCER_D = address(0xA4);
    address constant ALICE = address(0xA5);

    uint256 constant ONE_USDC = 1e6;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdFeed = new MockOracle(int256(1e8), 8);

        factory = Deployer.deployProtocol(OWNER, OWNER, address(usdc), address(0));
        vm.prank(OWNER);
        factory.setMinSeasonDuration(1 hours);

        // GROW system
        GrowfiToken tImpl = new GrowfiToken();
        bytes memory tInit = abi.encodeCall(
            GrowfiToken.initialize, ("GrowFi", "GROW", address(factory), DEPLOYER, 1_000_000e18, 1_000, 1e17)
        );
        growToken = GrowfiToken(address(new TransparentUpgradeableProxy(address(tImpl), OWNER, tInit)));

        GrowfiTreasury trImpl = new GrowfiTreasury();
        bytes memory trInit = abi.encodeCall(GrowfiTreasury.initialize, (address(factory), address(growToken)));
        growTreasury = GrowfiTreasury(address(new TransparentUpgradeableProxy(address(trImpl), OWNER, trInit)));

        GrowfiMinter mImpl = new GrowfiMinter();
        GrowfiMinter.BondingCurveParams memory params = GrowfiMinter.BondingCurveParams({
            tier1RateBps: 10_000, tier2RateBps: 7_000, tier3RateBps: 4_000, tier2to3ThresholdBps: 5_000
        });
        bytes memory mInit = abi.encodeCall(GrowfiMinter.initialize, (address(factory), address(growToken), params));
        growMinter = GrowfiMinter(address(new TransparentUpgradeableProxy(address(mImpl), OWNER, mInit)));

        GrowfiFeeSplitter fsImpl = new GrowfiFeeSplitter();
        bytes memory fsInit =
            abi.encodeCall(GrowfiFeeSplitter.initialize, (address(factory), address(growTreasury), OPS, 3_000));
        feeSplitter = GrowfiFeeSplitter(address(new TransparentUpgradeableProxy(address(fsImpl), OWNER, fsInit)));

        vm.startPrank(OWNER);
        factory.setGrowfiContracts(address(growToken), address(growMinter), address(growTreasury), address(feeSplitter));
        factory.setProtocolFeeRecipient(address(feeSplitter));
        factory.setGrowfiTreasuryAutomationEnabled(true);
        vm.stopPrank();

        vm.startPrank(address(factory));
        growToken.setMinter(address(growMinter));
        growToken.setTreasury(address(growTreasury));
        growTreasury.addAcceptedStablecoin(address(usdc), 1e12, address(usdFeed), 24 hours, 9_500, 10_500);
        growMinter.setExcludedFromMint(address(growTreasury), true);
        vm.stopPrank();

        // Seed Alice with USDC + initial GROW backing so the floor is non-zero on the
        // very first direct buy.
        usdc.mint(ALICE, 100_000 * ONE_USDC);
        usdc.mint(address(growTreasury), 1_000 * ONE_USDC);
        vm.prank(ALICE);
        usdc.approve(address(growToken), type(uint256).max);
    }

    /// @dev Helper: spawn a campaign + activate it past softcap so it's eligible for tracking.
    function _spawnCampaign(address producer, string memory name, uint256 price, uint256 maxCap)
        internal
        returns (address campaign)
    {
        // Pick minCap such that tokensOut from a $50 buy crosses softcap.
        // tokensOut for $50 net = 50e18 / price * 0.97 (3% fee) → fits if minCap ≤ that.
        // Use a generous 100 OLIVE minCap.
        uint256 minCap = 100e18;

        GrowfiCampaignFactory.CreateCampaignParams memory p = GrowfiCampaignFactory.CreateCampaignParams({
                producer: producer,
                campaignTokenName: name,
                campaignTokenSymbol: "TKN",
                yieldTokenName: "Y",
                yieldTokenSymbol: "y",
                minProductClaim: 1e18,
                sale: SaleClassicModule.InitParams({
                    pricePerToken: price,
                    minCap: minCap,
                    maxCap: maxCap,
                    fundingDeadline: block.timestamp + 30 days,
                    seasonDuration: 1 hours,
                    fundingFeeBps: 0,
                    sequencerUptimeFeed: address(0),
                    growMinter: address(0)
                }),
                collateral: CollateralModule.InitParams({
                    expectedAnnualHarvestUsd: 1000e18,
                    expectedAnnualHarvest: 100e18,
                    firstHarvestYear: 2027,
                    coverageHarvests: 0
                })
            });
        vm.prank(producer);
        campaign = factory.createCampaign(p);

        vm.prank(producer);
        IGrowfiCampaignFull(payable(campaign))
            .addAcceptedToken(address(usdc), SaleClassicModule.PricingMode.Fixed, price / 1e12, address(0));

        // Push past softcap so state -> Active.
        usdc.mint(producer, 200 * ONE_USDC);
        vm.prank(producer);
        usdc.approve(campaign, 200 * ONE_USDC);
        vm.prank(producer);
        IGrowfiCampaignFull(payable(campaign)).buy(address(usdc), 50 * ONE_USDC);
    }

    // ============================================================
    // 1. Auto-fire on direct buy when automation = ON
    // ============================================================

    function test_autoAlloc_firesOnDirectBuyWhenAutomationOn() public {
        // 4 tracked Active campaigns, all priced $0.10/token.
        address campA = _spawnCampaign(PRODUCER_A, "A", 1e17, 10_000e18);
        address campB = _spawnCampaign(PRODUCER_B, "B", 1e17, 10_000e18);
        address campC = _spawnCampaign(PRODUCER_C, "C", 1e17, 10_000e18);
        address campD = _spawnCampaign(PRODUCER_D, "D", 1e17, 10_000e18);

        vm.startPrank(OWNER);
        factory.addGrowfiTreasuryTrackedCampaign(campA);
        factory.addGrowfiTreasuryTrackedCampaign(campB);
        factory.addGrowfiTreasuryTrackedCampaign(campC);
        factory.addGrowfiTreasuryTrackedCampaign(campD);
        vm.stopPrank();

        IERC20 ctA = IERC20(IGrowfiCampaignFull(payable(campA)).campaignToken());
        IERC20 ctB = IERC20(IGrowfiCampaignFull(payable(campB)).campaignToken());
        IERC20 ctC = IERC20(IGrowfiCampaignFull(payable(campC)).campaignToken());
        IERC20 ctD = IERC20(IGrowfiCampaignFull(payable(campD)).campaignToken());

        uint256 balABefore = ctA.balanceOf(address(growTreasury));
        uint256 balBBefore = ctB.balanceOf(address(growTreasury));
        uint256 balCBefore = ctC.balanceOf(address(growTreasury));
        uint256 balDBefore = ctD.balanceOf(address(growTreasury));

        // Alice direct-buys $200 USDC. perCampaign = $50 each.
        vm.prank(ALICE);
        growToken.buy(address(usdc), 200 * ONE_USDC, type(uint256).max);

        uint256 deltaA = ctA.balanceOf(address(growTreasury)) - balABefore;
        uint256 deltaB = ctB.balanceOf(address(growTreasury)) - balBBefore;
        uint256 deltaC = ctC.balanceOf(address(growTreasury)) - balCBefore;
        uint256 deltaD = ctD.balanceOf(address(growTreasury)) - balDBefore;

        // perCampaign = $200 / 4 = $50 each. tokensOut is computed on the GROSS payment
        // (Campaign.buy v2 design — fee is skimmed downstream, mint is on full $50).
        // $50 / $0.10 = 500 tokens each.
        assertEq(deltaA, deltaB, "A==B");
        assertEq(deltaB, deltaC, "B==C");
        assertEq(deltaC, deltaD, "C==D");
        assertEq(deltaA, 500e18, "$50 / $0.10 = 500 OLIVE per campaign");
    }

    // ============================================================
    // 2. Silent skip when automation = OFF
    // ============================================================

    function test_autoAlloc_silentSkipWhenAutomationOff() public {
        address campA = _spawnCampaign(PRODUCER_A, "A", 1e17, 10_000e18);
        vm.prank(OWNER);
        factory.addGrowfiTreasuryTrackedCampaign(campA);

        // Flip automation off. The direct buy must still succeed; just no spread.
        vm.prank(OWNER);
        factory.setGrowfiTreasuryAutomationEnabled(false);

        IERC20 ctA = IERC20(IGrowfiCampaignFull(payable(campA)).campaignToken());
        uint256 balBefore = ctA.balanceOf(address(growTreasury));
        uint256 usdcBefore = usdc.balanceOf(address(growTreasury));

        vm.prank(ALICE);
        growToken.buy(address(usdc), 100 * ONE_USDC, type(uint256).max);

        // CT delta = 0, treasury USDC went up by the full $100.
        assertEq(ctA.balanceOf(address(growTreasury)), balBefore, "no auto-spread");
        assertEq(usdc.balanceOf(address(growTreasury)), usdcBefore + 100 * ONE_USDC, "usdc kept");
    }

    // ============================================================
    // 3. Silent skip when no Active tracked campaigns exist
    // ============================================================

    function test_autoAlloc_silentSkipWhenNoTrackedCampaigns() public {
        // Automation ON but nothing tracked.
        uint256 usdcBefore = usdc.balanceOf(address(growTreasury));
        vm.prank(ALICE);
        growToken.buy(address(usdc), 100 * ONE_USDC, type(uint256).max);
        assertEq(usdc.balanceOf(address(growTreasury)), usdcBefore + 100 * ONE_USDC, "usdc kept (no spread targets)");
    }

    // ============================================================
    // 4. Capping at remaining mintable room
    // ============================================================

    function test_autoAlloc_capsAtRemainingRoom() public {
        // Two campaigns: A has tiny room (room = 10 tokens), B has lots (10k tokens).
        address campA = _spawnCampaign(PRODUCER_A, "TightA", 1e17, 510e18); // already ~500 sold
        address campB = _spawnCampaign(PRODUCER_B, "RoomB", 1e17, 10_000e18);

        vm.startPrank(OWNER);
        factory.addGrowfiTreasuryTrackedCampaign(campA);
        factory.addGrowfiTreasuryTrackedCampaign(campB);
        vm.stopPrank();

        IERC20 ctA = IERC20(IGrowfiCampaignFull(payable(campA)).campaignToken());
        IERC20 ctB = IERC20(IGrowfiCampaignFull(payable(campB)).campaignToken());

        // Direct buy $200 -> perCampaign = $100 each.
        // A has only ~10 tokens room ≈ $1 worth (minus fee), so it caps very low.
        // B accepts the full $100 worth.
        vm.prank(ALICE);
        growToken.buy(address(usdc), 200 * ONE_USDC, type(uint256).max);

        // A capped (≤ remaining room = ~10e18 minus fee).
        // B got the full ~$100 worth of CT (~970e18).
        assertLt(ctA.balanceOf(address(growTreasury)), 11e18, "A capped at room");
        assertGt(ctB.balanceOf(address(growTreasury)), 950e18, "B took full share");
    }

    // ============================================================
    // 5. Funding-state campaign not eligible (not Active yet)
    // ============================================================

    function test_autoAlloc_fundingCampaignSkipped() public {
        // Spawn A but DON'T push past softcap.
        GrowfiCampaignFactory.CreateCampaignParams memory p = GrowfiCampaignFactory.CreateCampaignParams({
                producer: PRODUCER_A,
                campaignTokenName: "Funding A",
                campaignTokenSymbol: "TKN",
                yieldTokenName: "Y",
                yieldTokenSymbol: "y",
                minProductClaim: 1e18,
                sale: SaleClassicModule.InitParams({
                    pricePerToken: 1e17,
                    minCap: 100e18,
                    maxCap: 10_000e18,
                    fundingDeadline: block.timestamp + 30 days,
                    seasonDuration: 1 hours,
                    fundingFeeBps: 0,
                    sequencerUptimeFeed: address(0),
                    growMinter: address(0)
                }),
                collateral: CollateralModule.InitParams({
                    expectedAnnualHarvestUsd: 1000e18,
                    expectedAnnualHarvest: 100e18,
                    firstHarvestYear: 2027,
                    coverageHarvests: 0
                })
            });
        vm.prank(PRODUCER_A);
        address campA = factory.createCampaign(p);
        vm.prank(OWNER);
        factory.addGrowfiTreasuryTrackedCampaign(campA);

        IERC20 ctA = IERC20(IGrowfiCampaignFull(payable(campA)).campaignToken());
        uint256 usdcBefore = usdc.balanceOf(address(growTreasury));

        // No Active tracked campaign => Treasury allocator reverts NoActiveTrackedCampaigns
        // => Token's try/catch swallows it. Buy succeeds, USDC stays.
        vm.prank(ALICE);
        growToken.buy(address(usdc), 100 * ONE_USDC, type(uint256).max);

        assertEq(ctA.balanceOf(address(growTreasury)), 0, "Funding campaign skipped");
        assertEq(usdc.balanceOf(address(growTreasury)), usdcBefore + 100 * ONE_USDC, "usdc kept");
    }

    // ============================================================
    // 6. Manual factory-triggered allocateAcrossTracked still works
    // ============================================================

    function test_autoAlloc_manualFactoryTriggerStillWorks() public {
        address campA = _spawnCampaign(PRODUCER_A, "A", 1e17, 10_000e18);
        address campB = _spawnCampaign(PRODUCER_B, "B", 1e17, 10_000e18);

        vm.startPrank(OWNER);
        factory.addGrowfiTreasuryTrackedCampaign(campA);
        factory.addGrowfiTreasuryTrackedCampaign(campB);
        vm.stopPrank();

        // Seed Treasury directly (no Token.buy involved).
        usdc.mint(address(growTreasury), 100 * ONE_USDC);

        IERC20 ctA = IERC20(IGrowfiCampaignFull(payable(campA)).campaignToken());
        IERC20 ctB = IERC20(IGrowfiCampaignFull(payable(campB)).campaignToken());
        uint256 balA = ctA.balanceOf(address(growTreasury));
        uint256 balB = ctB.balanceOf(address(growTreasury));

        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 100 * ONE_USDC);

        assertGt(ctA.balanceOf(address(growTreasury)), balA, "A got tokens (manual path)");
        assertGt(ctB.balanceOf(address(growTreasury)), balB, "B got tokens (manual path)");
    }

    // ============================================================
    // 7. Mixed price points: equal $$ split, different token quantities
    // ============================================================

    /// @dev 4 campaigns with prices $0.05, $0.10, $0.20, $0.50. Direct buy of $200.
    ///      perCampaign = $50 each. Tokens received = $50 / price → 1000, 500, 250, 100.
    function test_autoAlloc_mixedPrices_proportionalTokenQty() public {
        address campA = _spawnCampaign(PRODUCER_A, "Cheap", 5e16, 100_000e18); // $0.05
        address campB = _spawnCampaign(PRODUCER_B, "Mid", 1e17, 100_000e18); // $0.10
        address campC = _spawnCampaign(PRODUCER_C, "Premium", 2e17, 100_000e18); // $0.20
        address campD = _spawnCampaign(PRODUCER_D, "Lux", 5e17, 100_000e18); // $0.50

        vm.startPrank(OWNER);
        factory.addGrowfiTreasuryTrackedCampaign(campA);
        factory.addGrowfiTreasuryTrackedCampaign(campB);
        factory.addGrowfiTreasuryTrackedCampaign(campC);
        factory.addGrowfiTreasuryTrackedCampaign(campD);
        vm.stopPrank();

        IERC20 ctA = IERC20(IGrowfiCampaignFull(payable(campA)).campaignToken());
        IERC20 ctB = IERC20(IGrowfiCampaignFull(payable(campB)).campaignToken());
        IERC20 ctC = IERC20(IGrowfiCampaignFull(payable(campC)).campaignToken());
        IERC20 ctD = IERC20(IGrowfiCampaignFull(payable(campD)).campaignToken());

        uint256 a0 = ctA.balanceOf(address(growTreasury));
        uint256 b0 = ctB.balanceOf(address(growTreasury));
        uint256 c0 = ctC.balanceOf(address(growTreasury));
        uint256 d0 = ctD.balanceOf(address(growTreasury));

        vm.prank(ALICE);
        growToken.buy(address(usdc), 200 * ONE_USDC, type(uint256).max);

        // tokensOut = $50 / pricePerToken (mint is on gross, fee already routed away)
        assertEq(ctA.balanceOf(address(growTreasury)) - a0, 1000e18, "Cheap   1000 tokens");
        assertEq(ctB.balanceOf(address(growTreasury)) - b0, 500e18, "Mid      500 tokens");
        assertEq(ctC.balanceOf(address(growTreasury)) - c0, 250e18, "Premium  250 tokens");
        assertEq(ctD.balanceOf(address(growTreasury)) - d0, 100e18, "Lux      100 tokens");

        // Sanity: $$ value into each campaign is identical (= $50). Multiply each
        // CT delta by its pricePerToken and confirm.
        uint256 valA = ((ctA.balanceOf(address(growTreasury)) - a0) * 5e16) / 1e18;
        uint256 valB = ((ctB.balanceOf(address(growTreasury)) - b0) * 1e17) / 1e18;
        uint256 valC = ((ctC.balanceOf(address(growTreasury)) - c0) * 2e17) / 1e18;
        uint256 valD = ((ctD.balanceOf(address(growTreasury)) - d0) * 5e17) / 1e18;
        assertEq(valA, valB, "$$ A==B");
        assertEq(valB, valC, "$$ B==C");
        assertEq(valC, valD, "$$ C==D");
        assertEq(valA, 50e18, "each = $50");
    }

    // ============================================================
    // 8. Random caller can NOT call allocateAcrossTracked
    // ============================================================

    function test_autoAlloc_randomCallerForbidden() public {
        address campA = _spawnCampaign(PRODUCER_A, "A", 1e17, 10_000e18);
        vm.prank(OWNER);
        factory.addGrowfiTreasuryTrackedCampaign(campA);

        usdc.mint(address(growTreasury), 100 * ONE_USDC);

        vm.expectRevert(GrowfiTreasury.NotFactory.selector);
        vm.prank(address(0xBAD));
        growTreasury.allocateAcrossTracked(address(usdc), 100 * ONE_USDC);
    }
}
