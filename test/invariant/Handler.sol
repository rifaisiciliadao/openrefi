// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CampaignStorage} from "../../src/host/CampaignStorage.sol";
import {IGrowfiCampaignFull} from "../../src/interfaces/IGrowfiCampaignFull.sol";
import {GrowfiCampaignToken} from "../../src/GrowfiCampaignToken.sol";
import {GrowfiYieldToken} from "../../src/GrowfiYieldToken.sol";
import {GrowfiStakingVault} from "../../src/GrowfiStakingVault.sol";
import {RepaymentModule} from "../../src/modules/RepaymentModule.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

contract Handler is Test {
    IGrowfiCampaignFull public campaign;
    GrowfiCampaignToken public campaignToken;
    GrowfiYieldToken public yieldToken;
    GrowfiStakingVault public stakingVault;
    MockERC20 public usdc;
    address public producer;

    address[] public actors;
    uint256 public currentSeason;
    bool public seasonActive;

    uint256 public ghost_totalBought;
    uint256 public ghost_totalBurned;
    uint256 public ghost_totalRedeemed;
    uint256 public ghost_repaymentPoolFunded;
    bool public repaymentAttached;
    mapping(bytes32 => uint256) public calls;

    modifier countCall(string memory name) {
        calls[keccak256(bytes(name))]++;
        _;
    }

    constructor(
        address _campaign,
        GrowfiCampaignToken _campaignToken,
        GrowfiYieldToken _yieldToken,
        GrowfiStakingVault _stakingVault,
        MockERC20 _usdc,
        address _producer,
        address[] memory _actors
    ) {
        campaign = IGrowfiCampaignFull(payable(_campaign));
        campaignToken = _campaignToken;
        yieldToken = _yieldToken;
        stakingVault = _stakingVault;
        usdc = _usdc;
        producer = _producer;
        actors = _actors;

        for (uint256 i = 0; i < actors.length; i++) {
            usdc.mint(actors[i], 10_000_000e6);
            vm.startPrank(actors[i]);
            usdc.approve(_campaign, type(uint256).max);
            campaignToken.approve(address(stakingVault), type(uint256).max);
            campaignToken.approve(_campaign, type(uint256).max);
            vm.stopPrank();
        }
    }

    function _pickActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function warp(uint256 secondsAhead) external countCall("warp") {
        secondsAhead = bound(secondsAhead, 1 hours, 30 days);
        vm.warp(block.timestamp + secondsAhead);
    }

    function buy(uint256 actorSeed, uint256 payAmount) external countCall("buy") {
        CampaignStorage.State s = campaign.state();
        if (s != CampaignStorage.State.Funding && s != CampaignStorage.State.Active) return;
        payAmount = bound(payAmount, 1_000_000, 5_000e6);

        address actor = _pickActor(actorSeed);
        uint256 supplyBefore = campaignToken.totalSupply();

        vm.prank(actor);
        try campaign.buy(address(usdc), payAmount) {
            ghost_totalBought += campaignToken.totalSupply() - supplyBefore;
        } catch {}
    }

    function triggerBuyback() external countCall("triggerBuyback") {
        if (campaign.state() != CampaignStorage.State.Funding) return;
        if (block.timestamp < campaign.fundingDeadline()) return;
        if (campaign.currentSupply() >= campaign.minCap()) return;
        try campaign.triggerBuyback() {} catch {}
    }

    function buyback(uint256 actorSeed) external countCall("buyback") {
        if (campaign.state() != CampaignStorage.State.Buyback) return;
        address actor = _pickActor(actorSeed);
        if (campaign.purchases(actor, address(usdc)) == 0) return;

        uint256 supplyBefore = campaignToken.totalSupply();
        vm.prank(actor);
        try campaign.buyback(address(usdc)) {
            ghost_totalBurned += supplyBefore - campaignToken.totalSupply();
        } catch {}
    }

    function sellBack(uint256 actorSeed, uint256 amount) external countCall("sellBack") {
        if (campaign.state() != CampaignStorage.State.Active) return;
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

    function startSeason(uint256) external countCall("startSeason") {
        if (campaign.state() != CampaignStorage.State.Active) return;
        if (seasonActive) return;

        vm.prank(producer);
        try campaign.startSeason() {
            currentSeason = campaign.currentSeasonId();
            seasonActive = true;
        } catch {}
    }

    function endSeason() external countCall("endSeason") {
        if (!seasonActive) return;
        if (campaign.state() != CampaignStorage.State.Active) return;
        vm.prank(producer);
        try campaign.endSeason() {
            seasonActive = false;
        } catch {}
    }

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

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    // ------------------------------------------------------------------
    // Repayment module fuzz actions
    // ------------------------------------------------------------------

    /// @dev Test entry point sets this to true once the Repayment module
    ///      is attached + initialized. Until then, the fuzz actions
    ///      below short-circuit.
    function setRepaymentAttached(bool v) external {
        repaymentAttached = v;
    }

    /// @dev Producer adds USDC to the Repayment pool. Bounded to stay
    ///      below producer's mint capacity in setUp (10M USDC each).
    function repay_fundPool(uint256 amount) external countCall("repay_fundPool") {
        if (!repaymentAttached) return;
        amount = bound(amount, 1e6, 1_000_000e6);
        usdc.mint(producer, amount);
        vm.startPrank(producer);
        usdc.approve(address(campaign), amount);
        try RepaymentModule(payable(address(campaign))).fundPool(amount) {
            ghost_repaymentPoolFunded += amount;
        } catch {}
        vm.stopPrank();
    }

    /// @dev Producer adjusts bonus markup.
    function repay_setBonus(uint256 bonus) external countCall("repay_setBonus") {
        if (!repaymentAttached) return;
        bonus = bound(bonus, 0, 1e6); // up to $1 bonus per CT
        vm.prank(producer);
        try RepaymentModule(payable(address(campaign))).setBonusPerCt(bonus) {} catch {}
    }

    /// @dev Producer withdraws from pool. May revert if balance < amount.
    function repay_withdrawPool(uint256 amount) external countCall("repay_withdrawPool") {
        if (!repaymentAttached) return;
        amount = bound(amount, 1, 1_000_000e6);
        vm.prank(producer);
        try RepaymentModule(payable(address(campaign))).withdrawUnusedPool(amount) {} catch {}
    }

    /// @dev Random actor redeems CT for USDC. May force-unstake one of
    ///      their own positions if they don't have enough free CT.
    function repay_redeem(uint256 actorSeed, uint256 amount, bool useUnstake) external countCall("repay_redeem") {
        if (!repaymentAttached) return;
        address actor = _pickActor(actorSeed);

        // Compose unstake list: maybe one of the actor's own positions
        uint256[] memory unstakeFirst;
        if (useUnstake) {
            uint256[] memory ids = stakingVault.getPositions(actor);
            if (ids.length > 0) {
                unstakeFirst = new uint256[](1);
                unstakeFirst[0] = ids[actorSeed % ids.length];
            } else {
                unstakeFirst = new uint256[](0);
            }
        } else {
            unstakeFirst = new uint256[](0);
        }

        amount = bound(amount, 1, 1_000e18); // cap to bound test runtime
        uint256 supplyBefore = campaignToken.totalSupply();

        vm.prank(actor);
        try RepaymentModule(payable(address(campaign))).redeem(amount, unstakeFirst) {
            ghost_totalBurned += supplyBefore - campaignToken.totalSupply();
            ghost_totalRedeemed += supplyBefore - campaignToken.totalSupply();
        } catch {}
    }
}
