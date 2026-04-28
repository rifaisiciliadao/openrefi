// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {CampaignFactory} from "../../src/CampaignFactory.sol";
import {Campaign} from "../../src/Campaign.sol";
import {CampaignToken} from "../../src/CampaignToken.sol";
import {YieldToken} from "../../src/YieldToken.sol";
import {StakingVault} from "../../src/StakingVault.sol";
import {HarvestManager} from "../../src/HarvestManager.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {Handler} from "./Handler.sol";
import {Deployer} from "../helpers/Deployer.sol";

/// @title Invariants — stateful fuzzing of protocol global properties
/// @notice Foundry fires random sequences of Handler calls; invariants must
///         hold after every single call across every run.
contract InvariantsTest is StdInvariant, Test {
    CampaignFactory factory;
    Campaign campaign;
    CampaignToken campaignToken;
    YieldToken yieldToken;
    StakingVault stakingVault;
    HarvestManager harvestManager;
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
        factory.createCampaign(
            CampaignFactory.CreateCampaignParams({
                producer: producer,
                tokenName: "Olive",
                tokenSymbol: "OLIVE",
                yieldName: "oY",
                yieldSymbol: "oY",
                pricePerToken: PRICE_PER_TOKEN,
                minCap: MIN_CAP,
                maxCap: MAX_CAP,
                fundingDeadline: block.timestamp + 90 days,
                seasonDuration: SEASON_DURATION,
                minProductClaim: 5e18,
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

        vm.prank(producer);
        campaign.addAcceptedToken(address(usdc), Campaign.PricingMode.Fixed, USDC_FIXED_RATE, address(0));

        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("charlie"));

        handler = new Handler(campaign, campaignToken, yieldToken, stakingVault, usdc, producer, actors);

        // Restrict fuzzer to the handler's functions
        bytes4[] memory selectors = new bytes4[](11);
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

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // -------------------------------------------------------------------------
    // INVARIANTS
    // -------------------------------------------------------------------------

    /// @dev INV-1: StakingVault must always hold exactly `totalStaked` $CAMPAIGN.
    ///             Any drift means stake/unstake accounting is broken.
    function invariant_vaultHoldsExactlyTotalStaked() public view {
        assertEq(
            campaignToken.balanceOf(address(stakingVault)), stakingVault.totalStaked(), "vault balance != totalStaked"
        );
    }

    /// @dev INV-2: currentSupply tracks total ever sold; actual circulating supply
    ///             diverges only downwards (penalties burn). So currentSupply must
    ///             always be ≥ totalSupply, and the delta equals ghost_totalBurned.
    function invariant_supplyTrackingConsistent() public view {
        assertGe(campaign.currentSupply(), campaignToken.totalSupply(), "currentSupply < totalSupply");
        assertEq(
            campaign.currentSupply() - campaignToken.totalSupply(), handler.ghost_totalBurned(), "burn accounting off"
        );
    }

    /// @dev INV-3: totalStaked equals the sum of all active positions' amounts.
    function invariant_totalStakedEqualsSumOfPositions() public view {
        uint256 sum;
        uint256 next = stakingVault.nextPositionId();
        for (uint256 i = 0; i < next; i++) {
            (, uint256 amount,,,, bool active) = stakingVault.positions(i);
            if (active) sum += amount;
        }
        assertEq(sum, stakingVault.totalStaked(), "sum(positions) != totalStaked");
    }

    /// @dev INV-4: Sum of `pendingSellBack[user]` for every actor must equal the
    ///             total remaining queue depth plus any already-filled-but-not-decremented
    ///             entries — captured by getSellBackQueueDepth().
    function invariant_sellBackBookkeeping() public view {
        uint256 queueDepth = campaign.getSellBackQueueDepth();
        uint256 sumPending;
        uint256 n = handler.actorsLength();
        for (uint256 i = 0; i < n; i++) {
            sumPending += campaign.pendingSellBack(handler.actors(i));
        }
        assertEq(sumPending, queueDepth, "pendingSellBack total != queueDepth");
    }

    /// @dev INV-5: During Funding, the Campaign contract holds exactly the sum of
    ///             purchases across users. After activation/buyback this relationship
    ///             changes, so we only check in Funding.
    function invariant_escrowMatchesPurchasesInFunding() public view {
        if (campaign.state() != Campaign.State.Funding) return;

        uint256 sum;
        uint256 n = handler.actorsLength();
        for (uint256 i = 0; i < n; i++) {
            sum += campaign.purchases(handler.actors(i), address(usdc));
        }
        assertEq(usdc.balanceOf(address(campaign)), sum, "escrow balance != sum(purchases)");
    }

    /// @dev INV-6: Campaign contract must hold at least the queued sell-back tokens
    ///             (sellers transferred their tokens here; queued ones are not yet
    ///             burned until a buyer fills them).
    function invariant_campaignHoldsQueuedSellbackTokens() public view {
        assertGe(
            campaignToken.balanceOf(address(campaign)),
            campaign.getSellBackQueueDepth(),
            "campaign balance < queued sellback"
        );
    }

    /// @dev INV-7: currentSupply never exceeds maxCap.
    function invariant_currentSupplyWithinMaxCap() public view {
        assertLe(campaign.currentSupply(), campaign.maxCap(), "currentSupply > maxCap");
    }

    /// @dev INV-9: per-user open sellback-order cap is always respected.
    function invariant_sellbackOrderCapHolds() public view {
        uint256 cap = campaign.MAX_OPEN_SELLBACK_ORDERS_PER_USER();
        uint256 n = handler.actorsLength();
        for (uint256 i = 0; i < n; i++) {
            assertLe(campaign.openSellBackCount(handler.actors(i)), cap, "openSellBackCount > cap");
        }
    }

    /// @dev INV-10: YieldToken supply never exceeds the cumulative totalYieldOwed
    ///              across all seasons that have started (with a small floor-drift
    ///              tolerance: per-position and aggregate floor divisions accumulate
    ///              rounding at most O(positions * seasons) wei).
    function invariant_yieldSupplyBoundedBySeasonAccruals() public view {
        uint256 currentSeason = stakingVault.currentSeasonId();
        if (currentSeason == 0 && !_seasonExists(0)) return; // no season yet
        uint256 totalOwed;
        for (uint256 sid = 0; sid <= currentSeason + 5; sid++) {
            if (_seasonExists(sid)) {
                totalOwed += stakingVault.seasonTotalYieldOwed(sid);
            }
        }
        // Drift budget: up to nextPositionId wei per season boundary. Very loose.
        uint256 drift = stakingVault.nextPositionId() * (currentSeason + 2);
        assertLe(yieldToken.totalSupply(), totalOwed + drift, "YIELD supply > sum season.totalYieldOwed + drift");
    }

    function _seasonExists(uint256 sid) internal view returns (bool) {
        (,,,,,, bool existed) = stakingVault.seasons(sid);
        return existed;
    }

    /// @dev INV-8: State only progresses forward. We check via the fact that once
    ///             Active or Buyback is reached, state is never Funding again.
    uint256 private maxStateSeen;

    function invariant_stateMonotonic() public {
        uint8 s = uint8(campaign.state());
        if (s > maxStateSeen) maxStateSeen = s;
        // Funding(0) → Active(1) / Buyback(2) → Ended(3). Funding can't come back.
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
