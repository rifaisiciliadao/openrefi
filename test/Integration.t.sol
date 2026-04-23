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
import {Deployer} from "./helpers/Deployer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract IntegrationTest is Test {
    CampaignFactory factory;
    MockERC20 usdc;
    MockERC20 weth;
    MockOracle wethOracle;

    address owner = address(this);
    address producer = makeAddr("producer");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    // Campaign contracts (set after creation)
    Campaign campaign;
    CampaignToken campaignToken;
    YieldToken yieldToken;
    StakingVault stakingVault;
    HarvestManager harvestManager;

    // Campaign params
    uint256 constant PRICE_PER_TOKEN = 0.144e18; // $0.144
    uint256 constant MIN_CAP = 50_000e18;
    uint256 constant MAX_CAP = 100_000e18;
    uint256 constant SEASON_DURATION = 365 days;
    uint256 constant MIN_PRODUCT_CLAIM = 5e18; // 5 liters

    function setUp() public {
        // Deploy mocks
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped ETH", "WETH", 18);
        wethOracle = new MockOracle(2880e8, 8); // WETH = $2880, 8 decimals (Chainlink standard)

        // Deploy factory
        factory = Deployer.deployProtocol(owner, feeRecipient, address(usdc), address(0));

        // Create campaign
        uint256 deadline = block.timestamp + 90 days;
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
                fundingDeadline: deadline,
                seasonDuration: SEASON_DURATION,
                minProductClaim: MIN_PRODUCT_CLAIM
            })
        );

        // Get contract references
        (address c, address ct, address yt, address sv, address hm,,) = factory.campaigns(0);
        campaign = Campaign(c);
        campaignToken = CampaignToken(ct);
        yieldToken = YieldToken(yt);
        stakingVault = StakingVault(sv);
        harvestManager = HarvestManager(hm);

        // Producer adds USDC as accepted payment (fixed rate)
        // fixedRate = 0.144e6 USDC per 1 $CAMPAIGN (since USDC has 6 decimals)
        // But our contract uses 18 decimal fixedRate. Let's use: 0.144e18 means 0.144 tokens of payment per 1 $CAMPAIGN
        // For USDC (6 decimals): 0.144 USDC = 144000 units. fixedRate = 144000 * 1e18 / 1e18 = 144000
        // Actually: tokensOut = paymentAmount * 1e18 / fixedRate
        // We want: 144000 USDC units (0.144 USDC) → 1e18 $CAMPAIGN
        // So: 1e18 = 144000 * 1e18 / fixedRate → fixedRate = 144000 = 0.144e6
        // For 6-decimal USDC: fixedRate = 0.144 * 1e6 = 144000
        // But we need 18 decimal precision: fixedRate = 144000 (raw USDC units per 1e18 $CAMPAIGN)
        // Let's simplify: fixedRate in payment token units (with its own decimals) per 1 $CAMPAIGN (1e18)
        vm.prank(producer);
        campaign.addAcceptedToken(address(usdc), Campaign.PricingMode.Fixed, 144000, address(0)); // 0.144 USDC per token

        // Mint USDC to buyers
        usdc.mint(alice, 100_000e6); // 100k USDC
        usdc.mint(bob, 100_000e6);

        // Approve
        vm.prank(alice);
        usdc.approve(address(campaign), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(campaign), type(uint256).max);
    }

    // --- Full Lifecycle Test ---

    function test_fullLifecycle() public {
        // 1. FUNDING: Alice buys 60,000 tokens (above min cap → auto-activates)
        // 60,000 $CAMPAIGN * 0.144 USDC = 8,640 USDC = 8,640,000,000 USDC units (6 decimals)
        // paymentAmount = 60000e18 * 144000 / 1e18 = 60000 * 144000 = 8,640,000,000
        uint256 alicePayment = 8_640_000_000; // 8640 USDC (6 decimals)
        vm.prank(alice);
        campaign.buy(address(usdc), alicePayment);

        // Should auto-activate since 60k > 50k min cap
        assertEq(uint8(campaign.state()), uint8(Campaign.State.Active));
        assertEq(campaignToken.balanceOf(alice), 60_000e18);

        // 2. STAKING: Alice stakes her tokens
        vm.prank(alice);
        campaignToken.approve(address(stakingVault), type(uint256).max);

        // Start season first (via campaign)
        vm.prank(producer);
        campaign.startSeason(1);

        vm.prank(alice);
        uint256 posId = stakingVault.stake(60_000e18);
        assertEq(posId, 0);
        assertEq(stakingVault.totalStaked(), 60_000e18);

        // 3. TIME PASSES: 6 months
        vm.warp(block.timestamp + 180 days);

        // 4. Bob buys 20,000 tokens
        uint256 bobPayment = 2_880_000_000; // 2880 USDC
        vm.prank(bob);
        campaign.buy(address(usdc), bobPayment);
        assertEq(campaignToken.balanceOf(bob), 20_000e18);

        // 5. Alice claims yield after 6 months
        uint256 aliceYield = stakingVault.earned(posId);
        assertGt(aliceYield, 0, "Alice should have earned yield");

        vm.prank(alice);
        stakingVault.claimYield(posId);
        assertGt(yieldToken.balanceOf(alice), 0, "Alice should have $YIELD");

        // 6. Full season passes
        vm.warp(block.timestamp + 185 days);

        // End season
        vm.prank(producer);
        campaign.endSeason();

        // 7. Claim remaining yield
        vm.prank(alice);
        stakingVault.claimYield(posId);
        uint256 aliceTotalYield = yieldToken.balanceOf(alice);
        assertGt(aliceTotalYield, 0);
    }

    // --- Buyback Test (Failed Campaign) ---

    function test_buybackOnFailedCampaign() public {
        // Alice buys 30,000 tokens (below min cap of 50,000)
        uint256 payment = 4_320_000_000; // 4320 USDC
        vm.prank(alice);
        campaign.buy(address(usdc), payment);

        assertEq(uint8(campaign.state()), uint8(Campaign.State.Funding));
        assertEq(campaignToken.balanceOf(alice), 30_000e18);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        // Fast forward past funding deadline
        vm.warp(block.timestamp + 91 days);

        // Anyone can trigger buyback
        campaign.triggerBuyback();
        assertEq(uint8(campaign.state()), uint8(Campaign.State.Buyback));

        // Alice claims refund
        vm.prank(alice);
        campaign.buyback(address(usdc));

        // Refund is net of the 3% funding fee (non-refundable by design).
        uint256 fundingFee = payment * 300 / 10_000;
        assertEq(campaignToken.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + payment - fundingFee);
    }

    // --- Sell-Back Queue Test ---

    function test_sellBackQueue() public {
        // Alice buys 60k tokens → activates campaign
        uint256 alicePayment = 8_640_000_000;
        vm.prank(alice);
        campaign.buy(address(usdc), alicePayment);

        // Start season and stake
        vm.prank(producer);
        campaign.startSeason(1);

        vm.prank(alice);
        campaignToken.approve(address(stakingVault), type(uint256).max);
        vm.prank(alice);
        stakingVault.stake(50_000e18);

        // After 6 months, unstake
        vm.warp(block.timestamp + 180 days);

        vm.prank(alice);
        stakingVault.unstake(0);
        // Alice gets back ~50% after penalty (6 months of 12)
        uint256 aliceTokens = campaignToken.balanceOf(alice);
        assertGt(aliceTokens, 0);

        // Alice puts remaining tokens in sell-back queue
        vm.prank(alice);
        campaignToken.approve(address(campaign), type(uint256).max);
        vm.prank(alice);
        campaign.sellBack(aliceTokens);

        assertEq(campaign.getSellBackQueueDepth(), aliceTokens);

        // Bob buys → should fill Alice's sell-back order
        uint256 bobPayment = 2_880_000_000; // 2880 USDC
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(bob);
        campaign.buy(address(usdc), bobPayment);

        // Alice should have received USDC from Bob's purchase
        assertGt(usdc.balanceOf(alice), aliceUsdcBefore);
    }

    // --- Dynamic Yield Rate Test ---

    function test_dynamicYieldRate() public {
        // At 0% fill, rate should be 5e18
        assertEq(stakingVault.currentYieldRate(), 5e18);

        // Buy and stake 50% of max supply
        uint256 payment = 7_200_000_000; // 50k tokens
        vm.prank(alice);
        campaign.buy(address(usdc), payment);

        vm.prank(producer);
        campaign.startSeason(1);

        vm.prank(alice);
        campaignToken.approve(address(stakingVault), type(uint256).max);
        vm.prank(alice);
        stakingVault.stake(50_000e18);

        // At 50% fill, rate should be 3e18
        assertEq(stakingVault.currentYieldRate(), 3e18);
    }

    // --- Penalty Test ---

    function test_earlyUnstakePenalty() public {
        // Setup: buy, activate, stake
        uint256 payment = 8_640_000_000;
        vm.prank(alice);
        campaign.buy(address(usdc), payment);

        vm.prank(producer);
        campaign.startSeason(1);

        vm.prank(alice);
        campaignToken.approve(address(stakingVault), type(uint256).max);
        vm.prank(alice);
        stakingVault.stake(10_000e18);

        // Unstake after 3 months (25% of season) → 75% penalty
        vm.warp(block.timestamp + 91.25 days);
        vm.prank(alice);
        stakingVault.unstake(0);

        // Should get ~25% back
        uint256 returned = campaignToken.balanceOf(alice);
        // Alice had 60k total, staked 10k, so 50k unstaked + ~2500 returned
        uint256 unstaked = returned - 50_000e18;
        assertApproxEqRel(unstaked, 2_500e18, 0.01e18); // ~1% tolerance
    }
}
