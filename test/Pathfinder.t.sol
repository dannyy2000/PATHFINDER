// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

import {Pathfinder} from "../src/Pathfinder.sol";
import {IPathfinder} from "../src/interfaces/IPathfinder.sol";
import {ILiquidityCache} from "../src/interfaces/ILiquidityCache.sol";

// ---------------------------------------------------------------------------
// Minimal mock — stands in for the real LiquidityCache until friend's
// src/MockLiquidityFeed.sol is ready.
// ---------------------------------------------------------------------------
contract MockLiquidityFeed is ILiquidityCache {
    mapping(bytes32 => LiquiditySnapshot) private _snaps;

    function set(address a, address b, LiquiditySnapshot calldata s) external {
        _snaps[_key(a, b)] = s;
    }

    function getSnapshot(address a, address b) external view returns (LiquiditySnapshot memory) {
        return _snaps[_key(a, b)];
    }

    function writeSnapshot(address, address, LiquiditySnapshot calldata) external {}

    function _key(address a, address b) internal pure returns (bytes32) {
        (address lo, address hi) = a < b ? (a, b) : (b, a);
        return keccak256(abi.encode(lo, hi));
    }
}

// ---------------------------------------------------------------------------
// Test suite
// ---------------------------------------------------------------------------
contract PathfinderTest is Test {
    using PoolIdLibrary for PoolKey;

    Pathfinder  hook;
    MockLiquidityFeed feed;

    // Bare address — we prank it to satisfy onlyPoolManager
    address poolManager = address(0xDEAD);

    // Token pair (must be sorted: currency0 < currency1)
    address constant TOKEN_A = address(0x1000);
    address constant TOKEN_B = address(0x2000);

    PoolKey  key;
    bytes32  poolId;

    // Config values
    uint256 constant THRESHOLD     = 15;   // 0.15 % in bps
    uint256 constant MAX_STALENESS = 30;   // seconds
    uint256 constant SMALL_LIMIT   = 1_000;
    uint256 constant WHALE_LIMIT   = 1_000_000;

    // ------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------

    function setUp() public {
        feed = new MockLiquidityFeed();
        hook = new Pathfinder(IPoolManager(poolManager), ILiquidityCache(address(feed)));

        key = PoolKey({
            currency0:   Currency.wrap(TOKEN_A),
            currency1:   Currency.wrap(TOKEN_B),
            fee:         3000,
            tickSpacing: 60,
            hooks:       IHooks(address(hook))
        });
        poolId = PoolId.unwrap(key.toId());

        // Pre-register config then simulate afterInitialize
        hook.registerConfig(key, IPathfinder.PoolConfig({
            routingThreshold: THRESHOLD,
            maxStaleness:     MAX_STALENESS,
            smallTradeLimit:  SMALL_LIMIT,
            whaleTradeLimit:  WHALE_LIMIT
        }));

        vm.prank(poolManager);
        hook.afterInitialize(address(this), key, 0, 0);
    }

    function test_constructor_setsImmutableAddresses() public view {
        assertEq(address(hook.poolManager()), poolManager);
        assertEq(address(hook.cache()), address(feed));
    }

    function test_afterInitialize_usesDefaultConfigWhenNothingRegistered() public {
        Pathfinder defaultHook = new Pathfinder(IPoolManager(poolManager), ILiquidityCache(address(feed)));
        PoolKey memory defaultKey = PoolKey({
            currency0: Currency.wrap(address(0x3000)),
            currency1: Currency.wrap(address(0x4000)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(defaultHook))
        });
        bytes32 defaultPoolId = PoolId.unwrap(defaultKey.toId());

        vm.prank(poolManager);
        bytes4 selector = defaultHook.afterInitialize(address(this), defaultKey, 0, 0);

        IPathfinder.PoolConfig memory cfg = defaultHook.getPoolConfig(defaultPoolId);
        assertEq(selector, IHooks.afterInitialize.selector);
        assertEq(cfg.routingThreshold, defaultHook.DEFAULT_ROUTING_THRESHOLD());
        assertEq(cfg.maxStaleness, defaultHook.DEFAULT_MAX_STALENESS());
        assertEq(cfg.smallTradeLimit, 0);
        assertEq(cfg.whaleTradeLimit, type(uint256).max);
    }

    function test_afterInitialize_onlyPoolManager() public {
        vm.expectRevert(Pathfinder.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, 0, 0);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// Build a fresh snapshot with a known timestamp
    function _snap(uint256 unichain, uint256 base, uint256 optimism)
        internal view returns (ILiquidityCache.LiquiditySnapshot memory)
    {
        return ILiquidityCache.LiquiditySnapshot({
            unichainImpactBps: unichain,
            baseImpactBps:     base,
            optimismImpactBps: optimism,
            timestamp:         block.timestamp
        });
    }

    /// Push snap to mock feed and call beforeSwap with prank
    function _swap(ILiquidityCache.LiquiditySnapshot memory snap, int256 amount)
        internal
        returns (bytes4 sel, uint24 fee)
    {
        feed.set(TOKEN_A, TOKEN_B, snap);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne:        true,
            amountSpecified:   amount,
            sqrtPriceLimitX96: 0
        });

        vm.prank(poolManager);
        (sel,, fee) = hook.beforeSwap(address(this), key, params, "");
    }

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------

    /// Small trade (below smallTradeLimit) always executes locally
    function test_smallTrade_executesLocally() public {
        ILiquidityCache.LiquiditySnapshot memory snap = _snap(100, 10, 20); // Base is way better
        feed.set(TOKEN_A, TOKEN_B, snap);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne:        true,
            amountSpecified:   -int256(SMALL_LIMIT - 1),  // below limit
            sqrtPriceLimitX96: 0
        });

        vm.expectEmit(true, false, false, true);
        emit Pathfinder.SwapRouted(poolId, hook.CHAIN_UNICHAIN(), "small_trade", 0);

        vm.prank(poolManager);
        hook.beforeSwap(address(this), key, params, "");
    }

    /// Improvement below routingThreshold → executes locally
    function test_belowThreshold_executesLocally() public {
        // Unichain 100 bps, Base 90 bps → improvement = 10 bps < threshold (15)
        ILiquidityCache.LiquiditySnapshot memory snap = _snap(100, 90, 120);
        feed.set(TOKEN_A, TOKEN_B, snap);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne:        true,
            amountSpecified:   -int256(SMALL_LIMIT + 1),  // medium trade
            sqrtPriceLimitX96: 0
        });

        vm.expectEmit(true, false, false, true);
        emit Pathfinder.SwapRouted(poolId, hook.CHAIN_UNICHAIN(), "below_threshold", 0);

        vm.prank(poolManager);
        hook.beforeSwap(address(this), key, params, "");
    }

    /// Improvement above routingThreshold → routes cross-chain
    function test_aboveThreshold_routesCrossChain() public {
        // Unichain 100 bps, Base 80 bps → improvement = 20 bps > threshold (15)
        ILiquidityCache.LiquiditySnapshot memory snap = _snap(100, 80, 120);
        feed.set(TOKEN_A, TOKEN_B, snap);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne:        true,
            amountSpecified:   -int256(SMALL_LIMIT + 1),
            sqrtPriceLimitX96: 0
        });

        vm.expectEmit(true, false, false, true);
        emit Pathfinder.SwapRouted(poolId, hook.CHAIN_BASE(), "improvement_route", 20);

        vm.prank(poolManager);
        hook.beforeSwap(address(this), key, params, "");
    }

    function test_beforeSwap_revertsWhenPoolNotInitialized() public {
        Pathfinder uninitializedHook = new Pathfinder(IPoolManager(poolManager), ILiquidityCache(address(feed)));
        PoolKey memory uninitializedKey = PoolKey({
            currency0: Currency.wrap(address(0x3000)),
            currency1: Currency.wrap(address(0x4000)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(uninitializedHook))
        });
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(SMALL_LIMIT + 1),
            sqrtPriceLimitX96: 0
        });

        vm.prank(poolManager);
        vm.expectRevert(Pathfinder.PoolNotInitialized.selector);
        uninitializedHook.beforeSwap(address(this), uninitializedKey, params, "");
    }

    function test_beforeSwap_onlyPoolManager() public {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(SMALL_LIMIT + 1),
            sqrtPriceLimitX96: 0
        });

        vm.expectRevert(Pathfinder.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
    }

    /// Stale cache data → falls back to local
    function test_staleData_fallsBackToLocal() public {
        vm.warp(1_000);  // ensure block.timestamp > MAX_STALENESS so subtraction is safe
        ILiquidityCache.LiquiditySnapshot memory snap = ILiquidityCache.LiquiditySnapshot({
            unichainImpactBps: 100,
            baseImpactBps:     10,
            optimismImpactBps: 20,
            timestamp:         block.timestamp - MAX_STALENESS - 1  // expired
        });
        feed.set(TOKEN_A, TOKEN_B, snap);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne:        true,
            amountSpecified:   -int256(SMALL_LIMIT + 1),
            sqrtPriceLimitX96: 0
        });

        vm.expectEmit(true, false, false, true);
        emit Pathfinder.SwapRouted(poolId, hook.CHAIN_UNICHAIN(), "stale_data", 0);

        vm.prank(poolManager);
        hook.beforeSwap(address(this), key, params, "");
    }

    /// Whale trade (above whaleTradeLimit) always routes to best chain
    function test_whaleTrade_alwaysRoutes() public {
        // Improvement only 5 bps — below threshold, but whale so routes anyway
        ILiquidityCache.LiquiditySnapshot memory snap = _snap(100, 95, 120);
        feed.set(TOKEN_A, TOKEN_B, snap);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne:        true,
            amountSpecified:   -int256(WHALE_LIMIT),
            sqrtPriceLimitX96: 0
        });

        vm.expectEmit(true, false, false, true);
        emit Pathfinder.SwapRouted(poolId, hook.CHAIN_BASE(), "whale_route", 5);

        vm.prank(poolManager);
        hook.beforeSwap(address(this), key, params, "");
    }

    function test_exactThreshold_executesLocally() public {
        ILiquidityCache.LiquiditySnapshot memory snap = _snap(100, 85, 120); // improvement = 15 == threshold
        feed.set(TOKEN_A, TOKEN_B, snap);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(SMALL_LIMIT + 1),
            sqrtPriceLimitX96: 0
        });

        vm.expectEmit(true, false, false, true);
        emit Pathfinder.SwapRouted(poolId, hook.CHAIN_UNICHAIN(), "below_threshold", 0);

        vm.prank(poolManager);
        hook.beforeSwap(address(this), key, params, "");
    }

    function test_positiveAmountSpecified_usesAbsoluteTradeSize() public {
        ILiquidityCache.LiquiditySnapshot memory snap = _snap(100, 80, 120);
        feed.set(TOKEN_A, TOKEN_B, snap);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: int256(SMALL_LIMIT + 1),
            sqrtPriceLimitX96: 0
        });

        vm.expectEmit(true, false, false, true);
        emit Pathfinder.SwapRouted(poolId, hook.CHAIN_BASE(), "improvement_route", 20);

        vm.prank(poolManager);
        hook.beforeSwap(address(this), key, params, "");
    }

    /// Base has best impact → routes to Base
    function test_baseIsBest_routesToBase() public {
        ILiquidityCache.LiquiditySnapshot memory snap = _snap(100, 50, 70);
        feed.set(TOKEN_A, TOKEN_B, snap);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne:        true,
            amountSpecified:   -int256(SMALL_LIMIT + 1),
            sqrtPriceLimitX96: 0
        });

        vm.expectEmit(true, false, false, true);
        emit Pathfinder.SwapRouted(poolId, hook.CHAIN_BASE(), "improvement_route", 50);

        vm.prank(poolManager);
        hook.beforeSwap(address(this), key, params, "");
    }

    /// Optimism has best impact → routes to Optimism
    function test_optimismIsBest_routesToOptimism() public {
        ILiquidityCache.LiquiditySnapshot memory snap = _snap(100, 70, 50);
        feed.set(TOKEN_A, TOKEN_B, snap);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne:        true,
            amountSpecified:   -int256(SMALL_LIMIT + 1),
            sqrtPriceLimitX96: 0
        });

        vm.expectEmit(true, false, false, true);
        emit Pathfinder.SwapRouted(poolId, hook.CHAIN_OPTIMISM(), "improvement_route", 50);

        vm.prank(poolManager);
        hook.beforeSwap(address(this), key, params, "");
    }

    /// Unichain is already best → executes locally
    function test_unichainIsBest_executesLocally() public {
        // Unichain has lowest impact
        ILiquidityCache.LiquiditySnapshot memory snap = _snap(30, 80, 90);
        feed.set(TOKEN_A, TOKEN_B, snap);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne:        true,
            amountSpecified:   -int256(SMALL_LIMIT + 1),
            sqrtPriceLimitX96: 0
        });

        vm.expectEmit(true, false, false, true);
        emit Pathfinder.SwapRouted(poolId, hook.CHAIN_UNICHAIN(), "local_best", 0);

        vm.prank(poolManager);
        hook.beforeSwap(address(this), key, params, "");
    }

    function test_afterSwap_emitsSettledEvent() public {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(1234),
            sqrtPriceLimitX96: 0
        });

        vm.expectEmit(true, false, false, true);
        emit Pathfinder.SwapSettled(poolId, -int256(1234), false);

        vm.prank(poolManager);
        (bytes4 selector, int128 unspecified) = hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");

        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(unspecified, 0);
    }

    function test_afterSwap_onlyPoolManager() public {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(1234),
            sqrtPriceLimitX96: 0
        });

        vm.expectRevert(Pathfinder.NotPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
    }

    function test_unusedHooks_revert() public {
        vm.expectRevert(Pathfinder.HookNotImplemented.selector);
        hook.beforeInitialize(address(this), key, 0);

        IPoolManager.ModifyLiquidityParams memory liquidityParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: 1,
            salt: bytes32(0)
        });

        vm.expectRevert(Pathfinder.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(this), key, liquidityParams, "");

        vm.expectRevert(Pathfinder.HookNotImplemented.selector);
        hook.afterAddLiquidity(address(this), key, liquidityParams, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");

        vm.expectRevert(Pathfinder.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), key, liquidityParams, "");

        vm.expectRevert(Pathfinder.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(address(this), key, liquidityParams, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");

        vm.expectRevert(Pathfinder.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 0, 0, "");

        vm.expectRevert(Pathfinder.HookNotImplemented.selector);
        hook.afterDonate(address(this), key, 0, 0, "");
    }
}
