// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GrowfiCampaign} from "../src/GrowfiCampaign.sol";
import {GrowfiStakingVault} from "../src/GrowfiStakingVault.sol";
import {GrowfiYieldToken} from "../src/GrowfiYieldToken.sol";
import {GrowfiHarvestManager} from "../src/GrowfiHarvestManager.sol";

/// @title OliveFinish — Phase 2 of the 2-actor lifecycle smoke on Base Sepolia
/// @notice Closes the season, both actors claim yield, Alice redeems USDC,
///         Bob redeems physical product via a 1-leaf Merkle tree (proof = []).
///         The deposit/claim cycle is intentionally left for the bash follow-up
///         because `GrowfiHarvestManager.remainingDepositGross` depends on live state
///         that forge-script's dual-pass simulation cannot pin down reliably.
///
/// Env required:
///   PRIVATE_KEY             — Alice (producer, staker A)
///   BOB_PRIVATE_KEY         — Bob (staker B)
///   OLIVE_CAMPAIGN          — GrowfiCampaign proxy
///   OLIVE_STAKING_VAULT     — GrowfiStakingVault proxy
///   OLIVE_HARVEST_MANAGER   — GrowfiHarvestManager proxy
///   OLIVE_YIELD_TOKEN       — GrowfiYieldToken proxy
contract OliveFinish is Script {
    uint256 internal constant REPORTED_VALUE_USD = 1_500e18; // $1,500 harvest
    uint256 internal constant TOTAL_PRODUCT_UNITS = 100e18; // 100 litres of olive oil

    function run() external {
        uint256 alicePK = vm.envUint("PRIVATE_KEY");
        uint256 bobPK = vm.envUint("BOB_PRIVATE_KEY");
        GrowfiCampaign campaign = GrowfiCampaign(vm.envAddress("OLIVE_CAMPAIGN"));
        GrowfiStakingVault vault = GrowfiStakingVault(vm.envAddress("OLIVE_STAKING_VAULT"));
        GrowfiHarvestManager hm = GrowfiHarvestManager(vm.envAddress("OLIVE_HARVEST_MANAGER"));
        GrowfiYieldToken yt = GrowfiYieldToken(vm.envAddress("OLIVE_YIELD_TOKEN"));
        address alice = vm.addr(alicePK);
        address bob = vm.addr(bobPK);

        console.log("--- OliveFinish ---");
        console.log("alice :", alice);
        console.log("bob   :", bob);

        // 1. Alice: endSeason, then claim her yield.
        vm.startBroadcast(alicePK);
        campaign.endSeason();
        vault.claimYield(0);
        vm.stopBroadcast();

        // 2. Bob: claim his yield.
        vm.startBroadcast(bobPK);
        vault.claimYield(1);
        vm.stopBroadcast();

        // 3. Read the canonical denominator + both yield balances (view, not broadcast).
        uint256 yieldA = yt.balanceOf(alice);
        uint256 yieldB = yt.balanceOf(bob);
        uint256 totalYieldSupply = vault.seasonTotalYieldOwed(1);
        console.log("yieldA           :", yieldA);
        console.log("yieldB           :", yieldB);
        console.log("totalYieldOwed   :", totalYieldSupply);

        // 4. Bob's product amount & single-leaf Merkle root (proof = []).
        uint256 bobProductAmount = yieldB * TOTAL_PRODUCT_UNITS / totalYieldSupply;
        bytes32 leafBob = keccak256(abi.encodePacked(bob, uint256(1), bobProductAmount));
        console.log("bobProductAmount :", bobProductAmount, "wei (scaled liters)");

        // 5. Alice reports harvest with bob's leaf as root + then burns her YIELD for USDC claim.
        vm.startBroadcast(alicePK);
        hm.reportHarvest(1, REPORTED_VALUE_USD, leafBob, TOTAL_PRODUCT_UNITS);
        hm.redeemUSDC(1, yieldA);
        vm.stopBroadcast();

        // 6. Bob redeems physical product (empty Merkle proof works for a 1-leaf tree).
        vm.startBroadcast(bobPK);
        bytes32[] memory emptyProof = new bytes32[](0);
        hm.redeemProduct(1, yieldB, emptyProof);
        vm.stopBroadcast();

        console.log("--- done ---");
        console.log("Run the deposit+claim step via bash:");
        console.log("  GROSS=$(cast call $OLIVE_HARVEST_MANAGER \"remainingDepositGross(uint256)(uint256)\" 1 ...)");
        console.log("  cast send $OLIVE_HARVEST_MANAGER \"depositUSDC(uint256,uint256)\" 1 $GROSS ...");
        console.log("  cast send $OLIVE_HARVEST_MANAGER \"claimUSDC(uint256)\" 1 ...");
    }
}
