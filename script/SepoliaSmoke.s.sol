// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {GrowfiCampaignFactory} from "../src/GrowfiCampaignFactory.sol";
import {GrowfiCampaign} from "../src/GrowfiCampaign.sol";
import {GrowfiToken} from "../src/GrowfiToken.sol";
import {GrowfiTreasury} from "../src/GrowfiTreasury.sol";
import {GrowfiMinter} from "../src/GrowfiMinter.sol";
import {GrowfiStakingPool} from "../src/GrowfiStakingPool.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {GrowfiCampaignRegistry} from "../src/GrowfiCampaignRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title SepoliaSmoke — single-key end-to-end demo against Base Sepolia v4 deploy.
/// @notice Deployer plays producer + alice + treasury operator. Demonstrates:
///   1. Create campaign + add mUSDC payment + register metadata
///   2. Buy → softcap → auto-activate → escrow → claim GROW
///   3. Treasury tracks + allocates → CT lands in treasury (funding bar split)
///   4. Direct GROW buy with mUSDC
///   5. Stake GROW into pool
contract SepoliaSmoke is Script {
    GrowfiCampaignFactory constant FACTORY =
        GrowfiCampaignFactory(0x2632Faf990511E9013830F96C6511C706D075317);
    MockUSDC constant USDC = MockUSDC(0xbadED9957EAa9A30bA26f787Ac31Dad4bB41b56D);
    GrowfiToken constant GROW =
        GrowfiToken(0xF1f61bf29CCeCce190427300874Dd66c417Fd84d);
    GrowfiTreasury constant TREASURY =
        GrowfiTreasury(0x3D3a76F91DaeFDd7CF08E257924aEA452042cda7);
    GrowfiMinter constant MINTER =
        GrowfiMinter(0x182627Cb46E61f59645f6d7996F16ae1f9E112Ee);
    GrowfiStakingPool constant POOL =
        GrowfiStakingPool(0x06eCa4677398fA720552272B3C4a6321c4FA072b);
    GrowfiCampaignRegistry constant REGISTRY =
        GrowfiCampaignRegistry(0x5fd7E887266F3F38d8442ad846aa1813e6679a6e);

    uint256 constant ONE_USDC = 1e6;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        console.log("smoke account :", me);

        // 1. Create campaign
        vm.startBroadcast(pk);
        GrowfiCampaignFactory.CreateCampaignParams memory params =
            GrowfiCampaignFactory.CreateCampaignParams({
                producer: me,
                tokenName: "Olive Demo Sepolia v4",
                tokenSymbol: "OLIVE",
                yieldName: "Olive Yield",
                yieldSymbol: "oYIELD",
                pricePerToken: 0.144e18,
                minCap: 347e18,           // ~$50
                maxCap: 6_944e18,         // ~$1000
                fundingDeadline: block.timestamp + 30 days,
                seasonDuration: 1 hours,
                minProductClaim: 5e18,
                expectedAnnualHarvestUsd: 1000e18,
                expectedAnnualHarvest: 50e18,
                firstHarvestYear: 2027,
                coverageHarvests: 0
            });
        address campaign = FACTORY.createCampaign(params);

        // mUSDC as fixed-rate payment token. raw rate for $0.144/token at 6 dec = 144_000.
        GrowfiCampaign(campaign).addAcceptedToken(
            address(USDC),
            GrowfiCampaign.PricingMode.Fixed,
            144_000,
            address(0)
        );

        // Register metadata so the subgraph + frontend pick the campaign up with a name.
        REGISTRY.setMetadata(
            campaign,
            "https://growfi-media.fra1.digitaloceanspaces.com/metadata/sepolia-olive-demo.json"
        );
        vm.stopBroadcast();
        console.log("campaign      :", campaign);

        // 2. Owner: track campaign + enable automation
        vm.startBroadcast(pk);
        FACTORY.addGrowfiTreasuryTrackedCampaign(campaign);
        FACTORY.setGrowfiTreasuryAutomationEnabled(true);
        vm.stopBroadcast();

        // 3. Buy $60 worth → softcap reached → auto-active → escrow lands → claim
        vm.startBroadcast(pk);
        USDC.mint(me, 200 * ONE_USDC);
        USDC.approve(campaign, 200 * ONE_USDC);
        GrowfiCampaign(campaign).buy(address(USDC), 60 * ONE_USDC);
        uint256 escrow = MINTER.getEscrow(campaign, me);
        uint256 claimed = MINTER.claimEscrow(campaign);
        vm.stopBroadcast();
        console.log("escrow lined  :", escrow);
        console.log("claimed       :", claimed);

        // 4. Treasury tracks + allocates: seed $50, allocate $30
        vm.startBroadcast(pk);
        USDC.mint(address(TREASURY), 50 * ONE_USDC);
        FACTORY.allocateAcrossTrackedGrowfiTreasury(address(USDC), 30 * ONE_USDC);
        vm.stopBroadcast();
        console.log(
            "treasury CT   :",
            IERC20(GrowfiCampaign(campaign).campaignToken()).balanceOf(address(TREASURY))
        );

        // 5. Direct buy GROW with $25 mUSDC
        vm.startBroadcast(pk);
        USDC.approve(address(GROW), 25 * ONE_USDC);
        uint256 growOut = GROW.buy(address(USDC), 25 * ONE_USDC, type(uint256).max);
        vm.stopBroadcast();
        console.log("direct GROW   :", growOut);

        // 6. Stake 100 GROW in pool
        vm.startBroadcast(pk);
        GROW.approve(address(POOL), 100e18);
        POOL.stake(100e18);
        vm.stopBroadcast();
        console.log("staked GROW   : 100e18");

        console.log("");
        console.log("=== final state ===");
        console.log("supply        :", GrowfiCampaign(campaign).currentSupply());
        console.log("state         :", uint8(GrowfiCampaign(campaign).state()));
        console.log("floor (USD18) :", TREASURY.intrinsicFloorPrice());
        console.log("my GROW       :", GROW.balanceOf(me));
        console.log("staked        :", POOL.balanceOf(me));
    }
}
