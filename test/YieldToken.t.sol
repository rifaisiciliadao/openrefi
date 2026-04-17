// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {YieldToken} from "../src/YieldToken.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract YieldTokenTest is Test {
    YieldToken token;
    address vault = address(0x1);
    address harvest = address(0x2);
    address user = address(0x3);

    function setUp() public {
        YieldToken impl = new YieldToken();
        bytes memory initData = abi.encodeCall(YieldToken.initialize, ("Olive Yield", "oYIELD", vault, harvest));
        token = YieldToken(address(new TransparentUpgradeableProxy(address(impl), address(this), initData)));
    }

    function test_mint_onlyVault() public {
        vm.prank(vault);
        token.mint(user, 500e18);
        assertEq(token.balanceOf(user), 500e18);
    }

    function test_mint_revertsIfNotVault() public {
        vm.prank(user);
        vm.expectRevert(YieldToken.OnlyStakingVault.selector);
        token.mint(user, 500e18);
    }

    function test_burn_byVault() public {
        vm.prank(vault);
        token.mint(user, 500e18);

        vm.prank(vault);
        token.burn(user, 200e18);
        assertEq(token.balanceOf(user), 300e18);
    }

    function test_burn_byHarvest() public {
        vm.prank(vault);
        token.mint(user, 500e18);

        vm.prank(harvest);
        token.burn(user, 200e18);
        assertEq(token.balanceOf(user), 300e18);
    }

    function test_burn_revertsIfUnauthorized() public {
        vm.prank(vault);
        token.mint(user, 500e18);

        vm.prank(user);
        vm.expectRevert(YieldToken.OnlyVaultOrHarvest.selector);
        token.burn(user, 200e18);
    }
}
