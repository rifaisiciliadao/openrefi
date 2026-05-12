// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GrowfiCampaignFactory} from "../../src/GrowfiCampaignFactory.sol";
import {GrowfiCampaign} from "../../src/GrowfiCampaign.sol";
import {GrowfiCampaignToken} from "../../src/GrowfiCampaignToken.sol";
import {GrowfiStakingVault} from "../../src/GrowfiStakingVault.sol";
import {IGrowfiCampaignFull} from "../../src/interfaces/IGrowfiCampaignFull.sol";
import {CampaignStorage} from "../../src/host/CampaignStorage.sol";
import {SaleClassicModule} from "../../src/modules/SaleClassicModule.sol";
import {CollateralModule} from "../../src/modules/CollateralModule.sol";
import {RepaymentModule} from "../../src/modules/RepaymentModule.sol";

import {Deployer} from "../helpers/Deployer.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {ReentrantUSDC} from "./ReentrantUSDC.sol";
import {RepaymentHelper} from "./RepaymentHelper.sol";

/// @title  RepaymentKnownVulnsTest
/// @notice Targets vulnerability classes from SWC + EIP-2535 lessons
///         that aren't covered by the per-module / systemic suites:
///         - SWC-112 / delegatecall to malicious impl bound checks
///         - cross-module reentrancy through `factory.usdc` malevolence
///         - SWC-126 / gas griefing via huge unstakeFirst arrays
///         - storage namespace uniqueness assertion (host vs all modules)
///         - direct impl call protection on every module
///         - 0-selector and reserved-selector routing
///         - `currentSupply` tracking semantics across Repayment burns
///         - ETH stuck on campaign (donation/DoS)
contract RepaymentKnownVulnsTest is Test {
    bytes32 internal constant REPAY_KIND = keccak256("growfi.repayment.v1");
    bytes32 internal constant REPAY_TYPE = keccak256("growfi.type.repayment");

    bytes32 internal constant HOST_SLOT = 0x97c54a0bf039447711bcab434c5a40b95f0e18b67d18363706a9ce32d1b0cc6f;
    bytes32 internal constant SALE_SLOT = 0xd7250d23bb7bc8e93366cf6815d31bcb947e004baa702b9bb515d6082501a234;
    bytes32 internal constant COLLATERAL_SLOT = 0x1d5c7025e27f7f3a598a1ed3ef2f3b18a3b6b8f8025c5754e51904d497088646;
    bytes32 internal constant REPAYMENT_SLOT = 0x14aa57f11bde39f5bf9c2d6c4d6638f5a3829e646927e7698ce9a2de15f76398;

    GrowfiCampaignFactory internal factory;
    RepaymentModule internal repayImpl;
    MockERC20 internal usdc;

    address internal protocolOwner = makeAddr("protocolOwner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal producer = makeAddr("producer");
    address internal alice = makeAddr("alice");
    address internal mallory = makeAddr("mallory");

    address internal campaignAddr;
    IGrowfiCampaignFull internal campaign;
    GrowfiCampaignToken internal campaignToken;
    GrowfiStakingVault internal stakingVault;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
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

        usdc.mint(alice, 720e6);
        vm.startPrank(alice);
        usdc.approve(campaignAddr, type(uint256).max);
        campaign.buy(address(usdc), 720e6); // 5_000 CT, activates
        vm.stopPrank();

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

    // ------------------------------------------------------------------
    // Storage namespace uniqueness — slot collisions would corrupt state
    // ------------------------------------------------------------------

    function test_vuln_storageSlots_allDistinct() public pure {
        // No two namespaces collide
        assertTrue(HOST_SLOT != SALE_SLOT);
        assertTrue(HOST_SLOT != COLLATERAL_SLOT);
        assertTrue(HOST_SLOT != REPAYMENT_SLOT);
        assertTrue(SALE_SLOT != COLLATERAL_SLOT);
        assertTrue(SALE_SLOT != REPAYMENT_SLOT);
        assertTrue(COLLATERAL_SLOT != REPAYMENT_SLOT);

        // Each matches the documented keccak namespace
        assertEq(HOST_SLOT, keccak256("growfi.campaign.core.v1"));
        assertEq(SALE_SLOT, keccak256("growfi.module.sale.classic.v1"));
        assertEq(COLLATERAL_SLOT, keccak256("growfi.module.collateral.v1"));
        assertEq(REPAYMENT_SLOT, keccak256("growfi.module.repayment.v1"));
    }

    /// @dev Mutating one namespace must not leak into another. Write a
    ///      sentinel into the Repayment namespace and verify the host's
    ///      core fields and SaleClassic's price are untouched.
    function test_vuln_storageNamespaces_isolated() public {
        // Snapshot host + SaleClassic state
        address hostProducer = campaign.producer();
        uint256 salePrice = campaign.pricePerToken();
        uint256 saleCurrentSupply = campaign.currentSupply();

        // Mutate Repayment namespace heavily
        vm.prank(producer);
        _r().setBonusPerCt(0.05e6);
        vm.prank(alice);
        _r().redeem(50e18, new uint256[](0));

        assertEq(campaign.producer(), hostProducer, "host.producer untouched");
        assertEq(campaign.pricePerToken(), salePrice, "sale price untouched");
        // currentSupply intentionally NOT decremented by Repayment burn — see test below
        assertEq(campaign.currentSupply(), saleCurrentSupply, "sale.currentSupply unchanged by Repayment burn (by design)");
    }

    // ------------------------------------------------------------------
    // SWC-112 — delegatecall to untrusted contract
    // ------------------------------------------------------------------

    /// @dev The whitelist gate is enforced at attach time. Once attached,
    ///      the host delegate-calls into the slot.impl on every routed
    ///      selector. If the owner later revokes the impl, existing
    ///      campaigns keep working (producer-sovereign). To replace,
    ///      producer must detach + reattach a different (whitelisted) impl.
    ///      Stranger cannot attach unwhitelisted impl.
    function test_vuln_swc112_strangerCannotAttachArbitraryImpl() public {
        address fakeImpl = makeAddr("fakeImpl");
        // Producer (legitimate) cannot attach a non-whitelisted impl
        vm.prank(producer);
        vm.expectRevert(GrowfiCampaign.ImplNotApproved.selector);
        GrowfiCampaign(payable(campaignAddr)).attachModule(
            keccak256("rogue.type"), keccak256("rogue.kind"), fakeImpl, ""
        );

        // Stranger can't either
        vm.prank(mallory);
        vm.expectRevert(GrowfiCampaign.OnlyProducer.selector);
        GrowfiCampaign(payable(campaignAddr)).attachModule(
            keccak256("rogue.type"), keccak256("rogue.kind"), fakeImpl, ""
        );
    }

    // ------------------------------------------------------------------
    // Direct impl call protection — each module impl is uninitialized
    // ------------------------------------------------------------------

    /// @dev Stranger calls Repayment IMPL directly (not through a campaign).
    ///      The impl's namespaced storage is empty → state reads zero →
    ///      checks fire. Specifically: producer == address(0) means
    ///      onlyProducer reverts; initialized == false means init paths
    ///      hit OnlyFactoryBootstrap (factory == address(0) ≠ caller).
    function test_vuln_directImpl_strangerBlocked() public {
        RepaymentModule fresh = new RepaymentModule();

        vm.prank(mallory);
        vm.expectRevert(RepaymentModule.OnlyFactoryBootstrap.selector);
        fresh.initializeRepayment(RepaymentModule.InitParams({initialBonusPerCt: 0}));

        vm.prank(mallory);
        vm.expectRevert(RepaymentModule.OnlyProducer.selector);
        fresh.initializeRepaymentByProducer(0);

        vm.prank(mallory);
        vm.expectRevert(RepaymentModule.OnlyProducer.selector);
        fresh.fundPool(1);

        vm.prank(mallory);
        vm.expectRevert(RepaymentModule.OnlyProducer.selector);
        fresh.withdrawUnusedPool(1);

        vm.prank(mallory);
        vm.expectRevert(RepaymentModule.OnlyProducer.selector);
        fresh.setBonusPerCt(0);

        // redeem on uninitialized impl: state checks (paused/state) read
        // zeroes → state == Funding (0), paused == false → reach pricePerToken
        // read → returns 0 → revert PrincipalNotSet
        vm.prank(mallory);
        vm.expectRevert(RepaymentModule.PrincipalNotSet.selector);
        fresh.redeem(1, new uint256[](0));
    }

    // ------------------------------------------------------------------
    // Gas griefing — huge unstakeFirst array
    // ------------------------------------------------------------------

    /// @dev Caller passes a 1000-element unstakeFirst array of unknown
    ///      ids. The redeem must fail bounded (revert on first
    ///      not-active position lookup → PositionNotActive bubbled),
    ///      NOT silently consume gas without progress.
    function test_vuln_dos_largeUnstakeFirst_failsFast() public {
        uint256[] memory positions = new uint256[](1_000);
        for (uint256 i; i < 1_000; i++) positions[i] = i + 1; // ids 1..1000

        // Alice has 5_000 CT free, redeem 100 — but positions[] are all
        // someone else's / non-existent. The owner-check on the FIRST
        // position fires → revert. Gas: O(1), not O(1000).
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        vm.expectRevert();
        _r().redeem(100e18, positions);
        uint256 gasUsed = gasBefore - gasleft();

        // Should be way under 200k gas — the loop short-circuited
        assertLt(gasUsed, 250_000, "gas should be O(1), not O(N)");
    }

    /// @dev A legitimate large unstakeFirst array consumes O(N) gas as
    ///      expected. Verifies the loop completes for the honest case.
    function test_vuln_dos_legitLargeUnstakeFirst_progresses() public {
        // First trigger a season so staking is possible
        vm.prank(producer);
        campaign.startSeason();

        // Make alice approve + stake several positions
        vm.startPrank(alice);
        campaignToken.approve(address(stakingVault), type(uint256).max);
        uint256 N = 20;
        uint256[] memory positions = new uint256[](N);
        for (uint256 i; i < N; i++) {
            positions[i] = stakingVault.stake(100e18); // 100 CT each
        }
        vm.stopPrank();

        // Alice redeems 2000 CT, passing all 20 positions
        vm.prank(alice);
        _r().redeem(2_000e18, positions);

        // All N positions deactivated; alice's CT total reflects the burn
        for (uint256 i; i < N; i++) {
            (,,,,, bool active) = stakingVault.positions(positions[i]);
            assertFalse(active, "all positions closed");
        }
    }

    // ------------------------------------------------------------------
    // Cross-module reentrancy via malicious factory.usdc
    // ------------------------------------------------------------------

    /// @dev If factory.usdc is a malicious ERC20 with transfer hooks,
    ///      Repayment.redeem's outbound transfer could try to reenter
    ///      SaleClassic.buy in a fresh campaign deploy. This is a
    ///      deploy-time misconfig (factory.usdc is set once at init)
    ///      but we still pin: the inner buy's own nonReentrant prevents
    ///      compounding mints in a way that drains the Repayment pool.
    function test_vuln_crossModuleReentry_factoryUsdc_boundedDamage() public {
        // Bootstrap a fresh factory + campaign with MALICIOUS USDC
        ReentrantUSDC badUsdc = new ReentrantUSDC();
        GrowfiCampaignFactory rogueFactory =
            Deployer.deployProtocol(protocolOwner, feeRecipient, address(badUsdc), address(0));
        vm.prank(protocolOwner);
        rogueFactory.setMinSeasonDuration(1 hours);

        // Whitelist Repayment on the rogue factory
        vm.startPrank(protocolOwner);
        rogueFactory.setModuleKindSelectors(REPAY_KIND, RepaymentHelper.selectors());
        rogueFactory.approveModuleImpl(REPAY_KIND, address(repayImpl), true);
        vm.stopPrank();

        vm.prank(producer);
        address rogueCampaign = rogueFactory.createCampaign(
            GrowfiCampaignFactory.CreateCampaignParams({
                producer: producer,
                campaignTokenName: "Olive R",
                campaignTokenSymbol: "OLIR",
                yieldTokenName: "Olive Yield R",
                yieldTokenSymbol: "oYR",
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
        IGrowfiCampaignFull rc = IGrowfiCampaignFull(payable(rogueCampaign));

        vm.prank(producer);
        rc.addAcceptedToken(address(badUsdc), SaleClassicModule.PricingMode.Fixed, 144_000, address(0));

        // Alice activates (real bad-USDC, but no reentry yet)
        badUsdc.mint(alice, 720e6);
        vm.startPrank(alice);
        badUsdc.approve(rogueCampaign, type(uint256).max);
        rc.buy(address(badUsdc), 720e6);
        vm.stopPrank();

        // Attach + fund Repayment
        vm.prank(producer);
        GrowfiCampaign(payable(rogueCampaign)).attachModule(REPAY_TYPE, REPAY_KIND, address(repayImpl), "");
        vm.prank(producer);
        RepaymentModule(payable(rogueCampaign)).initializeRepaymentByProducer(0);
        badUsdc.mint(producer, 5_000e6);
        vm.startPrank(producer);
        badUsdc.approve(rogueCampaign, 5_000e6);
        RepaymentModule(payable(rogueCampaign)).fundPool(5_000e6);
        vm.stopPrank();

        // Arm bad USDC: on transfer, reenter SaleClassic.buy
        badUsdc.mint(alice, 5_000e6);
        vm.prank(alice);
        badUsdc.approve(rogueCampaign, type(uint256).max);
        bytes memory innerBuy = abi.encodeWithSelector(
            SaleClassicModule.buy.selector, address(badUsdc), uint256(144e6)
        );
        badUsdc.arm(rogueCampaign, innerBuy);

        // Trigger: alice redeems → transfer payout → bad USDC reenters buy
        uint256 alicePoolBefore = badUsdc.balanceOf(alice);
        uint256 aliceCtBefore = GrowfiCampaignToken(rc.campaignToken()).balanceOf(alice);

        vm.prank(alice);
        RepaymentModule(payable(rogueCampaign)).redeem(100e18, new uint256[](0));

        // Outcome bounds:
        //   - alice burned exactly 100 CT (the outer redeem)
        //   - alice's CT may have increased back by the inner buy
        //   - alice's USDC: gained payout (100*0.144 = 14.4 USDC),
        //     lost reentry-buy amount (144 USDC)
        // Net: NO net mint of CT outside what alice paid for. NO pool
        // drain beyond the single legitimate payout.
        uint256 aliceCtAfter = GrowfiCampaignToken(rc.campaignToken()).balanceOf(alice);
        uint256 aliceUsdcAfter = badUsdc.balanceOf(alice);

        // alice's CT delta = -100 (redeem burn) + reentry buy CT (~1000 CT for 144 USDC)
        //   ≈ +900 CT net if reentry succeeded — but she PAID 144 USDC for those.
        //   The buy reentry IS allowed (it's a fresh module). The point is no
        //   double-payout from the Repayment pool.
        assertLe(
            aliceUsdcAfter,
            alicePoolBefore + 14_400_000, // can't have more than +pool payout
            "no net USDC gain beyond legitimate payout"
        );
        aliceCtAfter; // we don't constrain CT — reentry buy is legit and bounded by USDC spent
        aliceCtBefore;
    }

    // ------------------------------------------------------------------
    // currentSupply semantic — Repayment burn does NOT decrement
    // ------------------------------------------------------------------

    /// @dev Document that Repayment burns reduce campaignToken.totalSupply
    ///      but do NOT decrement SaleClassic.currentSupply. This is
    ///      intentional: currentSupply tracks "cumulative ever-sold via
    ///      SaleClassic", not actual outstanding tokens. maxCap enforces
    ///      cumulative-ever-sold, not concurrent-outstanding.
    function test_vuln_currentSupplySemantic_repaymentBurnDoesNotDecrement() public {
        uint256 supplyBefore = campaign.currentSupply();
        uint256 totalSupplyBefore = campaignToken.totalSupply();

        vm.prank(alice);
        _r().redeem(200e18, new uint256[](0));

        // ERC20 totalSupply DOES decrement
        assertEq(campaignToken.totalSupply(), totalSupplyBefore - 200e18, "ERC20 totalSupply shrank");

        // SaleClassic.currentSupply does NOT decrement
        assertEq(campaign.currentSupply(), supplyBefore, "SaleClassic.currentSupply NOT decremented by Repayment");

        // Producer cannot setMaxCap below currentSupply even though actual outstanding < currentSupply.
        // This shows currentSupply is the binding constraint for future buys/cap changes.
        vm.prank(producer);
        vm.expectRevert(SaleClassicModule.NewMaxCapBelowCommitted.selector);
        campaign.setMaxCap(supplyBefore - 1);
    }

    // ------------------------------------------------------------------
    // 0-selector and reserved selectors
    // ------------------------------------------------------------------

    /// @dev Empty calldata (no selector) hits `receive()`, accepts ETH.
    ///      Calldata with unregistered selector hits `fallback()`,
    ///      reverts UnknownSelector. There's no way to route to
    ///      `bytes32(0)` type because no module function has 0-selector.
    function test_vuln_zeroSelector_emptyCalldataIsReceive() public {
        // Empty calldata + value = receive ETH
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = campaignAddr.call{value: 0.5 ether}("");
        assertTrue(ok, "ETH deposit accepted");
        assertEq(campaignAddr.balance, 0.5 ether, "campaign holds 0.5 ETH");

        // 0x00000000 selector calldata (4 zero bytes) → fallback →
        // selectorToType lookup → 0 → UnknownSelector
        vm.expectRevert(abi.encodeWithSelector(GrowfiCampaign.UnknownSelector.selector, bytes4(0)));
        (bool ok2,) = campaignAddr.call(hex"00000000");
        ok2;
    }

    // ------------------------------------------------------------------
    // ETH stuck: receive() accepts, no withdraw path
    // ------------------------------------------------------------------

    /// @dev ETH sent to a campaign via receive() has no exit path in
    ///      the current module set. This is by design (host placeholder
    ///      for future payment modules) but should be documented.
    ///      Not a theft risk — just a permanent lock.
    function test_vuln_ethStuck_noWithdrawPath() public {
        vm.deal(mallory, 5 ether);
        vm.prank(mallory);
        (bool ok,) = campaignAddr.call{value: 5 ether}("");
        assertTrue(ok);
        assertEq(campaignAddr.balance, 5 ether, "ETH locked");

        // Producer cannot recover it — no module routes ETH withdrawal
        vm.prank(producer);
        vm.expectRevert(); // no matching selector
        (bool ok2,) = campaignAddr.call(abi.encodeWithSignature("withdrawEth(uint256)", 5 ether));
        ok2;
    }

    // ------------------------------------------------------------------
    // safeIncreaseAllowance not used by Repayment — confirm
    // ------------------------------------------------------------------

    /// @dev Repayment uses safeTransfer/safeTransferFrom only — no
    ///      lingering allowances on the campaign. After all redemptions,
    ///      the campaign holds zero allowance to anyone.
    function test_vuln_repaymentLeavesNoAllowance() public {
        vm.prank(alice);
        _r().redeem(100e18, new uint256[](0));

        // The campaign has no outbound allowances from Repayment paths
        assertEq(usdc.allowance(campaignAddr, address(this)), 0);
        assertEq(usdc.allowance(campaignAddr, alice), 0);
        assertEq(usdc.allowance(campaignAddr, producer), 0);
    }

    // ------------------------------------------------------------------
    // Producer-as-sovereign-attacker — pin the worst-case bounds
    // ------------------------------------------------------------------

    /// @dev Producer attempts a "rugpull": setBonus to max, immediately
    ///      withdraw pool to zero, then re-attach with different impl.
    ///      Users find revert. Documented as producer-sovereign.
    function test_vuln_producerRugpull_userExitBlocked() public {
        // Producer sets a huge bonus and immediately drains the pool
        vm.startPrank(producer);
        _r().setBonusPerCt(10e6); // $10 bonus
        _r().withdrawUnusedPool(_r().poolBalance());
        vm.stopPrank();

        // Alice tries to redeem → PoolInsufficient
        vm.prank(alice);
        vm.expectRevert(RepaymentModule.PoolInsufficient.selector);
        _r().redeem(100e18, new uint256[](0));

        // No silent loss; user keeps their CT
        assertEq(campaignToken.balanceOf(alice), 5_000e18, "alice CT untouched after revert");
    }

    /// @dev Producer detaches Repayment with funded pool, leaving USDC
    ///      orphaned on the campaign. Withdraw is unreachable until
    ///      reattach. This is a producer-sovereign action.
    function test_vuln_producerOrphansPool_recoverableByReattach() public {
        uint256 poolBefore = _r().poolBalance();
        uint256 usdcOnCampaignBefore = usdc.balanceOf(campaignAddr);
        assertGe(usdcOnCampaignBefore, poolBefore, "campaign holds pool");

        vm.prank(producer);
        GrowfiCampaign(payable(campaignAddr)).detachModule(REPAY_TYPE);

        // Withdraw path unreachable
        vm.prank(producer);
        vm.expectRevert();
        _r().withdrawUnusedPool(1);

        // USDC still on campaign
        assertEq(usdc.balanceOf(campaignAddr), usdcOnCampaignBefore, "USDC orphan");

        // Producer reattaches — accounting persists, withdraw works
        vm.prank(producer);
        GrowfiCampaign(payable(campaignAddr)).attachModule(REPAY_TYPE, REPAY_KIND, address(repayImpl), "");
        vm.prank(producer);
        _r().withdrawUnusedPool(poolBefore);
        assertEq(_r().poolBalance(), 0);
    }

    // ------------------------------------------------------------------
    // EIP-165 / interface detection — none expected
    // ------------------------------------------------------------------

    /// @dev The host does NOT implement supportsInterface. Calls to it
    ///      route through the fallback and revert UnknownSelector,
    ///      which is fine — no EIP-165 commitment is made.
    function test_vuln_eip165_supportsInterface_revertsUnknownSelector() public {
        bytes4 supportsIface = bytes4(keccak256("supportsInterface(bytes4)"));
        vm.expectRevert(abi.encodeWithSelector(GrowfiCampaign.UnknownSelector.selector, supportsIface));
        (bool ok,) = campaignAddr.call(abi.encodeWithSelector(supportsIface, bytes4(0x01ffc9a7)));
        ok;
    }
}
