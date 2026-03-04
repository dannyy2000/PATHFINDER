// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// TODO: Replaces LiquidityCache during testing
// Returns hardcoded snapshot data
// Exposes setter functions so tests can control what Pathfinder sees
// e.g. setSnapshot(tokenA, tokenB, snapshot) to simulate Base being best
// Implements ILiquidityCache
