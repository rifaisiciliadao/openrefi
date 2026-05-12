// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {GrowfiCampaignFactory} from "../src/GrowfiCampaignFactory.sol";
import {GrowfiToken} from "../src/GrowfiToken.sol";
import {GrowfiTreasury} from "../src/GrowfiTreasury.sol";
import {GrowfiMinter} from "../src/GrowfiMinter.sol";
import {GrowfiFeeSplitter} from "../src/GrowfiFeeSplitter.sol";
import {GrowfiStakingPool} from "../src/GrowfiStakingPool.sol";
import {MockOracle} from "../test/helpers/MockOracle.sol";

/// @title DeployGrowSepolia
/// @notice Deploys the GROW system (Token, Treasury, Minter, FeeSplitter,
///         StakingPool) on Ethereum Sepolia and wires it into the
///         existing factory deployed by DeployTestnetSepolia.s.sol.
///
///         After this script:
///         - GROW Minter hook fires on every campaign buy (SaleClassicModule
///           reads `factory.growMinter` and reports buy volume)
///         - Treasury auto-allocation fires on every direct GROW buy
///         - FeeSplitter receives campaign protocol fees (factory.protocolFeeRecipient)
///         - GROW stakers earn USDC rewards via Treasury.claimUsdcAndDistribute
///
///         Run:
///           PRIVATE_KEY=0x...
///           FACTORY_ADDRESS=0x...        (from DeployTestnetSepolia)
///           USDC_ADDRESS=0x...           (from DeployTestnetSepolia)
///           forge script script/DeployGrowSepolia.s.sol \
///             --rpc-url $SEPOLIA_RPC_URL --broadcast --slow
contract DeployGrowSepolia is Script {
    // Genesis allocation: 0 to deployer (no dilution), 100k to Treasury reserve
    uint256 internal constant GENESIS_DEPLOYER = 0;
    uint256 internal constant GENESIS_TREASURY = 100_000e18;
    // GROW initial direct-buy reference price: $0.10 (USD-18)
    uint256 internal constant BOOT_PRICE = 1e17;
    // Markup over floor: 10% (1000 bps)
    uint256 internal constant MARKUP_BPS = 1_000;
    // FeeSplitter: 30% to Treasury, 70% to Ops
    uint256 internal constant TREASURY_BPS = 3_000;
    // GROW staker rewards: 80% to stakers, 20% retained in Treasury
    // (Treasury.stakerRewardBps is "amount kept", so 2000 = 20% retained)
    // Default in contract is 80% to stakers — keep it.

    function run() public {
        require(block.chainid == 11_155_111, "Sepolia only");

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address factoryAddr = vm.envAddress("FACTORY_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address ops = vm.envOr("OPS_ADDRESS", deployer);

        GrowfiCampaignFactory factory = GrowfiCampaignFactory(factoryAddr);
        require(factory.owner() == deployer, "Deployer must own factory");

        vm.startBroadcast(deployerPk);

        // 1. Mock USD/USDC oracle: pegged to $1, 8 decimals (Chainlink shape)
        MockOracle usdFeed = new MockOracle(int256(1e8), 8);

        // 2. GrowfiToken (TUP) — genesis 0 to deployer, 100k mintable later to Treasury
        GrowfiToken tImpl = new GrowfiToken();
        bytes memory tInit = abi.encodeCall(
            GrowfiToken.initialize,
            ("GrowFi", "GROW", factoryAddr, deployer, GENESIS_DEPLOYER, MARKUP_BPS, BOOT_PRICE)
        );
        GrowfiToken growToken = GrowfiToken(
            address(new TransparentUpgradeableProxy(address(tImpl), deployer, tInit))
        );

        // 3. GrowfiTreasury (TUP)
        GrowfiTreasury trImpl = new GrowfiTreasury();
        bytes memory trInit = abi.encodeCall(GrowfiTreasury.initialize, (factoryAddr, address(growToken)));
        GrowfiTreasury growTreasury = GrowfiTreasury(
            address(new TransparentUpgradeableProxy(address(trImpl), deployer, trInit))
        );

        // 4. GrowfiMinter (TUP) — default 3-tier bonding curve
        GrowfiMinter mImpl = new GrowfiMinter();
        GrowfiMinter.BondingCurveParams memory curve = GrowfiMinter.BondingCurveParams({
            tier1RateBps: 10_000, // 1.0x for cumulative buys up to softcap
            tier2RateBps: 7_000, //  0.7x for next 50% of (maxcap - softcap)
            tier3RateBps: 4_000, //  0.4x beyond
            tier2to3ThresholdBps: 5_000
        });
        bytes memory mInit = abi.encodeCall(GrowfiMinter.initialize, (factoryAddr, address(growToken), curve));
        GrowfiMinter growMinter = GrowfiMinter(
            address(new TransparentUpgradeableProxy(address(mImpl), deployer, mInit))
        );

        // 5. GrowfiFeeSplitter (TUP) — 30% Treasury / 70% Ops
        GrowfiFeeSplitter fsImpl = new GrowfiFeeSplitter();
        bytes memory fsInit = abi.encodeCall(
            GrowfiFeeSplitter.initialize, (factoryAddr, address(growTreasury), ops, TREASURY_BPS)
        );
        GrowfiFeeSplitter feeSplitter = GrowfiFeeSplitter(
            address(new TransparentUpgradeableProxy(address(fsImpl), deployer, fsInit))
        );

        // 6. GrowfiStakingPool (TUP)
        GrowfiStakingPool spImpl = new GrowfiStakingPool();
        bytes memory spInit = abi.encodeCall(
            GrowfiStakingPool.initialize, (factoryAddr, address(growToken), usdc, address(growTreasury))
        );
        GrowfiStakingPool stakingPool = GrowfiStakingPool(
            address(new TransparentUpgradeableProxy(address(spImpl), deployer, spInit))
        );

        // 7. Wire factory <-> GROW + redirect protocolFeeRecipient -> feeSplitter
        factory.setGrowfiContracts(
            address(growToken), address(growMinter), address(growTreasury), address(feeSplitter)
        );
        factory.setProtocolFeeRecipient(address(feeSplitter));

        // 8. Wire GROW token <-> minter + treasury (via factory forwarders)
        factory.setGrowfiTokenMinter(address(growMinter));
        factory.setGrowfiTokenTreasury(address(growTreasury));

        // 9. Add MockUSDC as accepted stablecoin in the Treasury
        //    (scale 1e12: 6-dec -> 18-dec normalisation, $1 feed, 24h heartbeat,
        //     5% depeg band)
        factory.addGrowfiTreasuryStablecoin(
            usdc, 1e12, address(usdFeed), 24 hours, 9_500, 10_500
        );

        // 10. Treasury StakingPool wiring + automation
        factory.setGrowfiTreasuryStakingPool(address(stakingPool));
        factory.setGrowfiTreasuryAutomationEnabled(true);

        // 11. Treasury excluded from earning GROW on its own buys (avoid recursion)
        factory.setGrowfiMinterExcluded(address(growTreasury), true);

        // 12. Mint treasury genesis reserve (100k GROW, sits in Treasury — excluded
        //     from circulating, so doesn't dilute floor)
        factory.mintGrowfiTokenTreasuryGenesis(GENESIS_TREASURY);

        vm.stopBroadcast();

        console.log("");
        console.log("=== GROW system on Ethereum Sepolia ===");
        console.log("GrowfiToken:        ", address(growToken));
        console.log("GrowfiTreasury:     ", address(growTreasury));
        console.log("GrowfiMinter:       ", address(growMinter));
        console.log("GrowfiFeeSplitter:  ", address(feeSplitter));
        console.log("GrowfiStakingPool:  ", address(stakingPool));
        console.log("MockOracle USD/USDC:", address(usdFeed));
        console.log("");
        console.log("Frontend env (append to .env.sepolia.local):");
        console.log("  NEXT_PUBLIC_GROW_TOKEN=", address(growToken));
        console.log("  NEXT_PUBLIC_GROW_TREASURY=", address(growTreasury));
        console.log("  NEXT_PUBLIC_GROW_MINTER=", address(growMinter));
        console.log("  NEXT_PUBLIC_GROW_FEE_SPLITTER=", address(feeSplitter));
        console.log("  NEXT_PUBLIC_GROW_STAKING_POOL=", address(stakingPool));
        console.log("");
        console.log("Subgraph: add the GROW dataSources back, point at addresses above,");
        console.log("set startBlock to current block, bump version, redeploy.");
        console.log("Current block:", block.number);
    }
}
