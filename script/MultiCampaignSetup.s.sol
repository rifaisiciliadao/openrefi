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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Sets up two demo campaigns + tracks + automation + a couple of buys + a direct
///         GROW buy to demo the auto-alloc hook spreading USDC equally across both.
///
/// Deploy addresses are pinned to the v6 (2026-05-07) Sepolia deploy with 100k Treasury reserve.
contract MultiCampaignSetup is Script {
    GrowfiCampaignFactory constant FACTORY =
        GrowfiCampaignFactory(0x5d43e9B1835afDcb4c88f712e80D730B7890B31b);
    MockUSDC constant USDC = MockUSDC(0x57Fd40Bd9607CEb85B2c6c01C2ac34b8A0DcE66C);
    GrowfiToken constant GROW =
        GrowfiToken(0x6432D463B2264Bb8fD56DEC6bB119473c1e2b7B3);
    GrowfiTreasury constant TREASURY =
        GrowfiTreasury(0xC188324847dB525574A6FD26AD3A0B8f96421674);
    GrowfiMinter constant MINTER =
        GrowfiMinter(0xd11AcDAE626ffF50cf0BcB5C19D094a78feC7289);
    GrowfiStakingPool constant POOL =
        GrowfiStakingPool(0x605664f5861543656e4bfDb912C627025280b1Ee);

    uint256 constant ONE_USDC = 1e6;

    function _create(
        address producer,
        string memory name,
        string memory symbol,
        string memory yieldName,
        string memory yieldSymbol,
        uint256 price18,
        uint256 minCap18,
        uint256 maxCap18,
        uint256 expectedAnnualHarvestUsd18,
        uint256 expectedAnnualHarvestQty18,
        uint256 firstHarvestYear
    ) internal returns (address) {
        GrowfiCampaignFactory.CreateCampaignParams memory p =
            GrowfiCampaignFactory.CreateCampaignParams({
                producer: producer,
                tokenName: name,
                tokenSymbol: symbol,
                yieldName: yieldName,
                yieldSymbol: yieldSymbol,
                pricePerToken: price18,
                minCap: minCap18,
                maxCap: maxCap18,
                fundingDeadline: block.timestamp + 30 days,
                seasonDuration: 1 hours,
                minProductClaim: 1e18,
                expectedAnnualHarvestUsd: expectedAnnualHarvestUsd18,
                expectedAnnualHarvest: expectedAnnualHarvestQty18,
                firstHarvestYear: firstHarvestYear,
                coverageHarvests: 0
            });
        return FACTORY.createCampaign(p);
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        console.log("operator :", me);

        // ---------- Campaign A: Olive Sicily ----------
        vm.startBroadcast(pk);
        address campA = _create(
            me,
            "Olive IGP Sicily",
            "OLIVE",
            "Olive Yield",
            "oOIL",
            0.144e18,         // $0.144/token
            347e18,           // softcap ~$50
            6_944e18,         // hardcap ~$1000
            5_000e18,         // $5,000/yr commitment
            250e18,           // 250 L oil/yr → $20/L
            2027
        );
        // Whitelist mUSDC (Fixed): rate raw = 0.144e18 * 1e6 / 1e18 = 144_000
        GrowfiCampaign(campA).addAcceptedToken(
            address(USDC), GrowfiCampaign.PricingMode.Fixed, 144_000, address(0)
        );
        vm.stopBroadcast();
        console.log("campaign A:", campA, "Olive IGP Sicily");

        // ---------- Campaign B: Vineyard Etna ----------
        vm.startBroadcast(pk);
        address campB = _create(
            me,
            "Vineyard of Etna",
            "VINE",
            "Vineyard Yield",
            "oVINE",
            0.10e18,          // $0.10/token
            500e18,           // softcap = $50
            10_000e18,        // hardcap = $1000
            3_000e18,         // $3,000/yr
            1_500e18,         // 1500 bottles/yr → $2/bottle
            2028
        );
        GrowfiCampaign(campB).addAcceptedToken(
            address(USDC), GrowfiCampaign.PricingMode.Fixed, 100_000, address(0)
        );
        vm.stopBroadcast();
        console.log("campaign B:", campB, "Vineyard of Etna");

        // ---------- Mint payment + activate both past softcap ----------
        vm.startBroadcast(pk);
        USDC.mint(me, 500 * ONE_USDC);
        USDC.approve(campA, 200 * ONE_USDC);
        USDC.approve(campB, 200 * ONE_USDC);
        // $60 into each → past softcap → Active. Producer == buyer here, so the producer's
        // own funds bootstrap the campaign. On a real deploy a third party does the buys.
        GrowfiCampaign(campA).buy(address(USDC), 60 * ONE_USDC);
        GrowfiCampaign(campB).buy(address(USDC), 60 * ONE_USDC);
        vm.stopBroadcast();
        console.log("Both Active. supplies (A,B):");
        console.log("  A:", GrowfiCampaign(campA).currentSupply());
        console.log("  B:", GrowfiCampaign(campB).currentSupply());

        // ---------- Track + automation ON ----------
        vm.startBroadcast(pk);
        FACTORY.addGrowfiTreasuryTrackedCampaign(campA);
        FACTORY.addGrowfiTreasuryTrackedCampaign(campB);
        FACTORY.setGrowfiTreasuryAutomationEnabled(true);
        vm.stopBroadcast();
        console.log("tracked + automation ON");

        // ---------- Direct GROW buy → auto-alloc spreads to both ----------
        // Operator pays 100 mUSDC. Hook auto-fires allocateAcrossTracked($100).
        // perCampaign = $50, so each campaign receives ~$50 of CT into Treasury.
        vm.startBroadcast(pk);
        USDC.approve(address(GROW), 100 * ONE_USDC);
        uint256 growOut = GROW.buy(address(USDC), 100 * ONE_USDC, type(uint256).max);
        vm.stopBroadcast();
        console.log("direct GROW out :", growOut);

        IERC20 ctA = IERC20(GrowfiCampaign(campA).campaignToken());
        IERC20 ctB = IERC20(GrowfiCampaign(campB).campaignToken());
        console.log("treasury holds CT_A :", ctA.balanceOf(address(TREASURY)));
        console.log("treasury holds CT_B :", ctB.balanceOf(address(TREASURY)));
        console.log("treasury USDC left  :", USDC.balanceOf(address(TREASURY)));
        console.log("treasury floor (USD18):", TREASURY.intrinsicFloorPrice());
    }
}
