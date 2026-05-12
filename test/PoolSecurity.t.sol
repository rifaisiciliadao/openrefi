// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
import {ReentrantToken} from "./helpers/ReentrantToken.sol";
import {FeeOnTransferToken} from "./helpers/FeeOnTransferToken.sol";
import {Deployer} from "./helpers/Deployer.sol";

/// @title PoolSecurity — reentrancy + pool-accounting adversarial tests
contract PoolSecurityTest is Test {
    GrowfiCampaignFactory factory;
    MockERC20 usdc;
    IGrowfiCampaignFull campaign;
    GrowfiCampaignToken campaignToken;
    GrowfiYieldToken yieldToken;
    GrowfiStakingVault stakingVault;
    GrowfiHarvestManager harvestManager;

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
                    expectedAnnualHarvestUsd: 5_000e18,
                    expectedAnnualHarvest: 1_000e18,
                    firstHarvestYear: 2030,
                    coverageHarvests: 0
                })
            })
        );

        (address c, address ct, address yt, address sv, address hm,,) = factory.campaigns(0);
        campaign = IGrowfiCampaignFull(payable(c));
        campaignToken = GrowfiCampaignToken(ct);
        yieldToken = GrowfiYieldToken(yt);
        stakingVault = GrowfiStakingVault(sv);
        harvestManager = GrowfiHarvestManager(hm);

        vm.prank(producer);
        campaign.addAcceptedToken(address(usdc), SaleClassicModule.PricingMode.Fixed, USDC_FIXED_RATE, address(0));

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
        campaignToken.approve(address(stakingVault), type(uint256).max);
        campaignToken.approve(address(campaign), type(uint256).max);
        vm.stopPrank();
    }

    function _whitelistReentrantToken(ReentrantToken tok, uint256 fixedRate) internal {
        vm.prank(producer);
        campaign.addAcceptedToken(address(tok), SaleClassicModule.PricingMode.Fixed, fixedRate, address(0));
    }

    function _whitelistFotToken(FeeOnTransferToken tok, uint256 fixedRate) internal {
        vm.prank(producer);
        campaign.addAcceptedToken(address(tok), SaleClassicModule.PricingMode.Fixed, fixedRate, address(0));
    }

    function _activateViaAlice() internal {
        uint256 pay = 60_000 * USDC_FIXED_RATE;
        vm.prank(alice);
        campaign.buy(address(usdc), pay);
        assertEq(uint8(campaign.state()), uint8(CampaignStorage.State.Active), "setup: not active");
    }

    // =========================================================================
    // 1. DIRECT REENTRANCY
    // =========================================================================

    function test_reentrancy_buy_blocksSelfReentry() public {
        ReentrantToken rog = new ReentrantToken("Rogue", "ROG", 18);
        _whitelistReentrantToken(rog, 1e18);
        rog.mint(attacker, 1000e18);
        vm.prank(attacker);
        rog.approve(address(campaign), type(uint256).max);

        bytes memory payload = abi.encodeCall(SaleClassicModule.buy, (address(rog), 1e18));
        rog.arm(address(campaign), payload);

        vm.prank(attacker);
        vm.expectRevert();
        campaign.buy(address(rog), 10e18);
    }

    function test_reentrancy_buyback_blocksSelfReentry() public {
        ReentrantToken rog = new ReentrantToken("Rogue", "ROG", 18);
        _whitelistReentrantToken(rog, 1e18);
        rog.mint(attacker, 1000e18);
        vm.prank(attacker);
        rog.approve(address(campaign), type(uint256).max);

        vm.prank(attacker);
        campaign.buy(address(rog), 10e18);

        vm.warp(block.timestamp + 91 days);
        campaign.triggerBuyback();
        assertEq(uint8(campaign.state()), uint8(CampaignStorage.State.Buyback));

        bytes memory payload = abi.encodeCall(SaleClassicModule.buyback, (address(rog)));
        rog.arm(address(campaign), payload);

        vm.prank(attacker);
        vm.expectRevert();
        campaign.buyback(address(rog));
    }

    function test_reentrancy_buyFillQueue_blocksBuyRentry() public {
        _activateViaAlice();

        vm.prank(alice);
        campaign.sellBack(1000e18);

        ReentrantToken rog = new ReentrantToken("Rogue", "ROG", 18);
        _whitelistReentrantToken(rog, 1e18);
        rog.mint(attacker, 1000e18);
        vm.prank(attacker);
        rog.approve(address(campaign), type(uint256).max);

        bytes memory payload = abi.encodeCall(SaleClassicModule.buy, (address(rog), 1e18));
        rog.arm(address(campaign), payload);

        vm.prank(attacker);
        vm.expectRevert();
        campaign.buy(address(rog), 5e18);
    }

    function test_reentrancy_stake_campaignTokenHasNoHook() public {
        _activateViaAlice();
        vm.prank(producer);
        campaign.startSeason();

        uint256 supplyBefore = campaignToken.totalSupply();
        vm.prank(alice);
        campaign.buy(address(usdc), 1000 * USDC_FIXED_RATE);
        uint256 newSupply = campaignToken.totalSupply() - supplyBefore;

        vm.prank(alice);
        uint256 posId = stakingVault.stake(newSupply);
        (, uint256 amt,,,, bool active) = stakingVault.positions(posId);
        assertEq(amt, newSupply);
        assertTrue(active);
    }

    function test_reentrancy_depositUSDC_blocksSelfReentry() public {
        ReentrantToken rog = new ReentrantToken("Rogue USDC", "rUSDC", 6);
        GrowfiCampaignFactory rogueFactory =
            Deployer.deployProtocol(protocolOwner, feeRecipient, address(rog), address(0));

        vm.prank(producer);
        rogueFactory.createCampaign(
            GrowfiCampaignFactory.CreateCampaignParams({
                producer: producer,
                campaignTokenName: "Olive2",
                campaignTokenSymbol: "OLIVE2",
                yieldTokenName: "oY2",
                yieldTokenSymbol: "oY2",
                minProductClaim: 1e18,
                sale: SaleClassicModule.InitParams({
                    pricePerToken: PRICE_PER_TOKEN,
                    minCap: 100e18,
                    maxCap: 1000e18,
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
        (,,,, address hm2,,) = rogueFactory.campaigns(0);
        GrowfiHarvestManager hm = GrowfiHarvestManager(hm2);

        rog.mint(producer, 1_000e6);
        vm.prank(producer);
        rog.approve(address(campaign), type(uint256).max);

        bytes memory payload = abi.encodeCall(GrowfiHarvestManager.depositFromCollateral, (1, 1e6));
        rog.arm(address(hm), payload);

        vm.prank(producer);
        vm.expectRevert();
        campaign.depositUSDC(1, 1e6);
    }

    // =========================================================================
    // 2. CROSS-FUNCTION REENTRANCY
    // =========================================================================

    function test_reentrancy_buy_blocksSellBackRentry() public {
        _activateViaAlice();
        vm.prank(alice);
        campaign.sellBack(500e18);

        ReentrantToken rog = new ReentrantToken("Rogue", "ROG", 18);
        _whitelistReentrantToken(rog, 1e18);
        rog.mint(attacker, 1000e18);
        vm.prank(attacker);
        rog.approve(address(campaign), type(uint256).max);

        bytes memory payload = abi.encodeCall(SaleClassicModule.sellBack, (1));
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

        bytes memory payload = abi.encodeCall(SaleClassicModule.cancelSellBack, ());
        rog.arm(address(campaign), payload);

        vm.prank(attacker);
        vm.expectRevert();
        campaign.buy(address(rog), 10e18);
    }

    // =========================================================================
    // 3. CROSS-PROXY REENTRANCY
    // =========================================================================

    function test_crossProxy_buyReentersStakingVault_reentryHasRogueIdentity() public {
        _activateViaAlice();
        vm.prank(producer);
        campaign.startSeason();

        ReentrantToken rog = new ReentrantToken("Rogue", "ROG", 18);
        _whitelistReentrantToken(rog, 1e18);
        rog.mint(attacker, 100e18);
        vm.prank(attacker);
        rog.approve(address(campaign), type(uint256).max);

        bytes memory payload = abi.encodeCall(GrowfiStakingVault.stake, (1e18));
        rog.arm(address(stakingVault), payload, true);

        vm.prank(attacker);
        campaign.buy(address(rog), 10e18);

        assertFalse(rog.lastCallOk(), "reentry must fail on missing allowance");

        assertEq(stakingVault.getPositions(attacker).length, 0);
        assertEq(stakingVault.getPositions(address(rog)).length, 0);

        assertEq(campaignToken.balanceOf(attacker), 10e18);
        assertEq(stakingVault.totalStaked(), 0);
    }

    // =========================================================================
    // 4. FEE-ON-TRANSFER ACCOUNTING DOCUMENTATION
    // =========================================================================

    function test_feeOnTransfer_buybackShortfallForLastUser() public {
        FeeOnTransferToken fot = new FeeOnTransferToken("Fee Token", "FEE", 18, 100);
        _whitelistFotToken(fot, 1e18);
        fot.mint(alice, 1000e18);
        fot.mint(bob, 1000e18);
        vm.prank(alice);
        fot.approve(address(campaign), type(uint256).max);
        vm.prank(bob);
        fot.approve(address(campaign), type(uint256).max);

        vm.prank(alice);
        campaign.buy(address(fot), 100e18);
        vm.prank(bob);
        campaign.buy(address(fot), 100e18);

        assertEq(campaign.purchases(alice, address(fot)), 97e18);
        assertEq(campaign.purchases(bob, address(fot)), 97e18);
        assertEq(
            fot.balanceOf(address(campaign)),
            192e18,
            "shortfall: 2 on buy-in + 0.06 on fee transfer burned by FoT"
        );

        vm.warp(block.timestamp + 91 days);
        campaign.triggerBuyback();

        vm.prank(alice);
        campaign.buyback(address(fot));
        assertEq(fot.balanceOf(alice), 1000e18 - 100e18 + 97e18 * 99 / 100);

        vm.prank(bob);
        vm.expectRevert();
        campaign.buyback(address(fot));
    }

    function test_feeOnTransfer_activationUsesRealBalance() public {
        FeeOnTransferToken fot = new FeeOnTransferToken("Fee Token", "FEE", 18, 100);
        _whitelistFotToken(fot, 1e18);
        fot.mint(alice, 100_000e18);
        vm.prank(alice);
        fot.approve(address(campaign), type(uint256).max);

        uint256 declared = 60_000e18;
        vm.prank(alice);
        campaign.buy(address(fot), declared);

        assertEq(uint8(campaign.state()), uint8(CampaignStorage.State.Active));

        uint256 producerReceived = fot.balanceOf(producer);
        uint256 feeReceived = fot.balanceOf(feeRecipient);
        assertLt(producerReceived, declared, "producer cannot exceed declared");
        assertGt(feeReceived, 0, "feeRecipient got the funding fee");
    }
}
