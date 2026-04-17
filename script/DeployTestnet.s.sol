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
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @title DeployTestnet — one-shot deployment for Base Sepolia / Arbitrum Sepolia
/// @notice Deploys: MockUSDC + 5 core implementations + CampaignFactory impl +
///         TransparentUpgradeableProxy pre-initialized. Seeds the deployer with
///         1M mUSDC for demo campaign funding.
///
/// Usage (Base Sepolia):
///   PRIVATE_KEY=0x... \
///   forge script script/DeployTestnet.s.sol \
///     --rpc-url https://sepolia.base.org \
///     --broadcast \
///     --verify --verifier-url https://api-sepolia.basescan.org/api --etherscan-api-key $BASESCAN_KEY
contract DeployTestnet is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address owner = vm.envOr("OWNER_ADDRESS", deployer);
        address feeRecipient = vm.envOr("FEE_RECIPIENT_ADDRESS", deployer);

        uint256 chainId = block.chainid;
        require(
            chainId == 84_532 || chainId == 421_614 || chainId == 11_155_111 || chainId == 31_337,
            "DeployTestnet: unsupported chain (Base Sepolia 84532, Arb Sepolia 421614, Sepolia 11155111, local 31337)"
        );

        console.log("--- DeployTestnet ---");
        console.log("chainId      :", chainId);
        console.log("deployer     :", deployer);
        console.log("owner        :", owner);
        console.log("feeRecipient :", feeRecipient);

        vm.startBroadcast(pk);

        MockUSDC usdc = new MockUSDC();
        console.log("MockUSDC              :", address(usdc));

        address[5] memory impls;
        impls[0] = address(new Campaign());
        impls[1] = address(new CampaignToken());
        impls[2] = address(new StakingVault());
        impls[3] = address(new YieldToken());
        impls[4] = address(new HarvestManager());
        console.log("Campaign impl         :", impls[0]);
        console.log("CampaignToken impl    :", impls[1]);
        console.log("StakingVault impl     :", impls[2]);
        console.log("YieldToken impl       :", impls[3]);
        console.log("HarvestManager impl   :", impls[4]);

        CampaignFactory factoryImpl = new CampaignFactory();
        bytes memory initData =
            abi.encodeCall(CampaignFactory.initialize, (owner, feeRecipient, address(usdc), address(0), impls));
        TransparentUpgradeableProxy factoryProxy =
            new TransparentUpgradeableProxy(address(factoryImpl), owner, initData);
        console.log("CampaignFactory impl  :", address(factoryImpl));
        console.log("CampaignFactory proxy :", address(factoryProxy));

        usdc.mint(deployer, 1_000_000e6);
        console.log("Seeded                : 1_000_000 mUSDC ->", deployer);

        vm.stopBroadcast();

        console.log("--- done ---");
        console.log("Copy to frontend .env.local:");
        console.log("NEXT_PUBLIC_FACTORY_ADDRESS =", address(factoryProxy));
        console.log("NEXT_PUBLIC_USDC_ADDRESS    =", address(usdc));
    }
}
