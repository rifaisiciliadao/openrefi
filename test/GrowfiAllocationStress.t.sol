// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GrowfiCampaignFactory} from "../src/GrowfiCampaignFactory.sol";
import {GrowfiCampaign} from "../src/GrowfiCampaign.sol";
import {GrowfiToken} from "../src/GrowfiToken.sol";
import {GrowfiTreasury} from "../src/GrowfiTreasury.sol";
import {GrowfiMinter} from "../src/GrowfiMinter.sol";
import {GrowfiFeeSplitter} from "../src/GrowfiFeeSplitter.sol";
import {GrowfiStakingPool} from "../src/GrowfiStakingPool.sol";
import {Deployer} from "./helpers/Deployer.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {MockOracle} from "./helpers/MockOracle.sol";

/// @dev Stress + edge-case tests for `Treasury.allocateAcrossTracked` and the hide/ban system.
contract GrowfiAllocationStressTest is Test {
    GrowfiCampaignFactory factory;
    GrowfiToken growToken;
    GrowfiTreasury growTreasury;
    GrowfiMinter growMinter;
    GrowfiFeeSplitter feeSplitter;
    MockERC20 usdc;
    MockERC20 usdt;
    MockERC20 dai;
    MockOracle usdFeed;

    address constant OWNER = address(0xF000);
    address constant OPS = address(0x0123);
    address constant DEPLOYER = address(0xD000);
    address constant PRODUCER = address(0xA1);
    address constant ATTACKER = address(0xBAD);

    uint256 constant ONE_USDC = 1e6;
    uint256 constant ONE_DAI = 1e18;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);
        dai = new MockERC20("Dai", "DAI", 18);
        usdFeed = new MockOracle(int256(1e8), 8); // $1.00 8-dec

        factory = Deployer.deployProtocol(OWNER, OWNER, address(usdc), address(0));
        vm.prank(OWNER);
        factory.setMinSeasonDuration(1 hours);

        // GROW system
        GrowfiToken tImpl = new GrowfiToken();
        bytes memory tInit = abi.encodeCall(
            GrowfiToken.initialize, ("GrowFi", "GROW", address(factory), DEPLOYER, 1_000_000e18, 1_000, 1e17)
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
        factory.setGrowfiTreasuryAutomationEnabled(true);
        vm.stopPrank();

        vm.startPrank(address(factory));
        growToken.setMinter(address(growMinter));
        growToken.setTreasury(address(growTreasury));
        growTreasury.addAcceptedStablecoin(address(usdc), 1e12, address(usdFeed), 24 hours, 9_500, 10_500);
        growTreasury.addAcceptedStablecoin(address(usdt), 1e12, address(usdFeed), 24 hours, 9_500, 10_500);
        growTreasury.addAcceptedStablecoin(address(dai), 1, address(usdFeed), 24 hours, 9_500, 10_500);
        growMinter.setExcludedFromMint(address(growTreasury), true);
        vm.stopPrank();
    }

    function _createAndActivate(string memory name, uint256 minCap, uint256 maxCap, uint256 price)
        internal
        returns (address camp)
    {
        vm.prank(PRODUCER);
        camp = factory.createCampaign(
            GrowfiCampaignFactory.CreateCampaignParams({
                producer: PRODUCER,
                tokenName: name,
                tokenSymbol: "T",
                yieldName: "Y",
                yieldSymbol: "y",
                pricePerToken: price,
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
        GrowfiCampaign(camp).addAcceptedToken(address(usdc), GrowfiCampaign.PricingMode.Fixed, price / 1e12, address(0));
        vm.prank(PRODUCER);
        GrowfiCampaign(camp).addAcceptedToken(address(usdt), GrowfiCampaign.PricingMode.Fixed, price / 1e12, address(0));
        vm.prank(PRODUCER);
        GrowfiCampaign(camp).addAcceptedToken(address(dai), GrowfiCampaign.PricingMode.Fixed, price, address(0));

        // Activate via producer self-funding (uses USDC, the canonical token in the deploy)
        uint256 selfFund = (minCap * price) / 1e30; // USDC raw amount
        if (selfFund > 0) {
            usdc.mint(PRODUCER, selfFund);
            vm.prank(PRODUCER);
            usdc.approve(camp, selfFund);
            vm.prank(PRODUCER);
            GrowfiCampaign(camp).buy(address(usdc), selfFund);
        }
    }

    function _create(string memory name, uint256 minCap, uint256 maxCap, uint256 price)
        internal
        returns (address camp)
    {
        vm.prank(PRODUCER);
        camp = factory.createCampaign(
            GrowfiCampaignFactory.CreateCampaignParams({
                producer: PRODUCER,
                tokenName: name,
                tokenSymbol: "T",
                yieldName: "Y",
                yieldSymbol: "y",
                pricePerToken: price,
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
        GrowfiCampaign(camp).addAcceptedToken(address(usdc), GrowfiCampaign.PricingMode.Fixed, price / 1e12, address(0));
    }

    function _track(address camp) internal {
        vm.prank(address(factory));
        growTreasury.addTrackedCampaign(camp);
    }

    // ============================================================
    // BASIC SCENARIOS
    // ============================================================

    /// @dev 20 active tracked campaigns, $20 budget -> each gets $1.
    function test_stress_twentyCampaignsEqualSplit() public {
        address[] memory camps = new address[](20);
        for (uint256 i; i < 20; ++i) {
            string memory name = string(abi.encodePacked("C", vm.toString(i)));
            camps[i] = _createAndActivate(name, 50e18, 1000e18, 1e18);
            _track(camps[i]);
        }

        usdc.mint(address(growTreasury), 20 * ONE_USDC);

        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 20 * ONE_USDC);

        // Each got 1 token
        for (uint256 i; i < 20; ++i) {
            IERC20 ct = IERC20(GrowfiCampaign(camps[i]).campaignToken());
            assertEq(ct.balanceOf(address(growTreasury)), 1e18, "each campaign got $1 -> 1 token");
        }
    }

    /// @dev Mixed states: only Active tracked receive. Funding/Buyback/Ended skipped.
    function test_stress_mixedStates_onlyActiveReceive() public {
        address campActive = _createAndActivate("ActiveS", 50e18, 1000e18, 1e18);
        address campFunding = _create("FundingS", 100e18, 1000e18, 1e18); // not activated
        // Build a Buyback campaign: create, don't reach softcap, warp past deadline, trigger buyback.
        address campBuyback = _create("BuybackS", 100e18, 200e18, 1e18);
        skip(31 days);
        GrowfiCampaign(campBuyback).triggerBuyback();

        _track(campActive);
        _track(campFunding);
        _track(campBuyback);

        usdc.mint(address(growTreasury), 300 * ONE_USDC);

        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 300 * ONE_USDC);

        // All to the Active one (Funding + Buyback skipped)
        IERC20 ctA = IERC20(GrowfiCampaign(campActive).campaignToken());
        IERC20 ctF = IERC20(GrowfiCampaign(campFunding).campaignToken());
        IERC20 ctB = IERC20(GrowfiCampaign(campBuyback).campaignToken());

        assertEq(ctA.balanceOf(address(growTreasury)), 300e18);
        assertEq(ctF.balanceOf(address(growTreasury)), 0);
        assertEq(ctB.balanceOf(address(growTreasury)), 0);
    }

    /// @dev Some Active campaigns at maxCap -> skipped, others receive proportionally.
    function test_stress_someAtMaxCap_skipped() public {
        address campA = _createAndActivate("FullA", 50e18, 100e18, 1e18);
        // Fill A to maxCap by additional buys
        usdc.mint(PRODUCER, 50 * ONE_USDC);
        vm.prank(PRODUCER);
        usdc.approve(campA, 50 * ONE_USDC);
        vm.prank(PRODUCER);
        GrowfiCampaign(campA).buy(address(usdc), 50 * ONE_USDC); // now full at maxCap

        address campB = _createAndActivate("RoomB", 50e18, 1000e18, 1e18);

        _track(campA);
        _track(campB);

        usdc.mint(address(growTreasury), 200 * ONE_USDC);

        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 200 * ONE_USDC);

        IERC20 ctA = IERC20(GrowfiCampaign(campA).campaignToken());
        IERC20 ctB = IERC20(GrowfiCampaign(campB).campaignToken());

        // A is excluded from activeCount in the first pass (full -> mintableRoom == 0).
        // activeCount = 1, perCampaign = $200/1 = $200 -> B gets the full $200.
        assertEq(ctA.balanceOf(address(growTreasury)), 0);
        assertEq(ctB.balanceOf(address(growTreasury)), 200e18);
        assertEq(usdc.balanceOf(address(growTreasury)), 0);
    }

    /// @dev Total amount > total mintable capacity -> caps each at remaining room, dust stays.
    function test_stress_overBudget_capsToCapacity() public {
        // Two small campaigns with limited room
        address campA = _createAndActivate("SmallA", 50e18, 60e18, 1e18); // 10 room left after activation
        address campB = _createAndActivate("SmallB", 50e18, 60e18, 1e18); // 10 room left

        _track(campA);
        _track(campB);

        // Massive budget
        usdc.mint(address(growTreasury), 1_000 * ONE_USDC);

        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 1_000 * ONE_USDC);

        IERC20 ctA = IERC20(GrowfiCampaign(campA).campaignToken());
        IERC20 ctB = IERC20(GrowfiCampaign(campB).campaignToken());

        // Each capped at 10 tokens. Treasury keeps 980 USDC.
        assertEq(ctA.balanceOf(address(growTreasury)), 10e18);
        assertEq(ctB.balanceOf(address(growTreasury)), 10e18);
        assertEq(usdc.balanceOf(address(growTreasury)), 980 * ONE_USDC);
    }

    // ============================================================
    // PRICE / SCALE EDGE CASES
    // ============================================================

    /// @dev Different prices — high-price campaign gets fewer tokens for the same USDC.
    function test_stress_differentPrices_proportionalTokensOut() public {
        address campCheap = _createAndActivate("Cheap", 10e18, 1000e18, 5e17); // $0.50/token
        address campMid = _createAndActivate("Mid", 10e18, 1000e18, 1e18); // $1.00/token
        address campExp = _createAndActivate("Exp", 10e18, 1000e18, 5e18); // $5.00/token

        _track(campCheap);
        _track(campMid);
        _track(campExp);

        usdc.mint(address(growTreasury), 30 * ONE_USDC);

        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 30 * ONE_USDC);

        // Each gets $10. Tokens out: cheap=20, mid=10, exp=2.
        assertEq(IERC20(GrowfiCampaign(campCheap).campaignToken()).balanceOf(address(growTreasury)), 20e18);
        assertEq(IERC20(GrowfiCampaign(campMid).campaignToken()).balanceOf(address(growTreasury)), 10e18);
        assertEq(IERC20(GrowfiCampaign(campExp).campaignToken()).balanceOf(address(growTreasury)), 2e18);
    }

    /// @dev Same allocation works with USDT (6-dec, scale=1e12) — same outcome as USDC.
    function test_stress_paymentWithUsdt() public {
        address camp = _createAndActivate("UsdtCamp", 50e18, 1000e18, 1e18);
        _track(camp);

        usdt.mint(address(growTreasury), 100 * ONE_USDC);

        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdt), 100 * ONE_USDC);

        IERC20 ct = IERC20(GrowfiCampaign(camp).campaignToken());
        assertEq(ct.balanceOf(address(growTreasury)), 100e18);
    }

    /// @dev Same allocation works with DAI (18-dec, scale=1) — same outcome.
    function test_stress_paymentWithDai() public {
        address camp = _createAndActivate("DaiCamp", 50e18, 1000e18, 1e18);
        _track(camp);

        dai.mint(address(growTreasury), 100 * ONE_DAI);

        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(dai), 100 * ONE_DAI);

        IERC20 ct = IERC20(GrowfiCampaign(camp).campaignToken());
        assertEq(ct.balanceOf(address(growTreasury)), 100e18);
    }

    // ============================================================
    // RESILIENCE: ONE BAD CAMPAIGN DOESN'T DOS THE BATCH
    // ============================================================

    /// @dev If one tracked campaign is paused, allocation skips it and continues with others.
    function test_stress_pausedCampaignDoesNotBlockBatch() public {
        address campOk = _createAndActivate("OkOne", 50e18, 1000e18, 1e18);
        address campPaused = _createAndActivate("PausedOne", 50e18, 1000e18, 1e18);

        _track(campOk);
        _track(campPaused);

        // Pause one of them
        // Find its index
        uint256 idx;
        for (uint256 i; i < factory.getCampaignCount(); ++i) {
            (address campAddr,,,,,,) = factory.campaigns(i);
            if (campAddr == campPaused) {
                idx = i;
                break;
            }
        }
        vm.prank(OWNER);
        factory.pauseCampaign(idx);

        usdc.mint(address(growTreasury), 200 * ONE_USDC);

        // Allocation succeeds for the OK campaign, silently skips the paused one
        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 200 * ONE_USDC);

        IERC20 ctOk = IERC20(GrowfiCampaign(campOk).campaignToken());
        IERC20 ctPaused = IERC20(GrowfiCampaign(campPaused).campaignToken());

        // perCampaign = 100 USDC. OK got 100 tokens. Paused got 0 (buy reverted, caught).
        assertEq(ctOk.balanceOf(address(growTreasury)), 100e18);
        assertEq(ctPaused.balanceOf(address(growTreasury)), 0);
        // The 100 USDC for the paused one stays in Treasury (forceApprove was reset).
        assertEq(usdc.balanceOf(address(growTreasury)), 100 * ONE_USDC);
    }

    // ============================================================
    // ZERO / EDGE INPUTS
    // ============================================================

    function test_stress_zeroTotalAmountReverts() public {
        address camp = _createAndActivate("ZeroAmt", 50e18, 100e18, 1e18);
        _track(camp);

        vm.expectRevert(GrowfiTreasury.ZeroAmount.selector);
        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 0);
    }

    function test_stress_insufficientBalanceReverts() public {
        address camp = _createAndActivate("Insuf", 50e18, 100e18, 1e18);
        _track(camp);

        // Treasury empty
        vm.expectRevert(GrowfiTreasury.InsufficientBalance.selector);
        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 100 * ONE_USDC);
    }

    function test_stress_unsupportedPaymentTokenReverts() public {
        MockERC20 random = new MockERC20("Random", "RND", 6);
        address camp = _createAndActivate("Unsup", 50e18, 100e18, 1e18);
        _track(camp);

        random.mint(address(growTreasury), 100 * ONE_USDC);

        vm.expectRevert(GrowfiTreasury.NotAccepted.selector);
        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(random), 100 * ONE_USDC);
    }

    /// @dev Per-campaign share rounds to 0 (totalAmount < activeCount in raw units).
    function test_stress_perCampaignTooSmall_reverts() public {
        // 10 campaigns + totalAmount=5 raw -> perCampaign = 0 -> revert ZeroAmount
        for (uint256 i; i < 10; ++i) {
            string memory name = string(abi.encodePacked("Tiny", vm.toString(i)));
            address camp = _createAndActivate(name, 50e18, 1000e18, 1e18);
            _track(camp);
        }
        usdc.mint(address(growTreasury), 100 * ONE_USDC);

        vm.expectRevert(GrowfiTreasury.ZeroAmount.selector);
        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 5);
    }

    // ============================================================
    // SEQUENCING
    // ============================================================

    /// @dev Re-running allocation: first call works, subsequent calls keep working.
    function test_stress_repeatedRunsAccumulate() public {
        address camp = _createAndActivate("Repeat", 50e18, 10000e18, 1e18);
        _track(camp);

        usdc.mint(address(growTreasury), 300 * ONE_USDC);

        // First run: $100
        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 100 * ONE_USDC);

        // Second run: $100
        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 100 * ONE_USDC);

        // Third run: $100
        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 100 * ONE_USDC);

        IERC20 ct = IERC20(GrowfiCampaign(camp).campaignToken());
        assertEq(ct.balanceOf(address(growTreasury)), 300e18);
    }

    /// @dev Track, allocate, untrack, allocate again — untracked is skipped.
    function test_stress_untrackBetweenAllocations() public {
        address campA = _createAndActivate("AaA", 50e18, 1000e18, 1e18);
        address campB = _createAndActivate("BbB", 50e18, 1000e18, 1e18);

        _track(campA);
        _track(campB);

        usdc.mint(address(growTreasury), 400 * ONE_USDC);

        // First allocation: both get $100
        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 200 * ONE_USDC);
        assertEq(IERC20(GrowfiCampaign(campA).campaignToken()).balanceOf(address(growTreasury)), 100e18);
        assertEq(IERC20(GrowfiCampaign(campB).campaignToken()).balanceOf(address(growTreasury)), 100e18);

        // Untrack B
        vm.prank(OWNER);
        factory.removeGrowfiTreasuryTrackedCampaign(campB);

        // Second allocation: only A receives the $200 budget
        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 200 * ONE_USDC);
        assertEq(IERC20(GrowfiCampaign(campA).campaignToken()).balanceOf(address(growTreasury)), 300e18);
        assertEq(IERC20(GrowfiCampaign(campB).campaignToken()).balanceOf(address(growTreasury)), 100e18); // unchanged
    }

    // ============================================================
    // GAS / SCALE
    // ============================================================

    /// @dev Run allocation with 50 tracked campaigns. Verify gas is reasonable.
    function test_stress_fiftyCampaignsGasBound() public {
        address[] memory camps = new address[](50);
        for (uint256 i; i < 50; ++i) {
            string memory name = string(abi.encodePacked("Gas", vm.toString(i)));
            camps[i] = _createAndActivate(name, 50e18, 1000e18, 1e18);
            _track(camps[i]);
        }

        usdc.mint(address(growTreasury), 500 * ONE_USDC);

        uint256 gasBefore = gasleft();
        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 500 * ONE_USDC);
        uint256 gasUsed = gasBefore - gasleft();

        // Should complete well under block gas limit (30M on most chains)
        assertLt(gasUsed, 25_000_000, "50 campaigns alloc within 25M gas");

        // Each got $10
        for (uint256 i; i < 50; ++i) {
            assertEq(IERC20(GrowfiCampaign(camps[i]).campaignToken()).balanceOf(address(growTreasury)), 10e18);
        }
    }

    // ============================================================
    // AUTOMATION SWITCH
    // ============================================================

    function test_stress_switchOff_blocksAll() public {
        address camp = _createAndActivate("SwitchOff", 50e18, 1000e18, 1e18);
        _track(camp);

        // Disable automation
        vm.prank(OWNER);
        factory.setGrowfiTreasuryAutomationEnabled(false);

        usdc.mint(address(growTreasury), 100 * ONE_USDC);

        vm.expectRevert(GrowfiTreasury.AutomationDisabled.selector);
        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 100 * ONE_USDC);
    }

    function test_stress_switchToggleable() public {
        address camp = _createAndActivate("SwitchTog", 50e18, 1000e18, 1e18);
        _track(camp);

        vm.prank(OWNER);
        factory.setGrowfiTreasuryAutomationEnabled(false);

        usdc.mint(address(growTreasury), 100 * ONE_USDC);

        // Disabled -> reverts
        vm.expectRevert(GrowfiTreasury.AutomationDisabled.selector);
        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 100 * ONE_USDC);

        // Re-enable
        vm.prank(OWNER);
        factory.setGrowfiTreasuryAutomationEnabled(true);

        // Now works
        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 100 * ONE_USDC);
        assertEq(IERC20(GrowfiCampaign(camp).campaignToken()).balanceOf(address(growTreasury)), 100e18);
    }

    /// @dev Manual allocateToCampaign always works regardless of switch.
    function test_stress_manualAllocateAlwaysWorksRegardlessOfSwitch() public {
        address camp = _createAndActivate("ManualOk", 50e18, 1000e18, 1e18);
        _track(camp);

        // Disable automation switch
        vm.prank(OWNER);
        factory.setGrowfiTreasuryAutomationEnabled(false);

        usdc.mint(address(growTreasury), 100 * ONE_USDC);

        // Manual allocation still works — switch only affects across-tracked path
        vm.prank(OWNER);
        factory.allocateGrowfiTreasury(camp, address(usdc), 100 * ONE_USDC);

        assertEq(IERC20(GrowfiCampaign(camp).campaignToken()).balanceOf(address(growTreasury)), 100e18);
    }

    // ============================================================
    // HIDE / BAN
    // ============================================================

    function test_hide_setHidden() public {
        address camp = _createAndActivate("HideMe", 50e18, 1000e18, 1e18);
        assertFalse(factory.hiddenCampaigns(camp));

        vm.prank(OWNER);
        factory.setCampaignHidden(camp, true);
        assertTrue(factory.hiddenCampaigns(camp));

        vm.prank(OWNER);
        factory.setCampaignHidden(camp, false);
        assertFalse(factory.hiddenCampaigns(camp));
    }

    function test_hide_attackerCannotSetFlag() public {
        address camp = _createAndActivate("AttkHide", 50e18, 1000e18, 1e18);
        vm.expectRevert();
        vm.prank(ATTACKER);
        factory.setCampaignHidden(camp, true);
    }

    function test_hide_revertsForNonCampaign() public {
        vm.expectRevert("Not a campaign");
        vm.prank(OWNER);
        factory.setCampaignHidden(ATTACKER, true);
    }

    /// @dev Hidden flag is PURE UI: zero on-chain effect. The campaign keeps working
    ///      end-to-end -- buy, stake, harvest claim, redeem all unaffected.
    function test_hide_doesNotAffectOnChainOperations() public {
        address camp = _createAndActivate("HiddenButOk", 50e18, 1000e18, 1e18);
        _track(camp);

        vm.prank(OWNER);
        factory.setCampaignHidden(camp, true);

        // Treasury allocation still works (hidden doesn't block anything)
        usdc.mint(address(growTreasury), 100 * ONE_USDC);
        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 100 * ONE_USDC);
        assertEq(IERC20(GrowfiCampaign(camp).campaignToken()).balanceOf(address(growTreasury)), 100e18);

        // External user can still buy on the hidden campaign (knows the address)
        usdc.mint(ATTACKER, 50 * ONE_USDC);
        vm.prank(ATTACKER);
        usdc.approve(camp, 50 * ONE_USDC);
        vm.prank(ATTACKER);
        GrowfiCampaign(camp).buy(address(usdc), 50 * ONE_USDC);
        IERC20 ct = IERC20(GrowfiCampaign(camp).campaignToken());
        assertEq(ct.balanceOf(ATTACKER), 50e18, "buy works regardless of hidden flag");
    }

    // ============================================================
    // EDGE: PRICE CHANGE BETWEEN ALLOCATIONS
    // ============================================================

    /// @dev Producer cannot change pricePerToken (immutable). But maxCap is mutable.
    ///      Verify that increasing maxCap mid-flight increases allocation room on next call.
    function test_stress_maxCapIncreaseExpandsRoom() public {
        address camp = _createAndActivate("MaxCapBump", 50e18, 60e18, 1e18); // 10 room initially
        _track(camp);

        usdc.mint(address(growTreasury), 1_000 * ONE_USDC);

        // First allocation: capped at 10 tokens
        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 1_000 * ONE_USDC);
        assertEq(IERC20(GrowfiCampaign(camp).campaignToken()).balanceOf(address(growTreasury)), 10e18);

        // Producer raises maxCap to 100
        vm.prank(PRODUCER);
        GrowfiCampaign(camp).setMaxCap(100e18);

        // Second allocation: 30 more tokens of room (60 -> 100, treasury already had 10)
        // Wait — currentSupply = 60 (50 producer + 10 treasury), maxCap now = 100, room = 40.
        // Treasury has remaining $940 in cash. perCampaign = $940/1 = $940. Capped at 40 tokens.
        vm.prank(OWNER);
        factory.allocateAcrossTrackedGrowfiTreasury(address(usdc), 940 * ONE_USDC);
        assertEq(IERC20(GrowfiCampaign(camp).campaignToken()).balanceOf(address(growTreasury)), 50e18);
    }
}
