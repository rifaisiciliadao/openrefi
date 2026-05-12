// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CampaignStorage} from "../../src/host/CampaignStorage.sol";

/// @title  EchoModule
/// @notice Minimal module used to exercise the module-host plumbing.
///         When delegate-called by a Campaign, `echo(string)` writes
///         the message to the module's own namespaced storage and
///         records the original `msg.sender` (which should be the
///         end user, not the Campaign, thanks to delegatecall).
contract EchoModule {
    bytes32 internal constant STORAGE_SLOT = keccak256("growfi.module.echo.v1");

    struct Layout {
        string lastMessage;
        address lastCaller;
        uint256 callCount;
        address lastReadProducer; // read from CampaignStorage.layout().producer to verify context
    }

    function _storage() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }

    /// @dev Single external function — selector `echo(string)`.
    function echo(string calldata message) external {
        Layout storage es = _storage();
        es.lastMessage = message;
        es.lastCaller = msg.sender;
        es.callCount += 1;
        es.lastReadProducer = CampaignStorage.layout().producer;
    }

    function readLastMessage() external view returns (string memory) {
        return _storage().lastMessage;
    }

    function readLastCaller() external view returns (address) {
        return _storage().lastCaller;
    }

    function readCallCount() external view returns (uint256) {
        return _storage().callCount;
    }

    function readLastReadProducer() external view returns (address) {
        return _storage().lastReadProducer;
    }
}
