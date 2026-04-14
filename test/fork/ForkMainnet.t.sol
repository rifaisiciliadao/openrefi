// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ForkBase} from "./ForkBase.sol";

contract ForkMainnetTest is ForkBase {
    function _rpcUrl() internal pure override returns (string memory) {
        return "https://ethereum-rpc.publicnode.com";
    }

    function _usdc() internal pure override returns (address) {
        return 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    }

    function _ethUsdFeed() internal pure override returns (address) {
        return 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    }

    function _weth() internal pure override returns (address) {
        return 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    }

    function _chainName() internal pure override returns (string memory) {
        return "ethereum-mainnet";
    }
}
