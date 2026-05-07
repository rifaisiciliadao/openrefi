// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {GrowfiCampaignRegistry} from "../src/GrowfiCampaignRegistry.sol";
import {GrowfiCampaignFactory} from "../src/GrowfiCampaignFactory.sol";

/// @notice Deploys GrowfiCampaignRegistry pointing at an existing GrowfiCampaignFactory.
///
/// Usage:
///   FACTORY=0x3fA41528a22645Bef478E9eBae83981C02e98f74 \
///   forge script script/DeployRegistry.s.sol \
///     --rpc-url https://sepolia.base.org --broadcast --verify
contract DeployRegistryScript is Script {
    function run() external {
        address factoryAddr = vm.envAddress("FACTORY");
        require(factoryAddr != address(0), "FACTORY env var required");

        vm.startBroadcast();
        GrowfiCampaignRegistry registry = new GrowfiCampaignRegistry(GrowfiCampaignFactory(factoryAddr));
        vm.stopBroadcast();

        console.log("GrowfiCampaignRegistry deployed at:", address(registry));
        console.log("  Bound to factory:", factoryAddr);
    }
}
