// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Shared interface between LiquidityWatcher (writes) and Pathfinder (reads)
/// @dev Both contracts import this — agree on this before splitting work
interface ILiquidityCache {

    struct LiquiditySnapshot {
        uint256 unichainImpactBps;  // price impact on Unichain in basis points (e.g. 50 = 0.50%)
        uint256 baseImpactBps;      // price impact on Base in basis points
        uint256 optimismImpactBps;  // price impact on Optimism in basis points
        uint256 timestamp;          // when Reactive last wrote this — used for staleness check
    }

    /// @notice Read the latest snapshot for a token pair
    /// @dev Called by Pathfinder in beforeSwap
    function getSnapshot(address tokenA, address tokenB)
        external
        view
        returns (LiquiditySnapshot memory);

    /// @notice Write a new snapshot for a token pair
    /// @dev Called by LiquidityWatcher via Reactive callback when rankings change
    function writeSnapshot(
        address tokenA,
        address tokenB,
        LiquiditySnapshot calldata snapshot
    ) external;
}
