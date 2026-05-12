// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {GrowfiCampaignFactory} from "../../src/GrowfiCampaignFactory.sol";
import {GrowfiCampaign} from "../../src/GrowfiCampaign.sol";
import {GrowfiCampaignToken} from "../../src/GrowfiCampaignToken.sol";
import {GrowfiYieldToken} from "../../src/GrowfiYieldToken.sol";
import {GrowfiStakingVault} from "../../src/GrowfiStakingVault.sol";
import {IGrowfiCampaignFull} from "../../src/interfaces/IGrowfiCampaignFull.sol";
import {SaleClassicModule} from "../../src/modules/SaleClassicModule.sol";
import {CollateralModule} from "../../src/modules/CollateralModule.sol";
import {RepaymentModule} from "../../src/modules/RepaymentModule.sol";

import {Deployer} from "../helpers/Deployer.sol";
import {ReentrantUSDC} from "./ReentrantUSDC.sol";
import {RepaymentHelper} from "./RepaymentHelper.sol";

/// @title  RepaymentReentrancyTest
/// @notice Verifies the Repayment module's nonReentrant guard against
///         a malicious "USDC-shaped" token that calls back into the
///         module from its transfer hook. Each entry point that pays
///         out USDC (redeem, withdrawUnusedPool) and each entry point
///         that pulls USDC in (fundPool) must be protected.
contract RepaymentReentrancyTest is Test {
    bytes32 internal constant REPAY_KIND = keccak256("growfi.repayment.v1");
    bytes32 internal constant REPAY_TYPE = keccak256("growfi.type.repayment");

    GrowfiCampaignFactory internal factory;
    RepaymentModule internal repayImpl;
    ReentrantUSDC internal usdc;

    address internal protocolOwner = makeAddr("protocolOwner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal producer = makeAddr("producer");
    address internal alice = makeAddr("alice");

    address internal campaignAddr;
    IGrowfiCampaignFull internal campaign;
    GrowfiCampaignToken internal campaignToken;
    GrowfiStakingVault internal stakingVault;

    function setUp() public {
        usdc = new ReentrantUSDC();
        factory = Deployer.deployProtocol(protocolOwner, feeRecipient, address(usdc), address(0));

        vm.prank(protocolOwner);
        factory.setMinSeasonDuration(1 hours);

        repayImpl = new RepaymentModule();
        vm.startPrank(protocolOwner);
        factory.setModuleKindSelectors(REPAY_KIND, RepaymentHelper.selectors());
        factory.approveModuleImpl(REPAY_KIND, address(repayImpl), true);
        vm.stopPrank();

        vm.prank(producer);
        campaignAddr = factory.createCampaign(
            GrowfiCampaignFactory.CreateCampaignParams({
                producer: producer,
                campaignTokenName: "Olive",
                campaignTokenSymbol: "OLIVE",
                yieldTokenName: "Olive Yield",
                yieldTokenSymbol: "oYIELD",
                minProductClaim: 1e18,
                sale: SaleClassicModule.InitParams({
                    pricePerToken: 0.144e18,
                    minCap: 1_000e18,
                    maxCap: 50_000e18,
                    fundingDeadline: block.timestamp + 30 days,
                    seasonDuration: 7 days,
                    fundingFeeBps: 0,
                    sequencerUptimeFeed: address(0),
                    growMinter: address(0)
                }),
                collateral: CollateralModule.InitParams({
                    expectedAnnualHarvestUsd: 5_000e18,
                    expectedAnnualHarvest: 250e18,
                    firstHarvestYear: 2030,
                    coverageHarvests: 0
                })
            })
        );
        campaign = IGrowfiCampaignFull(payable(campaignAddr));
        campaignToken = GrowfiCampaignToken(campaign.campaignToken());
        stakingVault = GrowfiStakingVault(campaign.stakingVault());

        vm.prank(producer);
        campaign.addAcceptedToken(address(usdc), SaleClassicModule.PricingMode.Fixed, 144_000, address(0));

        // Alice activates
        usdc.mint(alice, 720e6);
        vm.startPrank(alice);
        usdc.approve(campaignAddr, type(uint256).max);
        campaign.buy(address(usdc), 720e6);
        vm.stopPrank();

        // Attach + fund Repayment
        vm.prank(producer);
        GrowfiCampaign(payable(campaignAddr)).attachModule(REPAY_TYPE, REPAY_KIND, address(repayImpl), "");
        vm.prank(producer);
        RepaymentModule(payable(campaignAddr)).initializeRepaymentByProducer(0);

        usdc.mint(producer, 5_000e6);
        vm.startPrank(producer);
        usdc.approve(campaignAddr, 5_000e6);
        RepaymentModule(payable(campaignAddr)).fundPool(5_000e6);
        vm.stopPrank();
    }

    function _r() internal view returns (RepaymentModule) {
        return RepaymentModule(payable(campaignAddr));
    }

    /// @dev On redeem payout, a malicious USDC tries to re-enter
    ///      redeem itself. nonReentrant must catch and bubble up.
    function test_reent_redeemReentryBlocked() public {
        bytes memory reentry = abi.encodeWithSelector(
            RepaymentModule.redeem.selector, uint256(50e18), new uint256[](0)
        );
        usdc.arm(campaignAddr, reentry);

        // Pranking alice — her redeem triggers payout → USDC transfer →
        // ReentrantUSDC._update fires → calls back into redeem.
        // The reentry inside the hook is silently caught by the mock,
        // but the SUT's guard must have prevented STATE CORRUPTION:
        // poolBalance, claimedByUser should be consistent with ONE redeem.
        uint256 aliceCtBefore = campaignToken.balanceOf(alice);
        uint256 poolBefore = _r().poolBalance();

        vm.prank(alice);
        _r().redeem(100e18, new uint256[](0));

        // Exactly one redeem worth of state change
        assertEq(campaignToken.balanceOf(alice), aliceCtBefore - 100e18, "exactly one burn");
        uint256 expected = 100e18 * 144_000 / 1e18;
        assertEq(_r().poolBalance(), poolBefore - expected, "pool drained by exactly one payout");
        assertEq(_r().claimedByUser(alice), expected, "claimed = one redeem only");
    }

    /// @dev fundPool re-entered during transferFrom callback. The
    ///      inbound transferFrom triggers _update on the mock; reentry
    ///      tries another fundPool. Guard must prevent double-counting.
    function test_reent_fundPoolReentryBlocked() public {
        usdc.mint(producer, 1_000e6);
        bytes memory reentry = abi.encodeWithSelector(RepaymentModule.fundPool.selector, uint256(500e6));
        usdc.arm(campaignAddr, reentry);

        uint256 poolBefore = _r().poolBalance();
        vm.startPrank(producer);
        usdc.approve(campaignAddr, 1_000e6);
        _r().fundPool(1_000e6);
        vm.stopPrank();

        // Pool grew by exactly 1_000e6 (one funding), NOT 1_500e6 (which
        // would indicate the reentry succeeded as an inner fundPool).
        assertEq(_r().poolBalance(), poolBefore + 1_000e6, "exactly one funding");
    }

    /// @dev withdrawUnusedPool re-entered during outbound transfer.
    function test_reent_withdrawReentryBlocked() public {
        bytes memory reentry = abi.encodeWithSelector(RepaymentModule.withdrawUnusedPool.selector, uint256(200e6));
        usdc.arm(campaignAddr, reentry);

        uint256 poolBefore = _r().poolBalance();
        uint256 producerBefore = usdc.balanceOf(producer);
        vm.prank(producer);
        _r().withdrawUnusedPool(1_000e6);

        // Producer received 1_000e6, NOT 1_200e6
        assertEq(usdc.balanceOf(producer), producerBefore + 1_000e6, "exactly one withdraw");
        assertEq(_r().poolBalance(), poolBefore - 1_000e6, "pool drained by exactly one withdraw");
    }

    /// @dev Cross-function reentry: redeem mid-call tries to re-enter
    ///      fundPool (different selector, but module's reentrancyStatus
    ///      is shared at the module level). Must be blocked.
    function test_reent_redeemReenterFundPoolBlocked() public {
        usdc.mint(producer, 100e6);
        vm.prank(producer);
        usdc.approve(campaignAddr, 100e6);

        bytes memory reentry = abi.encodeWithSelector(RepaymentModule.fundPool.selector, uint256(100e6));
        usdc.arm(campaignAddr, reentry);

        uint256 poolBefore = _r().poolBalance();
        vm.prank(alice);
        _r().redeem(100e18, new uint256[](0));

        // Pool went DOWN by the payout (redeem ran). The cross-function
        // reentry into fundPool was caught by the shared reentrancyStatus
        // guard — pool did NOT also gain 100e6.
        uint256 expectedPayout = 100e18 * 144_000 / 1e18;
        assertEq(_r().poolBalance(), poolBefore - expectedPayout, "pool drain only, no spurious fund");
    }

    /// @dev Cross-function reentry: fundPool reentering redeem. The
    ///      outer fund pulls USDC; the hook tries to redeem (would
    ///      need CT, which the producer doesn't have, but the GUARD
    ///      should fire BEFORE that check). Either way: no state pollution.
    function test_reent_fundPoolReenterRedeemBlocked() public {
        usdc.mint(alice, 100e6);
        vm.prank(alice);
        campaignToken.approve(campaignAddr, type(uint256).max);

        // Arm reentry as alice's redeem
        bytes memory reentry = abi.encodeWithSelector(
            RepaymentModule.redeem.selector, uint256(10e18), new uint256[](0)
        );
        usdc.arm(campaignAddr, reentry);

        usdc.mint(producer, 1_000e6);
        uint256 aliceCtBefore = campaignToken.balanceOf(alice);
        vm.startPrank(producer);
        usdc.approve(campaignAddr, 1_000e6);
        _r().fundPool(1_000e6);
        vm.stopPrank();

        // Alice's CT untouched — the reentered redeem was blocked by
        // the shared reentrancy flag (or by ownership/state mismatch).
        assertEq(campaignToken.balanceOf(alice), aliceCtBefore, "alice's CT untouched");
    }
}
