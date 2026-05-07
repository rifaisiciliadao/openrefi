// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockStablecoin — generic testnet ERC20 with public mint
/// @notice Used by DeployTestnetV4 to spin up mUSDC / mUSDT / mDAI side-by-side so the
///         multi-stablecoin allowlist can be exercised on testnet. Anyone can mint to
///         anyone. Reverts on mainnet chain IDs as a safety guard.
contract MockStablecoin is ERC20 {
    error MainnetDisallowed();

    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        uint256 id = block.chainid;
        if (id == 1 || id == 42_161 || id == 10 || id == 8_453 || id == 137) {
            revert MainnetDisallowed();
        }
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
