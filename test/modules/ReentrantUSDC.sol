// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title  ReentrantUSDC
/// @notice Adversarial ERC20: on every `transfer` callout (sender-side),
///         optionally re-enters a configured target with arbitrary
///         calldata. Used to verify the Repayment module's nonReentrant
///         guard against malicious "USDC-shaped" tokens. Real USDC does
///         NOT have transfer hooks — this is a worst-case mock to lock
///         down the guard's behavior in case a non-standard stable is
///         ever wired in.
contract ReentrantUSDC is ERC20 {
    address public reenterTarget;
    bytes public reenterData;
    bool public reentryArmed;
    uint8 private constant _DECIMALS = 6;

    constructor() ERC20("Malicious USDC", "mUSDC") {}

    function decimals() public pure override returns (uint8) {
        return _DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
        reentryArmed = true;
    }

    function disarm() external {
        reentryArmed = false;
    }

    /// @dev OZ ERC20 transfer hook. Fires AFTER state update on every
    ///      transfer (incl. transferFrom). If `reentryArmed`, we
    ///      attempt the configured callback. Failures are swallowed so
    ///      the outer call can still complete or revert as the SUT
    ///      decides.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (reentryArmed && reenterTarget != address(0)) {
            // one-shot: disarm before the call so we don't recurse forever
            reentryArmed = false;
            (bool ok,) = reenterTarget.call(reenterData);
            // Don't revert the outer transfer on reentry failure — we
            // want to see how the SUT's guard reacts.
            ok;
        }
    }
}
