// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {GrowfiProducerRegistry} from "../src/GrowfiProducerRegistry.sol";

/// @notice Deploys GrowfiProducerRegistry. Constructor takes the initial owner,
///         which controls the KYC admin set (default: the deployer). The
///         self-served profile surface remains zero-admin.
///
/// Usage:
///   PRIVATE_KEY=0x... \
///   OWNER=0x... (optional; defaults to deployer) \
///   forge script script/DeployProducerRegistry.s.sol \
///     --rpc-url https://sepolia.base.org --broadcast --verify
contract DeployProducerRegistryScript is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address owner = vm.envOr("OWNER", deployer);

        vm.startBroadcast(pk);
        GrowfiProducerRegistry registry = new GrowfiProducerRegistry(owner);
        vm.stopBroadcast();

        console.log("GrowfiProducerRegistry deployed at:", address(registry));
        console.log("Initial owner            :", owner);
    }
}
