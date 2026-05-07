// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {GrowfiCampaignFactory} from "../../src/GrowfiCampaignFactory.sol";
import {GrowfiCampaign} from "../../src/GrowfiCampaign.sol";
import {GrowfiCampaignToken} from "../../src/GrowfiCampaignToken.sol";
import {GrowfiStakingVault} from "../../src/GrowfiStakingVault.sol";
import {GrowfiYieldToken} from "../../src/GrowfiYieldToken.sol";
import {GrowfiHarvestManager} from "../../src/GrowfiHarvestManager.sol";

/// @title Deployer — shared protocol bootstrap used by every test suite
/// @notice Deploys:
///           - 5 core implementations (GrowfiCampaign, GrowfiCampaignToken, GrowfiStakingVault,
///             GrowfiYieldToken, GrowfiHarvestManager) once.
///           - GrowfiCampaignFactory implementation + a TransparentUpgradeableProxy
///             pointing at it, initialized with (owner, feeRecipient, usdc, seq, impls).
///         Returns the GrowfiCampaignFactory interface wrapping the proxy address.
library Deployer {
    /// @param owner        Factory owner (controls impl swaps + emergency pause).
    /// @param feeRecipient Immutable-per-campaign fee sink.
    /// @param usdc         USDC address.
    /// @param seqFeed      Chainlink L2 sequencer-uptime feed (address(0) on L1/testnet).
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
        address[5] memory implsArr = impls;
        bytes memory initData =
            abi.encodeCall(GrowfiCampaignFactory.initialize, (owner, feeRecipient, usdc, seqFeed, implsArr));
        // Transparent proxy auto-deploys a ProxyAdmin owned by `owner`.
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(factoryImpl), owner, initData);
        factory = GrowfiCampaignFactory(address(proxy));
    }
}
