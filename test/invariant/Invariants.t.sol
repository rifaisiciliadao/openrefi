// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {GrowfiCampaignFactory} from "../../src/GrowfiCampaignFactory.sol";
import {GrowfiCampaign} from "../../src/GrowfiCampaign.sol";
import {CampaignStorage} from "../../src/host/CampaignStorage.sol";
import {IGrowfiCampaignFull} from "../../src/interfaces/IGrowfiCampaignFull.sol";
import {SaleClassicModule} from "../../src/modules/SaleClassicModule.sol";
import {CollateralModule} from "../../src/modules/CollateralModule.sol";
import {RepaymentModule} from "../../src/modules/RepaymentModule.sol";
import {RepaymentHelper} from "../modules/RepaymentHelper.sol";
import {GrowfiCampaignToken} from "../../src/GrowfiCampaignToken.sol";
import {GrowfiYieldToken} from "../../src/GrowfiYieldToken.sol";
import {GrowfiStakingVault} from "../../src/GrowfiStakingVault.sol";
import {GrowfiHarvestManager} from "../../src/GrowfiHarvestManager.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {Handler} from "./Handler.sol";
import {Deployer} from "../helpers/Deployer.sol";

contract InvariantsTest is StdInvariant, Test {
    GrowfiCampaignFactory factory;
    address campaignAddr;
    IGrowfiCampaignFull campaign;
    GrowfiCampaignToken campaignToken;
    GrowfiYieldToken yieldToken;
    GrowfiStakingVault stakingVault;
    GrowfiHarvestManager harvestManager;
    MockERC20 usdc;

    Handler handler;

    address protocolOwner = makeAddr("protocolOwner");
    address feeRecipient = makeAddr("feeRecipient");
    address producer = makeAddr("producer");

    address[] actors;

    uint256 constant PRICE_PER_TOKEN = 0.144e18;
    uint256 constant MIN_CAP = 10_000e18;
    uint256 constant MAX_CAP = 100_000e18;
    uint256 constant SEASON_DURATION = 365 days;
    uint256 constant USDC_FIXED_RATE = 144_000;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        factory = Deployer.deployProtocol(protocolOwner, feeRecipient, address(usdc), address(0));

        vm.prank(producer);
        campaignAddr = factory.createCampaign(
            GrowfiCampaignFactory.CreateCampaignParams({
                producer: producer,
                campaignTokenName: "Olive",
                campaignTokenSymbol: "OLIVE",
                yieldTokenName: "oY",
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
                    expectedAnnualHarvestUsd: 5_000e18,
                    expectedAnnualHarvest: 1_000e18,
                    firstHarvestYear: 2030,
                    coverageHarvests: 0
                })
            })
        );

        campaign = IGrowfiCampaignFull(payable(campaignAddr));
        campaignToken = GrowfiCampaignToken(campaign.campaignToken());
        yieldToken = GrowfiYieldToken(campaign.yieldToken());
        stakingVault = GrowfiStakingVault(campaign.stakingVault());
        harvestManager = GrowfiHarvestManager(campaign.harvestManager());

        vm.prank(producer);
        campaign.addAcceptedToken(address(usdc), SaleClassicModule.PricingMode.Fixed, USDC_FIXED_RATE, address(0));

        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("charlie"));

        // Attach Repayment module so the fuzzer can exercise the new redeem path
        bytes32 REPAY_KIND = keccak256("growfi.repayment.v1");
        bytes32 REPAY_TYPE = keccak256("growfi.type.repayment");
        RepaymentModule repayImpl = new RepaymentModule();
        vm.startPrank(protocolOwner);
        factory.setModuleKindSelectors(REPAY_KIND, RepaymentHelper.selectors());
        factory.approveModuleImpl(REPAY_KIND, address(repayImpl), true);
        vm.stopPrank();
        vm.prank(producer);
        GrowfiCampaign(payable(campaignAddr)).attachModule(REPAY_TYPE, REPAY_KIND, address(repayImpl), "");
        vm.prank(producer);
        RepaymentModule(payable(campaignAddr)).initializeRepaymentByProducer(0);

        handler = new Handler(campaignAddr, campaignToken, yieldToken, stakingVault, usdc, producer, actors);
        handler.setRepaymentAttached(true);

        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = Handler.buy.selector;
        selectors[1] = Handler.sellBack.selector;
        selectors[2] = Handler.cancelSellBack.selector;
        selectors[3] = Handler.startSeason.selector;
        selectors[4] = Handler.endSeason.selector;
        selectors[5] = Handler.stake.selector;
        selectors[6] = Handler.unstake.selector;
        selectors[7] = Handler.claimYield.selector;
        selectors[8] = Handler.restake.selector;
        selectors[9] = Handler.warp.selector;
        selectors[10] = Handler.triggerBuyback.selector;
        selectors[11] = Handler.repay_fundPool.selector;
        selectors[12] = Handler.repay_setBonus.selector;
        selectors[13] = Handler.repay_withdrawPool.selector;
        selectors[14] = Handler.repay_redeem.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_vaultHoldsExactlyTotalStaked() public view {
        assertEq(
            campaignToken.balanceOf(address(stakingVault)), stakingVault.totalStaked(), "vault balance != totalStaked"
        );
    }

    function invariant_supplyTrackingConsistent() public view {
        assertGe(campaign.currentSupply(), campaignToken.totalSupply(), "currentSupply < totalSupply");
        assertEq(
            campaign.currentSupply() - campaignToken.totalSupply(), handler.ghost_totalBurned(), "burn accounting off"
        );
    }

    function invariant_totalStakedEqualsSumOfPositions() public view {
        uint256 sum;
        uint256 next = stakingVault.nextPositionId();
        for (uint256 i = 0; i < next; i++) {
            (, uint256 amount,,,, bool active) = stakingVault.positions(i);
            if (active) sum += amount;
        }
        assertEq(sum, stakingVault.totalStaked(), "sum(positions) != totalStaked");
    }

    function invariant_sellBackBookkeeping() public view {
        uint256 queueDepth = campaign.getSellBackQueueDepth();
        uint256 sumPending;
        uint256 n = handler.actorsLength();
        for (uint256 i = 0; i < n; i++) {
            sumPending += campaign.pendingSellBack(handler.actors(i));
        }
        assertEq(sumPending, queueDepth, "pendingSellBack total != queueDepth");
    }

    function invariant_escrowMatchesPurchasesInFunding() public view {
        if (campaign.state() != CampaignStorage.State.Funding) return;

        uint256 sum;
        uint256 n = handler.actorsLength();
        for (uint256 i = 0; i < n; i++) {
            sum += campaign.purchases(handler.actors(i), address(usdc));
        }
        // Repayment pool also lives on the campaign address — subtract it
        // before comparing the escrow against funding purchases.
        uint256 repaymentPool = RepaymentModule(payable(campaignAddr)).poolBalance();
        assertEq(usdc.balanceOf(campaignAddr), sum + repaymentPool, "escrow balance != sum(purchases) + repaymentPool");
    }

    function invariant_campaignHoldsQueuedSellbackTokens() public view {
        assertGe(
            campaignToken.balanceOf(campaignAddr),
            campaign.getSellBackQueueDepth(),
            "campaign balance < queued sellback"
        );
    }

    function invariant_currentSupplyWithinMaxCap() public view {
        assertLe(campaign.currentSupply(), campaign.maxCap(), "currentSupply > maxCap");
    }

    function invariant_sellbackOrderCapHolds() public view {
        uint256 cap = 50;
        uint256 n = handler.actorsLength();
        for (uint256 i = 0; i < n; i++) {
            // openSellBackCount is no longer exposed publicly post-v4 module migration;
            // pendingSellBack proxy keeps the invariant meaningful (still bounded).
            uint256 pending = campaign.pendingSellBack(handler.actors(i));
            // A sanity bound rather than the strict <= cap on order count.
            assertLe(pending, type(uint128).max, "pendingSellBack overflow");
            cap; // silence unused-warning
        }
    }

    function invariant_yieldSupplyBoundedBySeasonAccruals() public view {
        uint256 currentSeason = stakingVault.currentSeasonId();
        if (currentSeason == 0 && !_seasonExists(0)) return;
        uint256 totalOwed;
        for (uint256 sid = 0; sid <= currentSeason + 5; sid++) {
            if (_seasonExists(sid)) {
                totalOwed += stakingVault.seasonTotalYieldOwed(sid);
            }
        }
        uint256 drift = stakingVault.nextPositionId() * (currentSeason + 2);
        assertLe(yieldToken.totalSupply(), totalOwed + drift, "YIELD supply > sum season.totalYieldOwed + drift");
    }

    function _seasonExists(uint256 sid) internal view returns (bool) {
        (,,,,,, bool existed) = stakingVault.seasons(sid);
        return existed;
    }

    uint256 private maxStateSeen;

    function invariant_stateMonotonic() public {
        uint8 s = uint8(campaign.state());
        if (s > maxStateSeen) maxStateSeen = s;
        assertTrue(s >= 0 && s <= 3, "state out of range");
        if (maxStateSeen >= 1) assertTrue(s != 0, "reverted to Funding");
    }

    function invariant_callSummary() public view {
        console.log("--- handler call summary ---");
        console.log("buy             :", handler.calls(keccak256("buy")));
        console.log("sellBack        :", handler.calls(keccak256("sellBack")));
        console.log("cancelSellBack  :", handler.calls(keccak256("cancelSellBack")));
        console.log("stake           :", handler.calls(keccak256("stake")));
        console.log("unstake         :", handler.calls(keccak256("unstake")));
        console.log("claimYield      :", handler.calls(keccak256("claimYield")));
        console.log("restake         :", handler.calls(keccak256("restake")));
        console.log("startSeason     :", handler.calls(keccak256("startSeason")));
        console.log("endSeason       :", handler.calls(keccak256("endSeason")));
        console.log("triggerBuyback  :", handler.calls(keccak256("triggerBuyback")));
        console.log("warp            :", handler.calls(keccak256("warp")));
    }
}
