// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// TODO: Unit tests for Pathfinder hook routing logic
// Uses MockLiquidityFeed to control snapshot data
//
// Test cases:
// - small trade below smallTradeLimit → always executes locally
// - improvement below routingThreshold → executes locally
// - improvement above routingThreshold → routes cross-chain
// - stale cache data (timestamp too old) → falls back to local
// - whale trade above whaleTradeLimit → always routes
// - Base has best impact → routes to Base
// - Optimism has best impact → routes to Optimism
// - Unichain is already best → executes locally
