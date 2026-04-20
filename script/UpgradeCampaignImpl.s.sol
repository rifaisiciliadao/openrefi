// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Campaign} from "../src/Campaign.sol";
import {CampaignFactory} from "../src/CampaignFactory.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title UpgradeCampaignImpl — ship the onlyProducer parameter setters
/// @notice Deploys a fresh Campaign impl (sellback-at-maxCap fix + now the
///         setFundingDeadline / setMinCap / setMaxCap setters), points the
///         factory at it for future campaigns, and upgrades every Campaign
///         proxy listed in env via its own producer-owned ProxyAdmin.
///
/// Usage:
///   PRIVATE_KEY=0x... \
///   FACTORY=0x199B... \
///   CAMPAIGN_PROXIES=0x68a2...,0xaaaa... \
///   forge script script/UpgradeCampaignImpl.s.sol --rpc-url https://sepolia.base.org --broadcast
///
/// Notes:
/// - Factory owner must run this to update the default impl (setCampaignImpl).
/// - Each proxy's ProxyAdmin is owned by that campaign's producer, so the
///   caller must own every proxy listed in CAMPAIGN_PROXIES, otherwise the
///   upgradeAndCall call to that specific ProxyAdmin reverts.
contract UpgradeCampaignImplScript is Script {
    // ERC-1967 admin slot: bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1)
    bytes32 constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        CampaignFactory factory = CampaignFactory(vm.envAddress("FACTORY"));
        address[] memory proxies = vm.envOr("CAMPAIGN_PROXIES", ",", new address[](0));

        vm.startBroadcast(pk);

        Campaign newImpl = new Campaign();
        console.log("New Campaign impl   :", address(newImpl));

        // Point factory at the new default (only affects future campaigns).
        factory.setCampaignImpl(address(newImpl));
        console.log("Factory default     : updated");

        // Per-proxy upgrade via the producer-owned ProxyAdmin.
        for (uint256 i = 0; i < proxies.length; i++) {
            address proxy = proxies[i];
            bytes32 adminRaw = vm.load(proxy, ADMIN_SLOT);
            address admin = address(uint160(uint256(adminRaw)));
            console.log("Proxy               :", proxy);
            console.log(" ProxyAdmin         :", admin);
            ProxyAdmin(admin).upgradeAndCall(ITransparentUpgradeableProxy(proxy), address(newImpl), bytes(""));
            console.log(" upgraded");
        }

        vm.stopBroadcast();
    }
}
