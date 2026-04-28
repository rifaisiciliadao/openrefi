// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ProducerRegistry
/// @notice Onchain pointer from a producer address to a JSON profile
///         (name, bio, avatar/cover URLs, website, social, contact).
///         Every producer owns their row; anyone can read.
///
///         Single global registry, no admin, no upgrades for the public
///         profile surface. The producer writes for themselves via
///         msg.sender, full stop. The subgraph indexes `ProfileUpdated`
///         into the `Producer` entity and the frontend links
///         `Campaign.producer` to it.
///
///         Separately, the registry carries a KYC bit per producer that
///         is **not** self-attested — only addresses granted the
///         `KYC_ADMIN_ROLE` (multi-slot) by the contract owner can flip
///         it. Off-chain process (third-party verifier) decides; this
///         contract just reflects the result on-chain via `KycSet`.
contract ProducerRegistry {
    // --- Profile (self-served) ---

    /// @notice Current profile URI per producer (latest overwrite).
    mapping(address => string) public profileURI;

    /// @notice Monotonically increasing revision per producer — lets
    ///         callers invalidate caches without polling the URI.
    mapping(address => uint256) public version;

    event ProfileUpdated(address indexed producer, uint256 indexed version, string uri);

    error EmptyURI();

    // --- KYC (role-gated) ---

    /// @notice Contract owner. Single-slot, ownable-style. Set at deploy.
    ///         Owner can transfer ownership and grant/revoke KYC admins.
    address public owner;

    /// @notice Pending owner for the 2-step transfer pattern.
    address public pendingOwner;

    /// @notice True if `addr` may flip the KYC bit on any producer.
    mapping(address => bool) public isKycAdmin;

    /// @notice Latest KYC verdict per producer. Defaults to false.
    mapping(address => bool) public kyced;

    /// @notice Block timestamp of the last KYC flip (0 if never set).
    mapping(address => uint256) public kycSetAt;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event KycAdminGranted(address indexed admin, address indexed by);
    event KycAdminRevoked(address indexed admin, address indexed by);
    event KycSet(address indexed producer, bool indexed kyced, address indexed by);

    error NotOwner();
    error NotPendingOwner();
    error NotKycAdmin();
    error ZeroAddress();
    error NoChange();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyKycAdmin() {
        if (!isKycAdmin[msg.sender]) revert NotKycAdmin();
        _;
    }

    /// @param owner_ Initial owner; receives the right to grant the first
    ///        KYC admin and to transfer ownership later.
    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    /// @notice Publish or update a profile. The caller is always the
    ///         producer; there's no way to write to someone else's row.
    /// @param uri Fully-qualified URL to the profile JSON (e.g. on DO
    ///        Spaces, IPFS, or any other host). The shape is a frontend
    ///        concern, not enforced on-chain.
    function setProfile(string calldata uri) external {
        if (bytes(uri).length == 0) revert EmptyURI();

        uint256 newVersion = version[msg.sender] + 1;
        version[msg.sender] = newVersion;
        profileURI[msg.sender] = uri;

        emit ProfileUpdated(msg.sender, newVersion, uri);
    }

    // --- Ownership (2-step) ---

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previous = owner;
        owner = pendingOwner;
        delete pendingOwner;
        emit OwnershipTransferred(previous, owner);
    }

    // --- KYC admin set ---

    function grantKycAdmin(address admin) external onlyOwner {
        if (admin == address(0)) revert ZeroAddress();
        if (isKycAdmin[admin]) revert NoChange();
        isKycAdmin[admin] = true;
        emit KycAdminGranted(admin, msg.sender);
    }

    function revokeKycAdmin(address admin) external onlyOwner {
        if (!isKycAdmin[admin]) revert NoChange();
        isKycAdmin[admin] = false;
        emit KycAdminRevoked(admin, msg.sender);
    }

    // --- KYC verdict ---

    /// @notice Flip the KYC bit on a producer. Idempotent guard against
    ///         no-op writes so subgraphs don't have to dedupe.
    function setKyc(address producer, bool kyced_) external onlyKycAdmin {
        if (producer == address(0)) revert ZeroAddress();
        if (kyced[producer] == kyced_) revert NoChange();
        kyced[producer] = kyced_;
        kycSetAt[producer] = block.timestamp;
        emit KycSet(producer, kyced_, msg.sender);
    }
}
