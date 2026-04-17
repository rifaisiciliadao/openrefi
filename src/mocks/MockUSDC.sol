// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC — testnet-only ERC20 with public mint
/// @notice Deliberately permissive: anyone can mint any amount to any address.
///         The constructor reverts on mainnet chain IDs so the contract can
///         never be accidentally used where real funds live.
contract MockUSDC is ERC20 {
    error MainnetDisallowed();

    constructor() ERC20("Mock USD Coin", "mUSDC") {
        uint256 id = block.chainid;
        // Ethereum (1), Arbitrum One (42161), Optimism (10), Base (8453), Polygon (137)
        if (id == 1 || id == 42_161 || id == 10 || id == 8_453 || id == 137) {
            revert MainnetDisallowed();
        }
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Anyone can mint to anyone. Testnet only — see constructor guard.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
