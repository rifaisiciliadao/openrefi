// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";

import {GrowfiCampaignFactory} from "../src/GrowfiCampaignFactory.sol";
import {GrowfiCampaign} from "../src/GrowfiCampaign.sol";
import {CampaignStorage} from "../src/host/CampaignStorage.sol";
import {IGrowfiCampaignFull} from "../src/interfaces/IGrowfiCampaignFull.sol";
import {SaleClassicModule} from "../src/modules/SaleClassicModule.sol";
import {CollateralModule} from "../src/modules/CollateralModule.sol";
import {GrowfiCampaignToken} from "../src/GrowfiCampaignToken.sol";
import {GrowfiYieldToken} from "../src/GrowfiYieldToken.sol";
import {GrowfiStakingVault} from "../src/GrowfiStakingVault.sol";
import {GrowfiHarvestManager} from "../src/GrowfiHarvestManager.sol";

import {MockERC20} from "./helpers/MockERC20.sol";
import {FeeOnTransferToken} from "./helpers/FeeOnTransferToken.sol";
import {ReentrantToken} from "./helpers/ReentrantToken.sol";
import {Deployer} from "./helpers/Deployer.sol";

/// @title CollateralHardening — defense-in-depth tests for the collateral
///        path. Pins down the surfaces that are closed by design and
///        re-asserts them so a future refactor can't quietly open them.
contract CollateralHardeningTest is Test {
    address protocolOwner = makeAddr("protocolOwner");
    address feeRecipient = makeAddr("feeRecipient");
    address producer = makeAddr("producer");
    address alice = makeAddr("alice");

    uint256 constant PRICE_PER_TOKEN = 0.144e18;
    uint256 constant MIN_CAP = 50_000e18;
    uint256 constant MAX_CAP = 100_000e18;
    uint256 constant SEASON_DURATION = 365 days;
    uint256 constant USDC_RATE_FOT = 1e18;
    uint256 constant USDC_RATE_RGN = 1e18;
    uint256 constant COVERAGE = 3;

    function _bootstrap(address tokenAddr)
        internal
        returns (
            GrowfiCampaignFactory factory,
            IGrowfiCampaignFull campaign,
            GrowfiCampaignToken ct,
            GrowfiHarvestManager hm
        )
    {
        factory = Deployer.deployProtocol(protocolOwner, feeRecipient, tokenAddr, address(0));

        vm.prank(producer);
        factory.createCampaign(
            GrowfiCampaignFactory.CreateCampaignParams({
                producer: producer,
                campaignTokenName: "Olive",
                campaignTokenSymbol: "OLIVE",
                yieldTokenName: "oYield",
                yieldTokenSymbol: "oY",
                minProductClaim: 5e18,
                sale: SaleClassicModule.InitParams({
                    pricePerToken: PRICE_PER_TOKEN,
                    minCap: MIN_CAP,
                    maxCap: MAX_CAP,
                    fundingDeadline: block.timestamp + 90 days,
                    seasonDuration: SEASON_DURATION,
                    fundingFeeBps: 0,
                    sequencerUptimeFeed: address(0),
                    growMinter: address(0)
                }),
                collateral: CollateralModule.InitParams({
                    // 18-dec misconfigured "USDC" mocks (FoT/Rogue) → e18-scaled
                    // lock amounts → big commitment to fit them.
                    expectedAnnualHarvestUsd: 1e36,
                    expectedAnnualHarvest: 1_000e18,
                    firstHarvestYear: 2030,
                    coverageHarvests: COVERAGE
                })
            })
        );

        (address c, address cTok,,, address hmAddr,,) = factory.campaigns(0);
        campaign = IGrowfiCampaignFull(payable(c));
        ct = GrowfiCampaignToken(cTok);
        hm = GrowfiHarvestManager(hmAddr);
    }

    // =========================================================================
    // 1. FEE-ON-TRANSFER "USDC" MISCONFIG
    // =========================================================================

    function test_fot_lockCollateral_overCountsBalance() public {
        FeeOnTransferToken fot = new FeeOnTransferToken("FoT", "FOT", 18, 100); // 1% burn
        (, IGrowfiCampaignFull campaign,,) = _bootstrap(address(fot));

        vm.prank(producer);
        campaign.addAcceptedToken(address(fot), SaleClassicModule.PricingMode.Fixed, USDC_RATE_FOT, address(0));
        fot.mint(alice, 200_000e18);
        vm.startPrank(alice);
        fot.approve(address(campaign), type(uint256).max);
        campaign.buy(address(fot), 60_000e18);
        vm.stopPrank();
        assertEq(uint8(campaign.state()), uint8(CampaignStorage.State.Active));

        fot.mint(producer, 1_000e18);
        vm.startPrank(producer);
        fot.approve(address(campaign), type(uint256).max);
        uint256 producerBefore = fot.balanceOf(producer);
        uint256 campaignBefore = fot.balanceOf(address(campaign));
        campaign.lockCollateral(1_000e18);
        uint256 producerAfter = fot.balanceOf(producer);
        uint256 campaignAfter = fot.balanceOf(address(campaign));
        vm.stopPrank();

        assertEq(producerBefore - producerAfter, 1_000e18, "producer lost declared 1000");
        assertEq(campaignAfter - campaignBefore, 990e18, "contract received 990 (1% burned)");
        assertEq(campaign.collateralLocked(), 1_000e18, "collateralLocked over-counts: drift confirmed");
    }

    // =========================================================================
    // 2. REENTRANCY ON lockCollateral
    // =========================================================================

    function test_reentrancy_lockCollateral_blocked() public {
        ReentrantToken rog = new ReentrantToken("Rogue", "ROG", 18);
        (, IGrowfiCampaignFull campaign,,) = _bootstrap(address(rog));

        vm.prank(producer);
        campaign.addAcceptedToken(address(rog), SaleClassicModule.PricingMode.Fixed, USDC_RATE_RGN, address(0));
        rog.mint(alice, 200_000e18);
        vm.startPrank(alice);
        rog.approve(address(campaign), type(uint256).max);
        campaign.buy(address(rog), 60_000e18);
        vm.stopPrank();
        assertEq(uint8(campaign.state()), uint8(CampaignStorage.State.Active));

        rog.mint(producer, 1_000e18);
        vm.prank(producer);
        rog.approve(address(campaign), type(uint256).max);

        bytes memory payload = abi.encodeCall(CollateralModule.lockCollateral, (100e18));
        rog.arm(address(campaign), payload);

        vm.prank(producer);
        vm.expectRevert();
        campaign.lockCollateral(500e18);
    }

    // =========================================================================
    // 3. REENTRANCY ON settleSeasonShortfall
    // =========================================================================

    function test_reentrancy_settleSeasonShortfall_blocked() public {
        ReentrantToken rog = new ReentrantToken("Rogue", "ROG", 18);
        (, IGrowfiCampaignFull campaign, GrowfiCampaignToken ct, GrowfiHarvestManager hm) =
            _bootstrap(address(rog));

        vm.prank(producer);
        campaign.addAcceptedToken(address(rog), SaleClassicModule.PricingMode.Fixed, USDC_RATE_RGN, address(0));
        rog.mint(alice, 1_000_000e18);
        vm.startPrank(alice);
        rog.approve(address(campaign), type(uint256).max);
        campaign.buy(address(rog), 60_000e18);
        ct.approve(address(campaign), type(uint256).max);
        vm.stopPrank();

        rog.mint(producer, 100_000e18);
        vm.startPrank(producer);
        rog.approve(address(campaign), type(uint256).max);
        campaign.lockCollateral(10_000e18);
        campaign.startSeason();
        vm.stopPrank();

        vm.startPrank(alice);
        GrowfiStakingVault sv = GrowfiStakingVault(payable(campaign.stakingVault()));
        ct.approve(address(sv), type(uint256).max);
        uint256 posId = sv.stake(ct.balanceOf(alice));
        vm.stopPrank();
        vm.warp(block.timestamp + SEASON_DURATION);
        vm.prank(producer);
        campaign.endSeason();
        vm.prank(producer);
        hm.reportHarvest(1, 5_000e18, bytes32(0), 0);

        vm.startPrank(alice);
        sv.claimYield(posId);
        GrowfiYieldToken yt = GrowfiYieldToken(address(hm.yieldToken()));
        uint256 yieldBal = yt.balanceOf(alice);
        if (yieldBal > 0) hm.redeemUSDC(1, yieldBal);
        vm.stopPrank();

        (,,,,,, uint256 deadline,,,,,) = hm.seasonHarvests(1);
        vm.warp(deadline + 1);

        bytes memory payload = abi.encodeCall(CollateralModule.settleSeasonShortfall, (1));
        rog.arm(address(campaign), payload);

        vm.expectRevert();
        campaign.settleSeasonShortfall(1);
        assertFalse(campaign.seasonShortfallSettled(1), "outer revert rolled back the flag");
    }

    // =========================================================================
    // 4. STORAGE-LAYOUT REGRESSION (v4-native)
    // =========================================================================

    /// The v4 host stores its state at `keccak256("growfi.campaign.core.v1")`
    /// and the modules use their own namespaced slots. Reading public
    /// fields after creation must return their initialized values via the
    /// host + module accessors. If any field's slot moved, an auto-getter
    /// would surface garbage and this test would fail.
    function test_storageLayout_v4FieldsResolveAtExpectedAccessors() public {
        MockERC20 usdcMock = new MockERC20("USD Coin", "USDC", 6);
        (, IGrowfiCampaignFull campaign,,) = _bootstrap(address(usdcMock));

        // Host fields
        assertEq(campaign.producer(), producer, "host: producer");
        assertTrue(campaign.factory() != address(0), "host: factory");
        assertEq(uint8(campaign.state()), uint8(CampaignStorage.State.Funding), "host: state");
        assertEq(campaign.usdc(), address(usdcMock), "host: usdc");
        assertEq(campaign.protocolFeeRecipient(), feeRecipient, "host: protocolFeeRecipient");

        // SaleClassicModule fields
        assertEq(campaign.pricePerToken(), PRICE_PER_TOKEN, "sale: pricePerToken");
        assertEq(campaign.minCap(), MIN_CAP, "sale: minCap");
        assertEq(campaign.maxCap(), MAX_CAP, "sale: maxCap");
        assertEq(campaign.seasonDuration(), SEASON_DURATION, "sale: seasonDuration");
        assertEq(campaign.currentSupply(), 0, "sale: currentSupply");
        assertEq(campaign.fundingFeeBps(), 300, "sale: fundingFeeBps (factory-pinned 3%)");

        // CollateralModule fields
        assertEq(campaign.expectedAnnualHarvestUsd(), 1e36, "collateral: expectedAnnualHarvestUsd");
        assertEq(campaign.firstHarvestYear(), 2030, "collateral: firstHarvestYear");
        assertEq(campaign.coverageHarvests(), COVERAGE, "collateral: coverageHarvests");
        assertEq(campaign.collateralLocked(), 0, "collateral: collateralLocked initial 0");
        assertEq(campaign.collateralDrawn(), 0, "collateral: collateralDrawn initial 0");
        assertFalse(campaign.seasonShortfallSettled(1), "collateral: seasonShortfallSettled initial false");
    }
}
