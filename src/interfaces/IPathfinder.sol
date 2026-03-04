// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPathfinder {

    struct PoolConfig {
        uint256 routingThreshold;  // minimum improvement in bps to trigger cross-chain route (default: 15)
        uint256 maxStaleness;      // maximum age of cache data in seconds before fallback to local (default: 30)
        uint256 smallTradeLimit;   // trade size in USD below which routing is always skipped
        uint256 whaleTradeLimit;   // trade size in USD above which routing is always attempted
    }

    /// @notice Returns the routing config for a given pool
    function getPoolConfig(bytes32 poolId) external view returns (PoolConfig memory);
}
