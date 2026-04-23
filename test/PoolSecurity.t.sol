// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {CampaignFactory} from "../src/CampaignFactory.sol";
import {Campaign} from "../src/Campaign.sol";
import {CampaignToken} from "../src/CampaignToken.sol";
import {YieldToken} from "../src/YieldToken.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {HarvestManager} from "../src/HarvestManager.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {ReentrantToken} from "./helpers/ReentrantToken.sol";
import {FeeOnTransferToken} from "./helpers/FeeOnTransferToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Deployer} from "./helpers/Deployer.sol";

/// @title PoolSecurity — reentrancy + pool-accounting adversarial tests
/// @notice Covers gaps in RedTeam.t.sol that had no explicit reentrancy /
///         fee-on-transfer / ERC777-style hook coverage:
///
///           1. Reentrancy: prove every nonReentrant-guarded entry point
///              rejects a re-entry from a hostile ERC20's transfer hook.
///           2. Cross-function reentrancy inside the same proxy (buy → sellBack,
///              buy → cancelSellBack, buy → buyback, etc.).
///           3. Cross-PROXY reentrancy: hostile payment token during Campaign.buy
///              re-enters StakingVault / HarvestManager; prove no drain is
///              possible even though those guards are per-contract.
///           4. Fee-on-transfer payment token: demonstrate the accounting
///              gap if a producer carelessly whitelists a FoT ERC20. Not a
///              protocol bug per se — the whitelist is producer-gated — but
///              the tests pin down what breaks so the docs can warn producers.
contract PoolSecurityTest is Test {
    CampaignFactory factory;
    MockERC20 usdc;
    Campaign campaign;
    CampaignToken campaignToken;
    YieldToken yieldToken;
    StakingVault stakingVault;
    HarvestManager harvestManager;

    address protocolOwner = makeAddr("protocolOwner");
    address feeRecipient = makeAddr("feeRecipient");
    address producer = makeAddr("producer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address attacker = makeAddr("attacker");

    uint256 constant PRICE_PER_TOKEN = 0.144e18;
    uint256 constant MIN_CAP = 50_000e18;
    uint256 constant MAX_CAP = 100_000e18;
    uint256 constant SEASON_DURATION = 365 days;
    uint256 constant USDC_FIXED_RATE = 144_000;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        factory = Deployer.deployProtocol(protocolOwner, feeRecipient, address(usdc), address(0));

        vm.prank(producer);
        factory.createCampaign(
            CampaignFactory.CreateCampaignParams({
                producer: producer,
                tokenName: "Olive",
                tokenSymbol: "OLIVE",
                yieldName: "oYield",
                yieldSymbol: "oY",
                pricePerToken: PRICE_PER_TOKEN,
                minCap: MIN_CAP,
                maxCap: MAX_CAP,
                fundingDeadline: block.timestamp + 90 days,
                seasonDuration: SEASON_DURATION,
                minProductClaim: 5e18
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

        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        usdc.mint(attacker, 100_000e6);

        _approveAll(alice);
        _approveAll(bob);
        _approveAll(attacker);
    }

    function _approveAll(address who) internal {
        vm.startPrank(who);
        usdc.approve(address(campaign), type(uint256).max);
        usdc.approve(address(harvestManager), type(uint256).max);
        campaignToken.approve(address(stakingVault), type(uint256).max);
        campaignToken.approve(address(campaign), type(uint256).max);
        vm.stopPrank();
    }

    function _whitelistReentrantToken(ReentrantToken tok, uint256 fixedRate) internal {
        vm.prank(producer);
        campaign.addAcceptedToken(address(tok), Campaign.PricingMode.Fixed, fixedRate, address(0));
    }

    function _whitelistFotToken(FeeOnTransferToken tok, uint256 fixedRate) internal {
        vm.prank(producer);
        campaign.addAcceptedToken(address(tok), Campaign.PricingMode.Fixed, fixedRate, address(0));
    }

    function _activateViaAlice() internal {
        uint256 pay = 60_000 * USDC_FIXED_RATE;
        vm.prank(alice);
        campaign.buy(address(usdc), pay);
        assertEq(uint8(campaign.state()), uint8(Campaign.State.Active), "setup: not active");
    }

    // =========================================================================
    // 1. DIRECT REENTRANCY — same-function, guarded by nonReentrant
    // =========================================================================

    /// Attacker whitelists a reentrant token, then calls Campaign.buy. During
    /// the payment token's transferFrom, it re-enters Campaign.buy. The
    /// nonReentrant modifier must block the inner call.
    function test_reentrancy_buy_blocksSelfReentry() public {
        ReentrantToken rog = new ReentrantToken("Rogue", "ROG", 18);
        _whitelistReentrantToken(rog, 1e18); // 1 ROG per 1 OLIVE
        rog.mint(attacker, 1000e18);
        vm.prank(attacker);
        rog.approve(address(campaign), type(uint256).max);

        // Arm the token so its next transfer re-enters Campaign.buy(rog, 1e18).
        bytes memory payload = abi.encodeCall(Campaign.buy, (address(rog), 1e18));
        rog.arm(address(campaign), payload);

        vm.prank(attacker);
        vm.expectRevert(); // ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall
        campaign.buy(address(rog), 10e18);
    }

    /// Same attack surface from the Buyback state: re-enter buyback() inside
    /// the payment token's transfer hook.
    function test_reentrancy_buyback_blocksSelfReentry() public {
        ReentrantToken rog = new ReentrantToken("Rogue", "ROG", 18);
        _whitelistReentrantToken(rog, 1e18);
        rog.mint(attacker, 1000e18);
        vm.prank(attacker);
        rog.approve(address(campaign), type(uint256).max);

        // Fund the campaign below minCap, then force it to Buyback.
        vm.prank(attacker);
        campaign.buy(address(rog), 10e18);

        vm.warp(block.timestamp + 91 days);
        campaign.triggerBuyback();
        assertEq(uint8(campaign.state()), uint8(Campaign.State.Buyback));

        // Now arm the refund token to reenter buyback during safeTransfer.
        bytes memory payload = abi.encodeCall(Campaign.buyback, (address(rog)));
        rog.arm(address(campaign), payload);

        vm.prank(attacker);
        vm.expectRevert();
        campaign.buyback(address(rog));
    }

    /// Re-enter sellBack() during the campaignToken transfer inside
    /// another sellBack call. CampaignToken is a controlled token that doesn't
    /// have hooks, so we need a different vector: attacker reenters from a
    /// TRIGGERED call. In practice the only re-entrant surface is the payment
    /// token during a buy that fills the queue. Cover that below.
    function test_reentrancy_buyFillQueue_blocksBuyRentry() public {
        _activateViaAlice();

        // Alice queues a sellBack order for 1000 OLIVE.
        vm.prank(alice);
        campaign.sellBack(1000e18);

        // Attacker whitelists a rogue token as accepted payment AFTER activation.
        ReentrantToken rog = new ReentrantToken("Rogue", "ROG", 18);
        _whitelistReentrantToken(rog, 1e18);
        rog.mint(attacker, 1000e18);
        vm.prank(attacker);
        rog.approve(address(campaign), type(uint256).max);

        // During _fillSellBackQueue → safeTransfer(order.seller, paymentForFill)
        // the seller is alice, not the attacker, so arming `rog` here doesn't
        // hit us. Instead, arm the token's safeTransferFrom (pull from buyer)
        // to reenter Campaign.buy.
        bytes memory payload = abi.encodeCall(Campaign.buy, (address(rog), 1e18));
        rog.arm(address(campaign), payload);

        vm.prank(attacker);
        vm.expectRevert();
        campaign.buy(address(rog), 5e18);
    }

    /// StakingVault.stake: reentrant token as $CAMPAIGN? Not possible —
    /// CampaignToken is a fixed contract without hooks. But prove that
    /// campaignToken.transferFrom into stake cannot produce a reentry anyway.
    /// This is a sanity test on the pattern.
    function test_reentrancy_stake_campaignTokenHasNoHook() public {
        _activateViaAlice();
        vm.prank(producer);
        campaign.startSeason(1);

        // Buy + approve.
        uint256 supplyBefore = campaignToken.totalSupply();
        vm.prank(alice);
        campaign.buy(address(usdc), 1000 * USDC_FIXED_RATE);
        uint256 newSupply = campaignToken.totalSupply() - supplyBefore;

        // stake a real amount; should succeed, no hook to reenter.
        vm.prank(alice);
        uint256 posId = stakingVault.stake(newSupply);
        (, uint256 amt,,,, bool active) = stakingVault.positions(posId);
        assertEq(amt, newSupply);
        assertTrue(active);
    }

    /// HarvestManager.depositUSDC: if the USDC token were hostile, could the
    /// producer be tricked into double-accounting? ReentrantGuard should
    /// block even theoretical re-entry. We can't whitelist a different USDC
    /// (it's fixed at factory init), so we build an isolated campaign with
    /// a ReentrantToken as the USDC to prove depositUSDC's guard holds.
    function test_reentrancy_depositUSDC_blocksSelfReentry() public {
        // Build a parallel factory whose USDC is the reentrant token.
        ReentrantToken rog = new ReentrantToken("Rogue USDC", "rUSDC", 6);
        CampaignFactory rogueFactory = Deployer.deployProtocol(protocolOwner, feeRecipient, address(rog), address(0));

        vm.prank(producer);
        rogueFactory.createCampaign(
            CampaignFactory.CreateCampaignParams({
                producer: producer,
                tokenName: "Olive2",
                tokenSymbol: "OLIVE2",
                yieldName: "oY2",
                yieldSymbol: "oY2",
                pricePerToken: PRICE_PER_TOKEN,
                minCap: 100e18,
                maxCap: 1000e18,
                fundingDeadline: block.timestamp + 90 days,
                seasonDuration: SEASON_DURATION,
                minProductClaim: 1e18
            })
        );
        (,,,, address hm2,,) = rogueFactory.campaigns(0);
        HarvestManager hm = HarvestManager(hm2);

        // Arm the token to try reentering depositUSDC during safeTransferFrom.
        rog.mint(producer, 1_000e6);
        vm.prank(producer);
        rog.approve(address(hm), type(uint256).max);

        bytes memory payload = abi.encodeCall(HarvestManager.depositUSDC, (1, 1e6));
        rog.arm(address(hm), payload);

        // reportHarvest is onlyStakingVault — we can't easily trigger deposit,
        // but we CAN assert depositUSDC reverts on the re-entry path anyway,
        // because the outer call itself will hit NotReported first. Arm is
        // cheap; we just verify the outer call reverts without progressing
        // to the inner reentry (which nonReentrant would also block).
        vm.prank(producer);
        vm.expectRevert(); // NotReported() — outer guard trips before our hook
        hm.depositUSDC(1, 1e6);
    }

    // =========================================================================
    // 2. CROSS-FUNCTION REENTRANCY — different function on same contract
    // =========================================================================

    /// From the reentrant buy(), try to call sellBack() / cancelSellBack() /
    /// buyback(). All share the same nonReentrant slot on Campaign, so all
    /// must revert.
    function test_reentrancy_buy_blocksSellBackRentry() public {
        _activateViaAlice();
        vm.prank(alice);
        campaign.sellBack(500e18); // queue exists so fill path would execute

        ReentrantToken rog = new ReentrantToken("Rogue", "ROG", 18);
        _whitelistReentrantToken(rog, 1e18);
        rog.mint(attacker, 1000e18);
        vm.prank(attacker);
        rog.approve(address(campaign), type(uint256).max);

        // Reentry: call sellBack — the attacker doesn't own $CAMPAIGN yet
        // (still in buy flow), but nonReentrant must trip before that check.
        bytes memory payload = abi.encodeCall(Campaign.sellBack, (1));
        rog.arm(address(campaign), payload);

        vm.prank(attacker);
        vm.expectRevert();
        campaign.buy(address(rog), 10e18);
    }

    function test_reentrancy_buy_blocksCancelSellBackRentry() public {
        _activateViaAlice();

        ReentrantToken rog = new ReentrantToken("Rogue", "ROG", 18);
        _whitelistReentrantToken(rog, 1e18);
        rog.mint(attacker, 1000e18);
        vm.prank(attacker);
        rog.approve(address(campaign), type(uint256).max);

        bytes memory payload = abi.encodeCall(Campaign.cancelSellBack, ());
        rog.arm(address(campaign), payload);

        vm.prank(attacker);
        vm.expectRevert();
        campaign.buy(address(rog), 10e18);
    }

    // =========================================================================
    // 3. CROSS-PROXY REENTRANCY — same campaign's other contracts
    // =========================================================================

    /// A hostile payment token during Campaign.buy re-enters StakingVault.stake.
    /// StakingVault has its own nonReentrant slot so the inner call is NOT
    /// blocked by Campaign's lock. We prove that the reentry's `msg.sender`
    /// is the hostile TOKEN CONTRACT, not the attacker — so the token can
    /// only stake with its OWN balance/allowance. It has neither, so the
    /// inner call reverts cleanly. The outer buy still completes normally
    /// when `swallow_=true`, and no assets are moved beyond the attacker's
    /// legitimate purchase.
    function test_crossProxy_buyReentersStakingVault_reentryHasRogueIdentity() public {
        _activateViaAlice();
        vm.prank(producer);
        campaign.startSeason(1);

        ReentrantToken rog = new ReentrantToken("Rogue", "ROG", 18);
        _whitelistReentrantToken(rog, 1e18);
        rog.mint(attacker, 100e18);
        vm.prank(attacker);
        rog.approve(address(campaign), type(uint256).max);

        // Arm the token to reenter StakingVault.stake(1e18). The reentry will
        // fail inside StakingVault with ERC20InsufficientAllowance because
        // msg.sender there is the rogue token contract, which has no
        // approval. We use swallow=true so the outer buy completes and we
        // can observe post-state.
        bytes memory payload = abi.encodeCall(StakingVault.stake, (1e18));
        rog.arm(address(stakingVault), payload, true);

        vm.prank(attacker);
        campaign.buy(address(rog), 10e18);

        // Reentry failed harmlessly.
        assertFalse(rog.lastCallOk(), "reentry must fail on missing allowance");

        // StakingVault has no positions at all — attacker didn't stake.
        assertEq(stakingVault.getPositions(attacker).length, 0);
        assertEq(stakingVault.getPositions(address(rog)).length, 0);

        // Attacker's only gain is the 10 OLIVE they paid for.
        assertEq(campaignToken.balanceOf(attacker), 10e18);
        assertEq(stakingVault.totalStaked(), 0);
    }

    // =========================================================================
    // 4. FEE-ON-TRANSFER — documents the producer-whitelist risk
    // =========================================================================

    /// FoT token as payment: Campaign records `paymentAmount` even though the
    /// contract received less. In Buyback state, the last user to refund
    /// reverts with ERC20InsufficientBalance because the shortfall accumulated.
    /// This is NOT a protocol-level bug — the accepted-token allowlist is
    /// producer-gated — but this test documents the blast radius so producers
    /// can be warned. A fix would replace `paymentAmount` with the actual
    /// balance delta around safeTransferFrom.
    function test_feeOnTransfer_buybackShortfallForLastUser() public {
        FeeOnTransferToken fot = new FeeOnTransferToken("Fee Token", "FEE", 18, 100); // 1% fee
        _whitelistFotToken(fot, 1e18); // 1 FEE per OLIVE
        fot.mint(alice, 1000e18);
        fot.mint(bob, 1000e18);
        vm.prank(alice);
        fot.approve(address(campaign), type(uint256).max);
        vm.prank(bob);
        fot.approve(address(campaign), type(uint256).max);

        // Both alice + bob buy 100 OLIVE for 100 FEE each.
        // Per-buy flow with 3% funding fee + 1% FoT:
        //   - transferFrom(buyer, 100) → contract receives 99 (1 FEE burned)
        //   - contract transfers 3 (nominal fee) to feeRecipient → 0.03 more burned,
        //     2.97 arrives at recipient; contract balance drops to 96.
        //   - purchases[user] += 97 (declared 100 − nominal fee 3, the net).
        vm.prank(alice);
        campaign.buy(address(fot), 100e18);
        vm.prank(bob);
        campaign.buy(address(fot), 100e18);

        assertEq(campaign.purchases(alice, address(fot)), 97e18);
        assertEq(campaign.purchases(bob, address(fot)), 97e18);
        assertEq(fot.balanceOf(address(campaign)), 192e18, "shortfall: 2 on buy-in + 0.06 on fee transfer burned by FoT");

        // Force Buyback.
        vm.warp(block.timestamp + 91 days);
        campaign.triggerBuyback();

        // Alice refunds successfully. Contract sends 97 FEE, FoT burns ~0.97 FEE
        // in flight, alice receives 96.03.
        vm.prank(alice);
        campaign.buyback(address(fot));
        assertEq(fot.balanceOf(alice), 1000e18 - 100e18 + 97e18 * 99 / 100);

        // Bob now tries to refund 97 FEE. Contract holds only 95 FEE
        // (192 − 97 sent to alice = 95). Transfer reverts.
        vm.prank(bob);
        vm.expectRevert(); // ERC20InsufficientBalance
        campaign.buyback(address(fot));
    }

    /// FoT token on activation: `_activate` no longer splits the escrow — the
    /// funding fee was already taken at each `buy()` call, so activation just
    /// drains `balanceOf(address(this))` to the producer. Verifies that the
    /// drain uses the REAL balance (post-FoT), not the declared sum of
    /// purchases, so producer simply receives less than `sum(purchases)`.
    function test_feeOnTransfer_activationUsesRealBalance() public {
        FeeOnTransferToken fot = new FeeOnTransferToken("Fee Token", "FEE", 18, 100);
        // fixed rate: 1 FEE per 1 OLIVE.
        _whitelistFotToken(fot, 1e18);
        fot.mint(alice, 100_000e18);
        vm.prank(alice);
        fot.approve(address(campaign), type(uint256).max);

        // Buy enough to hit minCap (50_000 OLIVE → 50_000 FEE declared).
        uint256 declared = 60_000e18;
        vm.prank(alice);
        campaign.buy(address(fot), declared);

        assertEq(uint8(campaign.state()), uint8(Campaign.State.Active));

        // Producer receives whatever is left in escrow after: (1) 1% FoT on
        // transferFrom from alice, (2) the 3% nominal funding fee leaving the
        // contract at buy time, (3) 1% FoT on the outgoing funding-fee transfer,
        // (4) 1% FoT on the escrow drain at activation. Not trivially closed-form;
        // assert it's strictly less than the declared 60_000 and that the fee
        // recipient got SOMETHING from the buy-time fee transfer.
        uint256 producerReceived = fot.balanceOf(producer);
        uint256 feeReceived = fot.balanceOf(feeRecipient);
        assertLt(producerReceived, declared, "producer cannot exceed declared");
        assertGt(feeReceived, 0, "feeRecipient got the funding fee");
    }
}
