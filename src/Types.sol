// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

library Types {
    // Use address(0) to represent native ETH as a "token"
    address public constant NATIVE_TOKEN = address(0);

    struct AssetConfig {
        // Chainlink price feed for TOKEN/USD (or ETH/USD when token == NATIVE_TOKEN)
        AggregatorV3Interface priceFeed;
        // Whether deposits/withdrawals are enabled for this asset
        bool enabled;
    }
}
