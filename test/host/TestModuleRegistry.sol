// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ModuleRegistry} from "../../src/host/ModuleRegistry.sol";

/// @notice Concrete instantiation of ModuleRegistry used by the unit
///         tests. The real factory inherits ModuleRegistry but adds the
///         per-campaign deploy choreography that the framework tests
///         don't need.
contract TestModuleRegistry is ModuleRegistry {
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_) external initializer {
        __ModuleRegistry_init(owner_);
    }
}
