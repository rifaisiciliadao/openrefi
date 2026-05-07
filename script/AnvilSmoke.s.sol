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
import {MockStablecoin} from "../src/mocks/MockStablecoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title AnvilSmoke — end-to-end demo flow against the local anvil deploy.
/// @notice Reproduces the producer + 2 backers + Treasury + GROW staker happy path.
///         Pinned to the addresses written to platform/frontend/.env.local by DeployTestnet.
///
/// Steps:
///   1. PRODUCER (Account 1) creates an olive campaign (price $0.144, min $50, max $1000)
///   2. PRODUCER whitelists mUSDC as a payment token on the campaign
///   3. OWNER (Account 0) tracks the campaign in the Treasury + enables automation
///   4. ALICE (Account 2) mints 200 mUSDC, buys $60 worth → softcap reached → auto-activate
///   5. ALICE claims her escrowed GROW (now Active)
///   6. BOB   (Account 3) mints 100 mUSDC, buys $40 worth (post-softcap → direct GROW mint)
///   7. OWNER seeds Treasury with $50 mUSDC, runs `allocateAcrossTracked($30)` → treasury buys CT
///   8. ALICE direct-buys GROW with $25 mUSDC at floor + 10% markup
///   9. ALICE stakes 100 GROW into the staking pool
///
/// Run:
///   forge script script/AnvilSmoke.s.sol:AnvilSmoke --rpc-url http://127.0.0.1:8545 \
///     --broadcast --skip-simulation --slow
contract AnvilSmoke is Script {
    // Pinned addresses from the previous DeployTestnet run on chainId 31337.
    GrowfiCampaignFactory constant FACTORY =
        GrowfiCampaignFactory(0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0);
    MockUSDC constant USDC = MockUSDC(0x5FbDB2315678afecb367f032d93F642f64180aa3);
    GrowfiToken constant GROW =
        GrowfiToken(0x0B306BF915C4d645ff596e518fAf3F9669b97016);
    GrowfiTreasury constant TREASURY =
        GrowfiTreasury(0x9A9f2CCfdE556A7E9Ff0848998Aa4a0CFD8863AE);
    GrowfiMinter constant MINTER =
        GrowfiMinter(0x3Aa5ebB10DC797CAC828524e59A333d0A371443c);
    GrowfiStakingPool constant POOL =
        GrowfiStakingPool(0x322813Fd9A801c5507c9de605d63CEA4f2CE6c44);

    // Anvil default accounts (mnemonic = "test test test test test test test test test test test junk")
    uint256 constant PK_OWNER = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant PK_PRODUCER = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant PK_ALICE = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 constant PK_BOB = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;

    uint256 constant ONE_USDC = 1e6;

    function run() external {
        address owner = vm.addr(PK_OWNER);
        address producer = vm.addr(PK_PRODUCER);
        address alice = vm.addr(PK_ALICE);
        address bob = vm.addr(PK_BOB);

        console.log("--- AnvilSmoke ---");
        console.log("owner    :", owner);
        console.log("producer :", producer);
        console.log("alice    :", alice);
        console.log("bob      :", bob);

        // 1. PRODUCER creates campaign
        vm.startBroadcast(PK_PRODUCER);
        GrowfiCampaignFactory.CreateCampaignParams memory params =
            GrowfiCampaignFactory.CreateCampaignParams({
                producer: producer,
                tokenName: "Olive Sicily Demo",
                tokenSymbol: "OLIVE",
                yieldName: "Olive Yield",
                yieldSymbol: "oYIELD",
                pricePerToken: 0.144e18, // $0.144
                minCap: 347e18,           // ~$50  -> 50 / 0.144 = 347.22 tokens
                maxCap: 6_944e18,         // ~$1000 -> 1000 / 0.144 = 6944.44 tokens
                fundingDeadline: block.timestamp + 30 days,
                seasonDuration: 1 hours,
                minProductClaim: 5e18,
                expectedAnnualHarvestUsd: 1000e18,
                expectedAnnualHarvest: 50e18,
                firstHarvestYear: 2027,
                coverageHarvests: 0
            });
        address campaign = FACTORY.createCampaign(params);

        // 2. Whitelist mUSDC on the campaign (fixed-rate, $0.144/token = 144000 raw / token-18)
        // For a 6-dec stable: rate = pricePerToken * 10^(decimals_of_token) / 1e18
        //                          = 0.144e18 * 1e6 / 1e18 = 144_000 (raw 6-dec / token-18)
        GrowfiCampaign(campaign).addAcceptedToken(
            address(USDC),
            GrowfiCampaign.PricingMode.Fixed,
            144_000,            // raw rate (1 token = $0.144 → 144000 raw mUSDC)
            address(0)          // no oracle
        );
        vm.stopBroadcast();
        console.log("campaign :", campaign);

        // 3. OWNER tracks campaign + enables automation
        vm.startBroadcast(PK_OWNER);
        FACTORY.addGrowfiTreasuryTrackedCampaign(campaign);
        FACTORY.setGrowfiTreasuryAutomationEnabled(true);
        vm.stopBroadcast();

        // 4. ALICE buys $60 (advances past $50 softcap → auto-activate + escrow becomes claimable)
        vm.startBroadcast(PK_ALICE);
        USDC.mint(alice, 200 * ONE_USDC);
        USDC.approve(campaign, 200 * ONE_USDC);
        GrowfiCampaign(campaign).buy(address(USDC), 60 * ONE_USDC);
        vm.stopBroadcast();
        console.log("alice escrow before claim:", MINTER.getEscrow(campaign, alice));

        // 5. ALICE claims her escrowed GROW
        vm.startBroadcast(PK_ALICE);
        uint256 claimed = MINTER.claimEscrow(campaign);
        vm.stopBroadcast();
        console.log("alice claimed escrow     :", claimed);
        console.log("alice GROW balance       :", GROW.balanceOf(alice));

        // 6. BOB buys $40 post-softcap → GROW directly minted, no escrow
        vm.startBroadcast(PK_BOB);
        USDC.mint(bob, 100 * ONE_USDC);
        USDC.approve(campaign, 100 * ONE_USDC);
        GrowfiCampaign(campaign).buy(address(USDC), 40 * ONE_USDC);
        vm.stopBroadcast();
        console.log("bob GROW balance         :", GROW.balanceOf(bob));

        // 7. OWNER seeds Treasury with $50 USDC and runs cross-tracked allocation ($30 budget)
        vm.startBroadcast(PK_OWNER);
        USDC.mint(address(TREASURY), 50 * ONE_USDC);
        FACTORY.allocateAcrossTrackedGrowfiTreasury(address(USDC), 30 * ONE_USDC);
        vm.stopBroadcast();
        console.log("treasuryRaised reflected by CT balance:");
        console.log(
            "  treasury holds CT:",
            IERC20(GrowfiCampaign(campaign).campaignToken()).balanceOf(address(TREASURY))
        );

        // 8. ALICE direct-buys GROW for $25 USDC (uses live floor, +10% markup)
        vm.startBroadcast(PK_ALICE);
        USDC.approve(address(GROW), 25 * ONE_USDC);
        uint256 growOut = GROW.buy(address(USDC), 25 * ONE_USDC, type(uint256).max);
        vm.stopBroadcast();
        console.log("alice direct-bought GROW :", growOut);

        // 9. ALICE stakes 100 GROW into the pool
        vm.startBroadcast(PK_ALICE);
        GROW.approve(address(POOL), 100e18);
        POOL.stake(100e18);
        vm.stopBroadcast();
        console.log("alice staked GROW        : 100e18");

        console.log("");
        console.log("=== final state ===");
        console.log("campaign currentSupply :", GrowfiCampaign(campaign).currentSupply());
        console.log("campaign state         :", uint8(GrowfiCampaign(campaign).state()));
        console.log("Treasury holds USDC    :", USDC.balanceOf(address(TREASURY)));
        console.log("intrinsicFloorPrice    :", TREASURY.intrinsicFloorPrice());
        console.log("alice GROW total       :", GROW.balanceOf(alice));
        console.log("alice staked GROW      :", POOL.balanceOf(alice));
        console.log("bob   GROW total       :", GROW.balanceOf(bob));
    }
}
