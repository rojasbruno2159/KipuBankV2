// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Decimals conversion library (to USDC 6 decimals)
library Decimals {
    // Public constant to unify decimal reference across the project
    uint8 public constant USDC_DECIMALS = 6;

    function toUSDC(uint256 amount, uint8 tokenDecimals) internal pure returns (uint256) {
        if (tokenDecimals == USDC_DECIMALS) return amount;
        if (tokenDecimals > USDC_DECIMALS) {
            unchecked { return amount / (10 ** (tokenDecimals - USDC_DECIMALS)); }
        } else {
            unchecked { return amount * (10 ** (USDC_DECIMALS - tokenDecimals)); }
        }
    }
}
