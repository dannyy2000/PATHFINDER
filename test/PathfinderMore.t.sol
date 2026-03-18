// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ILiquidityCache} from "../src/interfaces/ILiquidityCache.sol";
import {IPathfinder} from "../src/interfaces/IPathfinder.sol";
import {Pathfinder} from "../src/Pathfinder.sol";

contract MockLiquidityFeedMore is ILiquidityCache {
    mapping(bytes32 => LiquiditySnapshot) private snapshots;

    function set(address tokenA, address tokenB, LiquiditySnapshot calldata snapshot) external {
        snapshots[_key(tokenA, tokenB)] = snapshot;
    }

    function getSnapshot(address tokenA, address tokenB) external view returns (LiquiditySnapshot memory) {
        return snapshots[_key(tokenA, tokenB)];
    }

    function writeSnapshot(address, address, LiquiditySnapshot calldata) external {}

    function _key(address tokenA, address tokenB) internal pure returns (bytes32) {
        (address a, address b) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encode(a, b));
    }
}

contract PathfinderMoreTest is Test {
    using PoolIdLibrary for PoolKey;

    Pathfinder internal hook;
    MockLiquidityFeedMore internal feed;

    address internal constant POOL_MANAGER = address(0xAAAA);
    address internal constant TOKEN_A = address(0x1111);
    address internal constant TOKEN_B = address(0x2222);

    PoolKey internal key;
    bytes32 internal poolId;

    function setUp() external {
        feed = new MockLiquidityFeedMore();
        hook = new Pathfinder(IPoolManager(POOL_MANAGER), ILiquidityCache(address(feed)));
        key = PoolKey({
            currency0: Currency.wrap(TOKEN_A),
            currency1: Currency.wrap(TOKEN_B),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = PoolId.unwrap(key.toId());
    }

    function test_getPoolConfig_uninitializedPoolIsZeroed() external view {
        IPathfinder.PoolConfig memory cfg = hook.getPoolConfig(poolId);
        assertEq(cfg.maxStaleness, 0);
    }

    function test_registerConfig_overwritesPendingConfigBeforeInitialize() external {
        hook.registerConfig(key, _config(10, 11, 12, 13));
        hook.registerConfig(key, _config(20, 21, 22, 23));

        vm.prank(POOL_MANAGER);
        hook.afterInitialize(address(this), key, 0, 0);

        IPathfinder.PoolConfig memory cfg = hook.getPoolConfig(poolId);
        assertEq(cfg.routingThreshold, 20);
        assertEq(cfg.maxStaleness, 21);
    }

    function test_afterInitialize_returnsSelector() external {
        vm.prank(POOL_MANAGER);
        bytes4 selector = hook.afterInitialize(address(this), key, 0, 0);
        assertEq(selector, IHooks.afterInitialize.selector);
    }

    function test_beforeSwap_timestampZeroIsStale() external {
        _initConfig();
        feed.set(TOKEN_A, TOKEN_B, _snapshot(10, 5, 6, 0));
        _expectRoute("stale_data", hook.CHAIN_UNICHAIN(), 0, 5_000);
    }

    function test_beforeSwap_exactSmallLimitDoesNotTakeSmallTradeBranch() external {
        _initConfig();
        feed.set(TOKEN_A, TOKEN_B, _snapshot(100, 10, 30, block.timestamp));
        _expectRoute("improvement_route", hook.CHAIN_BASE(), 90, 1_000);
    }

    function test_beforeSwap_exactWhaleLimitTriggersWhaleRoute() external {
        _initConfig();
        feed.set(TOKEN_A, TOKEN_B, _snapshot(100, 95, 120, block.timestamp));
        _expectRoute("whale_route", hook.CHAIN_BASE(), 5, 1_000_000);
    }

    function test_beforeSwap_unichainEqualToBaseExecutesLocally() external {
        _initConfig();
        feed.set(TOKEN_A, TOKEN_B, _snapshot(50, 50, 90, block.timestamp));
        _expectRoute("local_best", hook.CHAIN_UNICHAIN(), 0, 5_000);
    }

    function test_beforeSwap_unichainEqualToOptimismExecutesLocally() external {
        _initConfig();
        feed.set(TOKEN_A, TOKEN_B, _snapshot(40, 60, 40, block.timestamp));
        _expectRoute("local_best", hook.CHAIN_UNICHAIN(), 0, 5_000);
    }

    function test_beforeSwap_baseAndOptimismWorseThanUnichainExecutesLocally() external {
        _initConfig();
        feed.set(TOKEN_A, TOKEN_B, _snapshot(10, 11, 12, block.timestamp));
        _expectRoute("local_best", hook.CHAIN_UNICHAIN(), 0, 5_000);
    }

    function test_beforeSwap_positiveSmallTradeStillUsesSmallTradeBranch() external {
        _initConfig();
        feed.set(TOKEN_A, TOKEN_B, _snapshot(100, 10, 20, block.timestamp));

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: int256(999),
            sqrtPriceLimitX96: 0
        });

        vm.expectEmit(true, false, false, true);
        emit Pathfinder.SwapRouted(poolId, hook.CHAIN_UNICHAIN(), "small_trade", 0);

        vm.prank(POOL_MANAGER);
        hook.beforeSwap(address(this), key, params, "");
    }

    function test_beforeSwap_routesToOptimismWhenClearlyBest() external {
        _initConfig();
        feed.set(TOKEN_A, TOKEN_B, _snapshot(100, 90, 10, block.timestamp));
        _expectRoute("improvement_route", hook.CHAIN_OPTIMISM(), 90, 5_000);
    }

    function test_afterInitialize_partialZeroConfig_doesNotApplyDefaults() external {
        // maxStaleness == 0 but routingThreshold != 0 — AND condition not met, defaults NOT applied
        hook.registerConfig(key, _config(5, 0, 0, type(uint256).max));
        vm.prank(POOL_MANAGER);
        hook.afterInitialize(address(this), key, 0, 0);

        IPathfinder.PoolConfig memory cfg = hook.getPoolConfig(poolId);
        assertEq(cfg.routingThreshold, 5, "should use registered threshold, not default");
        assertEq(cfg.maxStaleness, 0,      "should stay 0, not be replaced by default");
    }

    function test_registerConfig_afterInit_doesNotAffectActiveConfig() external {
        _initConfig(); // threshold=15, staleness=30

        IPathfinder.PoolConfig memory before = hook.getPoolConfig(poolId);
        assertEq(before.routingThreshold, 15);

        // Calling registerConfig again only writes to pending — active config unchanged
        hook.registerConfig(key, _config(99, 999, 0, type(uint256).max));

        IPathfinder.PoolConfig memory after_ = hook.getPoolConfig(poolId);
        assertEq(after_.routingThreshold, 15, "active config must not change");
        assertEq(after_.maxStaleness, 30,      "active staleness must not change");
    }

    function test_beforeSwap_whaleLimitMinusOne_doesNotWhaleRoute() external {
        _initConfig(); // threshold=15, whale=1_000_000
        // improvement = 5 bps, below threshold — trade at WHALE_LIMIT-1 must not trigger whale path
        feed.set(TOKEN_A, TOKEN_B, _snapshot(100, 95, 120, block.timestamp));

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(1_000_000 - 1),
            sqrtPriceLimitX96: 0
        });

        vm.expectEmit(true, false, false, true);
        emit Pathfinder.SwapRouted(poolId, hook.CHAIN_UNICHAIN(), "below_threshold", 0);

        vm.prank(POOL_MANAGER);
        hook.beforeSwap(address(this), key, params, "");
    }

    function _initConfig() internal {
        hook.registerConfig(key, _config(15, 30, 1_000, 1_000_000));
        vm.prank(POOL_MANAGER);
        hook.afterInitialize(address(this), key, 0, 0);
    }

    function _expectRoute(string memory reason, uint8 destination, uint256 improvement, uint256 amount) internal {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: 0
        });

        vm.expectEmit(true, false, false, true);
        emit Pathfinder.SwapRouted(poolId, destination, reason, improvement);

        vm.prank(POOL_MANAGER);
        hook.beforeSwap(address(this), key, params, "");
    }

    function _config(uint256 threshold, uint256 staleness, uint256 small, uint256 whale)
        internal
        pure
        returns (IPathfinder.PoolConfig memory)
    {
        return IPathfinder.PoolConfig({
            routingThreshold: threshold,
            maxStaleness: staleness,
            smallTradeLimit: small,
            whaleTradeLimit: whale
        });
    }

    function _snapshot(uint256 unichain, uint256 base, uint256 optimism, uint256 timestamp)
        internal
        pure
        returns (ILiquidityCache.LiquiditySnapshot memory)
    {
        return ILiquidityCache.LiquiditySnapshot({
            unichainImpactBps: unichain,
            baseImpactBps: base,
            optimismImpactBps: optimism,
            timestamp: timestamp
        });
    }
}
