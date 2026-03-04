// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// TODO: Unit tests for LiquidityWatcher (Reactive contract)
//
// Test cases:
// - react() updates baseImpactBps correctly when Base pool event fires
// - react() updates optimismImpactBps correctly when Optimism pool event fires
// - react() updates unichainImpactBps correctly when Unichain pool event fires
// - snapshot pushed to LiquidityCache when best chain ranking changes
// - snapshot NOT pushed when ranking stays the same (no unnecessary writes)
// - timestamp updated on every write
// - per-pair isolation: ETH/USDC snapshot does not affect WBTC/USDC snapshot
