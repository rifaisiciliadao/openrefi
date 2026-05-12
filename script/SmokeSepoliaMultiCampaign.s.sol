// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GrowfiCampaignFactory} from "../src/GrowfiCampaignFactory.sol";
import {GrowfiCampaign} from "../src/GrowfiCampaign.sol";
import {GrowfiCampaignToken} from "../src/GrowfiCampaignToken.sol";
import {IGrowfiCampaignFull} from "../src/interfaces/IGrowfiCampaignFull.sol";
import {SaleClassicModule} from "../src/modules/SaleClassicModule.sol";
import {CollateralModule} from "../src/modules/CollateralModule.sol";
import {GrowfiToken} from "../src/GrowfiToken.sol";
import {GrowfiTreasury} from "../src/GrowfiTreasury.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @title SmokeSepoliaMultiCampaign
/// @notice Spawns the standard 2-campaign demo set on Sepolia ETH:
///         - "Olive Sicily" (OLIVE) @ $0.144/CT, 350k maxCap, 7-day season
///         - "Vineyard of Etna" (ETNA) @ $0.10/CT, 500k maxCap, 7-day season
///         Producer self-buys $60 on each to cross softcap → auto-activate.
///         Both tracked in the GROW Treasury, automation ON.
///         Then a $100 USDC direct GROW buy via Token.buy fires the
///         allocateAcrossTracked hook, spreading the funds.
contract SmokeSepoliaMultiCampaign is Script {
    function run() public {
        require(block.chainid == 11_155_111, "Sepolia only");

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        GrowfiCampaignFactory factory = GrowfiCampaignFactory(vm.envAddress("FACTORY_ADDRESS"));
        MockUSDC usdc = MockUSDC(vm.envAddress("USDC_ADDRESS"));
        GrowfiToken growToken = GrowfiToken(vm.envAddress("GROW_TOKEN"));
        GrowfiTreasury treasury = GrowfiTreasury(vm.envAddress("GROW_TREASURY"));

        vm.startBroadcast(deployerPk);

        // Mint plenty of mUSDC to the deployer for seeding
        usdc.mint(deployer, 100_000e6);

        // ------------------------------------------------------------------
        // Campaign 1: Olive Sicily
        // ------------------------------------------------------------------
        address olive = factory.createCampaign(
            GrowfiCampaignFactory.CreateCampaignParams({
                producer: deployer,
                campaignTokenName: "Olive Sicily",
                campaignTokenSymbol: "OLIVE",
                yieldTokenName: "Olive Yield",
                yieldTokenSymbol: "oYIELD",
                minProductClaim: 1e18,
                sale: SaleClassicModule.InitParams({
                    pricePerToken: 0.144e18, // $0.144 USD per CT
                    minCap: 100e18, // 100 CT softcap
                    maxCap: 350_000e18,
                    fundingDeadline: block.timestamp + 30 days,
                    seasonDuration: 1 hours,
                    fundingFeeBps: 0, // factory overrides to 300
                    sequencerUptimeFeed: address(0),
                    growMinter: address(0) // factory wires growMinter at create
                }),
                collateral: CollateralModule.InitParams({
                    expectedAnnualHarvestUsd: 5_000e18,
                    expectedAnnualHarvest: 250e18,
                    firstHarvestYear: 2030,
                    coverageHarvests: 0
                })
            })
        );
        IGrowfiCampaignFull oliveC = IGrowfiCampaignFull(payable(olive));
        oliveC.addAcceptedToken(address(usdc), SaleClassicModule.PricingMode.Fixed, 144_000, address(0));

        // Self-buy $60: 60/0.144 = 416.66 CT → above 100 minCap → auto-activate
        usdc.approve(olive, type(uint256).max);
        oliveC.buy(address(usdc), 60e6);
        oliveC.startSeason();

        // ------------------------------------------------------------------
        // Campaign 2: Vineyard of Etna
        // ------------------------------------------------------------------
        address etna = factory.createCampaign(
            GrowfiCampaignFactory.CreateCampaignParams({
                producer: deployer,
                campaignTokenName: "Vineyard of Etna",
                campaignTokenSymbol: "ETNA",
                yieldTokenName: "Etna Yield",
                yieldTokenSymbol: "eYIELD",
                minProductClaim: 1e18,
                sale: SaleClassicModule.InitParams({
                    pricePerToken: 0.10e18,
                    minCap: 100e18,
                    maxCap: 500_000e18,
                    fundingDeadline: block.timestamp + 30 days,
                    seasonDuration: 1 hours,
                    fundingFeeBps: 0,
                    sequencerUptimeFeed: address(0),
                    growMinter: address(0)
                }),
                collateral: CollateralModule.InitParams({
                    expectedAnnualHarvestUsd: 8_000e18,
                    expectedAnnualHarvest: 1_000e18,
                    firstHarvestYear: 2030,
                    coverageHarvests: 0
                })
            })
        );
        IGrowfiCampaignFull etnaC = IGrowfiCampaignFull(payable(etna));
        etnaC.addAcceptedToken(address(usdc), SaleClassicModule.PricingMode.Fixed, 100_000, address(0));

        usdc.approve(etna, type(uint256).max);
        etnaC.buy(address(usdc), 60e6); // 60/0.10 = 600 CT > 100 minCap
        etnaC.startSeason();

        // ------------------------------------------------------------------
        // Treasury: track both campaigns, enable automation
        // ------------------------------------------------------------------
        factory.addGrowfiTreasuryTrackedCampaign(olive);
        factory.addGrowfiTreasuryTrackedCampaign(etna);
        // automationEnabled already true from DeployGrowSepolia
        require(treasury.automationEnabled(), "automation should be on");

        // ------------------------------------------------------------------
        // Direct GROW buy: $100 USDC via Token.buy → auto-allocateAcrossTracked
        // spreads the USDC across the 2 tracked Active campaigns.
        // ------------------------------------------------------------------
        usdc.approve(address(growToken), type(uint256).max);
        // slippage cap = type(uint256).max for smoke (no guard)
        growToken.buy(address(usdc), 100e6, type(uint256).max);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Sepolia ETH smoke seed complete ===");
        console.log("Olive Sicily campaign:    ", olive);
        console.log("Vineyard of Etna campaign:", etna);
        console.log("");
        console.log("Olive state:", uint8(oliveC.state()), "(2=Active)");
        console.log("Olive currentSupply:", oliveC.currentSupply());
        console.log("Olive currentSeasonId:", oliveC.currentSeasonId());
        console.log("");
        console.log("Etna state:", uint8(etnaC.state()), "(2=Active)");
        console.log("Etna currentSupply:", etnaC.currentSupply());
        console.log("Etna currentSeasonId:", etnaC.currentSeasonId());
        console.log("");
        console.log("Treasury tracked count:", treasury.trackedCampaignsLength());
        console.log("Treasury automation:", treasury.automationEnabled());
        console.log("Treasury intrinsicFloor:", treasury.intrinsicFloorPrice());
        console.log("Deployer GROW balance:", IERC20(address(growToken)).balanceOf(deployer));
        console.log("Olive CT held by Treasury:");
        console.log("  ", IERC20(oliveC.campaignToken()).balanceOf(address(treasury)));
        console.log("Etna CT held by Treasury:");
        console.log("  ", IERC20(etnaC.campaignToken()).balanceOf(address(treasury)));
    }
}
