// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProducerRegistry} from "../src/ProducerRegistry.sol";

/// @title ProducerRegistryKyc — adversarial coverage for KYC role + setKyc.
/// @notice Pins the trust model: producers self-write profile, but the KYC
///         bit is role-gated. A malicious producer cannot self-attest KYC;
///         a non-admin cannot set anyone's KYC.
contract ProducerRegistryKycTest is Test {
    ProducerRegistry registry;

    address owner = makeAddr("owner");
    address kycAdmin = makeAddr("kycAdmin");
    address otherAdmin = makeAddr("otherAdmin");
    address producer = makeAddr("producer");
    address bob = makeAddr("bob");
    address attacker = makeAddr("attacker");

    function setUp() public {
        registry = new ProducerRegistry(owner);
    }

    // ========================================================================
    // OWNER + 2-step transfer
    // ========================================================================

    function test_initialOwnerSet() public view {
        assertEq(registry.owner(), owner);
    }

    function test_constructor_rejectsZeroOwner() public {
        vm.expectRevert(ProducerRegistry.ZeroAddress.selector);
        new ProducerRegistry(address(0));
    }

    function test_transferOwnership_2step() public {
        vm.prank(owner);
        registry.transferOwnership(bob);
        // Until acceptOwnership runs, owner is still `owner`.
        assertEq(registry.owner(), owner);
        assertEq(registry.pendingOwner(), bob);

        vm.prank(bob);
        registry.acceptOwnership();
        assertEq(registry.owner(), bob);
        assertEq(registry.pendingOwner(), address(0));
    }

    function test_attack_acceptOwnership_byNonPending() public {
        vm.prank(owner);
        registry.transferOwnership(bob);
        vm.prank(attacker);
        vm.expectRevert(ProducerRegistry.NotPendingOwner.selector);
        registry.acceptOwnership();
    }

    function test_attack_transferOwnership_byNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert(ProducerRegistry.NotOwner.selector);
        registry.transferOwnership(bob);
    }

    // ========================================================================
    // KYC admin grant / revoke
    // ========================================================================

    function test_grantKycAdmin_byOwner() public {
        vm.prank(owner);
        registry.grantKycAdmin(kycAdmin);
        assertTrue(registry.isKycAdmin(kycAdmin));
    }

    function test_attack_grantKycAdmin_byNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert(ProducerRegistry.NotOwner.selector);
        registry.grantKycAdmin(kycAdmin);
    }

    function test_attack_grantKycAdmin_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ProducerRegistry.ZeroAddress.selector);
        registry.grantKycAdmin(address(0));
    }

    function test_attack_grantKycAdmin_alreadyAdmin_reverts() public {
        vm.prank(owner);
        registry.grantKycAdmin(kycAdmin);
        vm.prank(owner);
        vm.expectRevert(ProducerRegistry.NoChange.selector);
        registry.grantKycAdmin(kycAdmin);
    }

    function test_revokeKycAdmin_byOwner() public {
        vm.startPrank(owner);
        registry.grantKycAdmin(kycAdmin);
        registry.revokeKycAdmin(kycAdmin);
        vm.stopPrank();
        assertFalse(registry.isKycAdmin(kycAdmin));
    }

    function test_attack_revokeKycAdmin_byNonOwner() public {
        vm.prank(owner);
        registry.grantKycAdmin(kycAdmin);
        vm.prank(attacker);
        vm.expectRevert(ProducerRegistry.NotOwner.selector);
        registry.revokeKycAdmin(kycAdmin);
    }

    function test_attack_revokeKycAdmin_notAdmin_reverts() public {
        vm.prank(owner);
        vm.expectRevert(ProducerRegistry.NoChange.selector);
        registry.revokeKycAdmin(kycAdmin);
    }

    // ========================================================================
    // setKyc: only KYC admins, never the producer themselves
    // ========================================================================

    function test_setKyc_byAdmin_flipsFlag() public {
        vm.prank(owner);
        registry.grantKycAdmin(kycAdmin);

        vm.prank(kycAdmin);
        registry.setKyc(producer, true);
        assertTrue(registry.kyced(producer));
        assertEq(registry.kycSetAt(producer), block.timestamp);

        vm.prank(kycAdmin);
        registry.setKyc(producer, false);
        assertFalse(registry.kyced(producer));
    }

    /// Critical attack: producer self-attests KYC. MUST fail.
    function test_attack_producerCannotSelfKyc() public {
        vm.prank(producer);
        vm.expectRevert(ProducerRegistry.NotKycAdmin.selector);
        registry.setKyc(producer, true);
    }

    function test_attack_owner_cannotSetKyc_unlessAdmin() public {
        // Even the contract owner cannot setKyc unless they grant themselves
        // the role first. This is intentional — the role is its own gate.
        vm.prank(owner);
        vm.expectRevert(ProducerRegistry.NotKycAdmin.selector);
        registry.setKyc(producer, true);
    }

    function test_attack_revokedAdmin_cannotSetKyc() public {
        vm.startPrank(owner);
        registry.grantKycAdmin(kycAdmin);
        registry.revokeKycAdmin(kycAdmin);
        vm.stopPrank();

        vm.prank(kycAdmin);
        vm.expectRevert(ProducerRegistry.NotKycAdmin.selector);
        registry.setKyc(producer, true);
    }

    function test_attack_setKyc_zeroAddress() public {
        vm.prank(owner);
        registry.grantKycAdmin(kycAdmin);
        vm.prank(kycAdmin);
        vm.expectRevert(ProducerRegistry.ZeroAddress.selector);
        registry.setKyc(address(0), true);
    }

    function test_attack_setKyc_noChange_reverts() public {
        vm.prank(owner);
        registry.grantKycAdmin(kycAdmin);
        vm.prank(kycAdmin);
        vm.expectRevert(ProducerRegistry.NoChange.selector);
        registry.setKyc(producer, false); // already false by default
    }

    // ========================================================================
    // Profile self-service surface unchanged
    // ========================================================================

    function test_setProfile_byProducer() public {
        vm.prank(producer);
        registry.setProfile("https://example.com/me.json");
        assertEq(registry.profileURI(producer), "https://example.com/me.json");
        assertEq(registry.version(producer), 1);
    }

    function test_setProfile_emptyReverts() public {
        vm.prank(producer);
        vm.expectRevert(ProducerRegistry.EmptyURI.selector);
        registry.setProfile("");
    }

    /// Producer can't write someone else's row.
    function test_attack_profileForeignAddress() public {
        vm.prank(attacker);
        registry.setProfile("https://hostile.com/profile.json");
        // Their own row was written, NOT producer's.
        assertEq(bytes(registry.profileURI(producer)).length, 0);
        assertEq(registry.profileURI(attacker), "https://hostile.com/profile.json");
    }

    // ========================================================================
    // Multi-admin scenario: granting two admins — both can flip independently;
    // revoking one leaves the other functional.
    // ========================================================================

    function test_multipleAdmins_independent() public {
        vm.startPrank(owner);
        registry.grantKycAdmin(kycAdmin);
        registry.grantKycAdmin(otherAdmin);
        vm.stopPrank();

        vm.prank(kycAdmin);
        registry.setKyc(producer, true);
        assertTrue(registry.kyced(producer));

        vm.prank(otherAdmin);
        registry.setKyc(producer, false);
        assertFalse(registry.kyced(producer));

        // Revoke kycAdmin; otherAdmin still works.
        vm.prank(owner);
        registry.revokeKycAdmin(kycAdmin);

        vm.prank(otherAdmin);
        registry.setKyc(producer, true);
        assertTrue(registry.kyced(producer));

        vm.prank(kycAdmin);
        vm.expectRevert(ProducerRegistry.NotKycAdmin.selector);
        registry.setKyc(producer, false);
    }
}
