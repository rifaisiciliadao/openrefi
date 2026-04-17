// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CampaignToken} from "../src/CampaignToken.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract CampaignTokenTest is Test {
    CampaignToken token;
    address campaign = address(0x1);
    address vault = address(0x2);
    address user = address(0x3);

    function setUp() public {
        CampaignToken impl = new CampaignToken();
        bytes memory initData = abi.encodeCall(CampaignToken.initialize, ("Olive Tree", "OLIVE", campaign));
        token = CampaignToken(address(new TransparentUpgradeableProxy(address(impl), address(this), initData)));
        vm.prank(campaign);
        token.setStakingVault(vault);
    }

    function test_mint_onlyCampaign() public {
        vm.prank(campaign);
        token.mint(user, 1000e18);
        assertEq(token.balanceOf(user), 1000e18);
    }

    function test_mint_revertsIfNotCampaign() public {
        vm.prank(user);
        vm.expectRevert(CampaignToken.OnlyCampaign.selector);
        token.mint(user, 1000e18);
    }

    function test_burn_byCampaign() public {
        vm.prank(campaign);
        token.mint(user, 1000e18);

        vm.prank(campaign);
        token.burn(user, 500e18);
        assertEq(token.balanceOf(user), 500e18);
    }

    function test_burn_byVault() public {
        vm.prank(campaign);
        token.mint(user, 1000e18);

        // Transfer to vault first (simulating staking)
        vm.prank(user);
        token.transfer(vault, 1000e18);

        vm.prank(vault);
        token.burn(vault, 500e18);
        assertEq(token.balanceOf(vault), 500e18);
    }

    function test_burn_revertsIfUnauthorized() public {
        vm.prank(campaign);
        token.mint(user, 1000e18);

        vm.prank(user);
        vm.expectRevert(CampaignToken.OnlyCampaignOrVault.selector);
        token.burn(user, 500e18);
    }

    function test_setStakingVault_cannotSetTwice() public {
        vm.prank(campaign);
        vm.expectRevert(CampaignToken.StakingVaultAlreadySet.selector);
        token.setStakingVault(address(0x99));
    }

    function test_deflationary() public {
        vm.prank(campaign);
        token.mint(user, 1000e18);
        assertEq(token.totalSupply(), 1000e18);

        vm.prank(campaign);
        token.burn(user, 200e18);
        assertEq(token.totalSupply(), 800e18);
    }
}
