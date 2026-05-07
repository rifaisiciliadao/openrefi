// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

/**
 * MockChainlinkFeed — testnet-only Chainlink AggregatorV3 stand-in.
 *
 * Used by `DeployTestnet` to give every mock stablecoin a USD price feed without depending on
 * a real Chainlink oracle on Base Sepolia. `setPrice(int256)` lets a smoke script simulate a
 * depeg (e.g. set USDC to $0.85e8) and verify the Treasury's depeg circuit breaker fires.
 *
 * NOT for mainnet: there `factory.addGrowfiTreasuryStablecoin` should pass the real
 * Chainlink feed addresses instead.
 */
contract MockChainlinkFeed is AggregatorV3Interface {
    int256 private _price;
    uint8 private immutable _decimals;
    uint256 private _updatedAt;
    uint80 private _roundId = 1;
    uint80 private _answeredInRound = 1;

    event PriceUpdated(int256 newPrice, uint256 updatedAt);

    constructor(int256 initialPrice, uint8 decimals_) {
        _price = initialPrice;
        _decimals = decimals_;
        _updatedAt = block.timestamp;
    }

    /// @notice Anyone can set the price — testnet only, no access control by design.
    function setPrice(int256 newPrice) external {
        _price = newPrice;
        _updatedAt = block.timestamp;
        _roundId++;
        _answeredInRound = _roundId;
        emit PriceUpdated(newPrice, block.timestamp);
    }

    /// @notice Force the feed stale by rewinding `updatedAt` by `secondsAgo`.
    function setStale(uint256 secondsAgo) external {
        _updatedAt = block.timestamp - secondsAgo;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _price, _updatedAt, _updatedAt, _answeredInRound);
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }
}
