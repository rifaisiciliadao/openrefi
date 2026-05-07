// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GrowfiToken} from "../../src/GrowfiToken.sol";
import {GrowfiTreasury} from "../../src/GrowfiTreasury.sol";
import {GrowfiFeeSplitter} from "../../src/GrowfiFeeSplitter.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

/// @notice Handler for GROW system invariant fuzzing. Exposes a small set of actions
///         that the foundry runner randomizes to stress-test cross-contract state.
contract GrowfiHandler is Test {
    GrowfiToken public growToken;
    GrowfiTreasury public treasury;
    GrowfiFeeSplitter public splitter;
    MockERC20 public usdc;
    MockERC20 public usdt;
    address public ops;

    address[] public actors;

    // Ghost vars
    uint256 public ghost_totalUsdcInflowToTreasury;
    uint256 public ghost_totalGrowMintedViaDirectBuy;
    uint256 public ghost_directBuyCalls;
    uint256 public ghost_redeemCalls;
    uint256 public ghost_flushCalls;
    uint256 public ghost_donateCalls;

    constructor(
        GrowfiToken _growToken,
        GrowfiTreasury _treasury,
        GrowfiFeeSplitter _splitter,
        MockERC20 _usdc,
        MockERC20 _usdt,
        address _ops,
        address[5] memory _actors
    ) {
        growToken = _growToken;
        treasury = _treasury;
        splitter = _splitter;
        usdc = _usdc;
        usdt = _usdt;
        ops = _ops;
        for (uint256 i; i < _actors.length; ++i) {
            actors.push(_actors[i]);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _stable(uint256 seed) internal view returns (MockERC20) {
        return seed % 2 == 0 ? usdc : usdt;
    }

    /// @notice Random user buys GROW directly. USDC routed to treasury.
    function directBuy(uint256 actorSeed, uint256 stableSeed, uint256 amount) public {
        amount = bound(amount, 1, 1_000_000 * 1e6); // up to 1M units (capped at MockERC20 mint capacity)
        address user = _actor(actorSeed);
        MockERC20 stable = _stable(stableSeed);

        stable.mint(user, amount);
        vm.prank(user);
        stable.approve(address(growToken), amount);

        try growToken.buy(address(stable), amount, type(uint256).max) returns (uint256 growOut) {
            ghost_directBuyCalls++;
            ghost_totalGrowMintedViaDirectBuy += growOut;
            if (address(stable) == address(usdc)) {
                ghost_totalUsdcInflowToTreasury += amount;
            }
        } catch {
            // Buy can revert if floor=0 etc. — acceptable, just don't track.
        }
    }

    /// @notice Anyone can donate USDC directly to treasury (philanthropy).
    function donateToTreasury(uint256 amount) public {
        amount = bound(amount, 1, 100_000 * 1e6);
        usdc.mint(address(treasury), amount);
        ghost_totalUsdcInflowToTreasury += amount;
        ghost_donateCalls++;
    }

    /// @notice Random user with GROW redeems some.
    function redeem(uint256 actorSeed, uint256 amount) public {
        address user = _actor(actorSeed);
        uint256 bal = growToken.balanceOf(user);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        vm.prank(user);
        growToken.approve(address(treasury), amount);
        try treasury.redeem(amount) {
            ghost_redeemCalls++;
        } catch {
            // Can fail if circulating = 0 or other edge cases.
        }
    }

    /// @notice Permissionless flush of accumulated fees in splitter.
    function flushSplitter(uint256 stableSeed) public {
        MockERC20 stable = _stable(stableSeed);
        try splitter.flushToken(address(stable)) {
            ghost_flushCalls++;
        } catch {
            // Reverts on zero balance — acceptable.
        }
    }

    /// @notice GROW holders transfer to each other randomly.
    function transferGrow(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (from == to) return;
        uint256 bal = growToken.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        vm.prank(from);
        growToken.transfer(to, amount);
    }
}
