// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {GrowfiCampaign} from "../../src/GrowfiCampaign.sol";
import {CampaignStorage} from "../../src/host/CampaignStorage.sol";
import {CollateralModule} from "../../src/modules/CollateralModule.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

import {TestModuleRegistry} from "../host/TestModuleRegistry.sol";
import {CollateralHelper} from "./CollateralHelper.sol";
import {MockHarvestManager} from "./MockHarvestManager.sol";

contract CollateralModuleTest is Test {
    bytes32 internal constant COLLATERAL_KIND = keccak256("growfi.collateral.v1");
    bytes32 internal constant COLLATERAL_TYPE = keccak256("growfi.type.collateral");

    address internal protocolOwner = makeAddr("protocolOwner");
    address internal producer = makeAddr("producer");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal randomCaller = makeAddr("randomCaller");

    TestModuleRegistry internal registry;
    GrowfiCampaign internal campaign;
    CollateralModule internal collateralImpl;
    MockUSDC internal usdc;
    MockHarvestManager internal harvestManager;

    // Commitments: $5,000/yr × 3 harvests coverage
    uint256 internal constant ANNUAL_USD = 5_000e18;
    uint256 internal constant ANNUAL_QTY = 1_000e18; // 1,000 L/yr
    uint256 internal constant FIRST_YEAR = 2030;
    uint256 internal constant COVERAGE = 3;

    function setUp() public {
        usdc = new MockUSDC();
        harvestManager = new MockHarvestManager(address(usdc));

        // Registry
        TestModuleRegistry registryImpl = new TestModuleRegistry();
        bytes memory initData = abi.encodeCall(TestModuleRegistry.initialize, (protocolOwner));
        TransparentUpgradeableProxy registryProxy =
            new TransparentUpgradeableProxy(address(registryImpl), protocolOwner, initData);
        registry = TestModuleRegistry(address(registryProxy));

        // Collateral whitelist
        collateralImpl = new CollateralModule();
        vm.startPrank(protocolOwner);
        registry.setModuleKindSelectors(COLLATERAL_KIND, CollateralHelper.selectors());
        registry.approveModuleImpl(COLLATERAL_KIND, address(collateralImpl), true);
        vm.stopPrank();

        // Campaign proxy
        GrowfiCampaign campImpl = new GrowfiCampaign();
        GrowfiCampaign.InitParams memory cp = GrowfiCampaign.InitParams({
            producer: producer,
            factory: address(registry),
            usdc: address(usdc),
            protocolFeeRecipient: feeRecipient
        });
        bytes memory campInit = abi.encodeCall(GrowfiCampaign.initialize, (cp));
        TransparentUpgradeableProxy campaignProxy =
            new TransparentUpgradeableProxy(address(campImpl), protocolOwner, campInit);
        campaign = GrowfiCampaign(payable(address(campaignProxy)));

        // setYieldToken/setStakingVault cross-wire to their peers; set the consumer side first.
        vm.startPrank(address(registry));
        campaign.setYieldToken(address(0xCa2));
        campaign.setHarvestManager(address(harvestManager));
        campaign.setStakingVault(address(0xCa3));
        campaign.setCampaignToken(address(0xCa1));
        vm.stopPrank();

        harvestManager.setCampaign(address(campaign));

        // Attach + init
        vm.prank(address(registry));
        campaign.attachModuleAsFactory(
            COLLATERAL_TYPE, COLLATERAL_KIND, address(collateralImpl), "ipfs://collateral.json"
        );

        CollateralModule.InitParams memory ip = CollateralModule.InitParams({
            expectedAnnualHarvestUsd: ANNUAL_USD,
            expectedAnnualHarvest: ANNUAL_QTY,
            firstHarvestYear: FIRST_YEAR,
            coverageHarvests: COVERAGE
        });
        vm.prank(address(registry));
        CollateralModule(payable(address(campaign))).initializeCollateral(ip);

        vm.prank(address(registry));
        campaign.closeBootstrap();

        // Mint plenty of USDC to the producer
        usdc.mint(producer, 1_000_000e6);
    }

    // ------------------------------------------------------------------
    // Commitments + cap math
    // ------------------------------------------------------------------

    function test_initialState() public view {
        assertEq(CollateralModule(payable(address(campaign))).expectedAnnualHarvestUsd(), ANNUAL_USD);
        assertEq(CollateralModule(payable(address(campaign))).coverageHarvests(), COVERAGE);
        // maxCollateral = $5000 * 3 / 1e12 = 15_000 * 1e6 = 15_000e6 (USDC-6)
        assertEq(CollateralModule(payable(address(campaign))).maxCollateral(), 15_000e6);
        assertEq(CollateralModule(payable(address(campaign))).collateralLocked(), 0);
        assertEq(CollateralModule(payable(address(campaign))).collateralDrawn(), 0);
    }

    // ------------------------------------------------------------------
    // Lock
    // ------------------------------------------------------------------

    function test_lockCollateral_happyPath() public {
        vm.startPrank(producer);
        usdc.approve(address(campaign), 5_000e6);
        CollateralModule(payable(address(campaign))).lockCollateral(5_000e6);
        vm.stopPrank();

        assertEq(CollateralModule(payable(address(campaign))).collateralLocked(), 5_000e6);
        assertEq(usdc.balanceOf(address(campaign)), 5_000e6);
        assertEq(CollateralModule(payable(address(campaign))).availableCollateral(), 5_000e6);
    }

    function test_lockCollateral_revertsIfNotProducer() public {
        usdc.mint(randomCaller, 1_000e6);
        vm.startPrank(randomCaller);
        usdc.approve(address(campaign), 1_000e6);
        vm.expectRevert(CollateralModule.OnlyProducer.selector);
        CollateralModule(payable(address(campaign))).lockCollateral(1_000e6);
        vm.stopPrank();
    }

    function test_lockCollateral_revertsIfOverCap() public {
        vm.startPrank(producer);
        usdc.approve(address(campaign), 20_000e6);
        vm.expectRevert(CollateralModule.CollateralCapExceeded.selector);
        CollateralModule(payable(address(campaign))).lockCollateral(16_000e6);
        vm.stopPrank();
    }

    function test_lockCollateral_revertsIfEndedState() public {
        // Transition the host to Ended via the producer-facing endCampaign().
        // CollateralModule rejects lock outside Funding/Active.
        vm.prank(producer);
        campaign.endCampaign();
        assertEq(uint8(campaign.state()), uint8(CampaignStorage.State.Ended));

        vm.startPrank(producer);
        usdc.approve(address(campaign), 1_000e6);
        vm.expectRevert(CollateralModule.InvalidState.selector);
        CollateralModule(payable(address(campaign))).lockCollateral(1_000e6);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // depositUSDC — collateral-first
    // ------------------------------------------------------------------

    function test_depositUSDC_drainsCollateralFirst() public {
        // Lock 5,000 USDC
        vm.startPrank(producer);
        usdc.approve(address(campaign), 5_000e6);
        CollateralModule(payable(address(campaign))).lockCollateral(5_000e6);
        vm.stopPrank();

        // Season 1 reported with $2,000 owed → gross obligation ≈ 2,040.81e6 USDC
        uint256 deadline = block.timestamp + 90 days;
        harvestManager.reportSeason(1, 2_000e18, deadline);

        // Producer deposits with walletCap=0 → entirely from collateral
        uint256 expectedGross = harvestManager.remainingDepositGross(1);
        vm.prank(producer);
        CollateralModule(payable(address(campaign))).depositUSDC(1, 0);

        assertEq(CollateralModule(payable(address(campaign))).collateralDrawn(), expectedGross);
        assertEq(CollateralModule(payable(address(campaign))).availableCollateral(), 5_000e6 - expectedGross);
        // Producer wallet untouched
        // (was 1_000_000e6 minus 5_000e6 lock)
        assertEq(usdc.balanceOf(producer), 1_000_000e6 - 5_000e6);
        // HarvestManager received the full gross (mock keeps the 2% internally)
        assertEq(usdc.balanceOf(address(harvestManager)), expectedGross);
    }

    function test_depositUSDC_walletGapPullsFromProducer() public {
        // Lock only 1,000 USDC
        vm.startPrank(producer);
        usdc.approve(address(campaign), 1_000e6);
        CollateralModule(payable(address(campaign))).lockCollateral(1_000e6);
        vm.stopPrank();

        uint256 deadline = block.timestamp + 90 days;
        harvestManager.reportSeason(1, 2_000e18, deadline);
        uint256 expectedGross = harvestManager.remainingDepositGross(1);
        uint256 gap = expectedGross - 1_000e6; // wallet portion

        vm.startPrank(producer);
        usdc.approve(address(campaign), gap);
        CollateralModule(payable(address(campaign))).depositUSDC(1, type(uint256).max);
        vm.stopPrank();

        assertEq(CollateralModule(payable(address(campaign))).collateralDrawn(), 1_000e6);
        // producer wallet drained by `gap`
        assertEq(usdc.balanceOf(producer), 1_000_000e6 - 1_000e6 - gap);
    }

    function test_depositUSDC_revertsIfSeasonNotReported() public {
        vm.prank(producer);
        vm.expectRevert(CollateralModule.SeasonNotReported.selector);
        CollateralModule(payable(address(campaign))).depositUSDC(7, 0);
    }

    function test_depositUSDC_revertsIfDeadlinePassed() public {
        harvestManager.reportSeason(1, 2_000e18, block.timestamp + 1 days);
        vm.warp(block.timestamp + 2 days);
        vm.prank(producer);
        vm.expectRevert(CollateralModule.DepositWindowClosed.selector);
        CollateralModule(payable(address(campaign))).depositUSDC(1, 0);
    }

    // ------------------------------------------------------------------
    // settleSeasonShortfall — permissionless post-deadline
    // ------------------------------------------------------------------

    function test_settleSeasonShortfall_permissionlessAfterDeadline() public {
        // Lock 5,000 USDC
        vm.startPrank(producer);
        usdc.approve(address(campaign), 5_000e6);
        CollateralModule(payable(address(campaign))).lockCollateral(5_000e6);
        vm.stopPrank();

        // Season 1 reported, deadline 1 day from now
        uint256 deadline = block.timestamp + 1 days;
        harvestManager.reportSeason(1, 1_000e18, deadline);

        // Warp past deadline
        vm.warp(deadline + 1);

        uint256 expectedGross = harvestManager.remainingDepositGross(1);

        // Anyone (random caller) can settle
        vm.prank(randomCaller);
        CollateralModule(payable(address(campaign))).settleSeasonShortfall(1);

        assertEq(CollateralModule(payable(address(campaign))).collateralDrawn(), expectedGross);
        assertTrue(CollateralModule(payable(address(campaign))).seasonShortfallSettled(1));
    }

    function test_settleSeasonShortfall_idempotent() public {
        vm.startPrank(producer);
        usdc.approve(address(campaign), 5_000e6);
        CollateralModule(payable(address(campaign))).lockCollateral(5_000e6);
        vm.stopPrank();

        uint256 deadline = block.timestamp + 1 days;
        harvestManager.reportSeason(1, 1_000e18, deadline);
        vm.warp(deadline + 1);

        vm.prank(randomCaller);
        CollateralModule(payable(address(campaign))).settleSeasonShortfall(1);

        vm.prank(randomCaller);
        vm.expectRevert(CollateralModule.AlreadySettled.selector);
        CollateralModule(payable(address(campaign))).settleSeasonShortfall(1);
    }

    function test_settleSeasonShortfall_revertsIfOutOfCoverage() public {
        uint256 deadline = block.timestamp + 1 days;
        harvestManager.reportSeason(COVERAGE + 1, 100e18, deadline);
        vm.warp(deadline + 1);

        vm.prank(randomCaller);
        vm.expectRevert(CollateralModule.NotInCoverage.selector);
        CollateralModule(payable(address(campaign))).settleSeasonShortfall(COVERAGE + 1);
    }

    function test_settleSeasonShortfall_revertsBeforeDeadline() public {
        uint256 deadline = block.timestamp + 90 days;
        harvestManager.reportSeason(1, 1_000e18, deadline);

        vm.prank(randomCaller);
        vm.expectRevert(CollateralModule.DepositWindowOpen.selector);
        CollateralModule(payable(address(campaign))).settleSeasonShortfall(1);
    }

}
