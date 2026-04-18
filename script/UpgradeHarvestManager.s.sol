// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {HarvestManager} from "../src/HarvestManager.sol";
import {CampaignFactory} from "../src/CampaignFactory.sol";

/// @title UpgradeHarvestManager — deploy new HarvestManager impl, point the factory at it,
///         then upgrade the 3 existing campaigns' HM proxies so they emit the renamed events.
///
/// Event rename: USDCRedeemed (in redeemUSDC) → USDCCommitted; USDCClaimed (in claimUSDC) → USDCRedeemed.
/// Pure ABI diff; no storage layout change; no reinit required.
///
/// Env required (all optional for the per-campaign section):
///   PRIVATE_KEY                 — factory owner + producer of all 3 demo campaigns
///   FACTORY_ADDRESS             — factory proxy
///   OLIVE_HARVEST_MANAGER       — HM proxy #1
///   FAST_HARVEST_MANAGER        — HM proxy #2
///   SMOKE_HARVEST_MANAGER       — HM proxy #3 (may not be set — skip if zero)
contract UpgradeHarvestManager is Script {
    bytes32 private constant ERC1967_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        CampaignFactory factory = CampaignFactory(vm.envAddress("FACTORY_ADDRESS"));

        vm.startBroadcast(pk);

        // 1. Deploy new implementation.
        HarvestManager newImpl = new HarvestManager();
        console.log("new HM impl         :", address(newImpl));

        // 2. Point factory at the new impl for FUTURE campaigns.
        factory.setHarvestManagerImpl(address(newImpl));
        console.log("factory.setHarvestManagerImpl: done");

        // 3. Upgrade existing campaigns' HM proxies.
        _upgradeOne(vm.envOr("OLIVE_HARVEST_MANAGER", address(0)), address(newImpl), "OLIVE");
        _upgradeOne(vm.envOr("FAST_HARVEST_MANAGER", address(0)), address(newImpl), "FAST");
        _upgradeOne(vm.envOr("SMOKE_HARVEST_MANAGER", address(0)), address(newImpl), "SMOKE");

        vm.stopBroadcast();

        console.log("--- done ---");
    }

    function _upgradeOne(address hmProxy, address newImpl, string memory tag) internal {
        if (hmProxy == address(0)) {
            console.log(string.concat(tag, ": skipped (env not set)"));
            return;
        }
        address admin = address(uint160(uint256(vm.load(hmProxy, ERC1967_ADMIN_SLOT))));
        console.log(tag, "proxy:", hmProxy);
        console.log(tag, "admin:", admin);
        // Pure event rename, no reinit → empty data.
        ProxyAdmin(admin).upgradeAndCall(ITransparentUpgradeableProxy(hmProxy), newImpl, "");
        console.log(tag, ": upgraded");
    }
}
