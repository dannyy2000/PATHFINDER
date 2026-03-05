// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILiquidityCache} from "./interfaces/ILiquidityCache.sol";

/// @title MockLiquidityFeed
/// @notice In-memory fake of LiquidityCache for deterministic tests.
contract MockLiquidityFeed is ILiquidityCache {
    mapping(bytes32 => LiquiditySnapshot) private _snapshots;

    event SnapshotSet(address indexed tokenA, address indexed tokenB, uint256 timestamp);

    /// @inheritdoc ILiquidityCache
    function getSnapshot(address tokenA, address tokenB)
        external
        view
        returns (LiquiditySnapshot memory)
    {
        return _snapshots[_pairKey(tokenA, tokenB)];
    }

    /// @inheritdoc ILiquidityCache
    function writeSnapshot(
        address tokenA,
        address tokenB,
        LiquiditySnapshot calldata snapshot
    ) external {
        _setSnapshot(tokenA, tokenB, snapshot);
    }

    /// @notice Convenience setter used directly by tests.
    function setSnapshot(
        address tokenA,
        address tokenB,
        LiquiditySnapshot calldata snapshot
    ) external {
        _setSnapshot(tokenA, tokenB, snapshot);
    }

    function _setSnapshot(
        address tokenA,
        address tokenB,
        LiquiditySnapshot calldata snapshot
    ) internal {
        _snapshots[_pairKey(tokenA, tokenB)] = snapshot;
        emit SnapshotSet(tokenA, tokenB, snapshot.timestamp);
    }

    function _pairKey(address tokenA, address tokenB) internal pure returns (bytes32) {
        (address a, address b) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encode(a, b));
    }
}
