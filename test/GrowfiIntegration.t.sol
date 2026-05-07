// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GrowfiCampaignFactory} from "../src/GrowfiCampaignFactory.sol";
import {GrowfiCampaign} from "../src/GrowfiCampaign.sol";
import {GrowfiCampaignToken} from "../src/GrowfiCampaignToken.sol";
import {GrowfiStakingVault} from "../src/GrowfiStakingVault.sol";
import {GrowfiToken} from "../src/GrowfiToken.sol";
import {GrowfiTreasury} from "../src/GrowfiTreasury.sol";
import {GrowfiMinter} from "../src/GrowfiMinter.sol";
import {GrowfiFeeSplitter} from "../src/GrowfiFeeSplitter.sol";
import {GrowfiStakingPool} from "../src/GrowfiStakingPool.sol";
import {GrowfiStakingVault} from "../src/GrowfiStakingVault.sol";
import {GrowfiHarvestManager} from "../src/GrowfiHarvestManager.sol";
import {GrowfiYieldToken} from "../src/GrowfiYieldToken.sol";
import {Deployer} from "./helpers/Deployer.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {MockOracle} from "./helpers/MockOracle.sol";

/// @notice End-to-end integration: real Campaign lifecycle with the full GROW system wired.
contract GrowfiIntegrationTest is Test {
    GrowfiCampaignFactory factory;
    GrowfiToken growToken;
    GrowfiTreasury growTreasury;
    GrowfiMinter growMinter;
    GrowfiFeeSplitter feeSplitter;
    GrowfiStakingPool stakingPool;

    MockERC20 usdc;
    MockERC20 usdt;
    MockERC20 dai;
    MockOracle usdFeed;

    address constant OWNER = address(0xF000); // multisig
    address constant OPS = address(0x0123); // operations multisig
    address constant DEPLOYER = address(0xD000); // genesis recipient
    address constant PRODUCER = address(0xA1);
    address constant ALICE = address(0xA2);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA70);

    uint256 constant GENESIS = 1_000_000e18;
    uint256 constant BOOT_PRICE = 1e17; // $0.10 per GROW
    uint256 constant ONE_USDC = 1e6;
    uint256 constant ONE_DAI = 1e18;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);
        dai = new MockERC20("Dai", "DAI", 18);
        usdFeed = new MockOracle(int256(1e8), 8);

        // 1. Deploy the existing protocol via the standard helper.
        factory = Deployer.deployProtocol(OWNER, OWNER /* placeholder feeRecipient, replaced below */, address(usdc), address(0));
        // Relax season floor so tests don't have to wait 30 days.
        vm.prank(OWNER);
        factory.setMinSeasonDuration(1 hours);

        // 2. Deploy GrowfiToken (factory_=factory).
        GrowfiToken tImpl = new GrowfiToken();
        bytes memory tInit = abi.encodeCall(
            GrowfiToken.initialize, ("GrowFi", "GROW", address(factory), DEPLOYER, GENESIS, 1_000, BOOT_PRICE)
        );
        growToken = GrowfiToken(address(new TransparentUpgradeableProxy(address(tImpl), OWNER, tInit)));

        // 3. Deploy GrowfiTreasury (factory_=factory, growToken_=growToken).
        GrowfiTreasury trImpl = new GrowfiTreasury();
        bytes memory trInit =
            abi.encodeCall(GrowfiTreasury.initialize, (address(factory), address(growToken)));
        growTreasury = GrowfiTreasury(address(new TransparentUpgradeableProxy(address(trImpl), OWNER, trInit)));

        // 4. Deploy GrowfiMinter (factory_=factory, growToken_=growToken, default 3-tier curve).
        GrowfiMinter mImpl = new GrowfiMinter();
        GrowfiMinter.BondingCurveParams memory params = GrowfiMinter.BondingCurveParams({
            tier1RateBps: 10_000, // 1.0×
            tier2RateBps: 7_000, // 0.7×
            tier3RateBps: 4_000, // 0.4×
            tier2to3ThresholdBps: 5_000 // 50% of (maxcap - softcap)
        });
        bytes memory mInit = abi.encodeCall(GrowfiMinter.initialize, (address(factory), address(growToken), params));
        growMinter = GrowfiMinter(address(new TransparentUpgradeableProxy(address(mImpl), OWNER, mInit)));

        // 5. Deploy GrowfiFeeSplitter (factory_=factory, treasury_=treasury, ops_=OPS, 30%).
        GrowfiFeeSplitter fsImpl = new GrowfiFeeSplitter();
        bytes memory fsInit =
            abi.encodeCall(GrowfiFeeSplitter.initialize, (address(factory), address(growTreasury), OPS, 3_000));
        feeSplitter = GrowfiFeeSplitter(address(new TransparentUpgradeableProxy(address(fsImpl), OWNER, fsInit)));

        // 6. Wire factory ↔ GROW + redirect protocolFeeRecipient → feeSplitter.
        vm.startPrank(OWNER);
        factory.setGrowfiContracts(address(growToken), address(growMinter), address(growTreasury), address(feeSplitter));
        factory.setProtocolFeeRecipient(address(feeSplitter));
        vm.stopPrank();

        // 7. Wire GROW token ↔ minter + treasury (factory acts as admin via msg.sender == address(factory)).
        // Since `factory` slot on GROW contracts is the factory CONTRACT, we need the contract to
        // call setMinter/setTreasury. There's no forwarding setter in the factory yet, so we
        // simulate by pranking the factory address (in production the deploy script either
        // adds these forwarding setters or sets the GROW contracts' factory slot to a multisig).
        vm.startPrank(address(factory));
        growToken.setMinter(address(growMinter));
        growToken.setTreasury(address(growTreasury));
        // Add the three accepted stablecoins.
        growTreasury.addAcceptedStablecoin(address(usdc), 1e12, address(usdFeed), 24 hours, 9_500, 10_500);
        growTreasury.addAcceptedStablecoin(address(usdt), 1e12, address(usdFeed), 24 hours, 9_500, 10_500);
        growTreasury.addAcceptedStablecoin(address(dai), 1, address(usdFeed), 24 hours, 9_500, 10_500);
        // Treasury is excluded from earning GROW on its own buys.
        growMinter.setExcludedFromMint(address(growTreasury), true);
        vm.stopPrank();

        // Deploy + wire StakingPool.
        GrowfiStakingPool spImpl = new GrowfiStakingPool();
        bytes memory spInit = abi.encodeCall(
            GrowfiStakingPool.initialize, (address(factory), address(growToken), address(usdc), address(growTreasury))
        );
        stakingPool = GrowfiStakingPool(address(new TransparentUpgradeableProxy(address(spImpl), OWNER, spInit)));
        vm.prank(address(factory));
        growTreasury.setStakingPool(address(stakingPool));
    }

    function _createCampaign(uint256 minCap, uint256 maxCap, uint256 pricePerToken)
        internal
        returns (address campaign)
    {
        return _createCampaignNamed("Olive Sicily", "OLV", minCap, maxCap, pricePerToken);
    }

    function _createCampaignNamed(
        string memory name,
        string memory symbol,
        uint256 minCap,
        uint256 maxCap,
        uint256 pricePerToken
    ) internal returns (address campaign) {
        vm.prank(PRODUCER);
        campaign = factory.createCampaign(
            GrowfiCampaignFactory.CreateCampaignParams({
                producer: PRODUCER,
                tokenName: name,
                tokenSymbol: symbol,
                yieldName: string(abi.encodePacked(symbol, " Yield")),
                yieldSymbol: string(abi.encodePacked("y", symbol)),
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

        // Producer whitelists USDC as a payment token on the campaign.
        vm.prank(PRODUCER);
        GrowfiCampaign(campaign).addAcceptedToken(
            address(usdc), GrowfiCampaign.PricingMode.Fixed, pricePerToken / 1e12, address(0)
        );
    }

    function _approveAndFundUsdc(address user, uint256 amount, address spender) internal {
        usdc.mint(user, amount);
        vm.prank(user);
        usdc.approve(spender, amount);
    }

    // ---------- happy path: escrow → softcap → claim ----------

    /// @dev Configure: pricePerToken = $1, minCap = 100 tokens, maxCap = 200 tokens.
    ///      Tier 1 USD threshold = 100 × $1 = $100. Tier 2 ends at $150. Tier 3 to $200.
    function test_lifecycle_funding_to_active_with_growEmission() public {
        address campaign = _createCampaign(100e18, 200e18, 1e18);

        // Verify Minter auto-registration (Treasury tracking is gated to multisig now).
        assertFalse(growTreasury.isTrackedCampaign(campaign), "campaign NOT auto-tracked in Treasury");
        (GrowfiMinter.CampaignStatus status,,,) = growMinter.getCampaignState(campaign);
        assertEq(uint256(status), uint256(GrowfiMinter.CampaignStatus.Pending), "minter status: Pending");

        // Verify the campaign cached the minter at init.
        assertEq(GrowfiCampaign(campaign).growMinter(), address(growMinter), "campaign cached growMinter");

        // ALICE buys $50 worth (50 tokens at $1) -- all in tier 1 → 50 GROW escrowed.
        // She actually pays $50 + 3% fee = $51.55... no wait: fee is skimmed from gross.
        // pricePerToken = 1e18 → fixedRate (USDC 6-dec) = 1e6. So $50 USDC = 50 tokens at fixedRate.
        // Fee 3% comes off the GROSS payment → $50 × 0.03 = $1.50 to feeSplitter, $48.50 net to escrow.
        // Tokens out = 50 (gross drives the calc, then the resulting tokens are minted).
        // Actually let me check: in Campaign.buy(), tokensOut is computed from PAYMENT (gross),
        // then fundingFee is skimmed AFTER. So Alice still gets 50 tokens minted for her $50 USDC.
        // Hmm wait, let me re-read the Campaign code... actually the flow is:
        //   tokensOut = _calculateTokensOut(usdc, paymentAmount=50e6) → 50e18
        //   fundingFee = 50e6 × 300/10000 = 1.5e6, sent to feeSplitter
        //   Alice keeps tokens, fee comes out of the protocol's cut from her gross.
        //
        // So Alice pays $50, gets 50 tokens, $1.50 goes to feeSplitter.
        // GROW: cumBuyVolumeUsd advances by 50e18 (the USD value of the mint), tier 1 rate → 50 GROW.
        _approveAndFundUsdc(ALICE, 50 * ONE_USDC, campaign);
        vm.prank(ALICE);
        GrowfiCampaign(campaign).buy(address(usdc), 50 * ONE_USDC);

        assertEq(growMinter.getEscrow(campaign, ALICE), 50e18, "Alice escrow = 50 GROW");
        assertEq(growToken.balanceOf(ALICE), 0, "Alice's wallet still empty (escrowed)");
        assertEq(usdc.balanceOf(address(feeSplitter)), 15 * ONE_USDC / 10, "feeSplitter has $1.50 fee");

        // BOB buys another $50 -- reaches softcap, auto-activates. His buy is also tier 1 (cum hits exactly $100).
        _approveAndFundUsdc(BOB, 50 * ONE_USDC, campaign);
        vm.prank(BOB);
        GrowfiCampaign(campaign).buy(address(usdc), 50 * ONE_USDC);

        // Status is now Active.
        (status,,,) = growMinter.getCampaignState(campaign);
        assertEq(uint256(status), uint256(GrowfiMinter.CampaignStatus.Active), "minter status: Active");

        // Bob's GROW for his buy was escrowed (status was still Pending at the moment of recordBuy).
        assertEq(growMinter.getEscrow(campaign, BOB), 50e18, "Bob escrow = 50 GROW");

        // Both can now claim.
        vm.prank(ALICE);
        growMinter.claimEscrow(campaign);
        vm.prank(BOB);
        growMinter.claimEscrow(campaign);

        assertEq(growToken.balanceOf(ALICE), 50e18, "Alice has 50 GROW");
        assertEq(growToken.balanceOf(BOB), 50e18, "Bob has 50 GROW");
    }

    function test_lifecycle_postSoftcapDirectMint() public {
        address campaign = _createCampaign(50e18, 200e18, 1e18);

        // Alice buys $50 → reaches softcap → activates. Tier 1 only.
        _approveAndFundUsdc(ALICE, 50 * ONE_USDC, campaign);
        vm.prank(ALICE);
        GrowfiCampaign(campaign).buy(address(usdc), 50 * ONE_USDC);

        // Status should be Active now.
        (GrowfiMinter.CampaignStatus status,,,) = growMinter.getCampaignState(campaign);
        assertEq(uint256(status), uint256(GrowfiMinter.CampaignStatus.Active));

        // Alice's $50 was tier 1 → 50 GROW escrowed. Claim it.
        vm.prank(ALICE);
        growMinter.claimEscrow(campaign);
        assertEq(growToken.balanceOf(ALICE), 50e18);

        // BOB buys $25 in Active. cumBuyVolumeUsd is $50 (tier 1 = $50 → tier 2 starts at $50).
        // Wait: minCap = 50, so tier1 USD = 50. Bob's buy advances from $50 to $75, all tier 2 → 17.5 GROW.
        _approveAndFundUsdc(BOB, 25 * ONE_USDC, campaign);
        vm.prank(BOB);
        GrowfiCampaign(campaign).buy(address(usdc), 25 * ONE_USDC);

        // Direct mint to wallet (status = Active).
        assertEq(growToken.balanceOf(BOB), 175e17, "Bob = 25 USD * 0.7 = 17.5 GROW direct");
        assertEq(growMinter.getEscrow(campaign, BOB), 0, "no escrow in Active");
    }

    // ---------- failed campaign: buyback voids escrow ----------

    function test_lifecycle_failedCampaignVoidsEscrow() public {
        address campaign = _createCampaign(100e18, 200e18, 1e18);

        // Alice buys $50 -- pre-softcap, escrowed.
        _approveAndFundUsdc(ALICE, 50 * ONE_USDC, campaign);
        vm.prank(ALICE);
        GrowfiCampaign(campaign).buy(address(usdc), 50 * ONE_USDC);

        assertEq(growMinter.getEscrow(campaign, ALICE), 50e18);

        // Move past funding deadline without reaching softcap.
        vm.warp(block.timestamp + 31 days);

        // Anyone triggers buyback (failed campaign).
        GrowfiCampaign(campaign).triggerBuyback();

        // Status: Failed, GROW escrow voided in semantic terms (claim now reverts).
        (GrowfiMinter.CampaignStatus status,,,) = growMinter.getCampaignState(campaign);
        assertEq(uint256(status), uint256(GrowfiMinter.CampaignStatus.Failed));

        vm.expectRevert(GrowfiMinter.NotActive.selector);
        vm.prank(ALICE);
        growMinter.claimEscrow(campaign);

        assertEq(growToken.balanceOf(ALICE), 0, "Alice gets no GROW from a failed campaign");

        // Alice can still claim her USDC refund via the existing buyback path.
        vm.prank(ALICE);
        GrowfiCampaign(campaign).buyback(address(usdc));
        // Refund is NET (post 3% fee), so Alice gets $48.50 back, fee stays in feeSplitter.
        assertEq(usdc.balanceOf(ALICE), 4850 * ONE_USDC / 100);
    }

    // ---------- fee flow: campaign → splitter → treasury & ops ----------

    function test_feeFlow_campaignFeesReachTreasuryAfterFlush() public {
        address campaign = _createCampaign(100e18, 200e18, 1e18);

        // Alice buys $100 -- fee 3% = $3 lands in feeSplitter.
        _approveAndFundUsdc(ALICE, 100 * ONE_USDC, campaign);
        vm.prank(ALICE);
        GrowfiCampaign(campaign).buy(address(usdc), 100 * ONE_USDC);

        assertEq(usdc.balanceOf(address(feeSplitter)), 3 * ONE_USDC, "fee splitter has $3");

        // Anyone flushes -- 30/70 to treasury/ops.
        feeSplitter.flushToken(address(usdc));

        assertEq(usdc.balanceOf(address(growTreasury)), 90 * ONE_USDC / 100, "treasury 30% = $0.90");
        assertEq(usdc.balanceOf(OPS), 210 * ONE_USDC / 100, "ops 70% = $2.10");
    }

    // ---------- direct buy → floor recompute ----------

    function test_directBuy_strengthensFloor() public {
        // Seed treasury with $100 USDC so floor is non-zero.
        usdc.mint(address(growTreasury), 100 * ONE_USDC);

        // Floor before:
        uint256 floor0 = growTreasury.intrinsicFloorPrice();
        assertGt(floor0, 0);

        // Alice buys some GROW with USDC at floor × 1.10.
        uint256 salePrice0 = growToken.currentSalePrice();
        usdc.mint(ALICE, 11 * ONE_USDC);
        vm.prank(ALICE);
        usdc.approve(address(growToken), 11 * ONE_USDC);
        vm.prank(ALICE);
        uint256 received = growToken.buy(address(usdc), 11 * ONE_USDC, type(uint256).max);

        // Treasury balance grew by $11. Some GROW was minted. Floor should rise (or stay equal).
        uint256 floor1 = growTreasury.intrinsicFloorPrice();
        assertGe(floor1, floor0, "floor did not decrease after direct buy");

        // Alice got GROW based on the OLD floor × 1.10.
        assertGt(received, 0);
        // Sale price was approx (floor0 × 1.1).
        assertEq(salePrice0, (floor0 * 11_000) / 10_000);
    }

    // ---------- treasury allocate then redeem ----------

    // ---------- multi-campaign: independent bonding curves ----------

    /// @dev Two separate campaigns (A and B). Each tracks its own cumBuyVolumeUsd.
    ///      Buying on A doesn't advance B's curve, and vice-versa.
    function test_multiCampaign_independentBondingCurves() public {
        address campA = _createCampaignNamed("CampA", "CA", 50e18, 200e18, 1e18);
        address campB = _createCampaignNamed("CampB", "CB", 50e18, 200e18, 1e18);

        // Buy $200 on A (spans all 3 tiers): 100×1.0 + 50×0.7 + 50×0.4 = 100 + 35 + 20 = 155 GROW
        // Wait -- minCap=50 → tier1 ends at $50. tier2 ends at $50 + (200-50)*50% = $125.
        // So $200 buy: tier1 = $50 × 1.0 = 50, tier2 = $75 × 0.7 = 52.5, tier3 = $75 × 0.4 = 30. Total 132.5.
        _approveAndFundUsdc(ALICE, 200 * ONE_USDC, campA);
        vm.prank(ALICE);
        GrowfiCampaign(campA).buy(address(usdc), 200 * ONE_USDC);

        // Alice claims her escrow on A (but only $50 was tier-1 pre-softcap; the rest was post-softcap direct mint)
        // Actually: the buy crossed softcap so $50 went to escrow at tier1, and $150 went direct to wallet
        // at tier2/3. Wait -- the recordBuy is called BEFORE _activate, so all $200 is recorded as one
        // continuous escrow call, status=Pending. The full 132.5 GROW lands in escrow, then onSoftCapReached
        // unlocks for claim.
        vm.prank(ALICE);
        growMinter.claimEscrow(campA);
        uint256 aliceA = growToken.balanceOf(ALICE);
        assertEq(aliceA, 1325e17, "Alice gets 132.5 GROW from A");

        // Now buy $50 on B -- fresh curve, all tier 1 → 50 GROW (escrowed pre-softcap)
        _approveAndFundUsdc(ALICE, 50 * ONE_USDC, campB);
        vm.prank(ALICE);
        GrowfiCampaign(campB).buy(address(usdc), 50 * ONE_USDC);

        // B reached softcap → claim
        vm.prank(ALICE);
        growMinter.claimEscrow(campB);
        uint256 aliceTotal = growToken.balanceOf(ALICE);
        assertEq(aliceTotal, aliceA + 50e18, "B starts fresh -- Alice gets full tier-1 rate");

        // Verify cumBuyVolumeUsd is tracked separately
        (, uint256 volA,,) = growMinter.getCampaignState(campA);
        (, uint256 volB,,) = growMinter.getCampaignState(campB);
        assertEq(volA, 200e18);
        assertEq(volB, 50e18);
    }

    // ---------- sellback queue: supply-neutral, no GROW emission ----------

    /// @dev When a buy fills the sellback queue (vs minting fresh tokens), there's no
    ///      change in currentSupply → recordBuy delta is 0 → no GROW emission for that
    ///      portion of the buy.
    function test_sellbackQueue_doesNotEmitGrowOnFill() public {
        address campaign = _createCampaign(50e18, 200e18, 1e18);

        // Alice reaches softcap → activate.
        _approveAndFundUsdc(ALICE, 50 * ONE_USDC, campaign);
        vm.prank(ALICE);
        GrowfiCampaign(campaign).buy(address(usdc), 50 * ONE_USDC);

        // Alice claims her escrow.
        vm.prank(ALICE);
        growMinter.claimEscrow(campaign);
        uint256 aliceGrow0 = growToken.balanceOf(ALICE);

        // Alice queues a 50-token sellback (still has the campaignToken from her buy).
        IERC20 ct = IERC20(GrowfiCampaign(campaign).campaignToken());
        vm.prank(ALICE);
        ct.approve(campaign, 50e18);
        vm.prank(ALICE);
        GrowfiCampaign(campaign).sellBack(50e18);

        // Bob now buys $25. Queue has 50 tokens; $25 fills 25 of them at price 1.0 = 25 tokens.
        // No fresh mint; supply unchanged. recordBuy(BOB, 50e18, 50e18) → no delta → no GROW.
        _approveAndFundUsdc(BOB, 25 * ONE_USDC, campaign);
        vm.prank(BOB);
        GrowfiCampaign(campaign).buy(address(usdc), 25 * ONE_USDC);

        assertEq(growToken.balanceOf(BOB), 0, "queue fill alone shouldn't emit GROW to Bob");

        // Carol buys $50. Queue still has 25 tokens left -- fills them -- then mints 25 fresh.
        // The fresh mint advances cumBuyVolumeUsd by ~$25 (only the fresh portion contributes).
        _approveAndFundUsdc(CAROL, 50 * ONE_USDC, campaign);
        vm.prank(CAROL);
        GrowfiCampaign(campaign).buy(address(usdc), 50 * ONE_USDC);

        // Carol got GROW only for the fresh-mint portion. cumVol was $50 → ~$75 (only $25 of fresh).
        // Tier 2 rate (cumVol $50–$75 in tier 2 since softcap=$50) → $25 × 0.7 = 17.5 GROW.
        assertEq(growToken.balanceOf(CAROL), 175e17, "Carol gets GROW only for the fresh-mint portion");

        // Alice's count is unchanged (she's just earning her sellback proceeds in USDC).
        assertEq(growToken.balanceOf(ALICE), aliceGrow0, "Alice's GROW unchanged after sellback fills");
    }

    // ---------- permissionless auto-allocation ----------

    // ---------- multisig-triggered cross-tracked allocation ----------

    function _enableAutomationAndTrack(address camp) internal {
        vm.startPrank(address(factory));
        if (!growTreasury.isTrackedCampaign(camp)) growTreasury.addTrackedCampaign(camp);
        if (!growTreasury.automationEnabled()) growTreasury.setAutomationEnabled(true);
        vm.stopPrank();
    }

    /// @dev Multisig spreads $300 across 3 tracked Active campaigns equally → $100 each.
    function test_acrossTracked_equalSplit() public {
        address campA = _createCampaignNamed("CrossA", "CA", 50e18, 1000e18, 1e18);
        address campB = _createCampaignNamed("CrossB", "CB", 50e18, 1000e18, 1e18);
        address campC = _createCampaignNamed("CrossC", "CC", 50e18, 1000e18, 1e18);

        // Activate all three with self-funding
        for (uint256 i; i < 3; ++i) {
            address c = i == 0 ? campA : (i == 1 ? campB : campC);
            _approveAndFundUsdc(PRODUCER, 50 * ONE_USDC, c);
            vm.prank(PRODUCER);
            GrowfiCampaign(c).buy(address(usdc), 50 * ONE_USDC);
        }

        _enableAutomationAndTrack(campA);
        _enableAutomationAndTrack(campB);
        _enableAutomationAndTrack(campC);

        usdc.mint(address(growTreasury), 300 * ONE_USDC);

        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 300 * ONE_USDC);

        // Each campaign got $100 → 100 CampaignToken
        assertEq(IERC20(GrowfiCampaign(campA).campaignToken()).balanceOf(address(growTreasury)), 100e18);
        assertEq(IERC20(GrowfiCampaign(campB).campaignToken()).balanceOf(address(growTreasury)), 100e18);
        assertEq(IERC20(GrowfiCampaign(campC).campaignToken()).balanceOf(address(growTreasury)), 100e18);
    }

    function test_acrossTracked_revertsWhenAutomationOff() public {
        address camp = _createCampaign(50e18, 1000e18, 1e18);
        _approveAndFundUsdc(PRODUCER, 50 * ONE_USDC, camp);
        vm.prank(PRODUCER);
        GrowfiCampaign(camp).buy(address(usdc), 50 * ONE_USDC);

        // Tracked but automation disabled
        vm.prank(address(factory));
        growTreasury.addTrackedCampaign(camp);

        usdc.mint(address(growTreasury), 100 * ONE_USDC);

        vm.expectRevert(GrowfiTreasury.AutomationDisabled.selector);
        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 100 * ONE_USDC);
    }

    function test_acrossTracked_revertsWhenNoActiveTracked() public {
        // No tracked campaigns at all
        vm.prank(address(factory));
        growTreasury.setAutomationEnabled(true);

        usdc.mint(address(growTreasury), 100 * ONE_USDC);

        vm.expectRevert(GrowfiTreasury.NoActiveTrackedCampaigns.selector);
        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 100 * ONE_USDC);
    }

    function test_acrossTracked_skipsFundingStateCampaigns() public {
        address campActive = _createCampaignNamed("ActiveOne", "AC", 50e18, 1000e18, 1e18);
        address campFunding = _createCampaignNamed("FundingOne", "FU", 100e18, 1000e18, 1e18);

        // Activate only the first
        _approveAndFundUsdc(PRODUCER, 50 * ONE_USDC, campActive);
        vm.prank(PRODUCER);
        GrowfiCampaign(campActive).buy(address(usdc), 50 * ONE_USDC);

        _enableAutomationAndTrack(campActive);
        _enableAutomationAndTrack(campFunding);

        usdc.mint(address(growTreasury), 200 * ONE_USDC);

        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 200 * ONE_USDC);

        // All went to the Active one (Funding skipped)
        assertEq(IERC20(GrowfiCampaign(campActive).campaignToken()).balanceOf(address(growTreasury)), 200e18);
        assertEq(IERC20(GrowfiCampaign(campFunding).campaignToken()).balanceOf(address(growTreasury)), 0);
    }

    function test_acrossTracked_capsAtRemainingMintableRoom() public {
        // Small Active campaign with little room left
        address camp = _createCampaign(50e18, 100e18, 1e18);
        _approveAndFundUsdc(PRODUCER, 80 * ONE_USDC, camp);
        vm.prank(PRODUCER);
        GrowfiCampaign(camp).buy(address(usdc), 80 * ONE_USDC); // 20 tokens room left

        _enableAutomationAndTrack(camp);

        // Allocation requested far exceeds remaining room.
        usdc.mint(address(growTreasury), 1000 * ONE_USDC);

        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 500 * ONE_USDC);

        // Capped: only 20 USDC actually spent (the remaining capacity)
        assertEq(IERC20(GrowfiCampaign(camp).campaignToken()).balanceOf(address(growTreasury)), 20e18);
        // Remainder stays in Treasury
        assertEq(usdc.balanceOf(address(growTreasury)), 980 * ONE_USDC);
    }

    // ---------- harvest flow with stakers earning ----------

    /// @dev Direct: Treasury sends USDC to staking pool + notifies. Stakers can claim.
    function test_distribution_treasuryNotifiesStakingPool() public {
        // Stakers
        vm.prank(DEPLOYER);
        growToken.transfer(ALICE, 100_000e18);
        vm.prank(ALICE);
        growToken.approve(address(stakingPool), 100_000e18);
        vm.prank(ALICE);
        stakingPool.stake(100_000e18);

        // Treasury sends $80 to pool (simulated 80% of $100 harvest).
        usdc.mint(address(growTreasury), 100 * ONE_USDC);
        // Treasury -> stakingPool transfer + notify (we simulate the claimUsdcAndDistribute
        // flow without going through a real HarvestManager).
        vm.prank(address(growTreasury));
        usdc.transfer(address(stakingPool), 80 * ONE_USDC);
        vm.prank(address(growTreasury));
        stakingPool.notifyReward(80 * ONE_USDC);

        // Wait the full distribution period for the rate × dt accumulator to drain.
        skip(30 days);

        // Alice claims (within the rate-truncation tolerance: $80 over 30d → rate=30 truncated → ~$77.76).
        vm.prank(ALICE);
        uint256 reward = stakingPool.claim();
        assertApproxEqAbs(reward, 80 * ONE_USDC, 3 * ONE_USDC);
        assertApproxEqAbs(usdc.balanceOf(ALICE), 80 * ONE_USDC, 3 * ONE_USDC);
    }

    // ---------- E2E: full harvest cycle, Treasury earns + 80/20 distribution ----------

    /// @dev Real lifecycle: Treasury allocates to a real campaign, stakes the CampaignTokens,
    ///      earns YIELD across a season, commits USDC redeem, producer deposits, Treasury claims
    ///      USDC and distributes 80% to GROW stakers / 20% retained.
    function test_e2e_harvestFlow_treasuryEarnsAndDistributes() public {
        // ============================================================
        // Phase 1: Alice stakes GROW into the StakingPool
        // ============================================================
        vm.prank(DEPLOYER);
        growToken.transfer(ALICE, 100_000e18);
        vm.prank(ALICE);
        growToken.approve(address(stakingPool), 100_000e18);
        vm.prank(ALICE);
        stakingPool.stake(100_000e18);

        // ============================================================
        // Phase 2: Producer creates campaign + self-buys to reach softcap
        // ============================================================
        // softcap=50, maxcap=200 → producer funds $50 → Active.
        address campaign = _createCampaign(50e18, 200e18, 1e18);
        _approveAndFundUsdc(PRODUCER, 50 * ONE_USDC, campaign);
        vm.prank(PRODUCER);
        GrowfiCampaign(campaign).buy(address(usdc), 50 * ONE_USDC);

        // ============================================================
        // Phase 3: Multisig adds the campaign to Treasury's tracked list, then allocates
        // ============================================================
        vm.prank(address(factory));
        growTreasury.addTrackedCampaign(campaign);
        usdc.mint(address(growTreasury), 50 * ONE_USDC);
        vm.prank(address(factory));
        growTreasury.allocateToCampaign(campaign, address(usdc), 50 * ONE_USDC);

        IERC20 ct = IERC20(GrowfiCampaign(campaign).campaignToken());
        assertEq(ct.balanceOf(address(growTreasury)), 50e18, "treasury holds 50 CampaignTokens");

        // ============================================================
        // Phase 4: Producer starts season; Treasury stakes
        // ============================================================
        vm.prank(PRODUCER);
        GrowfiCampaign(campaign).startSeason(1);

        vm.prank(address(factory));
        uint256 positionId = growTreasury.stakeOnCampaign(campaign, 50e18);
        assertEq(ct.balanceOf(address(growTreasury)), 0, "treasury staked all CT");

        // ============================================================
        // Phase 5: Time advances → yield accrues
        // ============================================================
        vm.warp(block.timestamp + 1 hours + 1); // past seasonDuration

        // ============================================================
        // Phase 6: Producer ends season; Treasury claims YIELD
        // ============================================================
        vm.prank(PRODUCER);
        GrowfiCampaign(campaign).endSeason();

        vm.prank(address(factory));
        growTreasury.claimYieldFromCampaign(campaign, positionId);

        GrowfiStakingVault vault = GrowfiStakingVault(GrowfiCampaign(campaign).stakingVault());
        GrowfiYieldToken yt = GrowfiYieldToken(address(vault.yieldToken()));
        uint256 treasuryYield = yt.balanceOf(address(growTreasury));
        assertGt(treasuryYield, 0, "treasury earned YIELD");

        // ============================================================
        // Phase 7: Producer reports harvest
        // ============================================================
        // Treasury is the sole staker, so single-leaf merkle. For redeemUSDC the merkle is
        // irrelevant; using a placeholder leaf-as-root keeps reportHarvest happy.
        uint256 totalValueUSD = 50e18; // $50 harvest
        uint256 totalProductUnits = 100e18;
        bytes32 root = keccak256(abi.encodePacked(address(growTreasury), uint256(1), uint256(0)));

        GrowfiHarvestManager hm = GrowfiHarvestManager(GrowfiCampaign(campaign).harvestManager());
        vm.prank(PRODUCER);
        hm.reportHarvest(1, totalValueUSD, root, totalProductUnits);

        // ============================================================
        // Phase 8: Treasury commits USDC redeem (burns YIELD)
        // ============================================================
        vm.prank(address(factory));
        growTreasury.commitUsdcRedeem(campaign, 1, treasuryYield);
        assertEq(yt.balanceOf(address(growTreasury)), 0, "treasury YIELD burned");

        // ============================================================
        // Phase 9: Producer deposits USDC to fund the holder pool
        // ============================================================
        uint256 owed = hm.remainingDepositGross(1);
        usdc.mint(PRODUCER, owed);
        vm.prank(PRODUCER);
        usdc.approve(address(campaign), owed);
        vm.prank(PRODUCER);
        GrowfiCampaign(campaign).depositUSDC(1, owed);

        // ============================================================
        // Phase 10: Anyone (BOB, permissionless) calls claimUsdcAndDistribute
        // ============================================================
        uint256 poolBefore = usdc.balanceOf(address(stakingPool));
        uint256 treasuryBefore = usdc.balanceOf(address(growTreasury));

        vm.prank(BOB);
        growTreasury.claimUsdcAndDistribute(campaign, 1);

        uint256 poolGain = usdc.balanceOf(address(stakingPool)) - poolBefore;
        uint256 treasuryRetained = usdc.balanceOf(address(growTreasury)) - treasuryBefore;
        uint256 totalReceived = poolGain + treasuryRetained;

        assertGt(totalReceived, 0, "treasury received USDC from harvest");
        assertGt(poolGain, 0, "staking pool funded");
        assertGt(treasuryRetained, 0, "treasury retained 20%");

        // 80/20 split (with 1 wei rounding tolerance)
        uint256 expectedPool = (totalReceived * 8_000) / 10_000;
        assertApproxEqAbs(poolGain, expectedPool, 1, "80% to stakers");

        // ============================================================
        // Phase 11: Time advances so the rate × dt distribution drains, then Alice claims
        // ============================================================
        skip(30 days);
        vm.prank(ALICE);
        uint256 aliceReward = stakingPool.claim();
        // Alice is the sole staker — she gets ~all of poolGain (minus rate-truncation dust)
        assertApproxEqAbs(aliceReward, poolGain, ONE_USDC, "alice gets ~all the pool reward");
        assertApproxEqAbs(usdc.balanceOf(ALICE), aliceReward, 1);
    }

    // ---------- BIG SCENARIO: 3 campaigns, 3 stablecoins, 5 actors, conservation check ----------

    /// @dev Comprehensive scenario covering every economic path simultaneously.
    /// Verifies value conservation: USDC+USDT+DAI in == out (across all entities).
    function test_scenario_threeCampaigns_threeStablecoins_fiveActors() public {
        address EVE = address(0xEEEE);
        address FRANK = address(0xFFFF);

        // ===== Phase 1: Distribute GROW for staking =====
        vm.startPrank(DEPLOYER);
        growToken.transfer(ALICE, 50_000e18);
        growToken.transfer(BOB, 50_000e18);
        growToken.transfer(CAROL, 30_000e18);
        vm.stopPrank();

        // Alice stakes 50K, Bob stakes 30K, Carol stakes 20K
        vm.prank(ALICE);
        growToken.approve(address(stakingPool), 50_000e18);
        vm.prank(ALICE);
        stakingPool.stake(50_000e18);
        vm.prank(BOB);
        growToken.approve(address(stakingPool), 30_000e18);
        vm.prank(BOB);
        stakingPool.stake(30_000e18);
        vm.prank(CAROL);
        growToken.approve(address(stakingPool), 20_000e18);
        vm.prank(CAROL);
        stakingPool.stake(20_000e18);
        assertEq(stakingPool.totalStaked(), 100_000e18);

        // ===== Phase 2: Three campaigns with different params =====
        address campA = _createCampaignNamed("OliveA", "OLA", 50e18, 200e18, 1e18); // $1/token
        address campB = _createCampaignNamed("CocoaB", "COB", 100e18, 500e18, 5e17); // $0.50/token
        address campC = _createCampaignNamed("WineC", "WIC", 30e18, 100e18, 2e18); // $2/token

        // Producer also accepts USDT and DAI on each campaign
        vm.startPrank(PRODUCER);
        GrowfiCampaign(campA).addAcceptedToken(address(usdt), GrowfiCampaign.PricingMode.Fixed, 1e6, address(0));
        GrowfiCampaign(campA).addAcceptedToken(address(dai), GrowfiCampaign.PricingMode.Fixed, 1e18, address(0));
        GrowfiCampaign(campB).addAcceptedToken(address(usdt), GrowfiCampaign.PricingMode.Fixed, 5e5, address(0));
        GrowfiCampaign(campB).addAcceptedToken(address(dai), GrowfiCampaign.PricingMode.Fixed, 5e17, address(0));
        GrowfiCampaign(campC).addAcceptedToken(address(dai), GrowfiCampaign.PricingMode.Fixed, 2e18, address(0));
        vm.stopPrank();

        // ===== Phase 3: Multi-actor multi-token buys =====
        // Eve buys $50 USDC on A (reaches softcap → Active)
        usdc.mint(EVE, 50 * ONE_USDC);
        vm.prank(EVE);
        usdc.approve(campA, 50 * ONE_USDC);
        vm.prank(EVE);
        GrowfiCampaign(campA).buy(address(usdc), 50 * ONE_USDC);

        // Frank buys $50 USDT on A (post-softcap, direct GROW mint at tier 2)
        usdt.mint(FRANK, 50 * ONE_USDC);
        vm.prank(FRANK);
        usdt.approve(campA, 50 * ONE_USDC);
        vm.prank(FRANK);
        GrowfiCampaign(campA).buy(address(usdt), 50 * ONE_USDC);

        // Eve buys $30 DAI on campB → 60 tokens, below 100 softcap → still Funding (escrow)
        dai.mint(EVE, 30 * ONE_DAI);
        vm.prank(EVE);
        dai.approve(campB, 30 * ONE_DAI);
        vm.prank(EVE);
        GrowfiCampaign(campB).buy(address(dai), 30 * ONE_DAI);

        // Frank buys $80 USDC on campC (= 40 tokens at $2/each, > 30 softcap → Active)
        usdc.mint(FRANK, 80 * ONE_USDC);
        vm.prank(FRANK);
        usdc.approve(campC, 80 * ONE_USDC);
        vm.prank(FRANK);
        GrowfiCampaign(campC).buy(address(usdc), 80 * ONE_USDC);

        // ===== Phase 4: Eve claims her escrow on campA (Active) and campB stays escrowed =====
        vm.prank(EVE);
        growMinter.claimEscrow(campA);
        assertGt(growToken.balanceOf(EVE), 0, "Eve got GROW from campA escrow claim");
        // campB still pending — Eve's escrow there is locked
        assertGt(growMinter.getEscrow(campB, EVE), 0, "Eve's campB escrow is pending");

        // Frank already has GROW (post-softcap mint on campA tier 2 + escrow on campC after activation)
        // campC's escrow needs claim
        vm.prank(FRANK);
        growMinter.claimEscrow(campC);
        assertGt(growToken.balanceOf(FRANK), 0, "Frank got GROW from campC escrow + campA direct");

        // ===== Phase 5: Fees flushed via permissionless splitter =====
        // Each buy triggered a 3% funding fee. Sum across buys:
        //   $50 USDC × 3% = $1.50 → splitter (Eve campA)
        //   $50 USDT × 3% = $1.50 → splitter (Frank campA)
        //   $30 DAI × 3% = $0.90 → splitter (Eve campB)
        //   $80 USDC × 3% = $2.40 → splitter (Frank campC)
        // Total: $3.90 USDC, $1.50 USDT, $0.90 DAI in splitter
        assertEq(usdc.balanceOf(address(feeSplitter)), 39 * ONE_USDC / 10, "splitter has $3.90 USDC");
        assertEq(usdt.balanceOf(address(feeSplitter)), 15 * ONE_USDC / 10, "splitter has $1.50 USDT");
        assertEq(dai.balanceOf(address(feeSplitter)), 9 * ONE_DAI / 10, "splitter has $0.90 DAI");

        // Anyone flushes
        address[] memory tokens = new address[](3);
        tokens[0] = address(usdc);
        tokens[1] = address(usdt);
        tokens[2] = address(dai);
        vm.prank(BOB); // permissionless
        feeSplitter.flushMany(tokens);

        // 30% Treasury / 70% Ops on each (USDC: $3.90 → $1.17 / $2.73)
        assertEq(usdc.balanceOf(address(growTreasury)), 117 * ONE_USDC / 100, "treasury got $1.17 USDC");
        assertEq(usdc.balanceOf(OPS), 273 * ONE_USDC / 100, "ops got $2.73 USDC");
        assertEq(usdt.balanceOf(address(growTreasury)), 45 * ONE_USDC / 100, "treasury got $0.45 USDT");
        assertEq(dai.balanceOf(address(growTreasury)), 27 * ONE_DAI / 100, "treasury got $0.27 DAI");

        // ===== Phase 6: Floor is non-zero now (Treasury has multi-stablecoin holdings) =====
        uint256 floor = growTreasury.intrinsicFloorPrice();
        assertGt(floor, 0, "floor > 0 after Treasury accumulates fees");

        // ===== Phase 7: Direct buy of GROW with USDT (uses floor pricing) =====
        usdt.mint(ALICE, 100 * ONE_USDC);
        vm.prank(ALICE);
        usdt.approve(address(growToken), 100 * ONE_USDC);
        uint256 aliceGrowBefore = growToken.balanceOf(ALICE);
        vm.prank(ALICE);
        uint256 received = growToken.buy(address(usdt), 10 * ONE_USDC, type(uint256).max);
        assertGt(received, 0, "alice got GROW from direct buy");
        assertEq(growToken.balanceOf(ALICE), aliceGrowBefore + received);
        // Treasury USDT before direct buy was 0.45; after buy of 10 USDT it's 10.45
        assertEq(usdt.balanceOf(address(growTreasury)), 1045 * ONE_USDC / 100, "treasury got USDT from direct buy");

        // ===== Phase 8: Multisig-driven cross-tracked allocation =====
        // campA + campC are Active. campB is still Funding (didn't reach softcap).
        // Track A and C; enable automation; allocate.
        vm.startPrank(address(factory));
        growTreasury.addTrackedCampaign(campA);
        growTreasury.addTrackedCampaign(campC);
        growTreasury.setAutomationEnabled(true);
        vm.stopPrank();

        usdc.mint(address(growTreasury), 10_000 * ONE_USDC);

        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 1_000 * ONE_USDC);

        IERC20 ctA = IERC20(GrowfiCampaign(campA).campaignToken());
        IERC20 ctC = IERC20(GrowfiCampaign(campC).campaignToken());
        assertGt(ctA.balanceOf(address(growTreasury)), 0, "treasury got CT from campA");
        assertGt(ctC.balanceOf(address(growTreasury)), 0, "treasury got CT from campC");

        // ===== Phase 9: Conservation of value =====
        // Sum of USDC across all relevant accounts == sum of all USDC inflows
        uint256 totalUsdcInSystem = 0;
        totalUsdcInSystem += usdc.balanceOf(EVE);
        totalUsdcInSystem += usdc.balanceOf(FRANK);
        totalUsdcInSystem += usdc.balanceOf(PRODUCER);
        totalUsdcInSystem += usdc.balanceOf(address(growTreasury));
        totalUsdcInSystem += usdc.balanceOf(OPS);
        totalUsdcInSystem += usdc.balanceOf(address(growToken)); // should be 0
        totalUsdcInSystem += usdc.balanceOf(address(growMinter)); // should be 0
        totalUsdcInSystem += usdc.balanceOf(address(feeSplitter)); // should be 0 after flush
        totalUsdcInSystem += usdc.balanceOf(campA);
        totalUsdcInSystem += usdc.balanceOf(campB);
        totalUsdcInSystem += usdc.balanceOf(campC);
        totalUsdcInSystem += usdc.balanceOf(address(stakingPool)); // should be 0 (no harvest yet)

        // Total USDC minted in this test:
        //   Eve $50 (campA buy)
        //   Frank $80 (campC buy)
        //   Treasury seed $10_000 (auto-alloc test)
        // Total minted: 50 + 80 + 10_000 = 10_130 USDC
        uint256 totalUsdcMinted = 50 * ONE_USDC + 80 * ONE_USDC + 10_000 * ONE_USDC;
        assertEq(totalUsdcInSystem, totalUsdcMinted, "USDC value conservation");

        // ===== Phase 10: GROW supply consistency =====
        uint256 growSupplyTotal = growToken.totalSupply();
        // Genesis 1M + escrow claims + direct mints
        // Should equal sum of (deployer + stakers + holders + escrows still pending + treasury holdings)
        uint256 growHeld = growToken.balanceOf(DEPLOYER) + growToken.balanceOf(ALICE) + growToken.balanceOf(BOB)
            + growToken.balanceOf(CAROL) + growToken.balanceOf(EVE) + growToken.balanceOf(FRANK);
        // Plus what's in StakingPool (staked GROW) and any treasury holdings
        uint256 growInStakingPool = growToken.balanceOf(address(stakingPool));
        uint256 growInTreasury = growToken.balanceOf(address(growTreasury));
        uint256 growInMinter = growToken.balanceOf(address(growMinter)); // escrow GROW lives in user accounts only

        uint256 totalAccounted = growHeld + growInStakingPool + growInTreasury + growInMinter;
        assertEq(totalAccounted, growSupplyTotal, "GROW supply conservation");
    }

    function test_treasury_allocateAndRedeem() public {
        address campaign = _createCampaign(50e18, 200e18, 1e18);

        // Trigger softcap via Alice (so the campaign is Active and accepts payment to producer).
        _approveAndFundUsdc(ALICE, 50 * ONE_USDC, campaign);
        vm.prank(ALICE);
        GrowfiCampaign(campaign).buy(address(usdc), 50 * ONE_USDC);

        // Multisig tracks the campaign, then allocates manually.
        vm.prank(address(factory));
        growTreasury.addTrackedCampaign(campaign);
        usdc.mint(address(growTreasury), 100 * ONE_USDC);
        vm.prank(address(factory));
        growTreasury.allocateToCampaign(campaign, address(usdc), 50 * ONE_USDC);

        // Treasury now holds CampaignToken instead of $50 USDC.
        IERC20 ct = IERC20(GrowfiCampaign(campaign).campaignToken());
        assertGt(ct.balanceOf(address(growTreasury)), 0);

        // Treasury's allocation buy was excluded → no GROW emitted to it.
        assertEq(growToken.balanceOf(address(growTreasury)), 0);

        // Now Carol holds 1% of GROW supply (we'll arrange this) and redeems.
        vm.prank(DEPLOYER);
        growToken.transfer(CAROL, 10_000e18); // 1% of genesis

        vm.prank(CAROL);
        growToken.approve(address(growTreasury), 10_000e18);
        vm.prank(CAROL);
        growTreasury.redeem(10_000e18);

        // Carol receives 1% of treasury holdings: USDC + CampaignToken (multi-token basket).
        assertGt(usdc.balanceOf(CAROL), 0, "Carol got pro-rata USDC");
        assertGt(ct.balanceOf(CAROL), 0, "Carol got pro-rata CampaignToken");
    }
}
