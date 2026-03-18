// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPoolManager as PM} from "v4-core/src/interfaces/IPoolManager.sol";

import {Pathfinder} from "../src/Pathfinder.sol";
import {ILiquidityCache} from "../src/interfaces/ILiquidityCache.sol";
import {IPathfinder} from "../src/interfaces/IPathfinder.sol";

// Reuse the simple MockLiquidityFeed from the existing tests
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

contract PathfinderExtrasTest is Test {
    using PoolIdLibrary for PoolKey;

    Pathfinder hook;
    MockLiquidityFeed feed;
    address poolManager = address(0xBEEF);

    address constant TOKEN_A = address(0x1010);
    address constant TOKEN_B = address(0x2020);

    PoolKey key;
    bytes32 poolId;

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
    }

    function test_twoPools_routingIsIsolated() public {
        // Initialize pool1 (key from setUp — was never initialized there)
        hook.registerConfig(key, IPathfinder.PoolConfig({
            routingThreshold: 1,
            maxStaleness:     1000,
            smallTradeLimit:  0,
            whaleTradeLimit:  type(uint256).max
        }));
        vm.prank(poolManager);
        hook.afterInitialize(address(this), key, 0, 0);

        // Second pool on the same hook — different tokens, different config
        PoolKey memory key2 = PoolKey({
            currency0:   Currency.wrap(address(0x3030)),
            currency1:   Currency.wrap(address(0x4040)),
            fee:         500,
            tickSpacing: 10,
            hooks:       IHooks(address(hook))
        });
        bytes32 poolId2 = PoolId.unwrap(key2.toId());

        hook.registerConfig(key2, IPathfinder.PoolConfig({
            routingThreshold: 5,
            maxStaleness:     1000,
            smallTradeLimit:  0,
            whaleTradeLimit:  type(uint256).max
        }));
        vm.prank(poolManager);
        hook.afterInitialize(address(this), key2, 0, 0);

        // Pool1 (TOKEN_A/B): unichain is best
        feed.set(TOKEN_A, TOKEN_B, ILiquidityCache.LiquiditySnapshot({
            unichainImpactBps: 10, baseImpactBps: 90, optimismImpactBps: 90,
            timestamp: block.timestamp
        }));
        // Pool2 (0x3030/0x4040): Base is best by 50 bps, above threshold=5
        feed.set(address(0x3030), address(0x4040), ILiquidityCache.LiquiditySnapshot({
            unichainImpactBps: 60, baseImpactBps: 10, optimismImpactBps: 90,
            timestamp: block.timestamp
        }));

        PM.SwapParams memory params = PM.SwapParams({
            zeroForOne: true, amountSpecified: -int256(5_000), sqrtPriceLimitX96: 0
        });

        // Pool1 stays local
        vm.expectEmit(true, false, false, true);
        emit Pathfinder.SwapRouted(poolId, hook.CHAIN_UNICHAIN(), "local_best", 0);
        vm.prank(poolManager);
        hook.beforeSwap(address(this), key, params, "");

        // Pool2 routes to Base
        vm.expectEmit(true, false, false, true);
        emit Pathfinder.SwapRouted(poolId2, hook.CHAIN_BASE(), "improvement_route", 50);
        vm.prank(poolManager);
        hook.beforeSwap(address(this), key2, params, "");
    }

    function test_registerConfig_anyoneCanCall_and_afterInitialize_appliesIt() public {
        // Register as an arbitrary caller
        IPathfinder.PoolConfig memory cfg = IPathfinder.PoolConfig({
            routingThreshold: 42,
            maxStaleness: 7,
            smallTradeLimit: 123,
            whaleTradeLimit: 9999
        });

        // call registerConfig from a non-deployer address
        vm.prank(address(0xABC));
        hook.registerConfig(key, cfg);

        // now simulate pool manager calling afterInitialize
        vm.prank(poolManager);
        hook.afterInitialize(address(this), key, 0, 0);

        Pathfinder.PoolConfig memory read = hook.getPoolConfig(poolId);
        assertEq(read.routingThreshold, 42);
        assertEq(read.maxStaleness, 7);
        assertEq(read.smallTradeLimit, 123);
        assertEq(read.whaleTradeLimit, 9999);
    }

    function test_bestExecutableChain_tiebreaker_prefersBaseWhenEqual() public {
        // Prepare a snapshot where baseImpact == optimismImpact and both are better than unichain
        ILiquidityCache.LiquiditySnapshot memory snap = ILiquidityCache.LiquiditySnapshot({
            unichainImpactBps: 200,
            baseImpactBps: 50,
            optimismImpactBps: 50,
            timestamp: block.timestamp
        });

        feed.set(TOKEN_A, TOKEN_B, snap);

        // register a config and initialize so beforeSwap proceeds
        hook.registerConfig(key, IPathfinder.PoolConfig({
            routingThreshold: 1,
            maxStaleness: 1000,
            smallTradeLimit: 0,
            whaleTradeLimit: type(uint256).max
        }));

        vm.prank(poolManager);
        hook.afterInitialize(address(this), key, 0, 0);

        PM.SwapParams memory params = PM.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(1000),
            sqrtPriceLimitX96: 0
        });

        // Expect Base chosen due to tie-breaker implementation
        vm.expectEmit(true, false, false, true);
        emit Pathfinder.SwapRouted(poolId, hook.CHAIN_BASE(), "improvement_route", 150);

        vm.prank(poolManager);
        (bytes4 sel,,) = hook.beforeSwap(address(this), key, params, "");

        assertEq(sel, IHooks.beforeSwap.selector);
    }

    function test_beforeSwap_returnsFeeAndSelector_and_zeroFeeWhenNotSet() public {
        // Simple snapshot where local is best
        ILiquidityCache.LiquiditySnapshot memory snap = ILiquidityCache.LiquiditySnapshot({
            unichainImpactBps: 10,
            baseImpactBps: 100,
            optimismImpactBps: 200,
            timestamp: block.timestamp
        });
        feed.set(TOKEN_A, TOKEN_B, snap);

        hook.registerConfig(key, IPathfinder.PoolConfig({
            routingThreshold: 1,
            maxStaleness: 1000,
            smallTradeLimit: 0,
            whaleTradeLimit: type(uint256).max
        }));

        vm.prank(poolManager);
        hook.afterInitialize(address(this), key, 0, 0);

        PM.SwapParams memory params = PM.SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(5000),
            sqrtPriceLimitX96: 0
        });

        vm.prank(poolManager);
        (bytes4 sel,, uint24 fee) = hook.beforeSwap(address(this), key, params, "");

        // Selector should match hook's beforeSwap selector and fee should be 0 (not used in M1)
        assertEq(sel, IHooks.beforeSwap.selector);
        assertEq(fee, 0);
    }
}
