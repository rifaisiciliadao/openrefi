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
import {MockOracle} from "./helpers/MockOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Deployer} from "./helpers/Deployer.sol";

/// @title RedTeam — Adversarial attack attempts against the GrowFi protocol
/// @notice Each test simulates an attacker trying to exploit a specific surface.
///         A passing test means the attack was successfully *blocked* by the contracts.
contract RedTeamTest is Test {
    CampaignFactory factory;
    MockERC20 usdc;
    MockERC20 weth;
    MockOracle wethOracle;

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
        weth = new MockERC20("WETH", "WETH", 18);
        wethOracle = new MockOracle(2880e8, 8);

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
                minProductClaim: 5e18,
                expectedAnnualHarvestUsd: 5_000e18,
                firstHarvestYear: 2030,
                coverageHarvests: 0
            })
        );

        (address c, address ct, address yt, address sv, address hm,,) = factory.campaigns(0);
        campaign = Campaign(c);
        campaignToken = CampaignToken(ct);
        yieldToken = YieldToken(yt);
        stakingVault = StakingVault(sv);
        harvestManager = HarvestManager(hm);

        vm.startPrank(producer);
        campaign.addAcceptedToken(address(usdc), Campaign.PricingMode.Fixed, USDC_FIXED_RATE, address(0));
        campaign.addAcceptedToken(address(weth), Campaign.PricingMode.Oracle, 0, address(wethOracle));
        vm.stopPrank();

        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        usdc.mint(attacker, 100_000e6);
        weth.mint(attacker, 100e18);

        _approveAll(alice);
        _approveAll(bob);
        _approveAll(attacker);
    }

    function _approveAll(address who) internal {
        vm.startPrank(who);
        usdc.approve(address(campaign), type(uint256).max);
        usdc.approve(address(harvestManager), type(uint256).max);
        weth.approve(address(campaign), type(uint256).max);
        campaignToken.approve(address(stakingVault), type(uint256).max);
        campaignToken.approve(address(campaign), type(uint256).max);
        vm.stopPrank();
    }

    function _activateCampaign() internal {
        uint256 pay = 60_000 * USDC_FIXED_RATE;
        vm.prank(alice);
        campaign.buy(address(usdc), pay);
        assertEq(uint8(campaign.state()), uint8(Campaign.State.Active));
    }

    // =========================================================================
    // ATTACK 1 — Unauthorized mint of CampaignToken
    // =========================================================================
    function test_attack_mintCampaignTokenDirectly() public {
        vm.prank(attacker);
        vm.expectRevert(CampaignToken.OnlyCampaign.selector);
        campaignToken.mint(attacker, 1_000_000e18);
    }

    // =========================================================================
    // ATTACK 2 — Unauthorized burn on someone else's balance
    // =========================================================================
    function test_attack_burnVictimTokens() public {
        _activateCampaign();
        vm.prank(attacker);
        vm.expectRevert(CampaignToken.OnlyCampaignOrVault.selector);
        campaignToken.burn(alice, 1e18);
    }

    // =========================================================================
    // ATTACK 3 — Mint $YIELD directly to attacker, bypassing staking
    // =========================================================================
    function test_attack_mintYieldTokenDirectly() public {
        vm.prank(attacker);
        vm.expectRevert(YieldToken.OnlyStakingVault.selector);
        yieldToken.mint(attacker, 1_000_000e18);
    }

    // =========================================================================
    // ATTACK 4 — Factory setter re-hijack (setCampaignToken twice)
    // =========================================================================
    function test_attack_resetCampaignTokenAfterDeploy() public {
        // Factory already called setCampaignToken during createCampaign
        // Even if factory could somehow re-call it, the one-time guard must block
        vm.prank(address(factory));
        vm.expectRevert(Campaign.AlreadySet.selector);
        campaign.setCampaignToken(address(0xdead));
    }

    function test_attack_resetStakingVaultOnToken() public {
        vm.prank(address(campaign));
        vm.expectRevert(CampaignToken.StakingVaultAlreadySet.selector);
        campaignToken.setStakingVault(address(0xdead));
    }

    function test_attack_resetYieldTokenOnHarvest() public {
        vm.prank(address(factory));
        vm.expectRevert(HarvestManager.AlreadySet.selector);
        harvestManager.setYieldToken(address(0xdead));
    }

    // =========================================================================
    // ATTACK 5 — Random caller forges a harvest report
    // =========================================================================
    function test_attack_forgeHarvestReport() public {
        vm.prank(attacker);
        vm.expectRevert(HarvestManager.OnlyProducer.selector);
        harvestManager.reportHarvest(1, 1_000_000e18, bytes32(uint256(0xdead)), 1000e18);
    }

    // =========================================================================
    // ATTACK 6 — Forge a Merkle proof for product redemption
    // =========================================================================
    function test_attack_forgeMerkleProof() public {
        _activateCampaign();
        vm.prank(producer);
        campaign.startSeason(1);
        vm.prank(alice);
        stakingVault.stake(60_000e18);
        vm.warp(block.timestamp + 365 days);
        vm.prank(alice);
        stakingVault.claimYield(0);
        vm.prank(producer);
        campaign.endSeason();

        // Producer reports a harvest with a real merkle root of a single honest leaf
        uint256 aliceYield = yieldToken.balanceOf(alice);
        uint256 totalProductUnits = 2000e18;
        uint256 totalYield = yieldToken.totalSupply();
        uint256 productAlice = aliceYield * totalProductUnits / totalYield;
        bytes32 realRoot = keccak256(abi.encodePacked(alice, uint256(1), productAlice));

        vm.prank(producer);
        harvestManager.reportHarvest(1, 14_000e18, realRoot, totalProductUnits);

        // Attacker tries to claim product as if they were in the tree with a bogus proof
        bytes32[] memory fakeProof = new bytes32[](1);
        fakeProof[0] = bytes32(uint256(0xbeef));
        vm.prank(attacker);
        vm.expectRevert(HarvestManager.InvalidMerkleProof.selector);
        harvestManager.redeemProduct(1, 10e18, fakeProof);

        // Even with correct-shaped proof but wrong leaf (attacker pretends to be alice)
        bytes32[] memory emptyProof = new bytes32[](0);
        vm.prank(attacker);
        vm.expectRevert(HarvestManager.InvalidMerkleProof.selector);
        harvestManager.redeemProduct(1, aliceYield, emptyProof);
    }

    // =========================================================================
    // ATTACK 7 — Double redemption (product, then USDC)
    // =========================================================================
    function test_attack_doubleRedemption() public {
        _activateCampaign();
        vm.prank(producer);
        campaign.startSeason(1);
        vm.prank(alice);
        stakingVault.stake(60_000e18);
        vm.warp(block.timestamp + 365 days);
        vm.prank(alice);
        stakingVault.claimYield(0);
        vm.prank(producer);
        campaign.endSeason();

        uint256 aliceYield = yieldToken.balanceOf(alice);
        uint256 totalYield = yieldToken.totalSupply();
        uint256 totalProductUnits = 2000e18;
        uint256 productAlice = aliceYield * totalProductUnits / totalYield;
        bytes32 leaf = keccak256(abi.encodePacked(alice, uint256(1), productAlice));

        vm.prank(producer);
        harvestManager.reportHarvest(1, 14_000e18, leaf, totalProductUnits);

        // First redemption ok
        bytes32[] memory emptyProof = new bytes32[](0);
        vm.prank(alice);
        harvestManager.redeemProduct(1, aliceYield, emptyProof);

        // Alice tries to also redeem USDC for the same season — must revert
        vm.prank(alice);
        vm.expectRevert(HarvestManager.AlreadyClaimed.selector);
        harvestManager.redeemUSDC(1, 1);
    }

    // =========================================================================
    // ATTACK 8 — Claim window bypass (redeem before window or after close)
    // =========================================================================
    function test_attack_redeemAfterWindow() public {
        _activateCampaign();
        vm.prank(producer);
        campaign.startSeason(1);
        vm.prank(alice);
        stakingVault.stake(60_000e18);
        vm.warp(block.timestamp + 365 days);
        vm.prank(alice);
        stakingVault.claimYield(0);
        vm.prank(producer);
        campaign.endSeason();

        uint256 aliceYield = yieldToken.balanceOf(alice);
        vm.prank(producer);
        harvestManager.reportHarvest(1, 14_000e18, bytes32(0), 2000e18);

        // 31 days later, window closed
        vm.warp(block.timestamp + 31 days);
        vm.prank(alice);
        vm.expectRevert(HarvestManager.ClaimWindowClosed.selector);
        harvestManager.redeemUSDC(1, aliceYield);
    }

    // =========================================================================
    // ATTACK 9 — Producer deposits USDC past the 90-day window
    // =========================================================================
    function test_attack_lateUSDCDeposit() public {
        _activateCampaign();
        vm.prank(producer);
        campaign.startSeason(1);
        vm.prank(alice);
        stakingVault.stake(60_000e18);
        vm.warp(block.timestamp + 365 days);
        vm.prank(alice);
        stakingVault.claimYield(0);
        vm.prank(producer);
        campaign.endSeason();

        vm.prank(producer);
        harvestManager.reportHarvest(1, 14_000e18, bytes32(0), 2000e18);

        // Warp past claimEnd (30d) + usdcDeposit window (90d)
        vm.warp(block.timestamp + 121 days);

        usdc.mint(producer, 1000e6);
        vm.prank(producer);
        vm.expectRevert(HarvestManager.DepositWindowClosed.selector);
        harvestManager.depositUSDC(1, 1000e6);
    }

    // =========================================================================
    // ATTACK 10 — Buyback claim for a token attacker never paid with
    // =========================================================================
    function test_attack_buybackWrongToken() public {
        uint256 alicePay = 30_000 * USDC_FIXED_RATE;
        vm.prank(alice);
        campaign.buy(address(usdc), alicePay);
        vm.warp(block.timestamp + 91 days);
        campaign.triggerBuyback();

        // Attacker never bought anything → NothingToRefund
        vm.prank(attacker);
        vm.expectRevert(Campaign.NothingToRefund.selector);
        campaign.buyback(address(usdc));
    }

    // =========================================================================
    // ATTACK 11 — Trigger buyback when min cap was reached (spurious exit)
    // =========================================================================
    function test_attack_triggerBuybackAfterActivation() public {
        _activateCampaign(); // 60k > 50k minCap
        vm.warp(block.timestamp + 91 days);

        // State is now Active, not Funding → InvalidState
        vm.prank(attacker);
        vm.expectRevert();
        campaign.triggerBuyback();
    }

    // =========================================================================
    // ATTACK 12 — Oracle manipulation: negative price
    // =========================================================================
    function test_attack_oracleNegativePrice() public {
        wethOracle.setPrice(-1); // malicious oracle reports negative
        vm.prank(attacker);
        vm.expectRevert(Campaign.NegativeOraclePrice.selector);
        campaign.buy(address(weth), 1e18);
    }

    // =========================================================================
    // ATTACK 13 — Oracle manipulation: stale price
    // =========================================================================
    function test_attack_oracleStalePrice() public {
        // Advance time 2h without updating oracle
        vm.warp(block.timestamp + 2 hours);
        vm.prank(attacker);
        vm.expectRevert(Campaign.StaleOraclePrice.selector);
        campaign.buy(address(weth), 1e18);
    }

    // =========================================================================
    // ATTACK 14 — Direct stake/unstake on someone else's position
    // =========================================================================
    function test_attack_unstakeOthersPosition() public {
        _activateCampaign();
        vm.prank(producer);
        campaign.startSeason(1);
        vm.prank(alice);
        uint256 pos = stakingVault.stake(60_000e18);

        // Attacker tries to unstake alice's position
        vm.prank(attacker);
        vm.expectRevert(StakingVault.NotPositionOwner.selector);
        stakingVault.unstake(pos);

        // Same for claim
        vm.prank(attacker);
        vm.expectRevert(StakingVault.NotPositionOwner.selector);
        stakingVault.claimYield(pos);

        // Same for restake
        vm.prank(attacker);
        vm.expectRevert(StakingVault.NotPositionOwner.selector);
        stakingVault.restake(pos);
    }

    // =========================================================================
    // ATTACK 15 — Season replay: reuse a seasonId that was already used
    // =========================================================================
    function test_attack_reusedSeasonId() public {
        _activateCampaign();
        vm.prank(producer);
        campaign.startSeason(1);
        vm.prank(producer);
        campaign.endSeason();

        // Try to re-start the same seasonId → SeasonAlreadyUsed
        vm.prank(producer);
        vm.expectRevert(StakingVault.SeasonAlreadyUsed.selector);
        campaign.startSeason(1);
    }

    // =========================================================================
    // ATTACK 16 — Harvest report replay for same seasonId
    // =========================================================================
    function test_attack_duplicateHarvestReport() public {
        _activateCampaign();
        vm.prank(producer);
        campaign.startSeason(1);
        vm.warp(block.timestamp + 365 days);
        vm.prank(producer);
        campaign.endSeason();

        vm.prank(producer);
        harvestManager.reportHarvest(1, 10_000e18, bytes32(0), 2000e18);

        // Producer tries to overwrite with higher value
        vm.prank(producer);
        vm.expectRevert(HarvestManager.AlreadyReported.selector);
        harvestManager.reportHarvest(1, 999_999e18, bytes32(0), 2000e18);
    }

    // =========================================================================
    // ATTACK 17 — Stake without active season
    // =========================================================================
    function test_attack_stakeNoActiveSeason() public {
        _activateCampaign();
        // No season started yet
        vm.prank(alice);
        vm.expectRevert(StakingVault.NoActiveSeason.selector);
        stakingVault.stake(10_000e18);
    }

    // =========================================================================
    // ATTACK 18 — Unauthorized pause (only factory)
    // =========================================================================
    function test_attack_pauseAsAttacker() public {
        vm.prank(attacker);
        vm.expectRevert(Campaign.OnlyFactory.selector);
        campaign.emergencyPause();

        vm.prank(attacker);
        vm.expectRevert(StakingVault.OnlyFactory.selector);
        stakingVault.emergencyPause();
    }

    // =========================================================================
    // ATTACK 19 — Pause-then-buy (buyer blocked while campaign frozen)
    // =========================================================================
    function test_attack_buyWhilePaused() public {
        vm.prank(protocolOwner);
        factory.pauseCampaign(0);

        vm.prank(attacker);
        vm.expectRevert(); // Pausable: paused
        campaign.buy(address(usdc), 1000e6);
    }

    // =========================================================================
    // ATTACK 20 — Sell-back with more tokens than owned (ERC20 underflow)
    // =========================================================================
    function test_attack_sellBackOverBalance() public {
        _activateCampaign();
        // alice has 60k. Attacker has 0 campaignTokens.
        vm.prank(attacker);
        vm.expectRevert(); // ERC20 insufficient balance
        campaign.sellBack(1e18);
    }

    // =========================================================================
    // ATTACK 21 — Cancel sell-back when nothing pending
    // =========================================================================
    function test_attack_cancelSellBackNoPending() public {
        _activateCampaign();
        vm.prank(attacker);
        vm.expectRevert(Campaign.NoSellBackPending.selector);
        campaign.cancelSellBack();
    }

    // =========================================================================
    // ATTACK 22 — Producer activates campaign below min cap
    // =========================================================================
    function test_attack_producerActivateBelowMinCap() public {
        uint256 pay = 10_000 * USDC_FIXED_RATE;
        vm.prank(alice);
        campaign.buy(address(usdc), pay);
        assertEq(uint8(campaign.state()), uint8(Campaign.State.Funding));

        vm.prank(producer);
        vm.expectRevert(Campaign.MinCapNotReached.selector);
        campaign.activateCampaign();
    }

    // =========================================================================
    // ATTACK 23 — Claim USDC before producer deposits anything
    // =========================================================================
    function test_attack_claimUsdcWithoutDeposit() public {
        _activateCampaign();
        vm.prank(producer);
        campaign.startSeason(1);
        vm.prank(alice);
        stakingVault.stake(60_000e18);
        vm.warp(block.timestamp + 365 days);
        vm.prank(alice);
        stakingVault.claimYield(0);
        vm.prank(producer);
        campaign.endSeason();

        vm.prank(producer);
        harvestManager.reportHarvest(1, 14_000e18, bytes32(0), 2000e18);

        uint256 aliceYield = yieldToken.balanceOf(alice);
        vm.prank(alice);
        harvestManager.redeemUSDC(1, aliceYield);

        // Producer hasn't deposited yet
        vm.prank(alice);
        vm.expectRevert(HarvestManager.USDCNotDeposited.selector);
        harvestManager.claimUSDC(1);
    }

    // =========================================================================
    // ATTACK 24 — Buy zero amount
    // =========================================================================
    function test_attack_zeroBuy() public {
        vm.prank(attacker);
        vm.expectRevert(Campaign.ZeroAmount.selector);
        campaign.buy(address(usdc), 0);
    }

    // =========================================================================
    // ATTACK 25 — Add unaccepted payment token (attacker-controlled)
    // =========================================================================
    function test_attack_addMaliciousPaymentToken() public {
        MockERC20 attackerToken = new MockERC20("Fake", "FAKE", 18);
        vm.prank(attacker);
        vm.expectRevert(Campaign.OnlyProducer.selector);
        campaign.addAcceptedToken(address(attackerToken), Campaign.PricingMode.Fixed, 1, address(0));
    }

    // =========================================================================
    // ATTACK 26 — Buy with a token that's not on the whitelist
    // =========================================================================
    function test_attack_buyWithRogueToken() public {
        MockERC20 rogue = new MockERC20("Rogue", "RG", 18);
        rogue.mint(attacker, 1000e18);
        vm.prank(attacker);
        rogue.approve(address(campaign), type(uint256).max);

        vm.prank(attacker);
        vm.expectRevert(Campaign.TokenNotAccepted.selector);
        campaign.buy(address(rogue), 100e18);
    }

    // =========================================================================
    // ATTACK 27 — Max cap bypass: try to mint past maxCap
    // =========================================================================
    function test_attack_exceedMaxCap() public {
        // Buy up to maxCap
        uint256 fullPay = 100_000 * USDC_FIXED_RATE;
        usdc.mint(alice, fullPay);
        vm.prank(alice);
        usdc.approve(address(campaign), type(uint256).max);
        vm.prank(alice);
        campaign.buy(address(usdc), fullPay);
        assertEq(campaign.currentSupply(), MAX_CAP);

        // Attacker tries to buy more
        vm.prank(attacker);
        vm.expectRevert(Campaign.MaxCapReached.selector);
        campaign.buy(address(usdc), USDC_FIXED_RATE);
    }

    // =========================================================================
    // ATTACK 28 — Restake twice in same season (must revert)
    // =========================================================================
    function test_attack_restakeSameSeason() public {
        _activateCampaign();
        vm.prank(producer);
        campaign.startSeason(1);
        vm.prank(alice);
        uint256 pos = stakingVault.stake(10_000e18);

        vm.prank(alice);
        vm.expectRevert(StakingVault.RestakeSameSeason.selector);
        stakingVault.restake(pos);
    }

    // =========================================================================
    // ATTACK 29 — Attempt startSeason while another is active
    // =========================================================================
    function test_attack_doubleStartSeason() public {
        _activateCampaign();
        vm.prank(producer);
        campaign.startSeason(1);

        vm.prank(producer);
        vm.expectRevert(StakingVault.SeasonAlreadyActive.selector);
        campaign.startSeason(2);
    }

    // =========================================================================
    // ATTACK 30 — Zero yield mint/burn on direct call
    // =========================================================================
    function test_attack_burnYieldAsRandomUser() public {
        // Even if yield exists on an account, random user can't burn
        _activateCampaign();
        vm.prank(producer);
        campaign.startSeason(1);
        vm.prank(alice);
        stakingVault.stake(60_000e18);
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        stakingVault.claimYield(0);

        assertGt(yieldToken.balanceOf(alice), 0);

        vm.prank(attacker);
        vm.expectRevert(YieldToken.OnlyVaultOrHarvest.selector);
        yieldToken.burn(alice, 1);
    }

    // =========================================================================
    // ATTACK 31 — Producer drains escrow via wrong state (cannot in Funding)
    // =========================================================================
    function test_attack_producerDrainsFundingEscrow() public {
        // Alice buys in funding (funds stay in Campaign contract until activation,
        // minus the 3% funding fee skimmed at buy time → the rest escrows).
        uint256 pay = 20_000 * USDC_FIXED_RATE;
        vm.prank(alice);
        campaign.buy(address(usdc), pay);

        uint256 fee = pay * 300 / 10_000;
        uint256 escrowed = usdc.balanceOf(address(campaign));
        assertEq(escrowed, pay - fee, "escrow holds gross minus funding fee");

        // Producer cannot pull the USDC — no admin function on Campaign for that
        // Only path to release is _activate() or buyback(). Attacker calls whatever is callable.
        vm.prank(producer);
        vm.expectRevert(Campaign.MinCapNotReached.selector);
        campaign.activateCampaign();

        // Funds remain escrowed
        assertEq(usdc.balanceOf(address(campaign)), escrowed);
    }

    // =========================================================================
    // ATTACK 32 — Attacker tries to end season as non-producer
    // =========================================================================
    function test_attack_endSeasonAsAttacker() public {
        _activateCampaign();
        vm.prank(producer);
        campaign.startSeason(1);
        vm.prank(attacker);
        vm.expectRevert(Campaign.OnlyProducer.selector);
        campaign.endSeason();
    }

    // =========================================================================
    // ATTACK 33 — No-fund buyback: try buyback without going through triggerBuyback
    // =========================================================================
    function test_attack_buybackWithoutTrigger() public {
        uint256 pay = 30_000 * USDC_FIXED_RATE;
        vm.prank(alice);
        campaign.buy(address(usdc), pay);

        // State still Funding, not Buyback
        vm.prank(alice);
        vm.expectRevert();
        campaign.buyback(address(usdc));
    }

    // =========================================================================
    // ATTACK 34 — Trigger buyback before deadline
    // =========================================================================
    function test_attack_earlyTriggerBuyback() public {
        uint256 pay = 30_000 * USDC_FIXED_RATE;
        vm.prank(alice);
        campaign.buy(address(usdc), pay);

        vm.prank(attacker);
        vm.expectRevert(Campaign.FundingNotExpired.selector);
        campaign.triggerBuyback();
    }

    // =========================================================================
    // ATTACK 35 — Oracle tiny decimals: ensure normalization works
    // =========================================================================
    function test_attack_oracleOver18Decimals() public {
        MockOracle badOracle = new MockOracle(100e19, 19); // 19 decimals
        MockERC20 strangeToken = new MockERC20("ST", "ST", 18);
        strangeToken.mint(attacker, 10e18);

        vm.prank(producer);
        campaign.addAcceptedToken(address(strangeToken), Campaign.PricingMode.Oracle, 0, address(badOracle));

        vm.prank(attacker);
        strangeToken.approve(address(campaign), type(uint256).max);

        vm.prank(attacker);
        vm.expectRevert("Oracle decimals > 18");
        campaign.buy(address(strangeToken), 1e18);
    }

    // =========================================================================
    // ATTACK 36 — Griefing: 50 positions opened, then blocked on 51st
    // =========================================================================
    function test_attack_maxPositionsGriefing() public {
        _activateCampaign();
        vm.prank(producer);
        campaign.startSeason(1);

        // Alice stakes 50 small positions
        vm.startPrank(alice);
        for (uint256 i = 0; i < 50; i++) {
            stakingVault.stake(1e18);
        }

        vm.expectRevert(StakingVault.TooManyPositions.selector);
        stakingVault.stake(1e18);
        vm.stopPrank();

        // But compactPositions is a self-help lever after unstaking
    }

    // =========================================================================
    // ATTACK 37 — redeemProduct below min product claim
    // =========================================================================
    function test_attack_dustRedemption() public {
        _activateCampaign();
        vm.prank(producer);
        campaign.startSeason(1);
        vm.prank(alice);
        stakingVault.stake(60_000e18);
        vm.warp(block.timestamp + 365 days);
        vm.prank(alice);
        stakingVault.claimYield(0);
        vm.prank(producer);
        campaign.endSeason();

        uint256 aliceYield = yieldToken.balanceOf(alice);
        uint256 totalProduct = 2000e18;
        uint256 totalYield = yieldToken.totalSupply();

        // Dust burn — productAmount < 5e18 min
        uint256 dustYield = totalYield * 4e18 / totalProduct; // ~4 liters worth
        bytes32 leaf = keccak256(abi.encodePacked(alice, uint256(1), dustYield * totalProduct / totalYield));

        vm.prank(producer);
        harvestManager.reportHarvest(1, 14_000e18, leaf, totalProduct);

        bytes32[] memory emptyProof = new bytes32[](0);
        vm.prank(alice);
        vm.expectRevert(HarvestManager.BelowMinProductClaim.selector);
        harvestManager.redeemProduct(1, dustYield, emptyProof);

        // Unused vars
        aliceYield;
    }
}
