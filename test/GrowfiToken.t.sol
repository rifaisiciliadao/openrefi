// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {GrowfiToken} from "../src/GrowfiToken.sol";
import {IGrowfiTreasury} from "../src/interfaces/IGrowfiTreasury.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

/// @dev Minimal Treasury stub: dial floor + manage stablecoin allowlist for tests.
contract MockGrowfiTreasury is IGrowfiTreasury {
    uint256 public floorPrice;
    mapping(address => bool) private _accepted;
    mapping(address => uint256) private _scale;
    mapping(address => uint256) private _priceUsd18;
    /// @notice If true, getStablecoinPriceUsd18 reverts to simulate a depegged feed.
    mapping(address => bool) private _depegged;

    error StablecoinDepegged(address token);

    function setFloorPrice(uint256 price) external {
        floorPrice = price;
    }

    function setAccepted(address token, uint256 scale) external {
        _accepted[token] = scale > 0;
        _scale[token] = scale;
        if (scale > 0 && _priceUsd18[token] == 0) {
            _priceUsd18[token] = 1e18; // default $1 peg
        }
    }

    function setStablecoinPrice(address token, uint256 priceUsd18) external {
        _priceUsd18[token] = priceUsd18;
    }

    function setDepegged(address token, bool depegged) external {
        _depegged[token] = depegged;
    }

    function intrinsicFloorPrice() external view returns (uint256) {
        return floorPrice;
    }

    function isAcceptedStablecoin(address token) external view returns (bool) {
        return _accepted[token];
    }

    function stablecoinScale(address token) external view returns (uint256) {
        return _scale[token];
    }

    function getStablecoinPriceUsd18(address token) external view returns (uint256) {
        if (_depegged[token]) revert StablecoinDepegged(token);
        return _priceUsd18[token];
    }

    /// @dev No-op stub. Treasury auto-alloc isn't exercised in the standalone Token tests;
    ///      the hook in `Token.buy` calls this and swallows any revert. Keeping it as a
    ///      no-op silently emits success.
    function allocateAcrossTracked(address /*paymentToken*/, uint256 /*totalAmount*/) external pure {}
}

contract GrowfiTokenTest is Test {
    GrowfiToken token;
    MockERC20 usdc; // 6-dec
    MockERC20 usdt; // 6-dec
    MockERC20 dai; // 18-dec
    MockGrowfiTreasury treasury;

    address constant FACTORY = address(0xF000);
    address constant DEPLOYER = address(0xD000);
    address constant ALICE = address(0xA1);
    address constant BOB = address(0xB0B);
    address constant MINTER = address(0x1117);
    address constant ATTACKER = address(0xBAD);

    uint256 constant GENESIS_AMOUNT = 1_000_000e18;
    uint256 constant INITIAL_MARKUP_BPS = 1_000; // 10%
    uint256 constant BOOT_PRICE = 1e17; // $0.10 per GROW
    uint256 constant ONE_USDC = 1e6;
    uint256 constant ONE_DAI = 1e18;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);
        dai = new MockERC20("Dai Stablecoin", "DAI", 18);
        treasury = new MockGrowfiTreasury();

        // Allowlist all three at the right scale (USDC/USDT 6-dec → 1e12, DAI 18-dec → 1)
        treasury.setAccepted(address(usdc), 1e12);
        treasury.setAccepted(address(usdt), 1e12);
        treasury.setAccepted(address(dai), 1);

        GrowfiToken impl = new GrowfiToken();
        bytes memory initData = abi.encodeCall(
            GrowfiToken.initialize,
            ("GrowFi", "GROW", FACTORY, DEPLOYER, GENESIS_AMOUNT, INITIAL_MARKUP_BPS, BOOT_PRICE)
        );
        token = GrowfiToken(address(new TransparentUpgradeableProxy(address(impl), FACTORY, initData)));

        vm.prank(FACTORY);
        token.setTreasury(address(treasury));
    }

    function _approveAndFund(MockERC20 stable, address user, uint256 amount) internal {
        stable.mint(user, amount);
        vm.prank(user);
        stable.approve(address(token), amount);
    }

    // ---------- initialize ----------

    function test_initialize_setsMetadata() public view {
        assertEq(token.name(), "GrowFi");
        assertEq(token.symbol(), "GROW");
        assertEq(token.decimals(), 18);
        assertEq(token.factory(), FACTORY);
        assertEq(token.markupBps(), INITIAL_MARKUP_BPS);
        assertEq(token.referencePrice(), BOOT_PRICE);
        assertTrue(token.saleActive());
    }

    function test_initialize_mintsGenesisToDeployer() public view {
        assertEq(token.balanceOf(DEPLOYER), GENESIS_AMOUNT);
        assertEq(token.totalSupply(), GENESIS_AMOUNT);
    }

    function test_initialize_zeroGenesisSkipsMint() public {
        GrowfiToken impl = new GrowfiToken();
        bytes memory initData = abi.encodeCall(
            GrowfiToken.initialize, ("GrowFi", "GROW", FACTORY, address(0), 0, INITIAL_MARKUP_BPS, BOOT_PRICE)
        );
        GrowfiToken t = GrowfiToken(address(new TransparentUpgradeableProxy(address(impl), FACTORY, initData)));
        assertEq(t.totalSupply(), 0);
    }

    function test_initialize_revertsOnZeroFactory() public {
        GrowfiToken impl = new GrowfiToken();
        bytes memory initData = abi.encodeCall(
            GrowfiToken.initialize,
            ("GrowFi", "GROW", address(0), DEPLOYER, GENESIS_AMOUNT, INITIAL_MARKUP_BPS, BOOT_PRICE)
        );
        vm.expectRevert(GrowfiToken.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(impl), FACTORY, initData);
    }

    function test_initialize_revertsOnExcessiveMarkup() public {
        GrowfiToken impl = new GrowfiToken();
        bytes memory initData = abi.encodeCall(
            GrowfiToken.initialize, ("GrowFi", "GROW", FACTORY, DEPLOYER, GENESIS_AMOUNT, 5_001, BOOT_PRICE)
        );
        vm.expectRevert(GrowfiToken.InvalidMarkup.selector);
        new TransparentUpgradeableProxy(address(impl), FACTORY, initData);
    }

    function test_initialize_cannotBeCalledTwice() public {
        vm.expectRevert();
        token.initialize("Other", "OTH", FACTORY, DEPLOYER, 1, INITIAL_MARKUP_BPS, BOOT_PRICE);
    }

    function test_initialize_cannotBeCalledOnImplementation() public {
        GrowfiToken impl = new GrowfiToken();
        vm.expectRevert();
        impl.initialize(
            "GrowFi", "GROW", FACTORY, DEPLOYER, GENESIS_AMOUNT, INITIAL_MARKUP_BPS, BOOT_PRICE
        );
    }

    // ---------- factory admin ----------

    function test_setMinter_byFactorySucceeds() public {
        vm.prank(FACTORY);
        token.setMinter(MINTER);
        assertEq(token.minter(), MINTER);
    }

    function test_setMinter_revertsForNonFactory() public {
        vm.expectRevert(GrowfiToken.NotFactory.selector);
        vm.prank(ATTACKER);
        token.setMinter(MINTER);
    }

    function test_setMinter_revertsOnZeroAddress() public {
        vm.expectRevert(GrowfiToken.ZeroAddress.selector);
        vm.prank(FACTORY);
        token.setMinter(address(0));
    }

    function test_setTreasury_byFactorySucceeds() public {
        address newTreasury = address(new MockGrowfiTreasury());
        vm.prank(FACTORY);
        token.setTreasury(newTreasury);
        assertEq(token.treasury(), newTreasury);
    }

    function test_setSaleActive_toggleable() public {
        assertTrue(token.saleActive());
        vm.prank(FACTORY);
        token.setSaleActive(false);
        assertFalse(token.saleActive());
    }

    function test_setMarkup_byFactorySucceeds() public {
        vm.prank(FACTORY);
        token.setMarkup(2_000);
        assertEq(token.markupBps(), 2_000);
    }

    function test_setMarkup_revertsOnExcessive() public {
        vm.expectRevert(GrowfiToken.InvalidMarkup.selector);
        vm.prank(FACTORY);
        token.setMarkup(5_001);
    }

    function test_setReferencePrice_byFactorySucceeds() public {
        vm.prank(FACTORY);
        token.setReferencePrice(2e17);
        assertEq(token.referencePrice(), 2e17);
    }

    // ---------- mint (minter authority) ----------

    function test_mint_byMinterSucceeds() public {
        vm.prank(FACTORY);
        token.setMinter(MINTER);

        vm.prank(MINTER);
        token.mint(ALICE, 100e18);
        assertEq(token.balanceOf(ALICE), 100e18);
    }

    function test_mint_revertsForNonMinter() public {
        vm.prank(FACTORY);
        token.setMinter(MINTER);

        vm.expectRevert(GrowfiToken.NotMinter.selector);
        vm.prank(ATTACKER);
        token.mint(ATTACKER, 1e18);
    }

    function test_mint_revertsBeforeMinterIsSet() public {
        vm.expectRevert(GrowfiToken.NotMinter.selector);
        vm.prank(MINTER);
        token.mint(ALICE, 1e18);
    }

    // ---------- burn ----------

    function test_burn_holderCanBurnOwn() public {
        vm.prank(DEPLOYER);
        token.burn(100e18);
        assertEq(token.balanceOf(DEPLOYER), GENESIS_AMOUNT - 100e18);
    }

    function test_burnFrom_requiresApproval() public {
        vm.prank(DEPLOYER);
        token.approve(BOB, 50e18);

        vm.prank(BOB);
        token.burnFrom(DEPLOYER, 50e18);
        assertEq(token.balanceOf(DEPLOYER), GENESIS_AMOUNT - 50e18);
    }

    // ---------- effectiveReferencePrice / currentSalePrice ----------

    function test_view_floorTakesPriorityOverReferenceWhenAvailable() public {
        treasury.setFloorPrice(2e17);
        assertEq(token.effectiveReferencePrice(), 2e17);
    }

    function test_view_fallsBackToReferencePriceWhenFloorIsZero() public {
        treasury.setFloorPrice(0);
        assertEq(token.effectiveReferencePrice(), BOOT_PRICE);
    }

    function test_view_currentSalePriceAppliesMarkup() public {
        treasury.setFloorPrice(1e17);
        assertEq(token.currentSalePrice(), 1.1e17);
    }

    function test_view_currentSalePriceRevertsWhenNoFloorAndNoReference() public {
        GrowfiToken impl = new GrowfiToken();
        bytes memory initData = abi.encodeCall(
            GrowfiToken.initialize, ("GrowFi", "GROW", FACTORY, DEPLOYER, GENESIS_AMOUNT, INITIAL_MARKUP_BPS, 0)
        );
        GrowfiToken t = GrowfiToken(address(new TransparentUpgradeableProxy(address(impl), FACTORY, initData)));

        vm.expectRevert(GrowfiToken.NoFloorAvailable.selector);
        t.currentSalePrice();
    }

    // ---------- buy: USDC ----------

    function test_buy_usdcAtFloorMintsCorrectAmount() public {
        treasury.setFloorPrice(1e17); // $0.10 floor → $0.11 sale price
        _approveAndFund(usdc, ALICE, 11 * ONE_USDC);

        vm.prank(ALICE);
        uint256 received = token.buy(address(usdc), 11 * ONE_USDC, type(uint256).max);

        // $11 USDC at $0.11/GROW = 100 GROW
        assertEq(received, 100e18);
        assertEq(token.balanceOf(ALICE), 100e18);
        assertEq(usdc.balanceOf(address(treasury)), 11 * ONE_USDC);
    }

    // ---------- buy: USDT (also 6-dec) ----------

    function test_buy_usdtMintsSameRateAsUsdc() public {
        treasury.setFloorPrice(1e17);
        _approveAndFund(usdt, ALICE, 11 * ONE_USDC); // 11 USDT raw

        vm.prank(ALICE);
        uint256 received = token.buy(address(usdt), 11 * ONE_USDC, type(uint256).max);

        assertEq(received, 100e18);
        assertEq(usdt.balanceOf(address(treasury)), 11 * ONE_USDC);
    }

    // ---------- buy: DAI (18-dec) ----------

    function test_buy_daiMintsCorrectlyDespiteDifferentDecimals() public {
        treasury.setFloorPrice(1e17);
        _approveAndFund(dai, ALICE, 11 * ONE_DAI); // 11 DAI raw (18-dec)

        vm.prank(ALICE);
        uint256 received = token.buy(address(dai), 11 * ONE_DAI, type(uint256).max);

        // $11 (DAI) at $0.11/GROW = 100 GROW
        assertEq(received, 100e18);
        assertEq(dai.balanceOf(address(treasury)), 11 * ONE_DAI);
    }

    // ---------- buy: not-accepted token reverts ----------

    function test_buy_revertsForNonAcceptedToken() public {
        MockERC20 random = new MockERC20("Random", "RND", 18);
        treasury.setFloorPrice(1e17);
        _approveAndFund(random, ALICE, 1e18);

        vm.expectRevert(GrowfiToken.PaymentTokenNotAccepted.selector);
        vm.prank(ALICE);
        token.buy(address(random), 1e18, type(uint256).max);
    }

    function test_buy_revertsAfterTokenRevoked() public {
        treasury.setFloorPrice(1e17);
        _approveAndFund(usdc, ALICE, 11 * ONE_USDC);

        // Multisig removes USDC mid-flight
        treasury.setAccepted(address(usdc), 0);

        vm.expectRevert(GrowfiToken.PaymentTokenNotAccepted.selector);
        vm.prank(ALICE);
        token.buy(address(usdc), 11 * ONE_USDC, type(uint256).max);
    }

    // ---------- buy: shared mechanics ----------

    function test_buy_emitsEvent() public {
        treasury.setFloorPrice(1e17);
        _approveAndFund(usdc, ALICE, 11 * ONE_USDC);

        vm.expectEmit(true, true, false, true);
        emit GrowfiToken.DirectBuy(ALICE, address(usdc), 11 * ONE_USDC, 100e18, 1.1e17);
        vm.prank(ALICE);
        token.buy(address(usdc), 11 * ONE_USDC, type(uint256).max);
    }

    function test_buy_usesReferencePriceFallbackWhenFloorIsZero() public {
        treasury.setFloorPrice(0);
        _approveAndFund(usdc, ALICE, 11 * ONE_USDC);

        vm.prank(ALICE);
        uint256 received = token.buy(address(usdc), 11 * ONE_USDC, type(uint256).max);
        assertEq(received, 100e18);
    }

    function test_buy_updatesReferencePriceCacheOnSuccess() public {
        treasury.setFloorPrice(2e17);
        _approveAndFund(usdc, ALICE, 1 * ONE_USDC);

        vm.prank(ALICE);
        token.buy(address(usdc), 1 * ONE_USDC, type(uint256).max);
        assertEq(token.referencePrice(), 2e17);
    }

    function test_buy_doesNotCacheWhenUsingFallback() public {
        treasury.setFloorPrice(0);
        _approveAndFund(usdc, ALICE, 1 * ONE_USDC);

        vm.prank(ALICE);
        token.buy(address(usdc), 1 * ONE_USDC, type(uint256).max);
        assertEq(token.referencePrice(), BOOT_PRICE);
    }

    function test_buy_respectsSlippageProtection() public {
        treasury.setFloorPrice(1e17);
        _approveAndFund(usdc, ALICE, 10 * ONE_USDC);

        vm.expectRevert(GrowfiToken.PriceExceedsMax.selector);
        vm.prank(ALICE);
        token.buy(address(usdc), 10 * ONE_USDC, 1e17);
    }

    function test_buy_revertsWhenSaleInactive() public {
        vm.prank(FACTORY);
        token.setSaleActive(false);

        treasury.setFloorPrice(1e17);
        _approveAndFund(usdc, ALICE, 1 * ONE_USDC);

        vm.expectRevert(GrowfiToken.SaleNotActive.selector);
        vm.prank(ALICE);
        token.buy(address(usdc), 1 * ONE_USDC, type(uint256).max);
    }

    function test_buy_revertsWhenTreasuryNotSet() public {
        GrowfiToken impl = new GrowfiToken();
        bytes memory initData = abi.encodeCall(
            GrowfiToken.initialize,
            ("GrowFi", "GROW", FACTORY, DEPLOYER, GENESIS_AMOUNT, INITIAL_MARKUP_BPS, BOOT_PRICE)
        );
        GrowfiToken t = GrowfiToken(address(new TransparentUpgradeableProxy(address(impl), FACTORY, initData)));

        _approveAndFund(usdc, ALICE, 1 * ONE_USDC);
        vm.prank(ALICE);
        usdc.approve(address(t), 1 * ONE_USDC);

        vm.expectRevert(GrowfiToken.TreasuryNotSet.selector);
        vm.prank(ALICE);
        t.buy(address(usdc), 1 * ONE_USDC, type(uint256).max);
    }

    function test_buy_revertsOnZeroAmount() public {
        treasury.setFloorPrice(1e17);
        vm.expectRevert(GrowfiToken.ZeroAmount.selector);
        vm.prank(ALICE);
        token.buy(address(usdc), 0, type(uint256).max);
    }

    function test_buy_revertsWhenNoFloorAvailable() public {
        // Both floor=0 AND referencePrice=0 → no way to price
        GrowfiToken impl = new GrowfiToken();
        bytes memory initData = abi.encodeCall(
            GrowfiToken.initialize, ("GrowFi", "GROW", FACTORY, DEPLOYER, GENESIS_AMOUNT, INITIAL_MARKUP_BPS, 0)
        );
        GrowfiToken t = GrowfiToken(address(new TransparentUpgradeableProxy(address(impl), FACTORY, initData)));

        vm.prank(FACTORY);
        t.setTreasury(address(treasury));
        treasury.setFloorPrice(0);

        _approveAndFund(usdc, ALICE, 1 * ONE_USDC);
        vm.prank(ALICE);
        usdc.approve(address(t), 1 * ONE_USDC);

        vm.expectRevert(GrowfiToken.NoFloorAvailable.selector);
        vm.prank(ALICE);
        t.buy(address(usdc), 1 * ONE_USDC, type(uint256).max);
    }

    function test_buy_revertsWithoutApproval() public {
        treasury.setFloorPrice(1e17);
        usdc.mint(ALICE, 1 * ONE_USDC);

        vm.expectRevert();
        vm.prank(ALICE);
        token.buy(address(usdc), 1 * ONE_USDC, type(uint256).max);
    }

    // ---------- buy with markup variations ----------

    function test_buy_atZeroMarkupSellsAtFloor() public {
        vm.prank(FACTORY);
        token.setMarkup(0);
        treasury.setFloorPrice(1e17);

        _approveAndFund(usdc, ALICE, 10 * ONE_USDC);
        vm.prank(ALICE);
        uint256 received = token.buy(address(usdc), 10 * ONE_USDC, type(uint256).max);
        assertEq(received, 100e18);
    }

    function test_buy_atMaxMarkup50pct() public {
        vm.prank(FACTORY);
        token.setMarkup(5_000);
        treasury.setFloorPrice(1e17);

        _approveAndFund(usdc, ALICE, 15 * ONE_USDC);
        vm.prank(ALICE);
        uint256 received = token.buy(address(usdc), 15 * ONE_USDC, type(uint256).max);
        assertEq(received, 100e18);
    }

    // ---------- red team ----------

    function test_redteam_cannotForceBuyBelowFloor() public {
        treasury.setFloorPrice(1e18);
        _approveAndFund(usdc, ATTACKER, 1 * ONE_USDC);

        vm.expectRevert(GrowfiToken.PriceExceedsMax.selector);
        vm.prank(ATTACKER);
        token.buy(address(usdc), 1 * ONE_USDC, 5e17);
    }

    function test_redteam_directMintBlockedEvenAfterMinterSet() public {
        vm.prank(FACTORY);
        token.setMinter(MINTER);

        vm.expectRevert(GrowfiToken.NotMinter.selector);
        vm.prank(ATTACKER);
        token.mint(ATTACKER, type(uint128).max);
    }

    function test_redteam_attackerCannotToggleSale() public {
        vm.expectRevert(GrowfiToken.NotFactory.selector);
        vm.prank(ATTACKER);
        token.setSaleActive(false);
    }

    function test_redteam_markupCappedAt50pct() public {
        vm.prank(FACTORY);
        vm.expectRevert(GrowfiToken.InvalidMarkup.selector);
        token.setMarkup(10_000);
    }

    /// @dev Multi-token: buyer can mix and match across multiple buys with different stablecoins.
    function test_redteam_multipleBuysAcrossStablecoins() public {
        treasury.setFloorPrice(1e17);
        _approveAndFund(usdc, ALICE, 11 * ONE_USDC);
        _approveAndFund(usdt, ALICE, 11 * ONE_USDC);
        _approveAndFund(dai, ALICE, 11 * ONE_DAI);

        vm.startPrank(ALICE);
        uint256 r1 = token.buy(address(usdc), 11 * ONE_USDC, type(uint256).max);
        uint256 r2 = token.buy(address(usdt), 11 * ONE_USDC, type(uint256).max);
        uint256 r3 = token.buy(address(dai), 11 * ONE_DAI, type(uint256).max);
        vm.stopPrank();

        assertEq(r1, 100e18);
        assertEq(r2, 100e18);
        assertEq(r3, 100e18);
        assertEq(token.balanceOf(ALICE), 300e18);
    }
}
