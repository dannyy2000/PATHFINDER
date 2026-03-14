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

    /// @notice Emitted when a Reactive subscription is registered for an origin feed or pool contract.
    event SubscriptionRegistered(
        uint256 indexed chainId,
        address indexed targetContract,
        uint256 indexed topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    );

    /// @notice Manual/local ingestion helper used by tests and controlled demos.
    /// @dev The payload is abi.encode(tokenA, tokenB, chain, impactBps).
    function react(bytes calldata eventData) external;

    /// @notice Set the LiquidityCache address on Unichain that this watcher writes to
    function setCache(address cache) external;

    /// @notice Register an event subscription with Reactive Network.
    function subscribe(
        uint256 chainId,
        address targetContract,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    ) external;

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
