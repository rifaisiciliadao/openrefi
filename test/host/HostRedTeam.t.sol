// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {GrowfiCampaign} from "../../src/GrowfiCampaign.sol";
import {CampaignStorage} from "../../src/host/CampaignStorage.sol";
import {EchoModule} from "./EchoModule.sol";
import {EchoModule2} from "./EchoModule2.sol";
import {TestModuleRegistry} from "./TestModuleRegistry.sol";

/// @title  HostRedTeamTest
/// @notice Adversarial scenarios on the GrowfiCampaign host (the
///         delegatecall router). Extends test/host/Modules.t.sol with
///         red-team cases:
///         - selector collision across module-pairs with partial overlap
///         - detach + reattach with a different kind under same type
///         - revoking impl post-attach (existing routing must still work)
///         - bootstrap one-shot guarantees
///         - setModuleEnabled / detach on un-attached type
///         - attach via factory after bootstrap close
contract HostRedTeamTest is Test {
    bytes32 internal constant ECHO_KIND = keccak256("growfi.echo.v1");
    bytes32 internal constant ECHO2_KIND = keccak256("growfi.echo2.v1");
    bytes32 internal constant ECHO_TYPE = keccak256("growfi.type.echo");
    bytes32 internal constant PING_TYPE = keccak256("growfi.type.ping");
    bytes32 internal constant UNUSED_TYPE = keccak256("growfi.type.unused");

    address internal protocolOwner = makeAddr("protocolOwner");
    address internal producer = makeAddr("producer");
    address internal user = makeAddr("user");
    address internal mallory = makeAddr("mallory");

    TestModuleRegistry internal registry;
    GrowfiCampaign internal campaign;
    EchoModule internal echoImpl;
    EchoModule2 internal echo2Impl;

    function setUp() public {
        TestModuleRegistry registryImpl = new TestModuleRegistry();
        bytes memory initData = abi.encodeCall(TestModuleRegistry.initialize, (protocolOwner));
        TransparentUpgradeableProxy registryProxy =
            new TransparentUpgradeableProxy(address(registryImpl), protocolOwner, initData);
        registry = TestModuleRegistry(address(registryProxy));

        echoImpl = new EchoModule();
        echo2Impl = new EchoModule2();

        // ECHO_KIND has 1 callable + view selectors so tests can read state via router
        bytes4[] memory echoSelectors = new bytes4[](2);
        echoSelectors[0] = EchoModule.echo.selector;
        echoSelectors[1] = EchoModule.readCallCount.selector;

        // ECHO2_KIND has 3 callables + 1 view (readEchoCount) so tests can verify
        bytes4[] memory echo2Selectors = new bytes4[](4);
        echo2Selectors[0] = EchoModule2.echo.selector;
        echo2Selectors[1] = EchoModule2.ping.selector;
        echo2Selectors[2] = EchoModule2.multi.selector;
        echo2Selectors[3] = EchoModule2.readEchoCount.selector;

        vm.startPrank(protocolOwner);
        registry.setModuleKindSelectors(ECHO_KIND, echoSelectors);
        registry.approveModuleImpl(ECHO_KIND, address(echoImpl), true);
        registry.setModuleKindSelectors(ECHO2_KIND, echo2Selectors);
        registry.approveModuleImpl(ECHO2_KIND, address(echo2Impl), true);
        vm.stopPrank();

        GrowfiCampaign campaignImpl = new GrowfiCampaign();
        GrowfiCampaign.InitParams memory p = GrowfiCampaign.InitParams({
            producer: producer,
            factory: address(registry),
            usdc: address(0xCa5),
            protocolFeeRecipient: address(0xCa6)
        });
        bytes memory campInit = abi.encodeCall(GrowfiCampaign.initialize, (p));
        TransparentUpgradeableProxy campaignProxy =
            new TransparentUpgradeableProxy(address(campaignImpl), protocolOwner, campInit);
        campaign = GrowfiCampaign(payable(address(campaignProxy)));

        // Dummy satellites — order matters (consumer side first, peer last)
        vm.startPrank(address(registry));
        campaign.setYieldToken(address(0xCa2));
        campaign.setHarvestManager(address(0xCa4));
        campaign.setStakingVault(address(0xCa3));
        campaign.setCampaignToken(address(0xCa1));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // 1. Selector-collision: partial overlap across multi-selector modules
    // ------------------------------------------------------------------

    /// @dev Attach a single-selector ECHO module, then try to attach a
    ///      3-selector ECHO2 module that shares ONE selector. The
    ///      attach must revert atomically — none of the 3 selectors
    ///      should get registered (no partial attach).
    function test_host_partialSelectorCollision_revertsAtomically() public {
        vm.prank(address(registry));
        campaign.attachModuleAsFactory(ECHO_TYPE, ECHO_KIND, address(echoImpl), "");

        // ECHO2 has echo() (collides) + ping() + multi() (unique).
        // Attach should revert on the collision, and ping/multi must
        // NOT be registered.
        vm.prank(address(registry));
        vm.expectRevert(abi.encodeWithSelector(GrowfiCampaign.SelectorAlreadyTaken.selector, EchoModule2.echo.selector));
        campaign.attachModuleAsFactory(PING_TYPE, ECHO2_KIND, address(echo2Impl), "");

        // None of ECHO2's selectors should be registered
        assertEq(campaign.selectorToType(EchoModule2.ping.selector), bytes32(0), "ping NOT registered");
        assertEq(campaign.selectorToType(EchoModule2.multi.selector), bytes32(0), "multi NOT registered");
        // ECHO_TYPE still owns echo()
        assertEq(campaign.selectorToType(EchoModule.echo.selector), ECHO_TYPE);
    }

    /// @dev If the colliding selector is FREED by detaching ECHO first,
    ///      the multi-selector module attaches cleanly.
    function test_host_collisionFreedByDetach_thenAttachSucceeds() public {
        vm.prank(address(registry));
        campaign.attachModuleAsFactory(ECHO_TYPE, ECHO_KIND, address(echoImpl), "");
        vm.prank(address(registry));
        campaign.closeBootstrap();

        // Producer detaches ECHO → echo() selector freed
        vm.prank(producer);
        campaign.detachModule(ECHO_TYPE);
        assertEq(campaign.selectorToType(EchoModule.echo.selector), bytes32(0));

        // Now attach ECHO2 with all 3 selectors
        vm.prank(producer);
        campaign.attachModule(PING_TYPE, ECHO2_KIND, address(echo2Impl), "");

        assertEq(campaign.selectorToType(EchoModule2.echo.selector), PING_TYPE);
        assertEq(campaign.selectorToType(EchoModule2.ping.selector), PING_TYPE);
        assertEq(campaign.selectorToType(EchoModule2.multi.selector), PING_TYPE);

        // Calling echo() now routes to ECHO2's impl
        vm.prank(user);
        EchoModule2(address(campaign)).echo("redirected");
        assertEq(EchoModule2(address(campaign)).readEchoCount(), 1, "ECHO2 received the call");
    }

    // ------------------------------------------------------------------
    // 2. Detach + reattach lifecycle
    // ------------------------------------------------------------------

    /// @dev Reattach SAME kind/impl under SAME type after detach. All
    ///      slot fields restored; routing works again.
    function test_host_detachThenReattachSameKind_restoresRouting() public {
        vm.prank(address(registry));
        campaign.attachModuleAsFactory(ECHO_TYPE, ECHO_KIND, address(echoImpl), "v1");
        vm.prank(address(registry));
        campaign.closeBootstrap();

        // Call once
        vm.prank(user);
        EchoModule(address(campaign)).echo("first");

        vm.prank(producer);
        campaign.detachModule(ECHO_TYPE);

        // Calling now routes to nothing → UnknownSelector
        vm.expectRevert(abi.encodeWithSelector(GrowfiCampaign.UnknownSelector.selector, EchoModule.echo.selector));
        vm.prank(user);
        EchoModule(address(campaign)).echo("dead");

        // Reattach
        vm.prank(producer);
        campaign.attachModule(ECHO_TYPE, ECHO_KIND, address(echoImpl), "v2");

        (address impl, bytes32 kind, string memory uri,, bool enabled) = campaign.moduleSlot(ECHO_TYPE);
        assertEq(impl, address(echoImpl));
        assertEq(kind, ECHO_KIND);
        assertEq(uri, "v2", "metadataURI replaced");
        assertTrue(enabled);

        // Routing restored — and the module's STORAGE was preserved
        // (callCount carries the "first" call from before detach,
        // because module storage namespace is keccak-derived and survives
        // attach/detach cycles).
        vm.prank(user);
        EchoModule(address(campaign)).echo("second");
        assertEq(EchoModule(address(campaign)).readCallCount(), 2, "module storage persisted across detach/reattach");
    }

    // ------------------------------------------------------------------
    // 3. Impl revocation post-attach
    // ------------------------------------------------------------------

    /// @dev Owner un-whitelists ECHO impl after it's attached. Existing
    ///      campaign keeps working — producer-sovereign. But a NEW
    ///      attach attempt with the same impl is blocked.
    function test_host_revokeImplPostAttach_existingCampaignKeepsWorking() public {
        vm.prank(address(registry));
        campaign.attachModuleAsFactory(ECHO_TYPE, ECHO_KIND, address(echoImpl), "");
        vm.prank(address(registry));
        campaign.closeBootstrap();

        // Owner revokes
        vm.prank(protocolOwner);
        registry.approveModuleImpl(ECHO_KIND, address(echoImpl), false);

        // Existing call still works
        vm.prank(user);
        EchoModule(address(campaign)).echo("still alive");
        assertEq(EchoModule(address(campaign)).readCallCount(), 1);

        // But producer cannot RE-attach this impl under a new type
        vm.prank(producer);
        vm.expectRevert(GrowfiCampaign.ImplNotApproved.selector);
        campaign.attachModule(UNUSED_TYPE, ECHO_KIND, address(echoImpl), "");
    }

    /// @dev Owner revokes impl WHILE bootstrap is open AND module is not
    ///      yet attached. Factory bootstrap call must revert.
    function test_host_revokeImplDuringBootstrap_blocksAttach() public {
        vm.prank(protocolOwner);
        registry.approveModuleImpl(ECHO_KIND, address(echoImpl), false);

        vm.prank(address(registry));
        vm.expectRevert(GrowfiCampaign.ImplNotApproved.selector);
        campaign.attachModuleAsFactory(ECHO_TYPE, ECHO_KIND, address(echoImpl), "");
    }

    // ------------------------------------------------------------------
    // 4. Bootstrap one-shot
    // ------------------------------------------------------------------

    /// @dev Once closeBootstrap is called, the factory path is locked
    ///      forever. There is no re-open path.
    function test_host_closeBootstrap_oneShotPermanent() public {
        vm.prank(address(registry));
        campaign.closeBootstrap();

        // Second close: revert
        vm.prank(address(registry));
        vm.expectRevert(GrowfiCampaign.BootstrapClosed.selector);
        campaign.closeBootstrap();

        // Factory attach: blocked
        vm.prank(address(registry));
        vm.expectRevert(GrowfiCampaign.BootstrapClosed.selector);
        campaign.attachModuleAsFactory(ECHO_TYPE, ECHO_KIND, address(echoImpl), "");
    }

    /// @dev Stranger cannot closeBootstrap.
    function test_host_strangerCannotCloseBootstrap() public {
        vm.prank(mallory);
        vm.expectRevert(GrowfiCampaign.OnlyFactory.selector);
        campaign.closeBootstrap();
    }

    // ------------------------------------------------------------------
    // 5. Detach / setEnabled on un-attached type
    // ------------------------------------------------------------------

    /// @dev Detach a moduleType that was never attached → revert.
    function test_host_detachUnattachedType_reverts() public {
        vm.prank(address(registry));
        campaign.closeBootstrap();

        vm.prank(producer);
        vm.expectRevert(GrowfiCampaign.TypeNotAttached.selector);
        campaign.detachModule(UNUSED_TYPE);
    }

    /// @dev setModuleEnabled on a moduleType that was never attached → revert.
    function test_host_setEnabledOnUnattachedType_reverts() public {
        vm.prank(producer);
        vm.expectRevert(GrowfiCampaign.TypeNotAttached.selector);
        campaign.setModuleEnabled(UNUSED_TYPE, true);
    }

    /// @dev Stranger cannot detach a producer-owned attached module.
    function test_host_strangerCannotDetach() public {
        vm.prank(address(registry));
        campaign.attachModuleAsFactory(ECHO_TYPE, ECHO_KIND, address(echoImpl), "");
        vm.prank(address(registry));
        campaign.closeBootstrap();

        vm.prank(mallory);
        vm.expectRevert(GrowfiCampaign.OnlyProducer.selector);
        campaign.detachModule(ECHO_TYPE);
    }

    /// @dev Stranger cannot toggle a module's enabled flag.
    function test_host_strangerCannotSetEnabled() public {
        vm.prank(address(registry));
        campaign.attachModuleAsFactory(ECHO_TYPE, ECHO_KIND, address(echoImpl), "");

        vm.prank(mallory);
        vm.expectRevert(GrowfiCampaign.OnlyProducer.selector);
        campaign.setModuleEnabled(ECHO_TYPE, false);
    }

    // ------------------------------------------------------------------
    // 6. Disabled module — fallback short-circuits before delegatecall
    // ------------------------------------------------------------------

    function test_host_disabledModule_fallbackRevertsBeforeDelegatecall() public {
        vm.prank(address(registry));
        campaign.attachModuleAsFactory(ECHO_TYPE, ECHO_KIND, address(echoImpl), "");
        vm.prank(producer);
        campaign.setModuleEnabled(ECHO_TYPE, false);

        vm.expectRevert(GrowfiCampaign.ModuleDisabled.selector);
        EchoModule(address(campaign)).echo("blocked");

        // Re-enable and the call works again
        vm.prank(producer);
        campaign.setModuleEnabled(ECHO_TYPE, true);

        vm.prank(user);
        EchoModule(address(campaign)).echo("ok");
        assertEq(EchoModule(address(campaign)).readCallCount(), 1);
    }

    // ------------------------------------------------------------------
    // 7. UnknownSelector on completely-unregistered selector
    // ------------------------------------------------------------------

    function test_host_unknownSelector_reverts() public {
        bytes4 mystery = bytes4(keccak256("totallyMadeUp(uint256,bool,address)"));

        vm.expectRevert(abi.encodeWithSelector(GrowfiCampaign.UnknownSelector.selector, mystery));
        (bool ok,) = address(campaign).call(abi.encodeWithSelector(mystery, uint256(1), true, address(0)));
        ok;
    }

    // ------------------------------------------------------------------
    // 8. attachModule with zero impl
    // ------------------------------------------------------------------

    function test_host_attachZeroImpl_reverts() public {
        vm.prank(address(registry));
        vm.expectRevert(GrowfiCampaign.ZeroAddress.selector);
        campaign.attachModuleAsFactory(ECHO_TYPE, ECHO_KIND, address(0), "");
    }
}
