// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {ILiquidityCache} from "./interfaces/ILiquidityCache.sol";
import {IPathfinder} from "./interfaces/IPathfinder.sol";

/// @title Pathfinder
/// @notice Uniswap v4 hook on Unichain that routes swaps to the chain with the best price impact.
///         afterInitialize  — stores per-pool routing config
///         beforeSwap       — reads LiquidityCache, emits routing decision (M2 executes cross-chain)
///         afterSwap        — emits post-swap analytics event
/// @dev In Milestone 1, cross-chain routing is decided and emitted but not yet executed.
///      The local swap proceeds regardless of routing decision. Execution is Milestone 2.
contract Pathfinder is IHooks, IPathfinder {
    using PoolIdLibrary for PoolKey;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @dev Default routing threshold in bps (0.15% improvement needed to justify routing)
    uint256 public constant DEFAULT_ROUTING_THRESHOLD = 15;

    /// @dev Default max cache staleness in seconds before falling back to local
    uint256 public constant DEFAULT_MAX_STALENESS = 30;

    // Chain identifiers used in events
    uint8 public constant CHAIN_UNICHAIN  = 0;
    uint8 public constant CHAIN_BASE      = 1;
    uint8 public constant CHAIN_OPTIMISM  = 2;

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    IPoolManager public immutable poolManager;
    ILiquidityCache public immutable cache;

    /// @dev Configs set by deployers via registerConfig before calling PoolManager.initialize
    mapping(bytes32 => PoolConfig) private _pendingConfigs;

    /// @dev Active configs — populated in afterInitialize
    mapping(bytes32 => PoolConfig) private _poolConfigs;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted in beforeSwap with the routing decision
    /// @param poolId      The pool that received the swap
    /// @param destination Chain the swap would route to (CHAIN_* constant)
    /// @param reason      Short string explaining the decision
    /// @param improvementBps Improvement over Unichain in bps (0 if routing locally)
    event SwapRouted(
        bytes32 indexed poolId,
        uint8 destination,
        string reason,
        uint256 improvementBps
    );

    /// @notice Emitted in afterSwap for analytics
    event SwapSettled(bytes32 indexed poolId, int256 amountSpecified, bool zeroForOne);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error NotPoolManager();
    error HookNotImplemented();
    error PoolNotInitialized();

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(IPoolManager _poolManager, ILiquidityCache _cache) {
        poolManager = _poolManager;
        cache = _cache;
    }

    // -------------------------------------------------------------------------
    // IPathfinder — config management
    // -------------------------------------------------------------------------

    /// @notice Pre-register a PoolConfig before calling PoolManager.initialize.
    ///         afterInitialize will move it to active storage.
    /// @dev Anyone can call — the poolId is derived from the key so it is scoped to that pool.
    function registerConfig(PoolKey calldata key, PoolConfig calldata config) external {
        _pendingConfigs[PoolId.unwrap(key.toId())] = config;
    }

    /// @inheritdoc IPathfinder
    function getPoolConfig(bytes32 poolId) external view returns (PoolConfig memory) {
        return _poolConfigs[poolId];
    }

    // -------------------------------------------------------------------------
    // IHooks — implemented hooks
    // -------------------------------------------------------------------------

    /// @dev Moves pending config to active config for this pool.
    ///      If no config was pre-registered, stores protocol defaults.
    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        onlyPoolManager
        returns (bytes4)
    {
        bytes32 id = PoolId.unwrap(key.toId());
        PoolConfig memory cfg = _pendingConfigs[id];

        // If nothing was pre-registered, apply defaults
        if (cfg.routingThreshold == 0 && cfg.maxStaleness == 0) {
            cfg = PoolConfig({
                routingThreshold: DEFAULT_ROUTING_THRESHOLD,
                maxStaleness:     DEFAULT_MAX_STALENESS,
                smallTradeLimit:  0,
                whaleTradeLimit:  type(uint256).max
            });
        }

        _poolConfigs[id] = cfg;
        delete _pendingConfigs[id];

        return IHooks.afterInitialize.selector;
    }

    /// @dev Reads LiquidityCache, applies routing decision logic, emits SwapRouted.
    ///      In M1, the local swap proceeds unconditionally — cross-chain execution is M2.
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        bytes32 id = PoolId.unwrap(key.toId());
        PoolConfig memory cfg = _poolConfigs[id];

        if (cfg.maxStaleness == 0) revert PoolNotInitialized();

        ILiquidityCache.LiquiditySnapshot memory snap = cache.getSnapshot(
            Currency.unwrap(key.currency0),
            Currency.unwrap(key.currency1)
        );

        // 1. Staleness check — if data is too old, always execute locally
        if (snap.timestamp == 0 || block.timestamp - snap.timestamp > cfg.maxStaleness) {
            emit SwapRouted(id, CHAIN_UNICHAIN, "stale_data", 0);
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // 2. Trade size — raw token amount (USD conversion requires oracle, out of M1 scope)
        uint256 tradeSize = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);

        // 3. Small trade — never worth routing cross-chain
        if (tradeSize < cfg.smallTradeLimit) {
            emit SwapRouted(id, CHAIN_UNICHAIN, "small_trade", 0);
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // 4. Find best executable chain (Base and Optimism only — Ethereum/Arbitrum not routable)
        (uint8 bestChain, uint256 bestImpact) = _bestExecutableChain(snap);

        // 5. If Unichain is already best — execute locally
        if (bestChain == CHAIN_UNICHAIN || snap.unichainImpactBps <= bestImpact) {
            emit SwapRouted(id, CHAIN_UNICHAIN, "local_best", 0);
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 improvementBps = snap.unichainImpactBps - bestImpact;

        // 6. Whale — always route regardless of threshold
        if (tradeSize >= cfg.whaleTradeLimit) {
            emit SwapRouted(id, bestChain, "whale_route", improvementBps);
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // 7. Improvement check — route only if gain exceeds threshold
        if (improvementBps > cfg.routingThreshold) {
            emit SwapRouted(id, bestChain, "improvement_route", improvementBps);
        } else {
            emit SwapRouted(id, CHAIN_UNICHAIN, "below_threshold", 0);
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Emits a settled event for analytics. No state changes.
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        emit SwapSettled(PoolId.unwrap(key.toId()), params.amountSpecified, params.zeroForOne);
        return (IHooks.afterSwap.selector, 0);
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    /// @dev Returns the chain identifier and impact bps for the best executable chain.
    ///      Only Base and Optimism are executable (Superchain members).
    ///      Falls back to CHAIN_UNICHAIN if Unichain is already the best executable option.
    function _bestExecutableChain(ILiquidityCache.LiquiditySnapshot memory snap)
        internal
        pure
        returns (uint8 bestChain, uint256 bestImpact)
    {
        if (snap.baseImpactBps <= snap.optimismImpactBps) {
            bestChain  = CHAIN_BASE;
            bestImpact = snap.baseImpactBps;
        } else {
            bestChain  = CHAIN_OPTIMISM;
            bestImpact = snap.optimismImpactBps;
        }
    }

    // -------------------------------------------------------------------------
    // IHooks — unused hooks (revert to save gas on accidental calls)
    // -------------------------------------------------------------------------

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external pure returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure returns (bytes4, BalanceDelta)
    {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external pure returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure returns (bytes4, BalanceDelta)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
