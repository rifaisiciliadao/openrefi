// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {CampaignFactory} from "../../src/CampaignFactory.sol";
import {Campaign} from "../../src/Campaign.sol";
import {CampaignToken} from "../../src/CampaignToken.sol";
import {StakingVault} from "../../src/StakingVault.sol";
import {YieldToken} from "../../src/YieldToken.sol";
import {HarvestManager} from "../../src/HarvestManager.sol";

/// @title Deployer — shared protocol bootstrap used by every test suite
/// @notice Deploys:
///           - 5 core implementations (Campaign, CampaignToken, StakingVault,
///             YieldToken, HarvestManager) once.
///           - CampaignFactory implementation + a TransparentUpgradeableProxy
///             pointing at it, initialized with (owner, feeRecipient, usdc, seq, impls).
///         Returns the CampaignFactory interface wrapping the proxy address.
library Deployer {
    /// @param owner        Factory owner (controls impl swaps + emergency pause).
    /// @param feeRecipient Immutable-per-campaign fee sink.
    /// @param usdc         USDC address.
    /// @param seqFeed      Chainlink L2 sequencer-uptime feed (address(0) on L1/testnet).
    function deployProtocol(address owner, address feeRecipient, address usdc, address seqFeed)
        internal
        returns (CampaignFactory factory)
    {
        address[5] memory impls;
        impls[0] = address(new Campaign());
        impls[1] = address(new CampaignToken());
        impls[2] = address(new StakingVault());
        impls[3] = address(new YieldToken());
        impls[4] = address(new HarvestManager());

        CampaignFactory factoryImpl = new CampaignFactory();
        address[5] memory implsArr = impls;
        bytes memory initData = abi.encodeCall(
            CampaignFactory.initialize, (owner, feeRecipient, usdc, seqFeed, implsArr)
        );
        // Transparent proxy auto-deploys a ProxyAdmin owned by `owner`.
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(factoryImpl), owner, initData);
        factory = CampaignFactory(address(proxy));
    }
}
