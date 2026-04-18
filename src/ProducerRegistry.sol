// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ProducerRegistry
/// @notice Onchain pointer from a producer address to a JSON profile
///         (name, bio, avatar/cover URLs, website, social, contact).
///         Every producer owns their row; anyone can read.
///
///         Single global registry, no admin, no upgrades. The on-chain
///         check is trivial — the producer writes for themselves via
///         msg.sender, full stop. The subgraph indexes `ProfileUpdated`
///         into the `Producer` entity and the frontend links
///         `Campaign.producer` to it.
contract ProducerRegistry {
    /// @notice Current profile URI per producer (latest overwrite).
    mapping(address => string) public profileURI;

    /// @notice Monotonically increasing revision per producer — lets
    ///         callers invalidate caches without polling the URI.
    mapping(address => uint256) public version;

    event ProfileUpdated(address indexed producer, uint256 indexed version, string uri);

    error EmptyURI();

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
}
