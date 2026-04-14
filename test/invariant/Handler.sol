// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Campaign} from "../../src/Campaign.sol";
import {CampaignToken} from "../../src/CampaignToken.sol";
import {YieldToken} from "../../src/YieldToken.sol";
import {StakingVault} from "../../src/StakingVault.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

/// @title Handler — bounded random actions for invariant testing
/// @notice Funnels fuzzer into meaningful protocol state transitions.
///         Every external function here is a potential call target for the invariant runner.
contract Handler is Test {
    Campaign public campaign;
    CampaignToken public campaignToken;
    YieldToken public yieldToken;
    StakingVault public stakingVault;
    MockERC20 public usdc;
    address public producer;

    address[] public actors;
    uint256 public currentSeason;
    bool public seasonActive;

    // Ghost variables for cross-check
    uint256 public ghost_totalBought; // total $CAMPAIGN tokens purchased
    uint256 public ghost_totalBurned; // total $CAMPAIGN burned across penalties + buybacks
    mapping(bytes32 => uint256) public calls;

    modifier countCall(string memory name) {
        calls[keccak256(bytes(name))]++;
        _;
    }

    constructor(
        Campaign _campaign,
        CampaignToken _campaignToken,
        YieldToken _yieldToken,
        StakingVault _stakingVault,
        MockERC20 _usdc,
        address _producer,
        address[] memory _actors
    ) {
        campaign = _campaign;
        campaignToken = _campaignToken;
        yieldToken = _yieldToken;
        stakingVault = _stakingVault;
        usdc = _usdc;
        producer = _producer;
        actors = _actors;

        // Pre-fund & approve every actor so the fuzzer doesn't waste runs on setup-level reverts
        for (uint256 i = 0; i < actors.length; i++) {
            usdc.mint(actors[i], 10_000_000e6);
            vm.startPrank(actors[i]);
            usdc.approve(address(campaign), type(uint256).max);
            campaignToken.approve(address(stakingVault), type(uint256).max);
            campaignToken.approve(address(campaign), type(uint256).max);
            vm.stopPrank();
        }
    }

    // --- Helpers ---

    function _pickActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // --- Time ---

    function warp(uint256 secondsAhead) external countCall("warp") {
        secondsAhead = bound(secondsAhead, 1 hours, 30 days);
        vm.warp(block.timestamp + secondsAhead);
    }

    // --- Campaign actions ---

    function buy(uint256 actorSeed, uint256 payAmount) external countCall("buy") {
        Campaign.State s = campaign.state();
        if (s != Campaign.State.Funding && s != Campaign.State.Active) return;
        payAmount = bound(payAmount, 1_000_000, 5_000e6); // 1 USDC to 5000 USDC

        address actor = _pickActor(actorSeed);
        uint256 supplyBefore = campaignToken.totalSupply();

        vm.prank(actor);
        try campaign.buy(address(usdc), payAmount) {
            ghost_totalBought += campaignToken.totalSupply() - supplyBefore;
        } catch {}
    }

    function triggerBuyback() external countCall("triggerBuyback") {
        if (campaign.state() != Campaign.State.Funding) return;
        if (block.timestamp < campaign.fundingDeadline()) return;
        if (campaign.currentSupply() >= campaign.minCap()) return;
        try campaign.triggerBuyback() {} catch {}
    }

    function buyback(uint256 actorSeed) external countCall("buyback") {
        if (campaign.state() != Campaign.State.Buyback) return;
        address actor = _pickActor(actorSeed);
        if (campaign.purchases(actor, address(usdc)) == 0) return;

        uint256 supplyBefore = campaignToken.totalSupply();
        vm.prank(actor);
        try campaign.buyback(address(usdc)) {
            ghost_totalBurned += supplyBefore - campaignToken.totalSupply();
        } catch {}
    }

    function sellBack(uint256 actorSeed, uint256 amount) external countCall("sellBack") {
        if (campaign.state() != Campaign.State.Active) return;
        address actor = _pickActor(actorSeed);
        uint256 balance = campaignToken.balanceOf(actor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        vm.prank(actor);
        try campaign.sellBack(amount) {} catch {}
    }

    function cancelSellBack(uint256 actorSeed) external countCall("cancelSellBack") {
        address actor = _pickActor(actorSeed);
        if (campaign.pendingSellBack(actor) == 0) return;
        vm.prank(actor);
        try campaign.cancelSellBack() {} catch {}
    }

    // --- Season management ---

    function startSeason(uint256 seasonSeed) external countCall("startSeason") {
        if (campaign.state() != Campaign.State.Active) return;
        if (seasonActive) return;
        uint256 newSeason = currentSeason + 1 + (seasonSeed % 3);

        vm.prank(producer);
        try campaign.startSeason(newSeason) {
            currentSeason = newSeason;
            seasonActive = true;
        } catch {}
    }

    function endSeason() external countCall("endSeason") {
        if (!seasonActive) return;
        if (campaign.state() != Campaign.State.Active) return;
        vm.prank(producer);
        try campaign.endSeason() {
            seasonActive = false;
        } catch {}
    }

    // --- Staking ---

    function stake(uint256 actorSeed, uint256 amount) external countCall("stake") {
        if (!seasonActive) return;
        address actor = _pickActor(actorSeed);
        uint256 balance = campaignToken.balanceOf(actor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        vm.prank(actor);
        try stakingVault.stake(amount) {} catch {}
    }

    function unstake(uint256 actorSeed, uint256 positionSeed) external countCall("unstake") {
        address actor = _pickActor(actorSeed);
        uint256[] memory ids = stakingVault.getPositions(actor);
        if (ids.length == 0) return;
        uint256 pid = ids[positionSeed % ids.length];

        uint256 supplyBefore = campaignToken.totalSupply();
        vm.prank(actor);
        try stakingVault.unstake(pid) {
            ghost_totalBurned += supplyBefore - campaignToken.totalSupply();
        } catch {}
    }

    function claimYield(uint256 actorSeed, uint256 positionSeed) external countCall("claimYield") {
        address actor = _pickActor(actorSeed);
        uint256[] memory ids = stakingVault.getPositions(actor);
        if (ids.length == 0) return;
        uint256 pid = ids[positionSeed % ids.length];
        vm.prank(actor);
        try stakingVault.claimYield(pid) {} catch {}
    }

    function restake(uint256 actorSeed, uint256 positionSeed) external countCall("restake") {
        if (!seasonActive) return;
        address actor = _pickActor(actorSeed);
        uint256[] memory ids = stakingVault.getPositions(actor);
        if (ids.length == 0) return;
        uint256 pid = ids[positionSeed % ids.length];
        vm.prank(actor);
        try stakingVault.restake(pid) {} catch {}
    }

    // --- Introspection for invariant ---

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }
}
