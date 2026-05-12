// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {GrowfiCampaign} from "../../src/GrowfiCampaign.sol";
import {CampaignStorage} from "../../src/host/CampaignStorage.sol";
import {ModuleRegistry} from "../../src/host/ModuleRegistry.sol";

import {EchoModule} from "./EchoModule.sol";
import {TestModuleRegistry} from "./TestModuleRegistry.sol";

contract ModulesTest is Test {
    // ------------------------------------------------------------------
    // Constants — module identifiers
    // ------------------------------------------------------------------

    bytes32 internal constant ECHO_KIND = keccak256("growfi.echo.v1");
    bytes32 internal constant ECHO_TYPE = keccak256("growfi.type.echo");
    bytes32 internal constant SAFE_RANDOM_TYPE = keccak256("growfi.type.random");

    // ------------------------------------------------------------------
    // Actors
    // ------------------------------------------------------------------

    address internal protocolOwner = makeAddr("protocolOwner");
    address internal producer = makeAddr("producer");
    address internal user = makeAddr("user");
    address internal stranger = makeAddr("stranger");

    // ------------------------------------------------------------------
    // System under test
    // ------------------------------------------------------------------

    TestModuleRegistry internal registry;
    GrowfiCampaign internal campaign;
    EchoModule internal echoImpl;

    // ------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------

    function setUp() public {
        // ---- registry (factory stub) ----
        TestModuleRegistry registryImpl = new TestModuleRegistry();
        bytes memory initData = abi.encodeCall(TestModuleRegistry.initialize, (protocolOwner));
        TransparentUpgradeableProxy registryProxy =
            new TransparentUpgradeableProxy(address(registryImpl), protocolOwner, initData);
        registry = TestModuleRegistry(address(registryProxy));

        // ---- echo impl + whitelist ----
        echoImpl = new EchoModule();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = EchoModule.echo.selector;
        vm.startPrank(protocolOwner);
        registry.setModuleKindSelectors(ECHO_KIND, selectors);
        registry.approveModuleImpl(ECHO_KIND, address(echoImpl), true);
        vm.stopPrank();

        // ---- campaign ----
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

        // Wire dummy satellites so subsequent module attaches don't trip
        // ZeroAddress checks. Real factory wires real satellites.
        // Order matters: setYieldToken/setStakingVault cross-wire into their
        // peer satellite (StakingVault.setYieldToken / CampaignToken.setStakingVault);
        // we set the consumer side first while the peer is still unset so the
        // cross-wire branch is skipped, then set the peer last.
        vm.startPrank(address(registry));
        campaign.setYieldToken(address(0xCa2));
        campaign.setHarvestManager(address(0xCa4));
        campaign.setStakingVault(address(0xCa3));
        campaign.setCampaignToken(address(0xCa1));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Lifecycle
    // ------------------------------------------------------------------

    function test_initialBootstrapOpen() public view {
        assertTrue(campaign.factoryBootstrap(), "bootstrap should start open");
        assertEq(campaign.producer(), producer);
        assertEq(campaign.factory(), address(registry));
        assertEq(uint8(campaign.state()), uint8(CampaignStorage.State.Funding));
    }

    function test_closeBootstrap_onlyFactory() public {
        vm.expectRevert(GrowfiCampaign.OnlyFactory.selector);
        vm.prank(stranger);
        campaign.closeBootstrap();

        vm.prank(address(registry));
        campaign.closeBootstrap();
        assertFalse(campaign.factoryBootstrap());
    }

    function test_closeBootstrap_oneShot() public {
        vm.prank(address(registry));
        campaign.closeBootstrap();

        vm.expectRevert(GrowfiCampaign.BootstrapClosed.selector);
        vm.prank(address(registry));
        campaign.closeBootstrap();
    }

    // ------------------------------------------------------------------
    // Attach / detach gating
    // ------------------------------------------------------------------

    function test_attachAsFactory_duringBootstrap() public {
        vm.prank(address(registry));
        campaign.attachModuleAsFactory(ECHO_TYPE, ECHO_KIND, address(echoImpl), "ipfs://echo.json");

        (address impl, bytes32 kind,, uint64 attachedAt, bool enabled) = campaign.moduleSlot(ECHO_TYPE);
        assertEq(impl, address(echoImpl));
        assertEq(kind, ECHO_KIND);
        assertGt(attachedAt, 0);
        assertTrue(enabled);

        assertEq(campaign.selectorToType(EchoModule.echo.selector), ECHO_TYPE);
        assertEq(campaign.moduleTypeCount(), 1);
        assertEq(campaign.moduleTypeAt(0), ECHO_TYPE);
    }

    function test_attachAsFactory_revertsAfterBootstrapClosed() public {
        vm.prank(address(registry));
        campaign.closeBootstrap();

        vm.prank(address(registry));
        vm.expectRevert(GrowfiCampaign.BootstrapClosed.selector);
        campaign.attachModuleAsFactory(ECHO_TYPE, ECHO_KIND, address(echoImpl), "");
    }

    function test_attachAsProducer_revertsForStranger() public {
        vm.prank(stranger);
        vm.expectRevert(GrowfiCampaign.OnlyProducer.selector);
        campaign.attachModule(ECHO_TYPE, ECHO_KIND, address(echoImpl), "");
    }

    function test_attachAsProducer_succeedsAfterBootstrap() public {
        vm.prank(address(registry));
        campaign.closeBootstrap();

        vm.prank(producer);
        campaign.attachModule(ECHO_TYPE, ECHO_KIND, address(echoImpl), "");

        (address impl,,,,) = campaign.moduleSlot(ECHO_TYPE);
        assertEq(impl, address(echoImpl));
    }

    function test_attach_revertsIfNotWhitelisted() public {
        address fakeImpl = makeAddr("fakeImpl");
        vm.prank(producer);
        vm.expectRevert(GrowfiCampaign.ImplNotApproved.selector);
        campaign.attachModule(ECHO_TYPE, ECHO_KIND, fakeImpl, "");
    }

    function test_attach_revertsIfKindHasNoSelectors() public {
        // Approve a random impl under a kind with no selectors set
        bytes32 emptyKind = keccak256("growfi.no.selectors");
        address impl = makeAddr("impl");
        vm.prank(protocolOwner);
        registry.approveModuleImpl(emptyKind, impl, true);

        vm.prank(producer);
        vm.expectRevert(GrowfiCampaign.KindHasNoSelectors.selector);
        campaign.attachModule(ECHO_TYPE, emptyKind, impl, "");
    }

    function test_attach_revertsIfTypeAlreadyTaken() public {
        vm.prank(address(registry));
        campaign.attachModuleAsFactory(ECHO_TYPE, ECHO_KIND, address(echoImpl), "");

        // Same type cannot be claimed twice
        vm.prank(address(registry));
        vm.expectRevert(GrowfiCampaign.TypeAlreadyAttached.selector);
        campaign.attachModuleAsFactory(ECHO_TYPE, ECHO_KIND, address(echoImpl), "");
    }

    function test_attach_revertsOnSelectorCollision() public {
        vm.prank(address(registry));
        campaign.attachModuleAsFactory(ECHO_TYPE, ECHO_KIND, address(echoImpl), "");

        // Trying to register the same `echo` selector under a different type
        EchoModule otherImpl = new EchoModule();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = EchoModule.echo.selector;
        bytes32 dupKind = keccak256("growfi.echo.duplicate.v1");
        vm.startPrank(protocolOwner);
        registry.setModuleKindSelectors(dupKind, selectors);
        registry.approveModuleImpl(dupKind, address(otherImpl), true);
        vm.stopPrank();

        vm.prank(address(registry));
        vm.expectRevert(
            abi.encodeWithSelector(GrowfiCampaign.SelectorAlreadyTaken.selector, EchoModule.echo.selector)
        );
        campaign.attachModuleAsFactory(SAFE_RANDOM_TYPE, dupKind, address(otherImpl), "");
    }

    function test_detach_clearsSelectorsAndSlot() public {
        vm.prank(address(registry));
        campaign.attachModuleAsFactory(ECHO_TYPE, ECHO_KIND, address(echoImpl), "");
        vm.prank(address(registry));
        campaign.closeBootstrap();

        vm.prank(producer);
        campaign.detachModule(ECHO_TYPE);

        (address impl,,,,) = campaign.moduleSlot(ECHO_TYPE);
        assertEq(impl, address(0));
        assertEq(campaign.selectorToType(EchoModule.echo.selector), bytes32(0));
        assertEq(campaign.moduleTypeCount(), 0);
    }

    function test_detach_thenReattach() public {
        vm.prank(address(registry));
        campaign.attachModuleAsFactory(ECHO_TYPE, ECHO_KIND, address(echoImpl), "");
        vm.prank(address(registry));
        campaign.closeBootstrap();

        vm.prank(producer);
        campaign.detachModule(ECHO_TYPE);

        vm.prank(producer);
        campaign.attachModule(ECHO_TYPE, ECHO_KIND, address(echoImpl), "v2 metadata");

        (address impl,, string memory uri,,) = campaign.moduleSlot(ECHO_TYPE);
        assertEq(impl, address(echoImpl));
        assertEq(uri, "v2 metadata");
        assertEq(campaign.selectorToType(EchoModule.echo.selector), ECHO_TYPE);
    }

    function test_setEnabled_togglesGate() public {
        vm.prank(address(registry));
        campaign.attachModuleAsFactory(ECHO_TYPE, ECHO_KIND, address(echoImpl), "");

        vm.prank(producer);
        campaign.setModuleEnabled(ECHO_TYPE, false);

        (,,,, bool enabled) = campaign.moduleSlot(ECHO_TYPE);
        assertFalse(enabled);

        vm.prank(producer);
        campaign.setModuleEnabled(ECHO_TYPE, true);

        (,,,, enabled) = campaign.moduleSlot(ECHO_TYPE);
        assertTrue(enabled);
    }

    // ------------------------------------------------------------------
    // Fallback routing — the real test of the framework
    // ------------------------------------------------------------------

    function test_fallback_routesDelegatecall() public {
        vm.prank(address(registry));
        campaign.attachModuleAsFactory(ECHO_TYPE, ECHO_KIND, address(echoImpl), "");

        // User calls Campaign.echo("hello") — the host fallback should
        // resolve the selector and delegatecall into EchoModule with the
        // user as msg.sender inside the module.
        vm.prank(user);
        EchoModule(address(campaign)).echo("hello");

        // EchoModule wrote into the Campaign's storage (delegatecall context),
        // so the readers — also exposed via the same delegated functions —
        // must reflect those values. Note: readers' selectors are NOT
        // registered, so we read by deploying a view EchoModule against the
        // namespaced slot — which requires the same storage namespace.
        // Instead we use vm.load against the known namespaced slot.
        bytes32 slot = keccak256("growfi.module.echo.v1");
        // Layout fields: lastMessage(string, 32 bytes head), lastCaller, callCount, lastReadProducer
        // lastCaller is the second 32-byte slot.
        bytes32 callerSlot = bytes32(uint256(slot) + 1);
        address recordedCaller = address(uint160(uint256(vm.load(address(campaign), callerSlot))));
        assertEq(recordedCaller, user, "msg.sender inside module must be the end user");

        bytes32 countSlot = bytes32(uint256(slot) + 2);
        uint256 recordedCount = uint256(vm.load(address(campaign), countSlot));
        assertEq(recordedCount, 1);

        bytes32 producerSlot = bytes32(uint256(slot) + 3);
        address recordedProducer = address(uint160(uint256(vm.load(address(campaign), producerSlot))));
        assertEq(recordedProducer, producer, "module must read producer via CampaignStorage layout");
    }

    function test_fallback_revertsUnknownSelector() public {
        bytes4 mystery = bytes4(keccak256("nonExistent()"));
        vm.expectRevert(abi.encodeWithSelector(GrowfiCampaign.UnknownSelector.selector, mystery));
        (bool ok,) = address(campaign).call(abi.encodeWithSelector(mystery));
        ok; // silence warning
    }

    function test_fallback_revertsWhenModuleDisabled() public {
        vm.prank(address(registry));
        campaign.attachModuleAsFactory(ECHO_TYPE, ECHO_KIND, address(echoImpl), "");
        vm.prank(producer);
        campaign.setModuleEnabled(ECHO_TYPE, false);

        vm.expectRevert(GrowfiCampaign.ModuleDisabled.selector);
        EchoModule(address(campaign)).echo("blocked");
    }

    // ------------------------------------------------------------------
    // Storage isolation between host and module
    // ------------------------------------------------------------------

    function test_moduleStorageDoesNotOverlapHostState() public {
        vm.prank(address(registry));
        campaign.attachModuleAsFactory(ECHO_TYPE, ECHO_KIND, address(echoImpl), "");

        // Write into module storage
        vm.prank(user);
        EchoModule(address(campaign)).echo("isolation");

        // Verify the host's core fields are unchanged
        assertEq(campaign.producer(), producer);
        assertEq(campaign.factory(), address(registry));
        assertEq(uint8(campaign.state()), uint8(CampaignStorage.State.Funding));
    }

    function test_revokedImplDoesNotBreakAttachedModule() public {
        vm.prank(address(registry));
        campaign.attachModuleAsFactory(ECHO_TYPE, ECHO_KIND, address(echoImpl), "");

        // Owner revokes the impl on the registry — already-attached
        // Campaigns should keep working (producer-sovereign).
        vm.prank(protocolOwner);
        registry.approveModuleImpl(ECHO_KIND, address(echoImpl), false);

        vm.prank(user);
        EchoModule(address(campaign)).echo("still works");

        bytes32 slot = keccak256("growfi.module.echo.v1");
        bytes32 countSlot = bytes32(uint256(slot) + 2);
        uint256 recordedCount = uint256(vm.load(address(campaign), countSlot));
        assertEq(recordedCount, 1, "delegate call must succeed even if impl was un-whitelisted later");
    }

    function test_revokedImpl_blocksNewAttach() public {
        vm.prank(protocolOwner);
        registry.approveModuleImpl(ECHO_KIND, address(echoImpl), false);

        vm.prank(producer);
        vm.expectRevert(GrowfiCampaign.ImplNotApproved.selector);
        campaign.attachModule(ECHO_TYPE, ECHO_KIND, address(echoImpl), "");
    }

    // ------------------------------------------------------------------
    // Storage namespace assertion
    // ------------------------------------------------------------------

    function test_campaignStorageSlotMatchesKeccak() public pure {
        assertEq(
            CampaignStorage.SLOT,
            keccak256("growfi.campaign.core.v1"),
            "CampaignStorage.SLOT must equal keccak256('growfi.campaign.core.v1')"
        );
    }
}
