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

/// @notice Coverage for the team/DAO reserve flow:
///   1. `GrowfiToken.mintTreasuryGenesis` is one-shot, factory-only, mints into Treasury
///   2. The minted reserve is EXCLUDED from `circulating` in the floor calc — so it does
///      NOT dilute the floor while it sits in the Treasury.
///   3. `GrowfiTreasury.releaseGrow` is the single path out, factory-only, with
///      access-control + zero-input guards.
contract GrowfiTreasuryReserveTest is Test {
    GrowfiToken token;
    GrowfiTreasury treasury;
    MockERC20 usdc;
    MockOracle usdFeed;

    address constant FACTORY = address(0xF000);
    address constant DEPLOYER = address(0xD000);
    address constant ALICE = address(0xA1);
    address constant ATTACKER = address(0xBAD);

    uint256 constant ONE_USDC = 1e6;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        usdFeed = new MockOracle(int256(1e8), 8);

        // Token with NO genesis (mint flows into Treasury later).
        GrowfiToken tImpl = new GrowfiToken();
        bytes memory tInit = abi.encodeCall(
            GrowfiToken.initialize, ("GrowFi", "GROW", FACTORY, DEPLOYER, 0, 1_000, 1e17)
        );
        token = GrowfiToken(address(new TransparentUpgradeableProxy(address(tImpl), FACTORY, tInit)));

        GrowfiTreasury trImpl = new GrowfiTreasury();
        bytes memory trInit = abi.encodeCall(GrowfiTreasury.initialize, (FACTORY, address(token)));
        treasury = GrowfiTreasury(address(new TransparentUpgradeableProxy(address(trImpl), FACTORY, trInit)));

        vm.prank(FACTORY);
        token.setTreasury(address(treasury));

        // Allowlist USDC so the Treasury floor calc has at least one stablecoin row.
        vm.prank(FACTORY);
        treasury.addAcceptedStablecoin(address(usdc), 1e12, address(usdFeed), 24 hours, 9_500, 10_500);
    }

    // ============================================================
    // mintTreasuryGenesis
    // ============================================================

    function test_reserve_factoryMintsIntoTreasury() public {
        vm.prank(FACTORY);
        token.mintTreasuryGenesis(100_000e18);
        assertEq(token.balanceOf(address(treasury)), 100_000e18);
        assertEq(token.totalSupply(), 100_000e18);
        assertTrue(token.treasuryGenesisMinted());
    }

    function test_reserve_isOneShot() public {
        vm.prank(FACTORY);
        token.mintTreasuryGenesis(100_000e18);
        vm.expectRevert(GrowfiToken.TreasuryGenesisAlreadyMinted.selector);
        vm.prank(FACTORY);
        token.mintTreasuryGenesis(1);
    }

    function test_reserve_revertsForNonFactory() public {
        vm.expectRevert(GrowfiToken.NotFactory.selector);
        vm.prank(ATTACKER);
        token.mintTreasuryGenesis(100_000e18);
    }

    function test_reserve_revertsOnZeroAmount() public {
        vm.expectRevert(GrowfiToken.ZeroAmount.selector);
        vm.prank(FACTORY);
        token.mintTreasuryGenesis(0);
    }

    function test_reserve_revertsWhenTreasuryNotSet() public {
        // Fresh token with no treasury wired yet.
        GrowfiToken tImpl = new GrowfiToken();
        bytes memory tInit = abi.encodeCall(
            GrowfiToken.initialize, ("X", "X", FACTORY, DEPLOYER, 0, 1_000, 1e17)
        );
        GrowfiToken fresh = GrowfiToken(
            address(new TransparentUpgradeableProxy(address(tImpl), FACTORY, tInit))
        );
        vm.expectRevert(GrowfiToken.TreasuryNotSet.selector);
        vm.prank(FACTORY);
        fresh.mintTreasuryGenesis(100_000e18);
    }

    // ============================================================
    // Reserve excluded from circulating in floor calc
    // ============================================================

    function test_reserve_doesNotDiluteFloor() public {
        // Seed Treasury with $100 of USDC backing (in addition to the GROW reserve).
        usdc.mint(address(treasury), 100 * ONE_USDC);

        // Mint 100k GROW into Treasury — should NOT show up in circulating divisor.
        vm.prank(FACTORY);
        token.mintTreasuryGenesis(100_000e18);

        // Plus 909 GROW circulating (simulate via rescue/external mint? — no minter set here,
        // so we use a separate path: setMinter to a test account, mint 909 to ALICE).
        address minter = address(0xCAFE);
        vm.prank(FACTORY);
        token.setMinter(minter);
        vm.prank(minter);
        token.mint(ALICE, 909e18);

        // Backing = $100. Circulating = 909 (treasury's 100k excluded). Floor = $100/909 ≈ $0.11
        uint256 floor = treasury.intrinsicFloorPrice();
        // expected ≈ 0.110011e18 (with rounding)
        assertGt(floor, 1099e14, "floor at least ~$0.1099");
        assertLt(floor, 1102e14, "floor at most ~$0.1102");
    }

    function test_reserve_floorDilutesAfterRelease() public {
        usdc.mint(address(treasury), 100 * ONE_USDC);
        vm.prank(FACTORY);
        token.mintTreasuryGenesis(100_000e18);

        address minter = address(0xCAFE);
        vm.prank(FACTORY);
        token.setMinter(minter);
        vm.prank(minter);
        token.mint(ALICE, 909e18);

        uint256 floorBefore = treasury.intrinsicFloorPrice(); // ≈ $0.11

        // Multisig releases 50k GROW from Treasury to Alice. Circulating goes from 909 to 50,909.
        // Floor should drop by ~50× since circulating expanded ~55×.
        vm.prank(FACTORY);
        treasury.releaseGrow(ALICE, 50_000e18);

        uint256 floorAfter = treasury.intrinsicFloorPrice();
        assertLt(floorAfter, floorBefore, "release dilutes floor");
        // Treasury still holds 50k, circulating = 909 + 50k = 50,909, backing = $100.
        // Floor ≈ $100 / 50,909 = $0.00196
        assertGt(floorAfter, 19e14, "lower bound");
        assertLt(floorAfter, 21e14, "upper bound");
    }

    // ============================================================
    // releaseGrow
    // ============================================================

    function test_release_factoryCanReleaseToWallet() public {
        vm.prank(FACTORY);
        token.mintTreasuryGenesis(100_000e18);

        vm.prank(FACTORY);
        treasury.releaseGrow(ALICE, 25_000e18);

        assertEq(token.balanceOf(ALICE), 25_000e18);
        assertEq(token.balanceOf(address(treasury)), 75_000e18);
    }

    function test_release_revertsForNonFactory() public {
        vm.prank(FACTORY);
        token.mintTreasuryGenesis(100_000e18);
        vm.expectRevert(GrowfiTreasury.NotFactory.selector);
        vm.prank(ATTACKER);
        treasury.releaseGrow(ATTACKER, 1e18);
    }

    function test_release_revertsOnZeroAddress() public {
        vm.prank(FACTORY);
        token.mintTreasuryGenesis(100_000e18);
        vm.expectRevert(GrowfiTreasury.ZeroAddress.selector);
        vm.prank(FACTORY);
        treasury.releaseGrow(address(0), 1e18);
    }

    function test_release_revertsOnZeroAmount() public {
        vm.prank(FACTORY);
        token.mintTreasuryGenesis(100_000e18);
        vm.expectRevert(GrowfiTreasury.ZeroAmount.selector);
        vm.prank(FACTORY);
        treasury.releaseGrow(ALICE, 0);
    }

    function test_release_revertsWhenInsufficientBalance() public {
        // Treasury has 0 GROW (no genesis mint).
        // releaseGrow uses safeTransfer → reverts with ERC20InsufficientBalance.
        vm.expectRevert();
        vm.prank(FACTORY);
        treasury.releaseGrow(ALICE, 1e18);
    }
}
