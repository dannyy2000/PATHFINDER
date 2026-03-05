// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILiquidityCache} from "./interfaces/ILiquidityCache.sol";
import {ILiquidityWatcher} from "./interfaces/ILiquidityWatcher.sol";

/// @title LiquidityWatcher
/// @notice Reactive-side watcher that processes pool event updates and pushes
///         updated snapshots to LiquidityCache when best-chain ranking changes.
contract LiquidityWatcher is ILiquidityWatcher {
    uint8 public constant CHAIN_UNICHAIN = 0;
    uint8 public constant CHAIN_BASE = 1;
    uint8 public constant CHAIN_OPTIMISM = 2;

    address public immutable owner;
    ILiquidityCache public cache;

    struct BestState {
        bool initialized;
        uint8 bestChain;
    }

    mapping(bytes32 => ILiquidityCache.LiquiditySnapshot) private _snapshots;
    mapping(bytes32 => uint8) private _seenMask;
    mapping(bytes32 => BestState) private _bestStates;

    error Unauthorized();
    error InvalidChain();
    error InvalidCache();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address cache_) {
        owner = msg.sender;
        _setCache(cache_);
    }

    /// @inheritdoc ILiquidityWatcher
    function react(bytes calldata eventData) external {
        (address tokenA, address tokenB, uint8 chain, uint256 impactBps) =
            abi.decode(eventData, (address, address, uint8, uint256));

        if (chain > CHAIN_OPTIMISM) revert InvalidChain();

        bytes32 key = _pairKey(tokenA, tokenB);
        ILiquidityCache.LiquiditySnapshot memory snapshot = _snapshots[key];

        if (chain == CHAIN_UNICHAIN) {
            snapshot.unichainImpactBps = impactBps;
            _seenMask[key] |= 1;
        } else if (chain == CHAIN_BASE) {
            snapshot.baseImpactBps = impactBps;
            _seenMask[key] |= 2;
        } else {
            snapshot.optimismImpactBps = impactBps;
            _seenMask[key] |= 4;
        }
        snapshot.timestamp = block.timestamp;
        _snapshots[key] = snapshot;

        emit ChainImpactUpdated(tokenA, tokenB, chain, impactBps);

        (uint8 bestChain, uint256 bestImpact) = _bestChainForKey(key, snapshot);
        BestState memory bestState = _bestStates[key];

        if (!bestState.initialized || bestState.bestChain != bestChain) {
            cache.writeSnapshot(tokenA, tokenB, snapshot);
            _bestStates[key] = BestState({initialized: true, bestChain: bestChain});
            emit SnapshotPushed(tokenA, tokenB, bestChain, bestImpact, snapshot.timestamp);
        }
    }

    /// @inheritdoc ILiquidityWatcher
    function setCache(address cache_) external onlyOwner {
        _setCache(cache_);
    }

    /// @inheritdoc ILiquidityWatcher
    function getSnapshot(address tokenA, address tokenB)
        external
        view
        returns (ILiquidityCache.LiquiditySnapshot memory)
    {
        return _snapshots[_pairKey(tokenA, tokenB)];
    }

    /// @inheritdoc ILiquidityWatcher
    function getBestChainSnapshot(address tokenA, address tokenB)
        external
        view
        returns (
            uint8 bestChain,
            uint256 bestImpactBps,
            uint256 unichainImpactBps,
            uint256 timestamp
        )
    {
        bytes32 key = _pairKey(tokenA, tokenB);
        ILiquidityCache.LiquiditySnapshot memory snapshot = _snapshots[key];
        (bestChain, bestImpactBps) = _bestChainForKey(key, snapshot);
        return (bestChain, bestImpactBps, snapshot.unichainImpactBps, snapshot.timestamp);
    }

    function _setCache(address cache_) internal {
        if (cache_ == address(0)) revert InvalidCache();
        address oldCache = address(cache);
        cache = ILiquidityCache(cache_);
        emit CacheUpdated(oldCache, cache_);
    }

    function _bestChainForKey(bytes32 key, ILiquidityCache.LiquiditySnapshot memory snapshot)
        internal
        view
        returns (uint8 bestChain, uint256 bestImpact)
    {
        uint8 seen = _seenMask[key];

        if (seen & 1 != 0) {
            bestChain = CHAIN_UNICHAIN;
            bestImpact = snapshot.unichainImpactBps;
        } else {
            bestChain = type(uint8).max;
            bestImpact = type(uint256).max;
        }

        if (seen & 2 != 0 && snapshot.baseImpactBps < bestImpact) {
            bestChain = CHAIN_BASE;
            bestImpact = snapshot.baseImpactBps;
        }
        if (seen & 4 != 0 && snapshot.optimismImpactBps < bestImpact) {
            bestChain = CHAIN_OPTIMISM;
            bestImpact = snapshot.optimismImpactBps;
        }

        if (bestChain == type(uint8).max) {
            return (CHAIN_UNICHAIN, 0);
        }
    }

    function _pairKey(address tokenA, address tokenB) internal pure returns (bytes32) {
        (address a, address b) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encode(a, b));
    }
}
