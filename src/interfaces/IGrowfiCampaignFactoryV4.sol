// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  IGrowfiCampaignFactoryV4
/// @notice Subset of factory functions that the GrowfiCampaign host calls
///         into during module attach. The factory enforces the whitelist
///         and publishes the canonical selector set per module class.
interface IGrowfiCampaignFactoryV4 {
    /// @notice True if `impl` is currently whitelisted as a valid
    ///         implementation for the given module `kind`.
    function isModuleImplApproved(bytes32 kind, address impl) external view returns (bool);

    /// @notice Canonical set of external selectors that the module class
    ///         `kind` claims. The host registers these in its
    ///         `selectorToType` map at attach time.
    function moduleKindSelectors(bytes32 kind) external view returns (bytes4[] memory);
}
