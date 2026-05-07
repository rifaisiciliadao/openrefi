// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {GrowfiCampaignFactory} from "../src/GrowfiCampaignFactory.sol";
import {GrowfiCampaign} from "../src/GrowfiCampaign.sol";
import {GrowfiCampaignToken} from "../src/GrowfiCampaignToken.sol";
import {GrowfiStakingVault} from "../src/GrowfiStakingVault.sol";
import {GrowfiYieldToken} from "../src/GrowfiYieldToken.sol";
import {GrowfiHarvestManager} from "../src/GrowfiHarvestManager.sol";
import {GrowfiToken} from "../src/GrowfiToken.sol";
import {GrowfiTreasury} from "../src/GrowfiTreasury.sol";
import {GrowfiMinter} from "../src/GrowfiMinter.sol";
import {GrowfiFeeSplitter} from "../src/GrowfiFeeSplitter.sol";
import {GrowfiStakingPool} from "../src/GrowfiStakingPool.sol";

/// @title Deploy -- production deployment (Arbitrum / Base / mainnet)
/// @notice Deploys: 5 campaign impls + factory + 4 GROW contracts, then wires everything.
///         Real USDC is passed in via env. Multisig MUST be set as OWNER for production.
///
/// Env vars:
///   OWNER_ADDRESS               -- factory owner (multisig)
///   USDC_ADDRESS                -- canonical USDC for collateral (chain-specific)
///   USDC_PRICE_FEED             -- Chainlink USDC/USD feed (e.g. 0x7e8...6B on Base)
///   SEQUENCER_UPTIME_FEED       -- Chainlink sequencer feed; address(0) on L1
///   OPS_ADDRESS                 -- operations multisig (70% of fees)
///   GENESIS_RECIPIENT           -- where the 1M GROW genesis lands
/// Additional stablecoins (USDT, DAI, ...) must be whitelisted post-deploy by the multisig
/// via factory.addGrowfiTreasuryStablecoin(token, scale, feed, heartbeat, minBps, maxBps).
contract DeployScript is Script {
    function run() external {
        address owner = vm.envAddress("OWNER_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address usdcFeed = vm.envAddress("USDC_PRICE_FEED");
        address ops = vm.envAddress("OPS_ADDRESS");
        address genesisRecipient = vm.envAddress("GENESIS_RECIPIENT");
        address sequencerUptimeFeed = vm.envOr("SEQUENCER_UPTIME_FEED", address(0));

        require(owner != address(0), "OWNER_ADDRESS required");
        require(usdc != address(0), "USDC_ADDRESS required");
        require(usdcFeed != address(0), "USDC_PRICE_FEED required");
        require(ops != address(0), "OPS_ADDRESS required");
        require(genesisRecipient != address(0), "GENESIS_RECIPIENT required");

        vm.startBroadcast();

        // -------- 1. Campaign implementations + factory --------
        address[5] memory impls;
        impls[0] = address(new GrowfiCampaign());
        impls[1] = address(new GrowfiCampaignToken());
        impls[2] = address(new GrowfiStakingVault());
        impls[3] = address(new GrowfiYieldToken());
        impls[4] = address(new GrowfiHarvestManager());

        GrowfiCampaignFactory factoryImpl = new GrowfiCampaignFactory();
        // protocolFeeRecipient is set to owner here as a placeholder; it gets pointed
        // at the FeeSplitter once the splitter is deployed (step 6 below).
        bytes memory factoryInit =
            abi.encodeCall(GrowfiCampaignFactory.initialize, (owner, owner, usdc, sequencerUptimeFeed, impls));
        TransparentUpgradeableProxy factoryProxy =
            new TransparentUpgradeableProxy(address(factoryImpl), owner, factoryInit);
        GrowfiCampaignFactory factory = GrowfiCampaignFactory(address(factoryProxy));

        // -------- 2. GrowfiToken (genesis to GENESIS_RECIPIENT) --------
        GrowfiToken tImpl = new GrowfiToken();
        bytes memory tInit = abi.encodeCall(
            GrowfiToken.initialize,
            (
                "GrowFi",
                "GROW",
                address(factory),
                genesisRecipient,
                1_000_000e18, // 1M GROW
                1_000, // markup 10%
                1e17 // reference price boot $0.10
            )
        );
        GrowfiToken growToken = GrowfiToken(address(new TransparentUpgradeableProxy(address(tImpl), owner, tInit)));

        // -------- 3. GrowfiTreasury --------
        GrowfiTreasury trImpl = new GrowfiTreasury();
        bytes memory trInit = abi.encodeCall(GrowfiTreasury.initialize, (address(factory), address(growToken)));
        GrowfiTreasury treasury =
            GrowfiTreasury(address(new TransparentUpgradeableProxy(address(trImpl), owner, trInit)));

        // -------- 4. GrowfiMinter --------
        GrowfiMinter mImpl = new GrowfiMinter();
        GrowfiMinter.BondingCurveParams memory params = GrowfiMinter.BondingCurveParams({
            tier1RateBps: 10_000,
            tier2RateBps: 7_000,
            tier3RateBps: 4_000,
            tier2to3ThresholdBps: 5_000
        });
        bytes memory mInit = abi.encodeCall(GrowfiMinter.initialize, (address(factory), address(growToken), params));
        GrowfiMinter minter = GrowfiMinter(address(new TransparentUpgradeableProxy(address(mImpl), owner, mInit)));

        // -------- 5. GrowfiFeeSplitter (30/70) --------
        GrowfiFeeSplitter fsImpl = new GrowfiFeeSplitter();
        bytes memory fsInit =
            abi.encodeCall(GrowfiFeeSplitter.initialize, (address(factory), address(treasury), ops, 3_000));
        GrowfiFeeSplitter splitter =
            GrowfiFeeSplitter(address(new TransparentUpgradeableProxy(address(fsImpl), owner, fsInit)));

        // -------- 6. GrowfiStakingPool (stake GROW, earn USDC) --------
        GrowfiStakingPool spImpl = new GrowfiStakingPool();
        bytes memory spInit = abi.encodeCall(
            GrowfiStakingPool.initialize, (address(factory), address(growToken), usdc, address(treasury))
        );
        GrowfiStakingPool stakingPool =
            GrowfiStakingPool(address(new TransparentUpgradeableProxy(address(spImpl), owner, spInit)));

        // -------- 7. Wiring (only if deployer == owner; otherwise multisig must do this) --------
        if (msg.sender == owner) {
            factory.setGrowfiContracts(address(growToken), address(minter), address(treasury), address(splitter));
            factory.setProtocolFeeRecipient(address(splitter));
            factory.setGrowfiTokenMinter(address(minter));
            factory.setGrowfiTokenTreasury(address(treasury));
            // canonical USDC (6-dec); 24h heartbeat + $0.95-$1.05 depeg bands
            factory.addGrowfiTreasuryStablecoin(usdc, 1e12, usdcFeed, 24 hours, 9_500, 10_500);
            factory.setGrowfiMinterExcluded(address(treasury), true);
            factory.setGrowfiTreasuryStakingPool(address(stakingPool));
        }

        vm.stopBroadcast();

        // -------- Output --------
        console.log("Factory proxy        :", address(factory));
        console.log("Factory impl         :", address(factoryImpl));
        console.log("Campaign impl        :", impls[0]);
        console.log("CampaignToken impl   :", impls[1]);
        console.log("StakingVault impl    :", impls[2]);
        console.log("YieldToken impl      :", impls[3]);
        console.log("HarvestManager impl  :", impls[4]);
        console.log("GrowfiToken          :", address(growToken));
        console.log("GrowfiTreasury       :", address(treasury));
        console.log("GrowfiMinter         :", address(minter));
        console.log("FeeSplitter          :", address(splitter));
        console.log("StakingPool          :", address(stakingPool));
        console.log("");
        console.log("Owner (factory)      :", owner);
        console.log("Operations           :", ops);
        console.log("Genesis recipient    :", genesisRecipient);
        console.log("USDC                 :", usdc);
        console.log("Sequencer feed       :", sequencerUptimeFeed);

        if (msg.sender != owner) {
            console.log("");
            console.log("WARN: deployer != owner -- multisig must run wiring manually:");
            console.log("  factory.setGrowfiContracts(token, minter, treasury, splitter)");
            console.log("  factory.setProtocolFeeRecipient(splitter)");
            console.log("  factory.setGrowfiTokenMinter(minter)");
            console.log("  factory.setGrowfiTokenTreasury(treasury)");
            console.log("  factory.addGrowfiTreasuryStablecoin(usdc, 1e12)");
            console.log("  factory.setGrowfiMinterExcluded(treasury, true)");
            console.log("  factory.setGrowfiTreasuryStakingPool(stakingPool)");
            console.log("  (+ any additional stablecoins via addGrowfiTreasuryStablecoin)");
        }
    }
}
