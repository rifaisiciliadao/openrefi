// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ForkBase} from "./ForkBase.sol";

contract ForkArbitrumTest is ForkBase {
    function _rpcUrl() internal pure override returns (string memory) {
        return "https://arb1.arbitrum.io/rpc";
    }

    function _usdc() internal pure override returns (address) {
        return 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    }

    function _ethUsdFeed() internal pure override returns (address) {
        return 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    }

    function _weth() internal pure override returns (address) {
        return 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    }

    function _chainName() internal pure override returns (string memory) {
        return "arbitrum-one";
    }
}
