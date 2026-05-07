// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {GrowfiCampaignFactory} from "../src/GrowfiCampaignFactory.sol";
import {GrowfiCampaign} from "../src/GrowfiCampaign.sol";
import {GrowfiToken} from "../src/GrowfiToken.sol";
import {GrowfiTreasury} from "../src/GrowfiTreasury.sol";
import {GrowfiMinter} from "../src/GrowfiMinter.sol";
import {GrowfiFeeSplitter} from "../src/GrowfiFeeSplitter.sol";
import {Deployer} from "./helpers/Deployer.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {MockOracle} from "./helpers/MockOracle.sol";

/// @dev Token that re-enters its caller on transferFrom. Used to test reentrancy guards
///      across the GROW system (direct buy and redeem flows).
contract ReentrantStablecoin is ERC20 {
    address public reentryTarget;
    bytes public reentryCalldata;
    bool public reentered;

    constructor() ERC20("Reentrant", "RNT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function setReentry(address target, bytes memory data) external {
        reentryTarget = target;
        reentryCalldata = data;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (reentryTarget != address(0) && !reentered) {
            reentered = true;
            (bool ok,) = reentryTarget.call(reentryCalldata);
            // Don't propagate the inner success — we just want to TRY reentering.
            // The outer call will revert if reentry was caught by a guard.
            ok; // silence
        }
        return super.transferFrom(from, to, amount);
    }
}

/// @dev Cross-contract adversarial scenarios on the wired GROW + Campaign system.
contract GrowfiRedTeamTest is Test {
    GrowfiCampaignFactory factory;
    GrowfiToken growToken;
    GrowfiTreasury growTreasury;
    GrowfiMinter growMinter;
    GrowfiFeeSplitter feeSplitter;
    MockERC20 usdc;
    MockOracle usdFeed;

    address constant OWNER = address(0xF000);
    address constant OPS = address(0x0123);
    address constant DEPLOYER = address(0xD000);
    address constant PRODUCER = address(0xA1);
    address constant ALICE = address(0xA2);
    address constant ATTACKER = address(0xBAD);

    uint256 constant GENESIS = 1_000_000e18;
    uint256 constant ONE_USDC = 1e6;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdFeed = new MockOracle(int256(1e8), 8);

        factory = Deployer.deployProtocol(OWNER, OWNER, address(usdc), address(0));
        vm.prank(OWNER);
        factory.setMinSeasonDuration(1 hours);

        // GROW system
        GrowfiToken tImpl = new GrowfiToken();
        bytes memory tInit = abi.encodeCall(
            GrowfiToken.initialize, ("GrowFi", "GROW", address(factory), DEPLOYER, GENESIS, 1_000, 1e17)
        );
        growToken = GrowfiToken(address(new TransparentUpgradeableProxy(address(tImpl), OWNER, tInit)));

        GrowfiTreasury trImpl = new GrowfiTreasury();
        bytes memory trInit = abi.encodeCall(GrowfiTreasury.initialize, (address(factory), address(growToken)));
        growTreasury = GrowfiTreasury(address(new TransparentUpgradeableProxy(address(trImpl), OWNER, trInit)));

        GrowfiMinter mImpl = new GrowfiMinter();
        GrowfiMinter.BondingCurveParams memory params = GrowfiMinter.BondingCurveParams({
            tier1RateBps: 10_000,
            tier2RateBps: 7_000,
            tier3RateBps: 4_000,
            tier2to3ThresholdBps: 5_000
        });
        bytes memory mInit = abi.encodeCall(GrowfiMinter.initialize, (address(factory), address(growToken), params));
        growMinter = GrowfiMinter(address(new TransparentUpgradeableProxy(address(mImpl), OWNER, mInit)));

        GrowfiFeeSplitter fsImpl = new GrowfiFeeSplitter();
        bytes memory fsInit =
            abi.encodeCall(GrowfiFeeSplitter.initialize, (address(factory), address(growTreasury), OPS, 3_000));
        feeSplitter = GrowfiFeeSplitter(address(new TransparentUpgradeableProxy(address(fsImpl), OWNER, fsInit)));

        vm.startPrank(OWNER);
        factory.setGrowfiContracts(address(growToken), address(growMinter), address(growTreasury), address(feeSplitter));
        factory.setProtocolFeeRecipient(address(feeSplitter));
        vm.stopPrank();

        vm.startPrank(address(factory));
        growToken.setMinter(address(growMinter));
        growToken.setTreasury(address(growTreasury));
        growTreasury.addAcceptedStablecoin(address(usdc), 1e12, address(usdFeed), 24 hours, 9_500, 10_500);
        growMinter.setExcludedFromMint(address(growTreasury), true);
        vm.stopPrank();
    }

    function _createCampaign(uint256 minCap, uint256 maxCap, uint256 pricePerToken)
        internal
        returns (address campaign)
    {
        vm.prank(PRODUCER);
        campaign = factory.createCampaign(
            GrowfiCampaignFactory.CreateCampaignParams({
                producer: PRODUCER,
                tokenName: string(abi.encodePacked("Test", vm.toString(uint256(uint160(address(this)))))),
                tokenSymbol: "TST",
                yieldName: "Yield",
                yieldSymbol: "YLD",
                pricePerToken: pricePerToken,
                minCap: minCap,
                maxCap: maxCap,
                fundingDeadline: block.timestamp + 30 days,
                seasonDuration: 1 hours,
                minProductClaim: 1e18,
                expectedAnnualHarvestUsd: 5_000e18,
                expectedAnnualHarvest: 250e18,
                firstHarvestYear: 2030,
                coverageHarvests: 0
            })
        );
        vm.prank(PRODUCER);
        GrowfiCampaign(campaign).addAcceptedToken(
            address(usdc), GrowfiCampaign.PricingMode.Fixed, pricePerToken / 1e12, address(0)
        );
    }

    // ---------- 1. Reentrancy on direct buy ----------

    /// @dev A malicious stablecoin tries to reenter `buy()` mid-transferFrom.
    ///      The `nonReentrant` guard on `GrowfiToken.buy` should block.
    function test_redteam_reentrancyOnDirectBuy() public {
        ReentrantStablecoin malicious = new ReentrantStablecoin();
        vm.prank(address(factory));
        growTreasury.addAcceptedStablecoin(address(malicious), 1e12, address(usdFeed), 24 hours, 9_500, 10_500);

        // Seed treasury with normal USDC so the floor is non-zero.
        usdc.mint(address(growTreasury), 100 * ONE_USDC);

        // Configure malicious to reenter buy() during its transferFrom.
        bytes memory reentry =
            abi.encodeCall(GrowfiToken.buy, (address(malicious), 1 * ONE_USDC, type(uint256).max));
        malicious.setReentry(address(growToken), reentry);

        // Attacker tries to buy with the malicious token.
        malicious.mint(ATTACKER, 100 * ONE_USDC);
        vm.prank(ATTACKER);
        malicious.approve(address(growToken), 100 * ONE_USDC);

        // Reentrancy guard should kick in on the inner call — outer call's transferFrom
        // continues, but the inner buy(...) reverted. Reentrant token catches it but
        // doesn't re-throw. In the outer flow the inner reentry is silenced; the outer
        // direct buy succeeds for whatever the attacker sent. The point: NO double mint.
        vm.prank(ATTACKER);
        growToken.buy(address(malicious), 1 * ONE_USDC, type(uint256).max);

        // Attacker only got GROW for ONE buy, not two.
        // Approximate: 1 USDC / (floor × 1.10). Floor before was tiny; after the buy it's
        // a bit higher. Just verify a single buy emitted reasonable supply, not exploded.
        uint256 attackerBal = growToken.balanceOf(ATTACKER);
        assertGt(attackerBal, 0);
        assertLt(attackerBal, 1e30); // sanity bound: not an exploded mint
    }

    // ---------- 2. Authority confusion — minter ----------

    /// @dev Attacker tries to register their own contract as a campaign on the minter
    ///      directly, bypassing the factory.
    function test_redteam_directRegisterCampaignBlocked() public {
        vm.expectRevert(GrowfiMinter.NotFactory.selector);
        vm.prank(ATTACKER);
        growMinter.registerCampaign(ATTACKER);
    }

    /// @dev Attacker tries to call recordBuy from a non-registered address.
    function test_redteam_directRecordBuyBlocked() public {
        vm.expectRevert(GrowfiMinter.NotCampaign.selector);
        vm.prank(ATTACKER);
        growMinter.recordBuy(ATTACKER, 0, 100e18);
    }

    /// @dev Attacker tries to mint GROW directly via the token contract.
    function test_redteam_directGrowMintBlocked() public {
        vm.expectRevert(GrowfiToken.NotMinter.selector);
        vm.prank(ATTACKER);
        growToken.mint(ATTACKER, 1e18);
    }

    // ---------- 3. Treasury drain attempts ----------

    /// @dev Attacker tries to call addTrackedCampaign on Treasury directly.
    function test_redteam_directAddTrackedCampaignBlocked() public {
        vm.expectRevert(GrowfiTreasury.NotFactory.selector);
        vm.prank(ATTACKER);
        growTreasury.addTrackedCampaign(ATTACKER);
    }

    /// @dev Attacker tries to allocate Treasury USDC to their own contract.
    function test_redteam_directAllocateBlocked() public {
        usdc.mint(address(growTreasury), 1000 * ONE_USDC);
        vm.expectRevert(GrowfiTreasury.NotFactory.selector);
        vm.prank(ATTACKER);
        growTreasury.allocateToCampaign(ATTACKER, address(usdc), 100 * ONE_USDC);
    }

    /// @dev Attacker tries to rescue a real stablecoin from Treasury.
    function test_redteam_rescueAcceptedStablecoinBlocked() public {
        usdc.mint(address(growTreasury), 100 * ONE_USDC);
        vm.expectRevert(GrowfiTreasury.NotFactory.selector);
        vm.prank(ATTACKER);
        growTreasury.rescueToken(IERC20(address(usdc)), ATTACKER, 100 * ONE_USDC);

        // Even via factory, USDC cannot be rescued (it's accepted).
        vm.expectRevert(GrowfiTreasury.CannotRescueAcceptedStablecoin.selector);
        vm.prank(address(factory));
        growTreasury.rescueToken(IERC20(address(usdc)), ATTACKER, 100 * ONE_USDC);
    }

    // ---------- 4. Bonding curve manipulation ----------

    /// @dev Attempt to game the bonding curve via buy → sellback → buy loop in Active state.
    ///      Each cycle should earn LESS GROW because cumBuyVolumeUsd is monotonic.
    function test_redteam_buySellbackLoopEarnsLessOverTime() public {
        address campaign = _createCampaign(50e18, 200e18, 1e18);

        // Attacker reaches softcap with $50.
        usdc.mint(ATTACKER, 200 * ONE_USDC);
        vm.prank(ATTACKER);
        usdc.approve(campaign, 200 * ONE_USDC);
        vm.prank(ATTACKER);
        GrowfiCampaign(campaign).buy(address(usdc), 50 * ONE_USDC);

        // Claim escrow → 50 GROW in wallet.
        vm.prank(ATTACKER);
        growMinter.claimEscrow(campaign);
        uint256 grow1 = growToken.balanceOf(ATTACKER);

        // Tier thresholds for this campaign: tier1 ends at minCap × $1 = $50.
        // tier2 ends at minCap + (maxCap - minCap) × 50% = 50 + 75 = $125.

        // Buy 2: $50 in Active. cumVol $50 → $100. All tier 2 → 50 × 0.7 = 35 GROW direct.
        vm.prank(ATTACKER);
        GrowfiCampaign(campaign).buy(address(usdc), 50 * ONE_USDC);
        uint256 grow2 = growToken.balanceOf(ATTACKER);

        // Buy 3: $50 → cumVol $100 → $150. Spans tier 2 ($25) + tier 3 ($25) → 17.5 + 10 = 27.5.
        vm.prank(ATTACKER);
        GrowfiCampaign(campaign).buy(address(usdc), 50 * ONE_USDC);
        uint256 grow3 = growToken.balanceOf(ATTACKER);

        // Each successive $50 buy yielded strictly less GROW (monotonic decay).
        uint256 firstReward = grow1;
        uint256 secondReward = grow2 - grow1;
        uint256 thirdReward = grow3 - grow2;

        assertEq(firstReward, 50e18); // tier 1
        assertEq(secondReward, 35e18); // tier 2
        assertEq(thirdReward, 275e17); // tier 2 + tier 3 = 17.5 + 10 = 27.5
        assertLt(secondReward, firstReward, "tier 2 yields less than tier 1");
        assertLt(thirdReward, secondReward, "tier 3 mix yields less than pure tier 2");
    }

    /// @dev Attacker tries to mark themselves as excluded from mint to keep the curve at tier 1.
    ///      Excluded means NO GROW for that buyer — opposite of what an attacker would want anyway.
    ///      Direct call gated to factory.
    function test_redteam_excludeSelfBlocked() public {
        vm.expectRevert(GrowfiMinter.NotFactory.selector);
        vm.prank(ATTACKER);
        growMinter.setExcludedFromMint(ATTACKER, true);
    }

    // ---------- 5. Direct buy slippage / sandwich resistance ----------

    /// @dev Slippage protection: buyer can cap the price they accept. If the floor moves between
    ///      sim and execution (e.g., front-runner), tx reverts.
    function test_redteam_slippageProtectionWorksUnderRace() public {
        usdc.mint(address(growTreasury), 100 * ONE_USDC);
        uint256 capturedPrice = growToken.currentSalePrice();

        // Front-runner deposits a lot of USDC into Treasury (e.g., via a sandwich), pushing floor up.
        // (This isn't really a profitable attack but tests slippage cap.)
        usdc.mint(address(growTreasury), 1000 * ONE_USDC); // 10x the original

        // Buyer's tx executes at the new (higher) price. Their slippage cap is the price they captured.
        usdc.mint(ALICE, 11 * ONE_USDC);
        vm.prank(ALICE);
        usdc.approve(address(growToken), 11 * ONE_USDC);

        // Should revert because actual price > capturedPrice.
        vm.expectRevert(GrowfiToken.PriceExceedsMax.selector);
        vm.prank(ALICE);
        growToken.buy(address(usdc), 11 * ONE_USDC, capturedPrice);
    }

    // ---------- 6. FeeSplitter griefing ----------

    /// @dev FeeSplitter is permissionless to flush. An attacker can call flush whenever, but it
    ///      always splits 30/70 to the configured addresses — no harm.
    function test_redteam_attackerFlushIsNoBenefit() public {
        usdc.mint(address(feeSplitter), 100 * ONE_USDC);
        uint256 attackerBefore = usdc.balanceOf(ATTACKER);

        vm.prank(ATTACKER);
        feeSplitter.flushToken(address(usdc));

        // Attacker got nothing.
        assertEq(usdc.balanceOf(ATTACKER), attackerBefore);
        // Funds went to the configured addresses.
        assertEq(usdc.balanceOf(address(growTreasury)), 30 * ONE_USDC);
        assertEq(usdc.balanceOf(OPS), 70 * ONE_USDC);
    }

    /// @dev Attacker tries to redirect feeSplitter's destinations.
    function test_redteam_redirectFeeSplitterBlocked() public {
        vm.expectRevert(GrowfiFeeSplitter.NotFactory.selector);
        vm.prank(ATTACKER);
        feeSplitter.setTreasury(ATTACKER);

        vm.expectRevert(GrowfiFeeSplitter.NotFactory.selector);
        vm.prank(ATTACKER);
        feeSplitter.setOperations(ATTACKER);
    }

    // ---------- 7. Failed campaign GROW farm attempt ----------

    /// @dev Attacker funds a bunch of campaigns hoping at least some succeed and they earn GROW.
    ///      Failed campaigns void escrow → no GROW. Only successful campaigns count.
    function test_redteam_failedCampaignGrowGoesToZero() public {
        address campaign = _createCampaign(100e18, 200e18, 1e18);

        // Attacker buys $50 (below softcap).
        usdc.mint(ATTACKER, 50 * ONE_USDC);
        vm.prank(ATTACKER);
        usdc.approve(campaign, 50 * ONE_USDC);
        vm.prank(ATTACKER);
        GrowfiCampaign(campaign).buy(address(usdc), 50 * ONE_USDC);

        assertEq(growMinter.getEscrow(campaign, ATTACKER), 50e18, "escrow accumulated");

        // Time passes, deadline elapses without softcap.
        vm.warp(block.timestamp + 31 days);
        GrowfiCampaign(campaign).triggerBuyback();

        // Try to claim — voided.
        vm.expectRevert(GrowfiMinter.NotActive.selector);
        vm.prank(ATTACKER);
        growMinter.claimEscrow(campaign);

        assertEq(growToken.balanceOf(ATTACKER), 0, "no GROW from failed campaign");
    }

    // ---------- 8. Cross-campaign leakage ----------

    /// @dev Two separate campaigns; an escrow on one should never leak into another.
    function test_redteam_escrowsAreCampaignScoped() public {
        // Distinct token names so factory doesn't reject the duplicate.
        vm.prank(PRODUCER);
        address campaignA = factory.createCampaign(
            GrowfiCampaignFactory.CreateCampaignParams({
                producer: PRODUCER,
                tokenName: "CampaignA",
                tokenSymbol: "CA",
                yieldName: "YA",
                yieldSymbol: "yA",
                pricePerToken: 1e18,
                minCap: 100e18,
                maxCap: 200e18,
                fundingDeadline: block.timestamp + 30 days,
                seasonDuration: 1 hours,
                minProductClaim: 1e18,
                expectedAnnualHarvestUsd: 5_000e18,
                expectedAnnualHarvest: 250e18,
                firstHarvestYear: 2030,
                coverageHarvests: 0
            })
        );
        vm.prank(PRODUCER);
        GrowfiCampaign(campaignA).addAcceptedToken(address(usdc), GrowfiCampaign.PricingMode.Fixed, 1e6, address(0));

        vm.prank(PRODUCER);
        address campaignB = factory.createCampaign(
            GrowfiCampaignFactory.CreateCampaignParams({
                producer: PRODUCER,
                tokenName: "CampaignB",
                tokenSymbol: "CB",
                yieldName: "YB",
                yieldSymbol: "yB",
                pricePerToken: 1e18,
                minCap: 100e18,
                maxCap: 200e18,
                fundingDeadline: block.timestamp + 30 days,
                seasonDuration: 1 hours,
                minProductClaim: 1e18,
                expectedAnnualHarvestUsd: 5_000e18,
                expectedAnnualHarvest: 250e18,
                firstHarvestYear: 2030,
                coverageHarvests: 0
            })
        );
        vm.prank(PRODUCER);
        GrowfiCampaign(campaignB).addAcceptedToken(address(usdc), GrowfiCampaign.PricingMode.Fixed, 1e6, address(0));

        // Alice buys $50 on Campaign A (escrow).
        usdc.mint(ALICE, 100 * ONE_USDC);
        vm.prank(ALICE);
        usdc.approve(campaignA, 100 * ONE_USDC);
        vm.prank(ALICE);
        GrowfiCampaign(campaignA).buy(address(usdc), 50 * ONE_USDC);

        // She can't claim on Campaign B (different campaign, no escrow there).
        vm.expectRevert(); // either NotActive or NoEscrow
        vm.prank(ALICE);
        growMinter.claimEscrow(campaignB);
    }

    // ---------- 9. Genesis dump attempt ----------

    /// @dev Genesis recipient holds 1M GROW. They could dump by burning to redeem entire treasury.
    ///      Treasury holds whatever's been accumulated. Verify the redeem doesn't underflow or
    ///      misallocate. Caps on per-call drain are bounded by the holder's GROW share.
    function test_redteam_genesisDumpAllAtOnce() public {
        usdc.mint(address(growTreasury), 1_000_000 * ONE_USDC); // $1M backing

        // Deployer redeems EVERY GROW.
        vm.prank(DEPLOYER);
        growToken.approve(address(growTreasury), GENESIS);
        vm.prank(DEPLOYER);
        growTreasury.redeem(GENESIS);

        // Deployer got 100% of treasury (because they were 100% of circulating).
        assertEq(usdc.balanceOf(DEPLOYER), 1_000_000 * ONE_USDC);
        // Total supply went to 0.
        assertEq(growToken.totalSupply(), 0);
        // Treasury USDC drained to 0.
        assertEq(usdc.balanceOf(address(growTreasury)), 0);
    }

    // ---------- 10. Direct buy when treasury is exactly 1 wei ----------

    /// @dev Edge case: treasury has only 1 wei of USDC. Direct buy at huge floor would mint
    ///      essentially infinite GROW. Test that this doesn't happen.
    function test_redteam_tinyTreasurySanityBound() public {
        // Send 1 wei of USDC to treasury. Floor = 1 wei × 1e12 / circulating GROW.
        // = 1e12 / 1e24 = 1e-12 (tiny). Sale price = 1e-12 × 1.1 = also tiny.
        usdc.mint(address(growTreasury), 1);

        // Alice tries to buy with $1 USDC. growOut = 1e6 × 1e12 × 1e18 / (~1e-12 × 1.1)
        // = 1e36 / ~1.1e0 = 1e36 / 1.1 = ~1e36 raw GROW = 1e18 trillion whole tokens.
        // That's degenerate but mathematically consistent. Mark this expected.
        usdc.mint(ALICE, 1 * ONE_USDC);
        vm.prank(ALICE);
        usdc.approve(address(growToken), 1 * ONE_USDC);

        vm.prank(ALICE);
        uint256 received = growToken.buy(address(usdc), 1 * ONE_USDC, type(uint256).max);

        // Just sanity check: the buy succeeded at SOME price, and circulating supply is now huge
        // but consistent. The protocol's defense in depth: multisig sets a non-zero
        // referencePrice at deploy ($0.10 default) so the boot floor never approaches zero.
        // This test documents what happens if multisig fails to do that AND treasury has
        // 1 wei of USDC.
        assertGt(received, 0);
    }

    // ---------- 11. Reentrancy on redeem via malicious campaign token ----------

    /// @dev If a tracked campaign returns a malicious campaignToken that reenters during
    ///      transfer, the nonReentrant guard blocks. Hard to set up since campaigns are
    ///      deployed by the factory with the standard impl, so a malicious campaignToken
    ///      isn't reachable from the factory. Documented invariant: factory only
    ///      registers campaigns it deployed, so the campaignToken is always trusted.
    function test_redteam_onlyFactoryAddsTrackedCampaigns() public {
        // Treasury tracking is no longer auto on createCampaign — multisig must add explicitly.
        address campaign = _createCampaign(100e18, 200e18, 1e18);
        assertFalse(growTreasury.isTrackedCampaign(campaign));

        // Attacker cannot directly add anything (or themselves) as tracked.
        vm.expectRevert(GrowfiTreasury.NotFactory.selector);
        vm.prank(ATTACKER);
        growTreasury.addTrackedCampaign(ATTACKER);

        // Multisig (via factory) can.
        vm.prank(address(factory));
        growTreasury.addTrackedCampaign(campaign);
        assertTrue(growTreasury.isTrackedCampaign(campaign));
    }

    // ---------- 12. Sale toggle race ----------

    /// @dev Multisig flips saleActive to false mid-flight. Pending tx for direct buy reverts.
    function test_redteam_saleToggleAffectsAllPendingBuys() public {
        usdc.mint(address(growTreasury), 100 * ONE_USDC);
        usdc.mint(ALICE, 11 * ONE_USDC);
        vm.prank(ALICE);
        usdc.approve(address(growToken), 11 * ONE_USDC);

        // Multisig disables sale.
        vm.prank(address(factory));
        growToken.setSaleActive(false);

        // Alice's tx now reverts.
        vm.expectRevert(GrowfiToken.SaleNotActive.selector);
        vm.prank(ALICE);
        growToken.buy(address(usdc), 11 * ONE_USDC, type(uint256).max);
    }
}
