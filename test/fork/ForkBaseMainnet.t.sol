// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ForkBase} from "./ForkBase.sol";

contract ForkBaseMainnetTest is ForkBase {
    function _rpcUrl() internal pure override returns (string memory) {
        return "https://mainnet.base.org";
    }

    function _usdc() internal pure override returns (address) {
        return 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    }

    function _ethUsdFeed() internal pure override returns (address) {
        return 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    }

    function _weth() internal pure override returns (address) {
        return 0x4200000000000000000000000000000000000006;
    }

    function _chainName() internal pure override returns (string memory) {
        return "base-mainnet";
    }
}
