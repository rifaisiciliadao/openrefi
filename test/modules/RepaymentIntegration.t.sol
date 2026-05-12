// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
import {MockERC20} from "../helpers/MockERC20.sol";
import {RepaymentHelper} from "./RepaymentHelper.sol";

/// @notice End-to-end test exercising the RepaymentModule against the
///         real v4 stack: factory, sale module, staking vault, yield
///         token. Verifies that `redeem` mints accrued $YIELD to the
///         position owner (no forfeit), returns full CT principal
///         (no penalty), burns the redeemed CT, and pays principal +
///         bonus in USDC from the producer-funded pool.
contract RepaymentIntegrationTest is Test {
    bytes32 internal constant REPAY_KIND = keccak256("growfi.repayment.v1");
    bytes32 internal constant REPAY_TYPE = keccak256("growfi.type.repayment");

    GrowfiCampaignFactory internal factory;
    RepaymentModule internal repayImpl;
    MockERC20 internal usdc;

    address internal protocolOwner = makeAddr("protocolOwner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal producer = makeAddr("producer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    address internal campaignAddr;
    IGrowfiCampaignFull internal campaign;
    GrowfiCampaignToken internal campaignToken;
    GrowfiYieldToken internal yieldToken;
    GrowfiStakingVault internal stakingVault;

    uint256 internal constant PRICE_PER_TOKEN_USD18 = 0.144e18; // $0.144 per CT
    uint256 internal constant USDC_FIXED_RATE = 144_000; // 0.144 USDC-6 per CT
    uint256 internal constant MIN_CAP = 1_000e18;
    uint256 internal constant MAX_CAP = 50_000e18;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);

        factory = Deployer.deployProtocol(protocolOwner, feeRecipient, address(usdc), address(0));

        // Relax season floor so the test can advance through a season fast.
        vm.prank(protocolOwner);
        factory.setMinSeasonDuration(1 hours);

        // Whitelist the Repayment module on the factory (one-time, owner).
        repayImpl = new RepaymentModule();
        vm.startPrank(protocolOwner);
        factory.setModuleKindSelectors(REPAY_KIND, RepaymentHelper.selectors());
        factory.approveModuleImpl(REPAY_KIND, address(repayImpl), true);
        vm.stopPrank();

        // Producer creates a campaign — default modules (sale + collateral)
        // attach automatically.
        vm.prank(producer);
        campaignAddr = factory.createCampaign(
            GrowfiCampaignFactory.CreateCampaignParams({
                producer: producer,
                campaignTokenName: "Olive Sicily",
                campaignTokenSymbol: "OLIVE",
                yieldTokenName: "Olive Yield",
                yieldTokenSymbol: "oYIELD",
                minProductClaim: 1e18,
                sale: SaleClassicModule.InitParams({
                    pricePerToken: PRICE_PER_TOKEN_USD18,
                    minCap: MIN_CAP,
                    maxCap: MAX_CAP,
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
        yieldToken = GrowfiYieldToken(campaign.yieldToken());
        stakingVault = GrowfiStakingVault(campaign.stakingVault());

        // Producer adds USDC as accepted payment token at fixed rate.
        vm.prank(producer);
        campaign.addAcceptedToken(address(usdc), SaleClassicModule.PricingMode.Fixed, USDC_FIXED_RATE, address(0));

        // Alice buys CT; reaching minCap auto-activates and sweeps the
        // escrow to the producer. Must happen BEFORE Repayment is funded
        // because _activate moves balanceOf(campaign) → producer.
        usdc.mint(alice, 1_440e6);
        vm.startPrank(alice);
        usdc.approve(campaignAddr, type(uint256).max);
        campaignToken.approve(address(stakingVault), type(uint256).max);
        campaign.buy(address(usdc), 1_440e6); // 1440 / 0.144 = 10_000 CT
        vm.stopPrank();
        assertEq(campaignToken.balanceOf(alice), 10_000e18, "alice gets 10k CT");

        // Producer attaches the Repayment module post-activation.
        vm.prank(producer);
        GrowfiCampaign(payable(campaignAddr)).attachModule(REPAY_TYPE, REPAY_KIND, address(repayImpl), "ipfs://repay");

        // Producer initializes with bonus = 0 (refund-at-par default).
        vm.prank(producer);
        RepaymentModule(payable(campaignAddr)).initializeRepaymentByProducer(0);

        // Fund pool AFTER activation. 10k CT × ($0.144 principal + headroom)
        uint256 poolSize = 5_000e6;
        usdc.mint(producer, poolSize);
        vm.startPrank(producer);
        usdc.approve(campaignAddr, poolSize);
        RepaymentModule(payable(campaignAddr)).fundPool(poolSize);
        vm.stopPrank();

        // Producer kicks off a season so staking yield can accrue.
        vm.prank(producer);
        campaign.startSeason();
    }

    function _r() internal view returns (RepaymentModule) {
        return RepaymentModule(payable(campaignAddr));
    }

    // ------------------------------------------------------------------
    // Smoke: principal derived live from SaleClassic.pricePerToken
    // ------------------------------------------------------------------

    function test_principal_readsFromSaleClassic() public view {
        // 0.144e18 USD-18 / 1e12 = 144_000 USDC-6
        assertEq(_r().principalPerCt(), 144_000, "principal mirrors pricePerToken / 1e12");
        assertEq(_r().bonusPerCt(), 0);
        assertEq(_r().payoutPerCt(), 144_000);
    }

    // ------------------------------------------------------------------
    // The headline test: redeem with active staking position
    // ------------------------------------------------------------------

    function test_redeem_withStakedPosition_mintsYieldReturnsPrincipalPaysUsdc() public {
        // Alice stakes 5k of her 10k CT
        uint256 stakeAmt = 5_000e18;
        vm.prank(alice);
        uint256 posId = stakingVault.stake(stakeAmt);

        // Warp 3 days into the 7-day season so yield accrues.
        vm.warp(block.timestamp + 3 days);

        uint256 earnedBefore = stakingVault.earned(posId);
        assertGt(earnedBefore, 0, "yield should have accrued");

        // Snapshots
        uint256 aliceCtBefore = campaignToken.balanceOf(alice); // 5_000e18 (the un-staked half)
        uint256 aliceYieldBefore = yieldToken.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 poolBefore = _r().poolBalance();
        uint256 vaultCtBefore = campaignToken.balanceOf(address(stakingVault));

        // Alice redeems 2000 CT. To cover that she needs the staked 5k
        // back, so she passes her position id in unstakeFirst.
        uint256 redeemAmt = 2_000e18;
        uint256[] memory positions = new uint256[](1);
        positions[0] = posId;

        vm.prank(alice);
        _r().redeem(redeemAmt, positions);

        // 1) YIELD minted to Alice (no forfeit)
        uint256 yieldDelta = yieldToken.balanceOf(alice) - aliceYieldBefore;
        assertGt(yieldDelta, 0, "alice should have received YIELD");
        // Allow ±1 wei drift on rate accumulator rounding.
        assertApproxEqAbs(yieldDelta, earnedBefore, 1, "YIELD minted == earned before");

        // 2) CT principal returned (no penalty), then redeem amount burned.
        //    Alice starts with 5k free + 5k staked. forceUnstake returns
        //    the full 5k staked → 10k free. Then 2k burned → 8k free.
        assertEq(campaignToken.balanceOf(alice), aliceCtBefore + stakeAmt - redeemAmt, "8k CT after redeem");
        // Vault held 5k stake → now holds 0
        assertEq(campaignToken.balanceOf(address(stakingVault)), vaultCtBefore - stakeAmt, "vault drained");
        assertEq(stakingVault.totalStaked(), 0, "totalStaked drained");

        // 3) USDC paid: principal only (bonus = 0)
        uint256 expectedPayout = redeemAmt * 144_000 / 1e18; // 2000 * 0.144 = 288 USDC
        assertEq(expectedPayout, 288e6);
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, expectedPayout, "alice paid 288 USDC");
        assertEq(_r().poolBalance(), poolBefore - expectedPayout, "pool drained by payout");
        assertEq(_r().claimedByUser(alice), expectedPayout);

        // 4) Position is closed
        (,,,,, bool active) = stakingVault.positions(posId);
        assertFalse(active, "position closed");
    }

    function test_redeem_withBonus_holderGetsPremium() public {
        // Producer sets bonus = $0.05 per CT
        vm.prank(producer);
        _r().setBonusPerCt(0.05e6);

        // Alice buys nothing extra, just redeems 1k of her existing 10k.
        uint256 redeemAmt = 1_000e18;
        uint256 expectedPrincipal = redeemAmt * 144_000 / 1e18; // 144e6
        uint256 expectedBonus = redeemAmt * 0.05e6 / 1e18; // 50e6
        uint256 expectedPayout = expectedPrincipal + expectedBonus; // 194e6

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        _r().redeem(redeemAmt, new uint256[](0));
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, expectedPayout, "principal + bonus");
    }

    function test_redeem_withoutUnstakeFirst_revertsIfStakedCtNeeded() public {
        // Alice stakes ALL her 10k CT
        vm.prank(alice);
        stakingVault.stake(10_000e18);

        // Now she has 0 free CT. Try to redeem 1k without unstaking → revert
        vm.prank(alice);
        vm.expectRevert(); // ERC20InsufficientBalance on the burn
        _r().redeem(1_000e18, new uint256[](0));
    }

    function test_redeem_doesNotImpactOtherStakers() public {
        // Bob buys some CT first; campaign already active so direct mint.
        usdc.mint(bob, 144e6); // 1k CT worth
        vm.startPrank(bob);
        usdc.approve(campaignAddr, 144e6);
        campaign.buy(address(usdc), 144e6);
        campaignToken.approve(address(stakingVault), type(uint256).max);
        uint256 bobPos = stakingVault.stake(500e18);
        vm.stopPrank();

        // Alice stakes too
        vm.prank(alice);
        uint256 alicePos = stakingVault.stake(5_000e18);

        vm.warp(block.timestamp + 2 days);

        uint256 bobYieldBefore = yieldToken.balanceOf(bob);
        uint256 totalStakedBefore = stakingVault.totalStaked();

        // Alice exits via Repayment
        uint256[] memory positions = new uint256[](1);
        positions[0] = alicePos;
        vm.prank(alice);
        _r().redeem(1_000e18, positions);

        // Bob's position is untouched
        (,,,,, bool bobActive) = stakingVault.positions(bobPos);
        assertTrue(bobActive, "bob's position still active");
        assertEq(yieldToken.balanceOf(bob), bobYieldBefore, "bob's YIELD wallet untouched");
        assertEq(stakingVault.totalStaked(), totalStakedBefore - 5_000e18, "only alice's stake left vault");

        // Bob can still claim yield he accrued
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        stakingVault.claimYield(bobPos);
        assertGt(yieldToken.balanceOf(bob), bobYieldBefore, "bob's YIELD grew on his own claim");
    }

    function test_redeem_mintsYieldNotForfeits() public {
        // Stake, accrue some time, then redeem and assert the season
        // accounting reflects MINTED yield rather than FORFEITED yield.
        // (Regular unstake would shrink totalYieldOwed; forceUnstake must
        // grow totalYieldMinted instead.)
        vm.prank(alice);
        uint256 posId = stakingVault.stake(5_000e18);
        vm.warp(block.timestamp + 1 days);

        uint256 sid = campaign.currentSeasonId();
        uint256 expected = stakingVault.earned(posId);
        assertGt(expected, 0, "yield must have accrued");

        // Snapshot the season's minted-so-far (should be 0 since nobody
        // has claimed yet).
        (,, uint256 mintedBefore,,,,) = stakingVault.seasons(sid);
        assertEq(mintedBefore, 0, "no yield minted yet");

        uint256[] memory positions = new uint256[](1);
        positions[0] = posId;
        vm.prank(alice);
        _r().redeem(1_000e18, positions);

        // After redeem: yield was minted (not forfeited).
        (,, uint256 mintedAfter,, uint256 owedAfter,,) = stakingVault.seasons(sid);
        assertApproxEqAbs(mintedAfter, expected, 1, "season.totalYieldMinted grew by expected yield");
        assertGe(owedAfter, mintedAfter, "owed >= minted invariant holds");
        assertApproxEqAbs(yieldToken.balanceOf(alice), expected, 1, "alice's YIELD balance == expected");
    }

    function test_redeem_repeatedExitsAccumulate() public {
        uint256 redeemAmt = 500e18;
        uint256 expectedPerCall = redeemAmt * 144_000 / 1e18;

        vm.startPrank(alice);
        _r().redeem(redeemAmt, new uint256[](0));
        _r().redeem(redeemAmt, new uint256[](0));
        _r().redeem(redeemAmt, new uint256[](0));
        vm.stopPrank();

        assertEq(_r().claimedByUser(alice), expectedPerCall * 3);
    }

    function test_redeem_setBonusToZero_stillRefundsPrincipal() public {
        vm.prank(producer);
        _r().setBonusPerCt(0.1e6);
        vm.prank(producer);
        _r().setBonusPerCt(0);

        uint256 redeemAmt = 100e18;
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        _r().redeem(redeemAmt, new uint256[](0));
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, redeemAmt * 144_000 / 1e18);
    }
}
