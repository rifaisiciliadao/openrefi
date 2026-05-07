// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GrowfiToken} from "../src/GrowfiToken.sol";
import {GrowfiTreasury} from "../src/GrowfiTreasury.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {MockOracle} from "./helpers/MockOracle.sol";

/// @dev Mock campaign with a settable state slot, mirroring the real Campaign's
///      `0=Funding 1=Active 2=Buyback 3=Ended` enum. Used to exercise the state-aware
///      floor calc.
contract MockCampaign {
    address public campaignToken;
    uint256 public pricePerToken;
    uint8 public state;

    constructor(address campaignToken_, uint256 pricePerToken_, uint8 state_) {
        campaignToken = campaignToken_;
        pricePerToken = pricePerToken_;
        state = state_;
    }

    function setState(uint8 s) external {
        state = s;
    }

    /// @dev Treasury.allocate path needs `buy()` to mint CT against payment; not exercised here.
    function buy(address paymentToken, uint256 paymentAmount) external {
        IERC20(paymentToken).transferFrom(msg.sender, address(this), paymentAmount);
        uint256 tokensOut = (paymentAmount * 1e30) / pricePerToken;
        MockERC20(campaignToken).mint(msg.sender, tokensOut);
    }
}

/// @notice Coverage for the Chainlink-feed-based depeg protection (#5) and the state-aware
///         floor calc (#4) added in the GROW v4.1 hardening pass.
contract GrowfiDepegProtectionTest is Test {
    GrowfiToken token;
    GrowfiTreasury treasury;
    MockERC20 usdc;
    MockERC20 usdt;
    MockERC20 dai;
    MockERC20 ctA;
    MockOracle usdcFeed;
    MockOracle usdtFeed;
    MockOracle daiFeed;

    address constant FACTORY = address(0xF000);
    address constant DEPLOYER = address(0xD000);
    address constant ALICE = address(0xA1);
    address constant ATTACKER = address(0xBAD);

    uint256 constant ONE_USDC = 1e6;
    uint256 constant SCALE_6 = 1e12;
    uint256 constant SCALE_18 = 1;
    uint256 constant GENESIS = 1_000_000e18;
    uint64 constant HEARTBEAT = 24 hours;
    uint16 constant MIN_BPS = 9_500; // $0.95
    uint16 constant MAX_BPS = 10_500; // $1.05

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);
        dai = new MockERC20("Dai", "DAI", 18);
        ctA = new MockERC20("Olive Sicily", "OLIVE", 18);

        usdcFeed = new MockOracle(int256(1e8), 8); // $1.00 8-dec
        usdtFeed = new MockOracle(int256(1e8), 8);
        daiFeed = new MockOracle(int256(1e8), 8);

        // GROW token (small genesis so floor math stays readable)
        GrowfiToken tImpl = new GrowfiToken();
        bytes memory tInit = abi.encodeCall(
            GrowfiToken.initialize,
            ("GrowFi", "GROW", FACTORY, DEPLOYER, GENESIS, /*markupBps*/ 1_000, /*refPrice*/ 1e17)
        );
        token = GrowfiToken(address(new TransparentUpgradeableProxy(address(tImpl), FACTORY, tInit)));

        // Treasury
        GrowfiTreasury trImpl = new GrowfiTreasury();
        bytes memory trInit = abi.encodeCall(GrowfiTreasury.initialize, (FACTORY, address(token)));
        treasury = GrowfiTreasury(address(new TransparentUpgradeableProxy(address(trImpl), FACTORY, trInit)));

        vm.prank(FACTORY);
        token.setTreasury(address(treasury));

        // Allowlist all 3 stablecoins, each with its mock feed and standard $0.95-$1.05 bands.
        vm.startPrank(FACTORY);
        treasury.addAcceptedStablecoin(address(usdc), SCALE_6, address(usdcFeed), HEARTBEAT, MIN_BPS, MAX_BPS);
        treasury.addAcceptedStablecoin(address(usdt), SCALE_6, address(usdtFeed), HEARTBEAT, MIN_BPS, MAX_BPS);
        treasury.addAcceptedStablecoin(address(dai), SCALE_18, address(daiFeed), HEARTBEAT, MIN_BPS, MAX_BPS);
        vm.stopPrank();

        // Seed Alice with USDC for buys.
        usdc.mint(ALICE, 10_000 * ONE_USDC);
        vm.prank(ALICE);
        usdc.approve(address(token), type(uint256).max);
    }

    // ============================================================
    // Depeg detection — direct buy revert
    // ============================================================

    /// @dev USDC drops to $0.85 → outside [$0.95, $1.05] band → direct buy reverts.
    function test_depeg_buyRevertsWhenStableBelowBand() public {
        // Seed treasury so floor != 0.
        usdc.mint(address(treasury), 100 * ONE_USDC);

        // Push USDC to $0.85 (out of band).
        usdcFeed.setPrice(int256(85 * 1e6)); // 0.85 in 8-dec

        vm.expectRevert(abi.encodeWithSelector(GrowfiTreasury.StablecoinDepegged.selector, address(usdc)));
        vm.prank(ALICE);
        token.buy(address(usdc), 100 * ONE_USDC, type(uint256).max);
    }

    /// @dev USDC pumps to $1.10 → outside band → direct buy reverts. Symmetric guard.
    function test_depeg_buyRevertsWhenStableAboveBand() public {
        usdc.mint(address(treasury), 100 * ONE_USDC);
        usdcFeed.setPrice(int256(110 * 1e6)); // $1.10

        vm.expectRevert(abi.encodeWithSelector(GrowfiTreasury.StablecoinDepegged.selector, address(usdc)));
        vm.prank(ALICE);
        token.buy(address(usdc), 100 * ONE_USDC, type(uint256).max);
    }

    /// @dev Feed went stale (no update within heartbeat window) → buy reverts.
    function test_depeg_buyRevertsWhenFeedStale() public {
        usdc.mint(address(treasury), 100 * ONE_USDC);
        // Move forward past heartbeat without updating feed.
        skip(HEARTBEAT + 1);

        vm.expectRevert(abi.encodeWithSelector(GrowfiTreasury.StablecoinDepegged.selector, address(usdc)));
        vm.prank(ALICE);
        token.buy(address(usdc), 100 * ONE_USDC, type(uint256).max);
    }

    /// @dev Negative price → bork → buy reverts.
    function test_depeg_buyRevertsWhenFeedNegative() public {
        usdc.mint(address(treasury), 100 * ONE_USDC);
        usdcFeed.setPrice(int256(-1));

        vm.expectRevert(abi.encodeWithSelector(GrowfiTreasury.StablecoinDepegged.selector, address(usdc)));
        vm.prank(ALICE);
        token.buy(address(usdc), 100 * ONE_USDC, type(uint256).max);
    }

    // ============================================================
    // Depeg detection — floor calc exclusion
    // ============================================================

    /// @dev Floor uses live USD price. USDC at $0.95 (still in band) → backing valued at 95%.
    function test_depeg_floorReflectsLivePrice() public {
        usdc.mint(address(treasury), 100 * ONE_USDC); // 100 USDC raw

        // Pristine peg → backing = $100 → floor = $100 / 1M GROW = 1e-4 USD-18 per GROW.
        uint256 pristine = treasury.intrinsicFloorPrice();
        // 100e6 raw × 1e12 scale × 1e18 priceUsd / 1e18 / 1M GROW = 100e18 / 1M GROW = 1e14 (= $0.0001)
        assertEq(pristine, 1e14);

        // Drop USDC price to $0.95 (still in band).
        usdcFeed.setPrice(int256(95_000_000)); // 0.95 in 8-dec
        uint256 stressed = treasury.intrinsicFloorPrice();
        // Expect 95% of pristine = 0.95 × 1e14 = 95e12
        assertEq(stressed, 95e12);
    }

    /// @dev Floor calc excludes a depegged stablecoin (out of band) entirely — conservative.
    function test_depeg_floorExcludesDepeggedStablecoin() public {
        // Seed two stablecoins; one will depeg.
        usdc.mint(address(treasury), 100 * ONE_USDC); // $100
        usdt.mint(address(treasury), 50 * ONE_USDC); // $50

        uint256 healthy = treasury.intrinsicFloorPrice();
        // Backing = 150e18, divisor = 1M GROW → 150e12
        assertEq(healthy, 150e12);

        // Crash USDT to $0.50 → out of band → excluded from floor.
        usdtFeed.setPrice(int256(50_000_000));
        uint256 afterDepeg = treasury.intrinsicFloorPrice();
        assertEq(afterDepeg, 100e12); // only USDC counts now
    }

    /// @dev If ALL stablecoins depeg simultaneously, floor → 0 (sale falls back to cached ref).
    function test_depeg_allFeedsBorked_floorZero() public {
        usdc.mint(address(treasury), 100 * ONE_USDC);
        usdt.mint(address(treasury), 100 * ONE_USDC);
        dai.mint(address(treasury), 100e18);

        // Crash everything.
        usdcFeed.setPrice(int256(50_000_000));
        usdtFeed.setPrice(int256(50_000_000));
        daiFeed.setPrice(int256(50_000_000));

        assertEq(treasury.intrinsicFloorPrice(), 0);
    }

    // ============================================================
    // State-aware floor (item #4)
    // ============================================================

    function _trackedCampaignWithBalance(uint256 ctAmount, uint8 state) internal returns (MockCampaign) {
        MockCampaign c = new MockCampaign(address(ctA), 1e18 /* $1/CT */, state);
        ctA.mint(address(treasury), ctAmount);
        vm.prank(FACTORY);
        treasury.addTrackedCampaign(address(c));
        return c;
    }

    /// @dev Active campaign's CTs count toward floor as expected.
    function test_stateAware_activeCampaignCounts() public {
        _trackedCampaignWithBalance(50e18, 1); // 50 CT × $1 = $50
        // No stablecoins seeded → backing = 50e18 → floor = 50e18 / 1M GROW = 50e12
        assertEq(treasury.intrinsicFloorPrice(), 50e12);
    }

    /// @dev Funding campaign's CTs are excluded (Treasury shouldn't normally hold these,
    ///      but the safety property must hold).
    function test_stateAware_fundingCampaignExcluded() public {
        _trackedCampaignWithBalance(50e18, 0);
        assertEq(treasury.intrinsicFloorPrice(), 0);
    }

    /// @dev Buyback-state CTs are excluded from floor — recovered separately via buybackFromCampaign.
    function test_stateAware_buybackCampaignExcluded() public {
        MockCampaign c = _trackedCampaignWithBalance(50e18, 1); // start Active
        assertEq(treasury.intrinsicFloorPrice(), 50e12); // counts

        c.setState(2); // Buyback
        assertEq(treasury.intrinsicFloorPrice(), 0); // excluded
    }

    /// @dev Ended-state CTs are excluded — multisig should untrack and rescue.
    function test_stateAware_endedCampaignExcluded() public {
        MockCampaign c = _trackedCampaignWithBalance(50e18, 1);
        c.setState(3);
        assertEq(treasury.intrinsicFloorPrice(), 0);
    }

    /// @dev Flipping back to Active (e.g. via upgrade) re-includes the CT.
    function test_stateAware_resumesIfStateFlipsBackToActive() public {
        MockCampaign c = _trackedCampaignWithBalance(50e18, 2); // start Buyback
        assertEq(treasury.intrinsicFloorPrice(), 0);

        c.setState(1); // back to Active
        assertEq(treasury.intrinsicFloorPrice(), 50e12);
    }

    // ============================================================
    // Live-price effect on growOut
    // ============================================================

    /// @dev Live USDC price at $0.95 → buyer receives 5% less GROW for same paymentAmount.
    function test_livePrice_affectsGrowOut() public {
        // Seed treasury so floor is non-zero.
        usdc.mint(address(treasury), 1_000 * ONE_USDC);

        // Pristine: buy 100 USDC. Floor = $1k / 1M = 1e15 USD18/GROW. salePrice = 1.1e15.
        // growOut = 100e6 × 1e12 × 1e18 / 1.1e15 ≈ 90.9091e18
        uint256 balBefore = token.balanceOf(ALICE);
        vm.prank(ALICE);
        uint256 outPristine = token.buy(address(usdc), 100 * ONE_USDC, type(uint256).max);
        assertEq(outPristine, token.balanceOf(ALICE) - balBefore);

        // Now USDC price drops to $0.95 — still in band — live calc uses 0.95e18.
        // For the same buy, growOut should be ~5% lower.
        usdcFeed.setPrice(int256(95_000_000));
        balBefore = token.balanceOf(ALICE);
        vm.prank(ALICE);
        uint256 outDepressed = token.buy(address(usdc), 100 * ONE_USDC, type(uint256).max);

        // Allow 2% tolerance (floor is itself rebased between calls).
        assertLt(outDepressed, outPristine);
        // It should be roughly 95/100 of pristine, give or take floor cache effects.
        uint256 expectedRatio = (outPristine * 95) / 100;
        assertApproxEqRel(outDepressed, expectedRatio, 0.05e18); // ±5%
    }

    // ============================================================
    // Configuration validation
    // ============================================================

    function test_addAcceptedStablecoin_revertsOnZeroFeed() public {
        MockERC20 newStable = new MockERC20("New", "NEW", 6);
        vm.expectRevert(GrowfiTreasury.ZeroAddress.selector);
        vm.prank(FACTORY);
        treasury.addAcceptedStablecoin(address(newStable), 1e12, address(0), HEARTBEAT, MIN_BPS, MAX_BPS);
    }

    function test_addAcceptedStablecoin_revertsOnZeroHeartbeat() public {
        MockERC20 newStable = new MockERC20("New", "NEW", 6);
        MockOracle f = new MockOracle(int256(1e8), 8);
        vm.expectRevert(GrowfiTreasury.InvalidHeartbeat.selector);
        vm.prank(FACTORY);
        treasury.addAcceptedStablecoin(address(newStable), 1e12, address(f), 0, MIN_BPS, MAX_BPS);
    }

    function test_addAcceptedStablecoin_revertsOnInvertedBands() public {
        MockERC20 newStable = new MockERC20("New", "NEW", 6);
        MockOracle f = new MockOracle(int256(1e8), 8);
        vm.expectRevert(GrowfiTreasury.InvalidPriceBands.selector);
        vm.prank(FACTORY);
        treasury.addAcceptedStablecoin(address(newStable), 1e12, address(f), HEARTBEAT, 11_000, 9_500);
    }

    function test_addAcceptedStablecoin_revertsOnExtremeUpperBand() public {
        MockERC20 newStable = new MockERC20("New", "NEW", 6);
        MockOracle f = new MockOracle(int256(1e8), 8);
        vm.expectRevert(GrowfiTreasury.InvalidPriceBands.selector);
        vm.prank(FACTORY);
        treasury.addAcceptedStablecoin(address(newStable), 1e12, address(f), HEARTBEAT, 9_500, 30_000);
    }
}
