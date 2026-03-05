// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILiquidityCache} from "./ILiquidityCache.sol";

interface ILiquidityWatcher {
    /// @notice Emitted when a chain impact update is processed for a pair.
    event ChainImpactUpdated(
        address indexed tokenA,
        address indexed tokenB,
        uint8 indexed chain,
        uint256 impactBps
    );

    /// @notice Emitted when the watcher pushes a new snapshot to cache.
    event SnapshotPushed(
        address indexed tokenA,
        address indexed tokenB,
        uint8 bestChain,
        uint256 bestImpactBps,
        uint256 timestamp
    );

    /// @notice Emitted when cache address is updated.
    event CacheUpdated(address indexed oldCache, address indexed newCache);

    /// @notice Called by Reactive Network when a subscribed pool event fires on any monitored chain
    /// @dev Processes event data, updates rankings, pushes to LiquidityCache if best chain changes
    function react(bytes calldata eventData) external;

    /// @notice Set the LiquidityCache address on Unichain that this watcher writes to
    function setCache(address cache) external;

    /// @notice Returns the latest chain-by-chain impact snapshot for a token pair.
    function getSnapshot(address tokenA, address tokenB)
        external
        view
        returns (ILiquidityCache.LiquiditySnapshot memory);

    /// @notice Returns best executable chain summary for a token pair.
    /// @dev 0=Unichain, 1=Base, 2=Optimism
    function getBestChainSnapshot(address tokenA, address tokenB)
        external
        view
        returns (
            uint8 bestChain,
            uint256 bestImpactBps,
            uint256 unichainImpactBps,
            uint256 timestamp
        );
}
