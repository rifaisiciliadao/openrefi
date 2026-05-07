// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {GrowfiFeeSplitter} from "../src/GrowfiFeeSplitter.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

contract GrowfiFeeSplitterTest is Test {
    GrowfiFeeSplitter splitter;
    MockERC20 usdc;
    MockERC20 usdt;
    MockERC20 dai;

    address constant FACTORY = address(0xF000);
    address constant TREASURY = address(0xABCD);
    address constant OPS = address(0x0123);
    address constant ALICE = address(0xA1);
    address constant ATTACKER = address(0xBAD);

    uint256 constant TREASURY_BPS = 3_000; // 30%
    uint256 constant ONE_USDC = 1e6;
    uint256 constant ONE_DAI = 1e18;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);
        dai = new MockERC20("Dai", "DAI", 18);

        GrowfiFeeSplitter impl = new GrowfiFeeSplitter();
        bytes memory data =
            abi.encodeCall(GrowfiFeeSplitter.initialize, (FACTORY, TREASURY, OPS, TREASURY_BPS));
        splitter = GrowfiFeeSplitter(address(new TransparentUpgradeableProxy(address(impl), FACTORY, data)));
    }

    // ---------- initialize ----------

    function test_initialize_setsState() public view {
        assertEq(splitter.factory(), FACTORY);
        assertEq(splitter.treasury(), TREASURY);
        assertEq(splitter.operations(), OPS);
        assertEq(splitter.treasuryBps(), TREASURY_BPS);
    }

    function test_initialize_revertsOnZeroFactory() public {
        GrowfiFeeSplitter impl = new GrowfiFeeSplitter();
        bytes memory data =
            abi.encodeCall(GrowfiFeeSplitter.initialize, (address(0), TREASURY, OPS, TREASURY_BPS));
        vm.expectRevert(GrowfiFeeSplitter.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(impl), FACTORY, data);
    }

    function test_initialize_revertsOnZeroTreasury() public {
        GrowfiFeeSplitter impl = new GrowfiFeeSplitter();
        bytes memory data =
            abi.encodeCall(GrowfiFeeSplitter.initialize, (FACTORY, address(0), OPS, TREASURY_BPS));
        vm.expectRevert(GrowfiFeeSplitter.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(impl), FACTORY, data);
    }

    function test_initialize_revertsOnExcessiveBps() public {
        GrowfiFeeSplitter impl = new GrowfiFeeSplitter();
        bytes memory data = abi.encodeCall(GrowfiFeeSplitter.initialize, (FACTORY, TREASURY, OPS, 5_001));
        vm.expectRevert(GrowfiFeeSplitter.InvalidBps.selector);
        new TransparentUpgradeableProxy(address(impl), FACTORY, data);
    }

    function test_initialize_cannotBeCalledTwice() public {
        vm.expectRevert();
        splitter.initialize(FACTORY, TREASURY, OPS, TREASURY_BPS);
    }

    // ---------- setters ----------

    function test_setTreasury_byFactory() public {
        address newT = address(0x1111);
        vm.prank(FACTORY);
        splitter.setTreasury(newT);
        assertEq(splitter.treasury(), newT);
    }

    function test_setTreasury_revertsForNonFactory() public {
        vm.expectRevert(GrowfiFeeSplitter.NotFactory.selector);
        vm.prank(ATTACKER);
        splitter.setTreasury(address(0x1111));
    }

    function test_setTreasury_revertsOnZero() public {
        vm.expectRevert(GrowfiFeeSplitter.ZeroAddress.selector);
        vm.prank(FACTORY);
        splitter.setTreasury(address(0));
    }

    function test_setOperations_byFactory() public {
        address newO = address(0x2222);
        vm.prank(FACTORY);
        splitter.setOperations(newO);
        assertEq(splitter.operations(), newO);
    }

    function test_setTreasuryBps_byFactory() public {
        vm.prank(FACTORY);
        splitter.setTreasuryBps(4_000);
        assertEq(splitter.treasuryBps(), 4_000);
    }

    function test_setTreasuryBps_revertsOnExcessive() public {
        vm.expectRevert(GrowfiFeeSplitter.InvalidBps.selector);
        vm.prank(FACTORY);
        splitter.setTreasuryBps(5_001);
    }

    // ---------- flush ----------

    function test_flush_splitsUsdc30_70() public {
        usdc.mint(address(splitter), 1000 * ONE_USDC);

        splitter.flushToken(address(usdc)); // permissionless

        assertEq(usdc.balanceOf(TREASURY), 300 * ONE_USDC); // 30%
        assertEq(usdc.balanceOf(OPS), 700 * ONE_USDC); // 70%
        assertEq(usdc.balanceOf(address(splitter)), 0);
    }

    function test_flush_worksForAnyTokenIncludingUsdt() public {
        usdt.mint(address(splitter), 200 * ONE_USDC);

        splitter.flushToken(address(usdt));

        assertEq(usdt.balanceOf(TREASURY), 60 * ONE_USDC);
        assertEq(usdt.balanceOf(OPS), 140 * ONE_USDC);
    }

    function test_flush_worksForDaiDespiteDecimals() public {
        dai.mint(address(splitter), 100 * ONE_DAI);

        splitter.flushToken(address(dai));

        assertEq(dai.balanceOf(TREASURY), 30 * ONE_DAI);
        assertEq(dai.balanceOf(OPS), 70 * ONE_DAI);
    }

    function test_flush_emitsEvent() public {
        usdc.mint(address(splitter), 1000 * ONE_USDC);

        vm.expectEmit(true, false, false, true);
        emit GrowfiFeeSplitter.Flushed(address(usdc), 300 * ONE_USDC, 700 * ONE_USDC);
        splitter.flushToken(address(usdc));
    }

    function test_flush_revertsOnZeroBalance() public {
        vm.expectRevert(GrowfiFeeSplitter.ZeroBalance.selector);
        splitter.flushToken(address(usdc));
    }

    function test_flush_anyoneCanCall() public {
        usdc.mint(address(splitter), 1000 * ONE_USDC);

        vm.prank(ATTACKER); // even attacker — no harm done, the split is fixed
        splitter.flushToken(address(usdc));

        assertEq(usdc.balanceOf(TREASURY), 300 * ONE_USDC);
        assertEq(usdc.balanceOf(OPS), 700 * ONE_USDC);
    }

    function test_flush_handlesRoundingCorrectly() public {
        // 7 raw units: 30% × 7 = 2.1 → floor to 2 (Treasury), Ops gets 5 (rest)
        usdc.mint(address(splitter), 7);
        splitter.flushToken(address(usdc));
        assertEq(usdc.balanceOf(TREASURY), 2);
        assertEq(usdc.balanceOf(OPS), 5);
        // No dust left in splitter
        assertEq(usdc.balanceOf(address(splitter)), 0);
    }

    // ---------- flushMany ----------

    function test_flushMany_routesAllInOneCall() public {
        usdc.mint(address(splitter), 1000 * ONE_USDC);
        usdt.mint(address(splitter), 500 * ONE_USDC);
        dai.mint(address(splitter), 100 * ONE_DAI);

        address[] memory tokens = new address[](3);
        tokens[0] = address(usdc);
        tokens[1] = address(usdt);
        tokens[2] = address(dai);

        splitter.flushMany(tokens);

        assertEq(usdc.balanceOf(TREASURY), 300 * ONE_USDC);
        assertEq(usdt.balanceOf(TREASURY), 150 * ONE_USDC);
        assertEq(dai.balanceOf(TREASURY), 30 * ONE_DAI);
        assertEq(usdc.balanceOf(OPS), 700 * ONE_USDC);
        assertEq(usdt.balanceOf(OPS), 350 * ONE_USDC);
        assertEq(dai.balanceOf(OPS), 70 * ONE_DAI);
    }

    function test_flushMany_silentlySkipsEmptyBalances() public {
        usdc.mint(address(splitter), 1000 * ONE_USDC);
        // usdt and dai have zero balance

        address[] memory tokens = new address[](3);
        tokens[0] = address(usdc);
        tokens[1] = address(usdt);
        tokens[2] = address(dai);

        splitter.flushMany(tokens); // doesn't revert
        assertEq(usdc.balanceOf(TREASURY), 300 * ONE_USDC);
    }

    // ---------- previewFlush ----------

    function test_previewFlush_matchesActual() public {
        usdc.mint(address(splitter), 1234 * ONE_USDC);

        (uint256 bal, uint256 toT, uint256 toO) = splitter.previewFlush(address(usdc));
        assertEq(bal, 1234 * ONE_USDC);
        assertEq(toT, (1234 * ONE_USDC * TREASURY_BPS) / 10_000);
        assertEq(toO, bal - toT);

        splitter.flushToken(address(usdc));
        assertEq(usdc.balanceOf(TREASURY), toT);
        assertEq(usdc.balanceOf(OPS), toO);
    }

    // ---------- different bps configurations ----------

    function test_flush_withZeroBpsAllToOperations() public {
        vm.prank(FACTORY);
        splitter.setTreasuryBps(0);

        usdc.mint(address(splitter), 1000 * ONE_USDC);
        splitter.flushToken(address(usdc));

        assertEq(usdc.balanceOf(TREASURY), 0);
        assertEq(usdc.balanceOf(OPS), 1000 * ONE_USDC);
    }

    function test_flush_withMaxBpsHalfToTreasury() public {
        vm.prank(FACTORY);
        splitter.setTreasuryBps(5_000);

        usdc.mint(address(splitter), 1000 * ONE_USDC);
        splitter.flushToken(address(usdc));

        assertEq(usdc.balanceOf(TREASURY), 500 * ONE_USDC);
        assertEq(usdc.balanceOf(OPS), 500 * ONE_USDC);
    }

    // ---------- red team ----------

    /// @dev Attacker can call flush but cannot redirect the funds — the split rule is fixed.
    function test_redteam_attackerCannotRedirectFlush() public {
        usdc.mint(address(splitter), 1000 * ONE_USDC);

        vm.prank(ATTACKER);
        splitter.flushToken(address(usdc));

        // Funds went where they were configured to go, not to attacker
        assertEq(usdc.balanceOf(ATTACKER), 0);
        assertEq(usdc.balanceOf(TREASURY), 300 * ONE_USDC);
        assertEq(usdc.balanceOf(OPS), 700 * ONE_USDC);
    }

    /// @dev Attacker tries to crank treasuryBps to 100% to drain operations.
    function test_redteam_attackerCannotCrankBps() public {
        vm.expectRevert(GrowfiFeeSplitter.NotFactory.selector);
        vm.prank(ATTACKER);
        splitter.setTreasuryBps(10_000);
    }

    /// @dev Even factory cannot exceed MAX_TREASURY_BPS — multisig sanity guard.
    function test_redteam_factoryCappedAt50pct() public {
        vm.expectRevert(GrowfiFeeSplitter.InvalidBps.selector);
        vm.prank(FACTORY);
        splitter.setTreasuryBps(10_000);
    }

    /// @dev Sequential donations and flushes work cleanly: each flush splits the latest balance.
    function test_redteam_sequentialFlushesNoStuckFunds() public {
        usdc.mint(address(splitter), 100 * ONE_USDC);
        splitter.flushToken(address(usdc));
        assertEq(usdc.balanceOf(TREASURY), 30 * ONE_USDC);

        usdc.mint(address(splitter), 100 * ONE_USDC); // another fee arrives
        splitter.flushToken(address(usdc));
        assertEq(usdc.balanceOf(TREASURY), 60 * ONE_USDC); // 30 + 30
        assertEq(usdc.balanceOf(OPS), 140 * ONE_USDC); // 70 + 70
        assertEq(usdc.balanceOf(address(splitter)), 0);
    }

    /// @dev Anyone (not even factory) can flush — useful for keepers, no centralized choke point.
    function test_redteam_factoryHasNoSpecialFlushPower() public {
        usdc.mint(address(splitter), 100 * ONE_USDC);

        // Random caller works
        vm.prank(ALICE);
        splitter.flushToken(address(usdc));

        assertEq(usdc.balanceOf(TREASURY), 30 * ONE_USDC);
        assertEq(usdc.balanceOf(OPS), 70 * ONE_USDC);
    }
}
