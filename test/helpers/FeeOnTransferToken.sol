// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title FeeOnTransferToken — ERC20 that skims `feeBps` on every transfer
/// @notice Burns the fee; recipient receives `amount * (10_000 - feeBps) / 10_000`.
///         Used to document Campaign's assumption that payment tokens are
///         not fee-on-transfer, and to prove what breaks if one is whitelisted.
contract FeeOnTransferToken is ERC20 {
    uint256 public immutable feeBps;
    uint8 private _decimalsValue;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 feeBps_) ERC20(name_, symbol_) {
        _decimalsValue = decimals_;
        feeBps = feeBps_;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimalsValue;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, amount);
            return;
        }
        uint256 fee = amount * feeBps / 10_000;
        uint256 net = amount - fee;
        super._update(from, to, net);
        // Burn the fee — this is what makes it "fee-on-transfer": the
        // recipient always receives less than the declared amount.
        if (fee > 0) super._update(from, address(0), fee);
    }
}
