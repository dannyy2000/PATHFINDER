// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILiquidityCache} from "./interfaces/ILiquidityCache.sol";

/// @title LiquidityCache
/// @notice Storage contract deployed on Unichain.
///         Written by LiquidityWatcher via Reactive callback when chain rankings change.
///         Read by Pathfinder in beforeSwap — local read, no cross-chain call at swap time.
contract LiquidityCache is ILiquidityCache {

    address public immutable deployer;
    address public authorizedWriter;

    mapping(bytes32 => LiquiditySnapshot) private _snapshots;

    event SnapshotWritten(address indexed tokenA, address indexed tokenB, uint256 timestamp);
    event WriterUpdated(address indexed oldWriter, address indexed newWriter);

    error Unauthorized();

    constructor() {
        deployer = msg.sender;
    }

    /// @notice Set the address allowed to write snapshots (LiquidityWatcher callback address)
    /// @dev Called after LiquidityWatcher is deployed and its callback address is known
    function setWriter(address writer) external {
        if (msg.sender != deployer) revert Unauthorized();
        emit WriterUpdated(authorizedWriter, writer);
        authorizedWriter = writer;
    }

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
        if (msg.sender != authorizedWriter) revert Unauthorized();
        _snapshots[_pairKey(tokenA, tokenB)] = snapshot;
        emit SnapshotWritten(tokenA, tokenB, snapshot.timestamp);
    }

    /// @dev Canonical pair key — token order normalized so (A,B) and (B,A) map to the same slot
    function _pairKey(address tokenA, address tokenB) internal pure returns (bytes32) {
        (address a, address b) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encode(a, b));
    }
}
