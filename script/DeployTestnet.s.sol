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
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockStablecoin} from "../src/mocks/MockStablecoin.sol";
import {MockChainlinkFeed} from "../src/mocks/MockChainlinkFeed.sol";

/// @title DeployTestnet -- full stack on Base Sepolia / Arbitrum Sepolia
/// @notice Deploys: 3 mock stablecoins (mUSDC, mUSDT, mDAI), 5 campaign impls, factory,
///         GROW system (Token + Treasury + Minter + FeeSplitter), wires everything,
///         seeds the allowlist, and mints test stablecoins to the deployer.
///
/// Usage:
///   PRIVATE_KEY=0x... forge script script/DeployTestnet.s.sol \
///     --rpc-url https://sepolia.base.org --broadcast
///
/// Env vars:
///   PRIVATE_KEY        -- deployer key (also genesis recipient + factory owner default)
///   OWNER_ADDRESS      -- factory owner (multisig). Defaults to deployer.
///   OPS_ADDRESS        -- operations multisig (70% of fees). Defaults to deployer.
///
/// Constants chosen here:
///   - Genesis: 100,000 GROW to Treasury (excluded from circulating, released by multisig)
///   - Markup: 10% (1000 bps)
///   - Reference price bootstrap: $0.10 per GROW (1e17)
///   - Bonding curve: 1.0x / 0.7x / 0.4x with tier 2-3 split at 50% of (maxCap-softCap)
///   - Fee splitter: 30% to Treasury, 70% to Operations
///   - Treasury allowlist: mUSDC, mUSDT, mDAI all enabled at deploy
contract DeployTestnet is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address owner = vm.envOr("OWNER_ADDRESS", deployer);
        address ops = vm.envOr("OPS_ADDRESS", deployer);

        uint256 chainId = block.chainid;
        require(
            chainId == 84_532 || chainId == 421_614 || chainId == 11_155_111 || chainId == 31_337,
            "DeployTestnet: unsupported chain"
        );

        console.log("--- DeployTestnet ---");
        console.log("chainId        :", chainId);
        console.log("deployer       :", deployer);
        console.log("owner          :", owner);
        console.log("ops            :", ops);

        vm.startBroadcast(pk);

        // -------- 1. Mock stablecoins (canonical USDC + USDT + DAI) --------
        MockUSDC usdc = new MockUSDC();
        MockStablecoin usdt = new MockStablecoin("Mock Tether USD", "mUSDT", 6);
        MockStablecoin dai = new MockStablecoin("Mock Dai", "mDAI", 18);
        console.log("mUSDC          :", address(usdc));
        console.log("mUSDT          :", address(usdt));
        console.log("mDAI           :", address(dai));

        // -------- 1b. Mock Chainlink USD price feeds (8-dec, $1 each) --------
        // Real Chainlink feeds on Base mainnet:
        //   USDC/USD: 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B
        //   USDT/USD: 0xf19d560eB8d2ADf07BD6D13ed03e1D11215721F9
        //   DAI/USD : 0x591e79239a7d679378eC8c847e5038150364C78F
        // On testnet we deploy mocks so smokes can simulate a depeg with feed.setPrice(...).
        MockChainlinkFeed usdcFeed = new MockChainlinkFeed(int256(1e8), 8);
        MockChainlinkFeed usdtFeed = new MockChainlinkFeed(int256(1e8), 8);
        MockChainlinkFeed daiFeed = new MockChainlinkFeed(int256(1e8), 8);
        console.log("mUSDC feed     :", address(usdcFeed));
        console.log("mUSDT feed     :", address(usdtFeed));
        console.log("mDAI  feed     :", address(daiFeed));

        // -------- 2. Campaign implementations + factory --------
        address[5] memory impls;
        impls[0] = address(new GrowfiCampaign());
        impls[1] = address(new GrowfiCampaignToken());
        impls[2] = address(new GrowfiStakingVault());
        impls[3] = address(new GrowfiYieldToken());
        impls[4] = address(new GrowfiHarvestManager());

        GrowfiCampaignFactory factoryImpl = new GrowfiCampaignFactory();
        // Initialize with `address(usdc)` as canonical USDC (used for collateral on
        // per-campaign contracts). protocolFeeRecipient gets pointed to the FeeSplitter
        // after that contract is deployed (step 6 below).
        bytes memory factoryInit = abi.encodeCall(
            GrowfiCampaignFactory.initialize, (owner, deployer /* placeholder feeRecipient */, address(usdc), address(0), impls)
        );
        TransparentUpgradeableProxy factoryProxy =
            new TransparentUpgradeableProxy(address(factoryImpl), owner, factoryInit);
        GrowfiCampaignFactory factory = GrowfiCampaignFactory(address(factoryProxy));
        console.log("Factory proxy  :", address(factory));

        // Relax season floor so testnet smokes work in minutes rather than days.
        if (deployer == owner) {
            factory.setMinSeasonDuration(1 hours);
        }

        // -------- 3. GrowfiToken (genesis = 0; the 100k team reserve is minted later
        //            into the Treasury via factory.mintGrowfiTokenTreasuryGenesis,
        //            keeping it OUT of the floor's circulating divisor) --------
        GrowfiToken tImpl = new GrowfiToken();
        bytes memory tInit = abi.encodeCall(
            GrowfiToken.initialize,
            (
                "GrowFi",
                "GROW",
                address(factory),
                deployer, // recipient is unused when amount == 0; pass deployer to satisfy the non-zero check
                0,        // no deployer-side genesis
                1_000, // markup 10%
                1e17 // reference $0.10
            )
        );
        GrowfiToken growToken = GrowfiToken(address(new TransparentUpgradeableProxy(address(tImpl), owner, tInit)));
        console.log("GrowfiToken    :", address(growToken));

        // -------- 4. GrowfiTreasury --------
        GrowfiTreasury trImpl = new GrowfiTreasury();
        bytes memory trInit = abi.encodeCall(GrowfiTreasury.initialize, (address(factory), address(growToken)));
        GrowfiTreasury treasury =
            GrowfiTreasury(address(new TransparentUpgradeableProxy(address(trImpl), owner, trInit)));
        console.log("GrowfiTreasury :", address(treasury));

        // -------- 5. GrowfiMinter (default 3-tier curve) --------
        GrowfiMinter mImpl = new GrowfiMinter();
        GrowfiMinter.BondingCurveParams memory params = GrowfiMinter.BondingCurveParams({
            tier1RateBps: 10_000, // 1.0x
            tier2RateBps: 7_000, // 0.7x
            tier3RateBps: 4_000, // 0.4x
            tier2to3ThresholdBps: 5_000 // 50% of (maxCap - softCap)
        });
        bytes memory mInit = abi.encodeCall(GrowfiMinter.initialize, (address(factory), address(growToken), params));
        GrowfiMinter minter = GrowfiMinter(address(new TransparentUpgradeableProxy(address(mImpl), owner, mInit)));
        console.log("GrowfiMinter   :", address(minter));

        // -------- 6. GrowfiFeeSplitter (30/70 split) --------
        GrowfiFeeSplitter fsImpl = new GrowfiFeeSplitter();
        bytes memory fsInit =
            abi.encodeCall(GrowfiFeeSplitter.initialize, (address(factory), address(treasury), ops, 3_000));
        GrowfiFeeSplitter splitter =
            GrowfiFeeSplitter(address(new TransparentUpgradeableProxy(address(fsImpl), owner, fsInit)));
        console.log("FeeSplitter    :", address(splitter));

        // -------- 7. GrowfiStakingPool (stake GROW, earn USDC) --------
        GrowfiStakingPool spImpl = new GrowfiStakingPool();
        bytes memory spInit = abi.encodeCall(
            GrowfiStakingPool.initialize, (address(factory), address(growToken), address(usdc), address(treasury))
        );
        GrowfiStakingPool stakingPool =
            GrowfiStakingPool(address(new TransparentUpgradeableProxy(address(spImpl), owner, spInit)));
        console.log("StakingPool    :", address(stakingPool));

        // -------- 8. Wire factory <-> GROW + redirect protocolFeeRecipient -> splitter --------
        if (deployer == owner) {
            factory.setGrowfiContracts(address(growToken), address(minter), address(treasury), address(splitter));
            factory.setProtocolFeeRecipient(address(splitter));

            // Wire token's minter + treasury via factory forwarding setters.
            factory.setGrowfiTokenMinter(address(minter));
            factory.setGrowfiTokenTreasury(address(treasury));

            // Mint the team / DAO reserve allocation directly into the Treasury.
            // Excluded from circulating in the floor calc, so DOES NOT dilute the floor.
            // Released later by the multisig via factory.releaseGrowFromTreasury.
            factory.mintGrowfiTokenTreasuryGenesis(100_000e18);

            // Allowlist mUSDC, mUSDT, mDAI in Treasury, each with its mock USD feed.
            // Bands: 9500/10500 = $0.95-$1.05 trip wire. Heartbeat: 24h (Chainlink's typical
            // for stablecoin/USD pairs on mainnet).
            factory.addGrowfiTreasuryStablecoin(address(usdc), 1e12, address(usdcFeed), 24 hours, 9_500, 10_500);
            factory.addGrowfiTreasuryStablecoin(address(usdt), 1e12, address(usdtFeed), 24 hours, 9_500, 10_500);
            factory.addGrowfiTreasuryStablecoin(address(dai),  1,    address(daiFeed),  24 hours, 9_500, 10_500);

            // Exclude Treasury from earning GROW on its own auto-allocations.
            factory.setGrowfiMinterExcluded(address(treasury), true);

            // Wire StakingPool into Treasury so harvest USDC flows 80% to stakers, 20% retained.
            factory.setGrowfiTreasuryStakingPool(address(stakingPool));
        } else {
            console.log("");
            console.log("WARN: deployer != owner -- manual multisig wiring required:");
            console.log("  factory.setGrowfiContracts(token, minter, treasury, splitter)");
            console.log("  factory.setProtocolFeeRecipient(splitter)");
            console.log("  factory.setGrowfiTokenMinter(minter)");
            console.log("  factory.setGrowfiTokenTreasury(treasury)");
            console.log("  factory.mintGrowfiTokenTreasuryGenesis(100_000e18)");
            console.log("  factory.addGrowfiTreasuryStablecoin(usdc, 1e12, usdcFeed, 86400, 9500, 10500)");
            console.log("  factory.addGrowfiTreasuryStablecoin(usdt, 1e12, usdtFeed, 86400, 9500, 10500)");
            console.log("  factory.addGrowfiTreasuryStablecoin(dai,  1,    daiFeed,  86400, 9500, 10500)");
            console.log("  factory.setGrowfiMinterExcluded(treasury, true)");
            console.log("  factory.setGrowfiTreasuryStakingPool(stakingPool)");
        }

        // -------- 9. Seed deployer with test stablecoins --------
        usdc.mint(deployer, 1_000_000e6);
        usdt.mint(deployer, 1_000_000e6);
        dai.mint(deployer, 1_000_000e18);
        console.log("Seeded         : 1M each of mUSDC/mUSDT/mDAI -> deployer");

        vm.stopBroadcast();

        console.log("");
        console.log("--- frontend .env.local ---");
        console.log("NEXT_PUBLIC_FACTORY_ADDRESS  =", address(factory));
        console.log("NEXT_PUBLIC_USDC_ADDRESS     =", address(usdc));
        console.log("NEXT_PUBLIC_GROW_TOKEN       =", address(growToken));
        console.log("NEXT_PUBLIC_GROW_TREASURY    =", address(treasury));
        console.log("NEXT_PUBLIC_GROW_MINTER      =", address(minter));
        console.log("NEXT_PUBLIC_FEE_SPLITTER     =", address(splitter));
        console.log("NEXT_PUBLIC_STAKING_POOL     =", address(stakingPool));
        console.log("");
        console.log("--- additional stablecoins ---");
        console.log("mUSDT (6-dec)                :", address(usdt));
        console.log("mDAI  (18-dec)               :", address(dai));
        console.log("");
        console.log("Genesis recipient            :", deployer);
        console.log("Genesis amount               : 1,000,000 GROW");
        console.log("Reference price (boot)       : 1e17 (= $0.10)");
        console.log("Markup                       : 1000 bps (10%)");
        console.log("Fee split                    : 30% Treasury / 70% Operations");
    }
}
