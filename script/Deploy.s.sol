// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {CampaignFactory} from "../src/CampaignFactory.sol";
import {Campaign} from "../src/Campaign.sol";
import {CampaignToken} from "../src/CampaignToken.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {YieldToken} from "../src/YieldToken.sol";
import {HarvestManager} from "../src/HarvestManager.sol";

/// @title Deploy — production deployment (Arbitrum / Base / mainnet)
/// @notice Deploys 5 core implementations, then the CampaignFactory behind a
///         TransparentUpgradeableProxy owned by OWNER_ADDRESS.
contract DeployScript is Script {
    function run() external {
        address owner = vm.envAddress("OWNER_ADDRESS");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        // Chain-specific L2 sequencer uptime feed. address(0) on L1.
        address sequencerUptimeFeed = vm.envOr("SEQUENCER_UPTIME_FEED", address(0));

        vm.startBroadcast();

        address[5] memory impls;
        impls[0] = address(new Campaign());
        impls[1] = address(new CampaignToken());
        impls[2] = address(new StakingVault());
        impls[3] = address(new YieldToken());
        impls[4] = address(new HarvestManager());

        CampaignFactory factoryImpl = new CampaignFactory();
        bytes memory initData =
            abi.encodeCall(CampaignFactory.initialize, (owner, feeRecipient, usdc, sequencerUptimeFeed, impls));
        TransparentUpgradeableProxy factory = new TransparentUpgradeableProxy(address(factoryImpl), owner, initData);

        vm.stopBroadcast();

        console.log("CampaignFactory proxy     :", address(factory));
        console.log("CampaignFactory impl      :", address(factoryImpl));
        console.log("Campaign impl             :", impls[0]);
        console.log("CampaignToken impl        :", impls[1]);
        console.log("StakingVault impl         :", impls[2]);
        console.log("YieldToken impl           :", impls[3]);
        console.log("HarvestManager impl       :", impls[4]);
        console.log("Owner (factory admin)     :", owner);
        console.log("Fee recipient             :", feeRecipient);
        console.log("USDC                      :", usdc);
        console.log("Sequencer feed            :", sequencerUptimeFeed);
    }
}
