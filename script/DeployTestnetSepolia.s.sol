// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {GrowfiCampaignFactory} from "../src/GrowfiCampaignFactory.sol";
import {GrowfiCampaign} from "../src/GrowfiCampaign.sol";
import {GrowfiCampaignToken} from "../src/GrowfiCampaignToken.sol";
import {GrowfiStakingVault} from "../src/GrowfiStakingVault.sol";
import {GrowfiYieldToken} from "../src/GrowfiYieldToken.sol";
import {GrowfiHarvestManager} from "../src/GrowfiHarvestManager.sol";
import {GrowfiCampaignRegistry} from "../src/GrowfiCampaignRegistry.sol";
import {GrowfiProducerRegistry} from "../src/GrowfiProducerRegistry.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

import {ModuleRegistry} from "../src/host/ModuleRegistry.sol";
import {SaleClassicModule} from "../src/modules/SaleClassicModule.sol";
import {CollateralModule} from "../src/modules/CollateralModule.sol";
import {RepaymentModule} from "../src/modules/RepaymentModule.sol";

import {SaleClassicHelper} from "../test/modules/SaleClassicHelper.sol";
import {CollateralHelper} from "../test/modules/CollateralHelper.sol";
import {RepaymentHelper} from "../test/modules/RepaymentHelper.sol";

/// @title DeployTestnetSepolia
/// @notice Fresh v4 deploy targeted at Ethereum Sepolia (chain id 11155111).
///         Deploys MockUSDC + the factory + 5 satellite impls + 3 module
///         impls (Sale, Collateral, Repayment) + 2 registries.
///         Repayment is whitelisted but NOT added to defaults — producers
///         attach it post-create.
///
///         Run:
///           PRIVATE_KEY=0x...
///           forge script script/DeployTestnetSepolia.s.sol \
///             --rpc-url $SEPOLIA_RPC_URL \
///             --broadcast \
///             --verify --etherscan-api-key $ETHERSCAN_API_KEY
contract DeployTestnetSepolia is Script {
    bytes32 internal constant TYPE_SALE = keccak256("growfi.type.sale");
    bytes32 internal constant TYPE_COLLATERAL = keccak256("growfi.type.collateral");
    bytes32 internal constant KIND_REPAYMENT = keccak256("growfi.repayment.v1");

    function run() public {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address feeRecipient = vm.envOr("FEE_RECIPIENT", deployer);
        // Sepolia ETH = L1, no sequencer-uptime feed
        address sequencerFeed = address(0);

        require(block.chainid == 11_155_111, "Wrong chain - Sepolia only");

        vm.startBroadcast(deployerPk);

        // 1. MockUSDC (testnet only, public mint)
        MockUSDC usdc = new MockUSDC();
        usdc.mint(deployer, 10_000_000e6);

        // 2. Five satellite implementations
        address[5] memory impls;
        impls[0] = address(new GrowfiCampaign());
        impls[1] = address(new GrowfiCampaignToken());
        impls[2] = address(new GrowfiStakingVault());
        impls[3] = address(new GrowfiYieldToken());
        impls[4] = address(new GrowfiHarvestManager());

        // 3. Factory impl + proxy
        GrowfiCampaignFactory factoryImpl = new GrowfiCampaignFactory();
        bytes memory factoryInit = abi.encodeCall(
            GrowfiCampaignFactory.initialize,
            (deployer, feeRecipient, address(usdc), sequencerFeed, impls)
        );
        TransparentUpgradeableProxy factoryProxy =
            new TransparentUpgradeableProxy(address(factoryImpl), deployer, factoryInit);
        GrowfiCampaignFactory factory = GrowfiCampaignFactory(address(factoryProxy));

        // 4. Module impls
        address saleImpl = address(new SaleClassicModule());
        address collateralImpl = address(new CollateralModule());
        address repaymentImpl = address(new RepaymentModule());

        // 5. Register module kinds + approve impls + set defaults
        bytes32 saleKind = factory.KIND_SALE_CLASSIC_V1();
        bytes32 collateralKind = factory.KIND_COLLATERAL_V1();

        factory.setModuleKindSelectors(saleKind, SaleClassicHelper.selectors());
        factory.approveModuleImpl(saleKind, saleImpl, true);

        factory.setModuleKindSelectors(collateralKind, CollateralHelper.selectors());
        factory.approveModuleImpl(collateralKind, collateralImpl, true);

        factory.setModuleKindSelectors(KIND_REPAYMENT, RepaymentHelper.selectors());
        factory.approveModuleImpl(KIND_REPAYMENT, repaymentImpl, true);

        ModuleRegistry.DefaultModule[] memory defaults = new ModuleRegistry.DefaultModule[](2);
        defaults[0] = ModuleRegistry.DefaultModule({
            moduleType: TYPE_SALE, kind: saleKind, impl: saleImpl, metadataURI: ""
        });
        defaults[1] = ModuleRegistry.DefaultModule({
            moduleType: TYPE_COLLATERAL, kind: collateralKind, impl: collateralImpl, metadataURI: ""
        });
        factory.setDefaultModules(defaults);

        // 6. Relax season floor for testnet smoke
        factory.setMinSeasonDuration(1 hours);

        // 7. Registries (standalone, not upgradeable)
        GrowfiCampaignRegistry campaignRegistry = new GrowfiCampaignRegistry(factory);
        GrowfiProducerRegistry producerRegistry = new GrowfiProducerRegistry(deployer);

        vm.stopBroadcast();

        // Output (copy into .env / CONTRACTS.md / frontend / subgraph)
        console.log("");
        console.log("=== Ethereum Sepolia v4 deploy ===");
        console.log("Chain id:                  ", block.chainid);
        console.log("Deployer:                  ", deployer);
        console.log("Fee recipient:             ", feeRecipient);
        console.log("");
        console.log("MockUSDC:                  ", address(usdc));
        console.log("Factory proxy:             ", address(factory));
        console.log("Factory impl:              ", address(factoryImpl));
        console.log("Campaign impl:             ", impls[0]);
        console.log("CampaignToken impl:        ", impls[1]);
        console.log("StakingVault impl:         ", impls[2]);
        console.log("YieldToken impl:           ", impls[3]);
        console.log("HarvestManager impl:       ", impls[4]);
        console.log("SaleClassic module impl:   ", saleImpl);
        console.log("Collateral module impl:    ", collateralImpl);
        console.log("Repayment module impl:     ", repaymentImpl);
        console.log("CampaignRegistry:          ", address(campaignRegistry));
        console.log("ProducerRegistry:          ", address(producerRegistry));
        console.log("");
        console.log("Frontend env:");
        console.log("  NEXT_PUBLIC_CHAIN_ID=11155111");
        console.log("  NEXT_PUBLIC_FACTORY_ADDRESS=", address(factory));
        console.log("  NEXT_PUBLIC_USDC_ADDRESS=", address(usdc));
        console.log("  NEXT_PUBLIC_REGISTRY_ADDRESS=", address(campaignRegistry));
        console.log("  NEXT_PUBLIC_PRODUCER_REGISTRY_ADDRESS=", address(producerRegistry));
        console.log("");
        console.log("Subgraph yaml - replace base-sepolia with sepolia and update:");
        console.log("  CampaignFactory.address:  ", address(factory));
        console.log("  CampaignRegistry.address: ", address(campaignRegistry));
        console.log("  ProducerRegistry.address: ", address(producerRegistry));
        console.log("  startBlock:               ", block.number);
    }
}
