// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  EchoModule2
/// @notice Sibling of EchoModule used to exercise selector-collision and
///         detach-reattach edge cases. Exposes:
///           - `echo(string)`         — same selector as EchoModule (collision)
///           - `ping()`                — unique selector
///           - `multi(uint256,bool)`   — unique selector
contract EchoModule2 {
    bytes32 internal constant STORAGE_SLOT = keccak256("growfi.module.echo2.v1");

    struct Layout {
        uint256 echoCount;
        uint256 pingCount;
        uint256 multiSum;
    }

    function _s() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }

    function echo(string calldata) external {
        _s().echoCount += 1;
    }

    function ping() external {
        _s().pingCount += 1;
    }

    function multi(uint256 n, bool /*flag*/ ) external {
        _s().multiSum += n;
    }

    function readEchoCount() external view returns (uint256) {
        return _s().echoCount;
    }

    function readPingCount() external view returns (uint256) {
        return _s().pingCount;
    }
}
