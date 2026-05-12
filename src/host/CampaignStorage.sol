// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  CampaignStorage
/// @notice Namespaced storage layout for the GrowfiCampaign host and every
///         module that runs in its `delegatecall` context.
///
///         The Campaign host and all attached modules access this single
///         struct via `CampaignStorage.layout()`, which resolves to a slot
///         derived from `keccak256("growfi.campaign.core.v1")`. Sequential
///         storage variables on the host are NOT used — this avoids
///         collisions with the layouts that future modules might choose,
///         and lets modules read/write host state directly without
///         knowing the host's compile-time slot ordering.
///
///         Modules MUST keep their own state in a separate namespace
///         (`keccak256("growfi.module.<kind>.v<n>")`). Touching slots
///         inside `CampaignStorage.Layout` from a module is allowed by
///         design (this is the whole point of the delegatecall model)
///         but must respect the host's invariants — bypassing them is
///         an audit finding.
///
///         See `docs/07 - Module Framework (Diamond).md` for the full
///         design rationale.
library CampaignStorage {
    /// @dev `keccak256("growfi.campaign.core.v1")`. Computed off-chain and
    ///      asserted equal in tests so a typo here is caught immediately.
    bytes32 internal constant SLOT =
        0x97c54a0bf039447711bcab434c5a40b95f0e18b67d18363706a9ce32d1b0cc6f;

    /// @notice Campaign lifecycle phases.
    /// @dev    Persisted as `uint8` inside `Layout.state` so the enum can
    ///         be evolved without breaking existing storage.
    enum State {
        Funding, // 0 — initial sale open, escrow held by Campaign
        Active, // 1 — min cap reached, staking + yield active
        Buyback, // 2 — funding deadline missed, refunds open
        Ended // 3 — campaign closed permanently
    }

    /// @notice One entry in the per-Campaign module registry. Indexed by
    ///         the `bytes32 moduleType` slot (e.g. `keccak256("growfi.type.sale")`).
    /// @param  impl         The module contract that gets `delegatecall`-ed
    ///                      when one of its selectors hits the Campaign.
    /// @param  kind         The module class (e.g. `keccak256("growfi.sale.classic.v1")`).
    ///                      The factory's whitelist is keyed on this value.
    /// @param  metadataURI  Off-chain JSON describing the module (human-readable
    ///                      name, version, audit URL).
    /// @param  attachedAt   Unix timestamp of the attach tx.
    /// @param  enabled      Producer-controlled fast disable without detach.
    struct ModuleSlot {
        address impl;
        bytes32 kind;
        string metadataURI;
        uint64 attachedAt;
        bool enabled;
    }

    /// @notice The single struct that holds all host-owned state. The
    ///         host contract declares NO sequential state variables; the
    ///         entire layout lives behind `layout()` at `SLOT`.
    struct Layout {
        // -------------------------------------------------------------
        // Bindings (set once during initialize, never mutated again)
        // -------------------------------------------------------------
        address producer;
        address factory;
        address campaignToken;
        address yieldToken;
        address stakingVault;
        address harvestManager;
        address usdc;
        address protocolFeeRecipient;
        // -------------------------------------------------------------
        // State machine
        // -------------------------------------------------------------
        uint8 state; // CampaignStorage.State packed as uint8
        bool paused;
        bool factoryBootstrap; // one-shot flag: open during default-module injection
        // -------------------------------------------------------------
        // Staking lifecycle counter (modules read it to size season ops)
        // -------------------------------------------------------------
        uint256 currentSeasonId;
        // -------------------------------------------------------------
        // Module registry
        // -------------------------------------------------------------
        mapping(bytes4 => bytes32) selectorToType;
        mapping(bytes32 => ModuleSlot) moduleSlot;
        bytes32[] moduleTypeList;
    }

    /// @notice Accessor used by both the host and every module to read
    ///         and write the layout. Returns a storage pointer rooted at
    ///         `SLOT`, so the caller sees the host's Campaign state
    ///         regardless of whether it's the host or a delegate-called
    ///         module.
    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }
}
