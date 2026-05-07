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

/// @dev Mock campaign for the Treasury tests. `buy()` pulls payment, mints CampaignToken at price.
contract MockGrowfiCampaign {
    address public campaignToken;
    uint256 public pricePerToken;
    /// @dev 0 = Funding, 1 = Active, 2 = Buyback, 3 = Ended. Defaults to Active so the
    ///      floor calc counts Treasury holdings of this campaign's token by default.
    uint8 public state = 1;

    constructor(address campaignToken_, uint256 pricePerToken_) {
        campaignToken = campaignToken_;
        pricePerToken = pricePerToken_;
    }

    function setState(uint8 newState) external {
        state = newState;
    }

    /// @dev Accepts any ERC20. Computes USD value at price assuming the payer feeds something
    ///      with `decimals()` properly scaled by the caller — for these tests we just use
    ///      6-dec USDC-style payments and scale up by 1e12 to USD-18-dec internally.
    function buy(address paymentToken, uint256 paymentAmount) external {
        IERC20(paymentToken).transferFrom(msg.sender, address(this), paymentAmount);
        uint256 tokensOut = (paymentAmount * 1e30) / pricePerToken;
        MockERC20(campaignToken).mint(msg.sender, tokensOut);
    }
}

contract GrowfiTreasuryTest is Test {
    GrowfiToken token;
    GrowfiTreasury treasury;
    MockERC20 usdc;
    MockERC20 usdt;
    MockERC20 dai;
    MockERC20 campaignTokenA;
    MockERC20 campaignTokenB;
    MockGrowfiCampaign campaignA;
    MockGrowfiCampaign campaignB;
    MockOracle usdFeed; // single $1 feed shared across mock stablecoins

    address constant FACTORY = address(0xF000);
    address constant DEPLOYER = address(0xD000);
    address constant ALICE = address(0xA1);
    address constant BOB = address(0xB0B);
    address constant ATTACKER = address(0xBAD);

    uint256 constant GENESIS_AMOUNT = 1_000_000e18;
    uint256 constant ONE_USDC = 1e6;
    uint256 constant ONE_DAI = 1e18;
    uint256 constant PRICE_A = 144e15; // $0.144
    uint256 constant PRICE_B = 250e15; // $0.250

    uint256 constant SCALE_6DEC = 1e12; // 6-dec → 18-dec
    uint256 constant SCALE_18DEC = 1; // 18-dec native

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);
        dai = new MockERC20("Dai", "DAI", 18);
        campaignTokenA = new MockERC20("Olive A", "OLA", 18);
        campaignTokenB = new MockERC20("Olive B", "OLB", 18);

        // Token (no usdc param anymore)
        GrowfiToken tImpl = new GrowfiToken();
        bytes memory tInit = abi.encodeCall(
            GrowfiToken.initialize, ("GrowFi", "GROW", FACTORY, DEPLOYER, GENESIS_AMOUNT, 1_000, 1e17)
        );
        token = GrowfiToken(address(new TransparentUpgradeableProxy(address(tImpl), FACTORY, tInit)));

        // Treasury (no usdc param anymore)
        GrowfiTreasury trImpl = new GrowfiTreasury();
        bytes memory trInit = abi.encodeCall(GrowfiTreasury.initialize, (FACTORY, address(token)));
        treasury = GrowfiTreasury(address(new TransparentUpgradeableProxy(address(trImpl), FACTORY, trInit)));

        // Wire & seed
        vm.prank(FACTORY);
        token.setTreasury(address(treasury));

        usdFeed = new MockOracle(int256(1e8), 8); // $1.00, 8-dec like Chainlink

        vm.prank(FACTORY);
        treasury.addAcceptedStablecoin(address(usdc), SCALE_6DEC, address(usdFeed), 24 hours, 9_500, 10_500);
        vm.prank(FACTORY);
        treasury.addAcceptedStablecoin(address(usdt), SCALE_6DEC, address(usdFeed), 24 hours, 9_500, 10_500);
        vm.prank(FACTORY);
        treasury.addAcceptedStablecoin(address(dai), SCALE_18DEC, address(usdFeed), 24 hours, 9_500, 10_500);

        campaignA = new MockGrowfiCampaign(address(campaignTokenA), PRICE_A);
        campaignB = new MockGrowfiCampaign(address(campaignTokenB), PRICE_B);
    }

    // ---------- initialize ----------

    function test_initialize_setsState() public view {
        assertEq(treasury.factory(), FACTORY);
        assertEq(address(treasury.growToken()), address(token));
        assertEq(treasury.acceptedStablecoinsLength(), 3);
        assertTrue(treasury.isAcceptedStablecoin(address(usdc)));
        assertTrue(treasury.isAcceptedStablecoin(address(usdt)));
        assertTrue(treasury.isAcceptedStablecoin(address(dai)));
        assertEq(treasury.stablecoinScale(address(usdc)), SCALE_6DEC);
        assertEq(treasury.stablecoinScale(address(dai)), SCALE_18DEC);
    }

    function test_initialize_revertsOnZeroFactory() public {
        GrowfiTreasury impl = new GrowfiTreasury();
        bytes memory data = abi.encodeCall(GrowfiTreasury.initialize, (address(0), address(token)));
        vm.expectRevert(GrowfiTreasury.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(impl), FACTORY, data);
    }

    function test_initialize_cannotBeCalledTwice() public {
        vm.expectRevert();
        treasury.initialize(FACTORY, address(token));
    }

    // ---------- accepted stablecoins ----------

    function test_addAcceptedStablecoin_revertsOnDuplicate() public {
        vm.expectRevert(GrowfiTreasury.AlreadyAccepted.selector);
        vm.prank(FACTORY);
        treasury.addAcceptedStablecoin(address(usdc), SCALE_6DEC, address(usdFeed), 24 hours, 9_500, 10_500);
    }

    function test_addAcceptedStablecoin_revertsOnZeroScale() public {
        MockERC20 newStable = new MockERC20("New", "NEW", 6);
        vm.expectRevert(GrowfiTreasury.InvalidScale.selector);
        vm.prank(FACTORY);
        treasury.addAcceptedStablecoin(address(newStable), 0, address(usdFeed), 24 hours, 9_500, 10_500);
    }

    function test_addAcceptedStablecoin_revertsForNonFactory() public {
        MockERC20 newStable = new MockERC20("New", "NEW", 6);
        vm.expectRevert(GrowfiTreasury.NotFactory.selector);
        vm.prank(ATTACKER);
        treasury.addAcceptedStablecoin(address(newStable), 1e12, address(usdFeed), 24 hours, 9_500, 10_500);
    }

    function test_removeAcceptedStablecoin_succeeds() public {
        vm.prank(FACTORY);
        treasury.removeAcceptedStablecoin(address(usdt));
        assertFalse(treasury.isAcceptedStablecoin(address(usdt)));
        assertEq(treasury.stablecoinScale(address(usdt)), 0);
    }

    function test_removeAcceptedStablecoin_revertsIfNotAccepted() public {
        MockERC20 random = new MockERC20("Random", "RND", 18);
        vm.expectRevert(GrowfiTreasury.NotAccepted.selector);
        vm.prank(FACTORY);
        treasury.removeAcceptedStablecoin(address(random));
    }

    // ---------- tracked campaigns ----------

    function test_addTrackedCampaign_byFactory() public {
        vm.prank(FACTORY);
        treasury.addTrackedCampaign(address(campaignA));
        assertTrue(treasury.isTrackedCampaign(address(campaignA)));
    }

    function test_addTrackedCampaign_revertsOnDuplicate() public {
        vm.prank(FACTORY);
        treasury.addTrackedCampaign(address(campaignA));
        vm.expectRevert(GrowfiTreasury.AlreadyTracked.selector);
        vm.prank(FACTORY);
        treasury.addTrackedCampaign(address(campaignA));
    }

    // ---------- intrinsicFloorPrice ----------

    function test_floor_zeroWhenEmpty() public view {
        assertEq(treasury.intrinsicFloorPrice(), 0);
    }

    function test_floor_withSingleStablecoin() public {
        usdc.mint(address(treasury), 100 * ONE_USDC);
        // Treasury value = 100 * 1e12 = 1e14 USD-18-dec ($100)
        // Floor = 1e20 / 1_000_000e18 = 1e20 / 1e24 = 1e-4 (= 1e14)
        uint256 expected = (100e18 * 1e18) / GENESIS_AMOUNT;
        assertEq(treasury.intrinsicFloorPrice(), expected);
    }

    function test_floor_sumsMultipleStablecoins() public {
        usdc.mint(address(treasury), 50 * ONE_USDC); // $50
        usdt.mint(address(treasury), 30 * ONE_USDC); // $30
        dai.mint(address(treasury), 20 * ONE_DAI); // $20

        // Total = $100 = 100e18 USD-18-dec
        uint256 expected = (100e18 * 1e18) / GENESIS_AMOUNT;
        assertEq(treasury.intrinsicFloorPrice(), expected);
    }

    function test_floor_withCampaignTokenAndStablecoins() public {
        vm.prank(FACTORY);
        treasury.addTrackedCampaign(address(campaignA));

        usdc.mint(address(treasury), 50 * ONE_USDC); // $50
        dai.mint(address(treasury), 50 * ONE_DAI); // $50
        campaignTokenA.mint(address(treasury), 1000e18); // $144 at PRICE_A

        // Total = $50 + $50 + $144 = $244
        uint256 expected = ((50e18 + 50e18 + 144e18) * 1e18) / GENESIS_AMOUNT;
        assertEq(treasury.intrinsicFloorPrice(), expected);
    }

    function test_floor_excludesTreasuryHeldGrow() public {
        vm.prank(DEPLOYER);
        token.transfer(address(treasury), 200_000e18);

        usdc.mint(address(treasury), 100 * ONE_USDC);

        uint256 expected = (100e18 * 1e18) / 800_000e18;
        assertEq(treasury.intrinsicFloorPrice(), expected);
    }

    function test_floor_zeroWhenAllSupplyHeldByTreasury() public {
        vm.prank(DEPLOYER);
        token.transfer(address(treasury), GENESIS_AMOUNT);
        usdc.mint(address(treasury), 100 * ONE_USDC);

        assertEq(treasury.intrinsicFloorPrice(), 0);
    }

    function test_floor_revokedStablecoinNoLongerCounted() public {
        usdc.mint(address(treasury), 100 * ONE_USDC); // $100
        uint256 floorWithUsdc = treasury.intrinsicFloorPrice();
        assertGt(floorWithUsdc, 0);

        vm.prank(FACTORY);
        treasury.removeAcceptedStablecoin(address(usdc));

        // USDC still in balance but no longer counted
        assertEq(treasury.intrinsicFloorPrice(), 0);
    }

    // ---------- allocateToCampaign ----------

    function test_allocate_buysCampaignTokensWithUsdc() public {
        vm.prank(FACTORY);
        treasury.addTrackedCampaign(address(campaignA));
        usdc.mint(address(treasury), 1000 * ONE_USDC);

        vm.prank(FACTORY);
        treasury.allocateToCampaign(address(campaignA), address(usdc), 100 * ONE_USDC);

        uint256 expectedTokens = (100 * ONE_USDC * 1e30) / PRICE_A;
        assertEq(campaignTokenA.balanceOf(address(treasury)), expectedTokens);
        assertEq(usdc.balanceOf(address(treasury)), 900 * ONE_USDC);
    }

    function test_allocate_revertsIfPaymentTokenNotAccepted() public {
        vm.prank(FACTORY);
        treasury.addTrackedCampaign(address(campaignA));

        MockERC20 random = new MockERC20("R", "R", 6);
        random.mint(address(treasury), 1000e6);

        vm.expectRevert(GrowfiTreasury.NotAccepted.selector);
        vm.prank(FACTORY);
        treasury.allocateToCampaign(address(campaignA), address(random), 100e6);
    }

    function test_allocate_revertsIfNotTracked() public {
        usdc.mint(address(treasury), 1000 * ONE_USDC);

        vm.expectRevert(GrowfiTreasury.NotTracked.selector);
        vm.prank(FACTORY);
        treasury.allocateToCampaign(address(campaignA), address(usdc), 100 * ONE_USDC);
    }

    function test_allocate_revertsForNonFactory() public {
        vm.prank(FACTORY);
        treasury.addTrackedCampaign(address(campaignA));
        usdc.mint(address(treasury), 1000 * ONE_USDC);

        vm.expectRevert(GrowfiTreasury.NotFactory.selector);
        vm.prank(ATTACKER);
        treasury.allocateToCampaign(address(campaignA), address(usdc), 100 * ONE_USDC);
    }

    function test_allocate_revertsOnInsufficientBalance() public {
        vm.prank(FACTORY);
        treasury.addTrackedCampaign(address(campaignA));
        usdc.mint(address(treasury), 50 * ONE_USDC);

        vm.expectRevert(GrowfiTreasury.InsufficientBalance.selector);
        vm.prank(FACTORY);
        treasury.allocateToCampaign(address(campaignA), address(usdc), 100 * ONE_USDC);
    }

    // ---------- redeem ----------

    function test_redeem_proRataSingleStablecoin() public {
        usdc.mint(address(treasury), 1000 * ONE_USDC);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 100_000e18); // 10% of supply

        vm.prank(ALICE);
        token.approve(address(treasury), 100_000e18);
        vm.prank(ALICE);
        treasury.redeem(100_000e18);

        // 10% of 1000 USDC = 100 USDC
        assertEq(usdc.balanceOf(ALICE), 100 * ONE_USDC);
        assertEq(token.totalSupply(), GENESIS_AMOUNT - 100_000e18);
    }

    function test_redeem_proRataMultipleStablecoinsAndCampaigns() public {
        vm.prank(FACTORY);
        treasury.addTrackedCampaign(address(campaignA));
        vm.prank(FACTORY);
        treasury.addTrackedCampaign(address(campaignB));

        usdc.mint(address(treasury), 1000 * ONE_USDC);
        usdt.mint(address(treasury), 500 * ONE_USDC);
        dai.mint(address(treasury), 200 * ONE_DAI);
        campaignTokenA.mint(address(treasury), 1000e18);
        campaignTokenB.mint(address(treasury), 500e18);

        // Alice has 1% of supply
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 10_000e18);
        vm.prank(ALICE);
        token.approve(address(treasury), 10_000e18);
        vm.prank(ALICE);
        treasury.redeem(10_000e18);

        // 1% of each
        assertEq(usdc.balanceOf(ALICE), 10 * ONE_USDC);
        assertEq(usdt.balanceOf(ALICE), 5 * ONE_USDC);
        assertEq(dai.balanceOf(ALICE), 2 * ONE_DAI);
        assertEq(campaignTokenA.balanceOf(ALICE), 10e18);
        assertEq(campaignTokenB.balanceOf(ALICE), 5e18);
    }

    function test_redeem_burnsGrow() public {
        usdc.mint(address(treasury), 1000 * ONE_USDC);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 50_000e18);

        uint256 supplyBefore = token.totalSupply();

        vm.prank(ALICE);
        token.approve(address(treasury), 50_000e18);
        vm.prank(ALICE);
        treasury.redeem(50_000e18);

        assertEq(token.totalSupply(), supplyBefore - 50_000e18);
        assertEq(token.balanceOf(address(treasury)), 0);
    }

    function test_redeem_revertsOnZeroAmount() public {
        vm.expectRevert(GrowfiTreasury.ZeroAmount.selector);
        vm.prank(ALICE);
        treasury.redeem(0);
    }

    function test_redeem_revertsWithoutApproval() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 1000e18);

        vm.expectRevert();
        vm.prank(ALICE);
        treasury.redeem(1000e18);
    }

    function test_redeem_revertsWhenAllSupplyInTreasury() public {
        vm.prank(DEPLOYER);
        token.transfer(address(treasury), GENESIS_AMOUNT);

        vm.expectRevert(GrowfiTreasury.NoCirculatingSupply.selector);
        vm.prank(ATTACKER);
        treasury.redeem(1);
    }

    // ---------- rescue ----------

    function test_rescue_randomToken() public {
        MockERC20 randomToken = new MockERC20("Random", "RND", 18);
        randomToken.mint(address(treasury), 500e18);

        vm.prank(FACTORY);
        treasury.rescueToken(IERC20(address(randomToken)), BOB, 500e18);

        assertEq(randomToken.balanceOf(BOB), 500e18);
    }

    function test_rescue_revertsForAcceptedStablecoin() public {
        usdc.mint(address(treasury), 100 * ONE_USDC);

        vm.expectRevert(GrowfiTreasury.CannotRescueAcceptedStablecoin.selector);
        vm.prank(FACTORY);
        treasury.rescueToken(IERC20(address(usdc)), BOB, 100 * ONE_USDC);
    }

    function test_rescue_revertsForGrow() public {
        vm.prank(DEPLOYER);
        token.transfer(address(treasury), 100e18);

        vm.expectRevert(GrowfiTreasury.CannotRescueGrow.selector);
        vm.prank(FACTORY);
        treasury.rescueToken(IERC20(address(token)), BOB, 100e18);
    }

    function test_rescue_revertsForTrackedCampaignToken() public {
        vm.prank(FACTORY);
        treasury.addTrackedCampaign(address(campaignA));
        campaignTokenA.mint(address(treasury), 100e18);

        vm.expectRevert(GrowfiTreasury.CannotRescueCampaignToken.selector);
        vm.prank(FACTORY);
        treasury.rescueToken(IERC20(address(campaignTokenA)), BOB, 100e18);
    }

    function test_rescue_succeedsAfterStablecoinRevoked() public {
        usdc.mint(address(treasury), 100 * ONE_USDC);
        vm.prank(FACTORY);
        treasury.removeAcceptedStablecoin(address(usdc));

        vm.prank(FACTORY);
        treasury.rescueToken(IERC20(address(usdc)), BOB, 100 * ONE_USDC);
        assertEq(usdc.balanceOf(BOB), 100 * ONE_USDC);
    }

    function test_rescue_revertsForNonFactory() public {
        MockERC20 randomToken = new MockERC20("Random", "RND", 18);
        randomToken.mint(address(treasury), 100e18);

        vm.expectRevert(GrowfiTreasury.NotFactory.selector);
        vm.prank(ATTACKER);
        treasury.rescueToken(IERC20(address(randomToken)), ATTACKER, 100e18);
    }

    // ---------- red team ----------

    function test_redteam_cannotInjectFakeStablecoin() public {
        MockERC20 fake = new MockERC20("Fake", "FK", 6);
        vm.expectRevert(GrowfiTreasury.NotFactory.selector);
        vm.prank(ATTACKER);
        treasury.addAcceptedStablecoin(address(fake), 1e12, address(usdFeed), 24 hours, 9_500, 10_500);
    }

    function test_redteam_redeemOnlyGivesProRata() public {
        usdc.mint(address(treasury), 1000 * ONE_USDC);

        vm.prank(DEPLOYER);
        token.transfer(ATTACKER, 1000e18); // 0.1%

        vm.prank(ATTACKER);
        token.approve(address(treasury), 1000e18);
        vm.prank(ATTACKER);
        treasury.redeem(1000e18);

        assertEq(usdc.balanceOf(ATTACKER), 1 * ONE_USDC);
    }

    function test_redteam_allocationGatedBeforeFundsMove() public {
        usdc.mint(address(treasury), 1000 * ONE_USDC);

        vm.expectRevert(GrowfiTreasury.NotTracked.selector);
        vm.prank(FACTORY);
        treasury.allocateToCampaign(address(campaignA), address(usdc), 100 * ONE_USDC);

        assertEq(usdc.balanceOf(address(treasury)), 1000 * ONE_USDC);
    }

    /// @dev Multisig depeg circuit-breaker: removes a destabilized stablecoin from the
    ///      allowlist. From that moment on, the floor calc ignores it (treats as worth $0
    ///      until rescued or rebought when peg restored).
    function test_redteam_depegCircuitBreaker() public {
        usdc.mint(address(treasury), 100 * ONE_USDC);
        usdt.mint(address(treasury), 100 * ONE_USDC);
        // Initially: floor counts both → $200 backing
        uint256 floorWithBoth = treasury.intrinsicFloorPrice();
        assertGt(floorWithBoth, 0);

        // USDT depegs → multisig revokes
        vm.prank(FACTORY);
        treasury.removeAcceptedStablecoin(address(usdt));

        // Floor now reflects only USDC ($100)
        uint256 floorAfterRevoke = treasury.intrinsicFloorPrice();
        assertEq(floorAfterRevoke, floorWithBoth / 2); // halved
    }
}
