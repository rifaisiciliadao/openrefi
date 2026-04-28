// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {CampaignFactory} from "../src/CampaignFactory.sol";
import {Campaign} from "../src/Campaign.sol";
import {CampaignToken} from "../src/CampaignToken.sol";
import {YieldToken} from "../src/YieldToken.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {HarvestManager} from "../src/HarvestManager.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {MockOracle} from "./helpers/MockOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Deployer} from "./helpers/Deployer.sol";

/// @title E2E — Full-Protocol End-to-End Lifecycle
/// @notice Simulates the entire protocol flow:
///         factory deploy → multi-investor funding (USDC fixed + WETH oracle) →
///         activation → staking multi-season → sell-back fills → harvest report
///         with real Merkle tree → product + USDC redemption → partial USDC
///         deposits with pro-rata claims → season 2 restake → final harvest.
contract E2ETest is Test {
    CampaignFactory factory;
    MockERC20 usdc;
    MockERC20 weth;
    MockOracle wethOracle;

    Campaign campaign;
    CampaignToken campaignToken;
    YieldToken yieldToken;
    StakingVault stakingVault;
    HarvestManager harvestManager;

    address protocolOwner = makeAddr("protocolOwner");
    address feeRecipient = makeAddr("feeRecipient");
    address producer = makeAddr("producer");

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");
    address dave = makeAddr("dave");
    address eve = makeAddr("eve"); // late buyer on secondary market (post-activation)

    uint256 constant PRICE_PER_TOKEN = 0.144e18; // $0.144 per $CAMPAIGN
    uint256 constant MIN_CAP = 50_000e18;
    uint256 constant MAX_CAP = 100_000e18;
    uint256 constant SEASON_DURATION = 365 days;
    uint256 constant MIN_PRODUCT_CLAIM = 5e18;

    // USDC fixed rate: 0.144 USDC (6 dec) per 1e18 $CAMPAIGN → fixedRate = 144000
    uint256 constant USDC_FIXED_RATE = 144_000;
    int256 constant WETH_USD_PRICE = 2880e8; // Chainlink 8 decimals

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped ETH", "WETH", 18);
        wethOracle = new MockOracle(WETH_USD_PRICE, 8);

        factory = Deployer.deployProtocol(protocolOwner, feeRecipient, address(usdc), address(0));

        vm.prank(producer);
        factory.createCampaign(
            CampaignFactory.CreateCampaignParams({
                producer: producer,
                tokenName: "Olive Tree",
                tokenSymbol: "OLIVE",
                yieldName: "Olive Yield",
                yieldSymbol: "oYIELD",
                pricePerToken: PRICE_PER_TOKEN,
                minCap: MIN_CAP,
                maxCap: MAX_CAP,
                fundingDeadline: block.timestamp + 90 days,
                seasonDuration: SEASON_DURATION,
                minProductClaim: MIN_PRODUCT_CLAIM,
                expectedYearlyReturnBps: 1000,
                expectedFirstYearHarvest: 1e18,
                coverageHarvests: 0
            })
        );

        (address c, address ct, address yt, address sv, address hm,,) = factory.campaigns(0);
        campaign = Campaign(c);
        campaignToken = CampaignToken(ct);
        yieldToken = YieldToken(yt);
        stakingVault = StakingVault(sv);
        harvestManager = HarvestManager(hm);

        // Producer configures both USDC (fixed) and WETH (oracle) as accepted payments
        vm.startPrank(producer);
        campaign.addAcceptedToken(address(usdc), Campaign.PricingMode.Fixed, USDC_FIXED_RATE, address(0));
        campaign.addAcceptedToken(address(weth), Campaign.PricingMode.Oracle, 0, address(wethOracle));
        vm.stopPrank();

        // Fund investors
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        usdc.mint(charlie, 100_000e6);
        usdc.mint(dave, 100_000e6);
        usdc.mint(eve, 100_000e6);
        weth.mint(bob, 100e18);

        _approveAll(alice);
        _approveAll(bob);
        _approveAll(charlie);
        _approveAll(dave);
        _approveAll(eve);
    }

    function _approveAll(address user) internal {
        vm.startPrank(user);
        usdc.approve(address(campaign), type(uint256).max);
        weth.approve(address(campaign), type(uint256).max);
        campaignToken.approve(address(stakingVault), type(uint256).max);
        campaignToken.approve(address(campaign), type(uint256).max);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Full E2E lifecycle
    // -------------------------------------------------------------------------

    function test_E2E_fullLifecycle() public {
        // ========================================================
        // PHASE 1 — FUNDING: multi-investor, multi-token purchases
        // ========================================================
        console.log("=== PHASE 1: FUNDING ===");

        // Alice buys 20k OLIVE with USDC (stays in escrow)
        uint256 alicePayUsdc = 20_000 * USDC_FIXED_RATE; // 2880e6
        vm.prank(alice);
        campaign.buy(address(usdc), alicePayUsdc);
        assertEq(campaignToken.balanceOf(alice), 20_000e18, "alice 20k");
        assertEq(uint8(campaign.state()), uint8(Campaign.State.Funding));

        // Bob buys 15k OLIVE with WETH via oracle
        // tokensOut = paymentAmount * oraclePrice / pricePerToken
        // We want 15k tokens. At WETH=$2880, 1 OLIVE=$0.144 → 0.00005 WETH per OLIVE
        // 15000 * 0.00005 = 0.75 WETH
        uint256 bobPayWeth = 0.75e18;
        vm.prank(bob);
        campaign.buy(address(weth), bobPayWeth);
        assertApproxEqRel(campaignToken.balanceOf(bob), 15_000e18, 0.0001e18, "bob ~15k");

        // Charlie pushes over min cap → auto-activation
        uint256 charliePay = 25_000 * USDC_FIXED_RATE;
        vm.prank(charlie);
        campaign.buy(address(usdc), charliePay);

        assertGt(campaign.currentSupply(), MIN_CAP, "minCap reached");
        assertEq(uint8(campaign.state()), uint8(Campaign.State.Active), "auto-activated");

        // Protocol fee was taken (2% of escrowed funds)
        uint256 feeRecipientUsdc = usdc.balanceOf(feeRecipient);
        assertGt(feeRecipientUsdc, 0, "protocol fee collected");

        // ========================================================
        // PHASE 2 — SECONDARY MARKET: post-activation, funds → producer
        // ========================================================
        console.log("=== PHASE 2: POST-ACTIVATION BUY ===");

        uint256 producerUsdcBefore = usdc.balanceOf(producer);
        uint256 davePay = 10_000 * USDC_FIXED_RATE;
        vm.prank(dave);
        campaign.buy(address(usdc), davePay);
        // Post-activation funds go to producer net of the funding fee (3%).
        uint256 daveFeeExpected = davePay * 300 / 10_000;
        assertEq(
            usdc.balanceOf(producer) - producerUsdcBefore,
            davePay - daveFeeExpected,
            "dave funds to producer net of fee"
        );
        assertEq(campaignToken.balanceOf(dave), 10_000e18);

        // ========================================================
        // PHASE 3 — SEASON 1 STAKING
        // ========================================================
        console.log("=== PHASE 3: SEASON 1 STAKING ===");

        vm.prank(producer);
        campaign.startSeason(1);

        // Alice stakes 20k (full holdings)
        vm.prank(alice);
        uint256 alicePos = stakingVault.stake(20_000e18);

        // Charlie stakes 20k of his 25k
        vm.prank(charlie);
        uint256 charliePos = stakingVault.stake(20_000e18);

        // Dave stakes 10k
        vm.prank(dave);
        uint256 davePos = stakingVault.stake(10_000e18);

        uint256 totalStaked1 = stakingVault.totalStaked();
        assertEq(totalStaked1, 50_000e18);

        // Yield rate at 50% fill = 5 - 4*0.5 = 3e18
        assertEq(stakingVault.currentYieldRate(), 3e18);

        // ========================================================
        // PHASE 4 — SELL-BACK QUEUE during active season
        // ========================================================
        console.log("=== PHASE 4: SELL-BACK FILLED BY EVE ===");

        // Bob's 15k OLIVE is unstaked → he posts 10k into sell-back queue
        vm.prank(bob);
        campaign.sellBack(10_000e18);
        assertEq(campaign.getSellBackQueueDepth(), 10_000e18);

        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        // Eve buys 5k OLIVE → should partially fill Bob's queue
        uint256 evePay = 5_000 * USDC_FIXED_RATE;
        vm.prank(eve);
        campaign.buy(address(usdc), evePay);
        assertEq(campaignToken.balanceOf(eve), 5_000e18, "eve gets 5k");
        // Bob receives the queue-fill payment NET of the 3% funding fee.
        uint256 eveFee = evePay * 300 / 10_000;
        assertEq(
            usdc.balanceOf(bob) - bobUsdcBefore,
            evePay - eveFee,
            "bob receives eve payment (net of funding fee)"
        );
        assertEq(campaign.getSellBackQueueDepth(), 5_000e18, "5k left in queue");
        assertEq(campaign.currentSupply(), 70_000e18, "supply unchanged (burn+mint net zero)");

        // Bob cancels remainder
        vm.prank(bob);
        campaign.cancelSellBack();
        assertEq(campaign.getSellBackQueueDepth(), 0);
        assertEq(campaign.pendingSellBack(bob), 0);

        // ========================================================
        // PHASE 5 — MID-SEASON YIELD CLAIM
        // ========================================================
        console.log("=== PHASE 5: MID-SEASON YIELD ===");

        vm.warp(block.timestamp + 180 days);

        uint256 aliceEarned = stakingVault.earned(alicePos);
        assertGt(aliceEarned, 0, "alice earned yield");

        vm.prank(alice);
        stakingVault.claimYield(alicePos);
        assertEq(yieldToken.balanceOf(alice), aliceEarned);

        // ========================================================
        // PHASE 6 — SEASON 1 ENDS, harvest reported with Merkle tree
        // ========================================================
        console.log("=== PHASE 6: SEASON 1 END + HARVEST ===");

        vm.warp(block.timestamp + 185 days); // full year

        // All stakers claim final yield before season end
        vm.prank(charlie);
        stakingVault.claimYield(charliePos);
        vm.prank(dave);
        stakingVault.claimYield(davePos);
        vm.prank(alice);
        stakingVault.claimYield(alicePos);

        vm.prank(producer);
        campaign.endSeason();

        // Producer reports harvest
        // Gross harvest = $20,000. Farmer keeps 30% ($6,000), holders+protocol get 70% ($14,000)
        uint256 totalValueUSD = 14_000e18;
        uint256 totalProductUnits = 2000e18; // 2000L olive oil

        // Compute each user's product entitlement based on their actual yield share.
        // productAmount = yieldHeld * totalProductUnits / totalYieldSupply
        uint256 totalYield = yieldToken.totalSupply();
        uint256 aliceY = yieldToken.balanceOf(alice);
        uint256 charlieY = yieldToken.balanceOf(charlie);
        uint256 daveY = yieldToken.balanceOf(dave);

        uint256 productAlice = aliceY * totalProductUnits / totalYield;
        uint256 productCharlie = charlieY * totalProductUnits / totalYield;
        uint256 productDave = daveY * totalProductUnits / totalYield;

        bytes32 leafA = keccak256(abi.encodePacked(alice, uint256(1), productAlice));
        bytes32 leafC = keccak256(abi.encodePacked(charlie, uint256(1), productCharlie));
        bytes32 leafD = keccak256(abi.encodePacked(dave, uint256(1), productDave));
        bytes32 leafE = keccak256(abi.encodePacked(eve, uint256(1), uint256(0)));

        bytes32 nodeAC = _hashPair(leafA, leafC);
        bytes32 nodeDE = _hashPair(leafD, leafE);
        bytes32 root = _hashPair(nodeAC, nodeDE);

        vm.prank(producer);
        harvestManager.reportHarvest(1, totalValueUSD, root, totalProductUnits);

        (, uint256 harvestValueUSD,,,,,,,, uint256 feeCollected,,) = harvestManager.seasonHarvests(1);
        assertEq(harvestValueUSD, totalValueUSD);
        assertEq(feeCollected, totalValueUSD * 200 / 10_000); // 2%

        // ========================================================
        // PHASE 7 — REDEMPTION: Alice takes product, Charlie+Dave take USDC
        // ========================================================
        console.log("=== PHASE 7: REDEMPTION ===");

        // Alice redeems product — burns all her $YIELD, gets 500L
        uint256 aliceYieldBalance = yieldToken.balanceOf(alice);
        bytes32[] memory proofA = new bytes32[](2);
        proofA[0] = leafC;
        proofA[1] = nodeDE;

        vm.prank(alice);
        harvestManager.redeemProduct(1, aliceYieldBalance, proofA);

        (bool claimedA, HarvestManager.RedemptionType typeA,,,) = harvestManager.claims(1, alice);
        assertTrue(claimedA);
        assertEq(uint8(typeA), uint8(HarvestManager.RedemptionType.Product));
        assertEq(yieldToken.balanceOf(alice), 0, "alice burned all yield");

        // Charlie redeems USDC
        uint256 charlieYield = yieldToken.balanceOf(charlie);
        vm.prank(charlie);
        harvestManager.redeemUSDC(1, charlieYield);

        (, HarvestManager.RedemptionType typeC,, uint256 charlieUsdcOwed18,) = harvestManager.claims(1, charlie);
        assertEq(uint8(typeC), uint8(HarvestManager.RedemptionType.USDC));
        assertGt(charlieUsdcOwed18, 0);

        // Dave redeems USDC
        uint256 daveYield = yieldToken.balanceOf(dave);
        vm.prank(dave);
        harvestManager.redeemUSDC(1, daveYield);

        // ========================================================
        // PHASE 8 — Producer partial USDC deposits, pro-rata claims
        // ========================================================
        console.log("=== PHASE 8: PARTIAL USDC DEPOSITS ===");

        // usdcOwed at struct index 8 (merkleRoot, totalValue, totalYieldSupply, totalProductUnits,
        //   claimStart, claimEnd, usdcDeadline, usdcDeposited, usdcOwed, protocolFeeCollected, reported)
        // Producer splits deposit in two halves — each is the cap at that point.
        uint256 firstDeposit = harvestManager.remainingDepositGross(1) / 2;
        usdc.mint(producer, firstDeposit);
        vm.startPrank(producer);
        usdc.approve(address(harvestManager), type(uint256).max);
        harvestManager.depositUSDC(1, firstDeposit);
        vm.stopPrank();

        // Charlie claims → gets ~50% of entitlement
        uint256 charlieUsdcBefore = usdc.balanceOf(charlie);
        vm.prank(charlie);
        harvestManager.claimUSDC(1);
        uint256 charlieFirstClaim = usdc.balanceOf(charlie) - charlieUsdcBefore;
        assertGt(charlieFirstClaim, 0);

        // Producer deposits the remaining gross cap.
        uint256 secondDeposit = harvestManager.remainingDepositGross(1);
        usdc.mint(producer, secondDeposit);
        vm.prank(producer);
        harvestManager.depositUSDC(1, secondDeposit);

        // Charlie claims remainder
        vm.prank(charlie);
        harvestManager.claimUSDC(1);
        uint256 charlieTotalUsdc = usdc.balanceOf(charlie) - charlieUsdcBefore;
        assertApproxEqRel(charlieTotalUsdc, charlieUsdcOwed18 / 1e12, 0.001e18);

        // Dave claims in one shot
        uint256 daveBefore = usdc.balanceOf(dave);
        vm.prank(dave);
        harvestManager.claimUSDC(1);
        assertGt(usdc.balanceOf(dave), daveBefore);

        // ========================================================
        // PHASE 9 — SEASON 2: restake, new yield accrual
        // ========================================================
        console.log("=== PHASE 9: SEASON 2 ===");

        vm.prank(producer);
        campaign.startSeason(2);

        // Charlie and Dave restake their still-active positions
        vm.prank(charlie);
        stakingVault.restake(charliePos);
        vm.prank(dave);
        stakingVault.restake(davePos);
        // Alice's position is still active (she only claimed yield, didn't unstake)
        vm.prank(alice);
        stakingVault.restake(alicePos);

        // Skip full season
        vm.warp(block.timestamp + 365 days);

        // All claim yield for season 2
        vm.prank(alice);
        stakingVault.claimYield(alicePos);
        vm.prank(charlie);
        stakingVault.claimYield(charliePos);
        vm.prank(dave);
        stakingVault.claimYield(davePos);

        assertGt(yieldToken.balanceOf(alice), 0, "season 2 yield alice");
        assertGt(yieldToken.balanceOf(charlie), 0, "season 2 yield charlie");
        assertGt(yieldToken.balanceOf(dave), 0, "season 2 yield dave");

        vm.prank(producer);
        campaign.endSeason();

        // ========================================================
        // PHASE 10 — FINAL: unstake (no penalty after full season)
        // ========================================================
        console.log("=== PHASE 10: UNSTAKE NO-PENALTY ===");

        uint256 aliceBefore = campaignToken.balanceOf(alice);
        vm.prank(alice);
        stakingVault.unstake(alicePos);
        assertEq(campaignToken.balanceOf(alice) - aliceBefore, 20_000e18, "full return after full season");

        // End campaign
        vm.prank(producer);
        campaign.endCampaign();
        assertEq(uint8(campaign.state()), uint8(Campaign.State.Ended));

        console.log("=== E2E COMPLETED ===");
    }

    // --- Merkle helper (sorted pair hash, compatible with OZ MerkleProof) ---
    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}
