// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILiquidityCache} from "./interfaces/ILiquidityCache.sol";
import {ILiquidityWatcher} from "./interfaces/ILiquidityWatcher.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";

/// @title LiquidityWatcher
/// @notice Reactive-side watcher that tracks cross-chain impact updates for a token pair.
///         In local tests and demos, `react(bytes)` writes directly to LiquidityCache.
///         On Reactive Network, `react(LogRecord)` emits a callback to Unichain Sepolia.
contract LiquidityWatcher is ILiquidityWatcher, AbstractReactive {
    uint8 public constant CHAIN_UNICHAIN = 0;
    uint8 public constant CHAIN_BASE = 1;
    uint8 public constant CHAIN_OPTIMISM = 2;
    uint256 public constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 public constant OPTIMISM_SEPOLIA_CHAIN_ID = 11155420;
    uint64 public constant CALLBACK_GAS_LIMIT = 800_000;
    uint256 public constant IMPACT_UPDATED_TOPIC0 =
        uint256(keccak256("ImpactUpdated(address,address,uint8,uint256)"));

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

    constructor(address cache_, address baseFeed_, address optimismFeed_) payable {
        owner = msg.sender;
        _setCache(cache_);

        if (!vm) {
            if (baseFeed_ != address(0)) {
                _subscribe(
                    BASE_SEPOLIA_CHAIN_ID,
                    baseFeed_,
                    IMPACT_UPDATED_TOPIC0,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                );
            }

            if (optimismFeed_ != address(0)) {
                _subscribe(
                    OPTIMISM_SEPOLIA_CHAIN_ID,
                    optimismFeed_,
                    IMPACT_UPDATED_TOPIC0,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                );
            }
        }
    }

    /// @inheritdoc ILiquidityWatcher
    /// @dev Local/manual ingestion path used by tests and controlled demo flows.
    function react(bytes calldata eventData) external onlyOwner {
        _processImpactUpdate(eventData, true);
    }

    /// @notice Reactive entry point called by the Reactive Network runtime.
    /// @dev Expects the origin event data to encode (tokenA, tokenB, chain, impactBps).
    function react(IReactive.LogRecord calldata log) external vmOnly {
        _processImpactUpdate(log.data, false);
    }

    /// @inheritdoc ILiquidityWatcher
    function subscribe(
        uint256 chainId,
        address targetContract,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    ) external onlyOwner {
        _subscribe(chainId, targetContract, topic0, topic1, topic2, topic3);
    }

    function _processImpactUpdate(bytes calldata eventData, bool localWrite) internal {
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
            if (localWrite) {
                cache.writeSnapshot(tokenA, tokenB, snapshot);
            } else {
                bytes memory payload = abi.encodeCall(
                    ILiquidityCache.writeSnapshot, (tokenA, tokenB, snapshot)
                );
                emit Callback(UNICHAIN_SEPOLIA_CHAIN_ID, address(cache), CALLBACK_GAS_LIMIT, payload);
            }
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

    function _subscribe(
        uint256 chainId,
        address targetContract,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    ) internal {
        if (!vm) {
            service.subscribe(chainId, targetContract, topic0, topic1, topic2, topic3);
        }

        emit SubscriptionRegistered(chainId, targetContract, topic0, topic1, topic2, topic3);
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
