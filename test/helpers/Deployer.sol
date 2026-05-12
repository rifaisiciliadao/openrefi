// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {GrowfiCampaignFactory} from "../../src/GrowfiCampaignFactory.sol";
import {GrowfiCampaign} from "../../src/GrowfiCampaign.sol";
import {GrowfiCampaignToken} from "../../src/GrowfiCampaignToken.sol";
import {GrowfiStakingVault} from "../../src/GrowfiStakingVault.sol";
import {GrowfiYieldToken} from "../../src/GrowfiYieldToken.sol";
import {GrowfiHarvestManager} from "../../src/GrowfiHarvestManager.sol";

import {ModuleRegistry} from "../../src/host/ModuleRegistry.sol";
import {SaleClassicModule} from "../../src/modules/SaleClassicModule.sol";
import {CollateralModule} from "../../src/modules/CollateralModule.sol";

import {SaleClassicHelper} from "../modules/SaleClassicHelper.sol";
import {CollateralHelper} from "../modules/CollateralHelper.sol";

/// @title Deployer — shared protocol bootstrap used by every test suite
/// @notice Drop-in compatible with the pre-v4 signature
///         `deployProtocol(owner, feeRecipient, usdc, seqFeed)`.
///         Internally deploys the v4 stack:
///           - 5 satellite implementations (Campaign host, CampaignToken,
///             StakingVault, YieldToken, HarvestManager) once
///           - 2 module implementations (SaleClassic + Collateral) once
///           - The factory proxy initialized with the v3-compat 5-arg
///             initializer, then seeded with the module whitelist + the
///             default modules so every subsequent `createCampaign` call
///             auto-injects them.
library Deployer {
    bytes32 internal constant TYPE_SALE = keccak256("growfi.type.sale");
    bytes32 internal constant TYPE_COLLATERAL = keccak256("growfi.type.collateral");

    function deployProtocol(address owner, address feeRecipient, address usdc, address seqFeed)
        internal
        returns (GrowfiCampaignFactory factory)
    {
        address[5] memory impls;
        impls[0] = address(new GrowfiCampaign());
        impls[1] = address(new GrowfiCampaignToken());
        impls[2] = address(new GrowfiStakingVault());
        impls[3] = address(new GrowfiYieldToken());
        impls[4] = address(new GrowfiHarvestManager());

        GrowfiCampaignFactory factoryImpl = new GrowfiCampaignFactory();
        bytes memory initData =
            abi.encodeCall(GrowfiCampaignFactory.initialize, (owner, feeRecipient, usdc, seqFeed, impls));
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(factoryImpl), owner, initData);
        factory = GrowfiCampaignFactory(address(proxy));

        // Seed the module whitelist + default modules so every new
        // campaign auto-attaches the sale + collateral modules.
        address saleImpl_ = address(new SaleClassicModule());
        address collateralImpl_ = address(new CollateralModule());

        bytes32 saleKind = factory.KIND_SALE_CLASSIC_V1();
        bytes32 collateralKind = factory.KIND_COLLATERAL_V1();

        vm_prankOwner(owner);
        factory.setModuleKindSelectors(saleKind, SaleClassicHelper.selectors());
        factory.approveModuleImpl(saleKind, saleImpl_, true);
        factory.setModuleKindSelectors(collateralKind, CollateralHelper.selectors());
        factory.approveModuleImpl(collateralKind, collateralImpl_, true);

        ModuleRegistry.DefaultModule[] memory defaults = new ModuleRegistry.DefaultModule[](2);
        defaults[0] = ModuleRegistry.DefaultModule({
            moduleType: TYPE_SALE,
            kind: saleKind,
            impl: saleImpl_,
            metadataURI: ""
        });
        defaults[1] = ModuleRegistry.DefaultModule({
            moduleType: TYPE_COLLATERAL,
            kind: collateralKind,
            impl: collateralImpl_,
            metadataURI: ""
        });
        factory.setDefaultModules(defaults);
        vm_stopPrank();
    }

    // --- vm cheats (no forge-std import in a library; use raw cheat address) ---

    address private constant VM = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D;

    function vm_prankOwner(address owner) internal {
        (bool ok,) = VM.call(abi.encodeWithSignature("startPrank(address)", owner));
        require(ok, "vm.startPrank failed");
    }

    function vm_stopPrank() internal {
        (bool ok,) = VM.call(abi.encodeWithSignature("stopPrank()"));
        require(ok, "vm.stopPrank failed");
    }
}
