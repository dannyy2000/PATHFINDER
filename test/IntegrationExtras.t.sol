// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Pathfinder} from "../src/Pathfinder.sol";
import {LiquidityWatcher} from "../src/LiquidityWatcher.sol";
import {LiquidityCache} from "../src/LiquidityCache.sol";
import {IPathfinder} from "../src/interfaces/IPathfinder.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

contract IntegrationExtrasTest is Test {
    using PoolIdLibrary for PoolKey;

    LiquidityCache internal cache;
    LiquidityWatcher internal watcher;
    Pathfinder internal hook;

    address internal constant TOKEN_A = address(0x1111);
    address internal constant TOKEN_B = address(0x2222);
    address internal constant TOKEN_C = address(0x3333);
    address internal constant POOL_MANAGER = address(0xDEAD);

    PoolKey internal key;
    bytes32 internal poolId;

    function setUp() external {
        cache = new LiquidityCache();
        watcher = new LiquidityWatcher(address(cache), address(0), address(0));
        cache.setWriter(address(watcher));
        hook = new Pathfinder(IPoolManager(POOL_MANAGER), cache);

        key = PoolKey({
            currency0: Currency.wrap(TOKEN_A),
            currency1: Currency.wrap(TOKEN_B),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = PoolId.unwrap(key.toId());

        hook.registerConfig(
            key,
            IPathfinder.PoolConfig({
                routingThreshold: 15,
                maxStaleness: 30,
                smallTradeLimit: 1_000,
                whaleTradeLimit: 1_000_000
            })
        );

        vm.prank(POOL_MANAGER);
        hook.afterInitialize(address(this), key, 0, 0);
    }

    function test_integration_localBestFlow() external {
        vm.warp(100);
        watcher.react(abi.encode(TOKEN_A, TOKEN_B, uint8(1), uint256(50)));
        watcher.react(abi.encode(TOKEN_A, TOKEN_B, uint8(2), uint256(60)));
        watcher.react(abi.encode(TOKEN_A, TOKEN_B, uint8(0), uint256(10)));

        _expectRoute(hook.CHAIN_UNICHAIN(), "local_best", 5_000);
    }

    function test_integration_belowThresholdFlow() external {
        vm.warp(100);
        watcher.react(abi.encode(TOKEN_A, TOKEN_B, uint8(0), uint256(30)));
        watcher.react(abi.encode(TOKEN_A, TOKEN_B, uint8(2), uint256(25)));
        watcher.react(abi.encode(TOKEN_A, TOKEN_B, uint8(1), uint256(20)));

        _expectRoute(hook.CHAIN_UNICHAIN(), "below_threshold", 5_000);
    }

    function test_integration_smallTradeFlow() external {
        vm.warp(100);
        watcher.react(abi.encode(TOKEN_A, TOKEN_B, uint8(0), uint256(100)));
        watcher.react(abi.encode(TOKEN_A, TOKEN_B, uint8(1), uint256(10)));

        _expectRoute(hook.CHAIN_UNICHAIN(), "small_trade", SMALL_LIMIT_MINUS_ONE());
    }

    function test_integration_whaleFlow() external {
        vm.warp(100);
        watcher.react(abi.encode(TOKEN_A, TOKEN_B, uint8(1), uint256(110)));
        watcher.react(abi.encode(TOKEN_A, TOKEN_B, uint8(0), uint256(100)));
        watcher.react(abi.encode(TOKEN_A, TOKEN_B, uint8(2), uint256(10)));

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(1_000_000),
            sqrtPriceLimitX96: 0
        });

        vm.expectEmit(true, false, false, true);
        emit Pathfinder.SwapRouted(poolId, hook.CHAIN_OPTIMISM(), "whale_route", 90);

        vm.prank(POOL_MANAGER);
        hook.beforeSwap(address(this), key, params, "");
    }

    function test_integration_pairIsolationAcrossWatcherAndCache() external {
        vm.warp(100);
        watcher.react(abi.encode(TOKEN_A, TOKEN_C, uint8(1), uint256(5)));

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(5_000),
            sqrtPriceLimitX96: 0
        });

        vm.expectEmit(true, false, false, true);
        emit Pathfinder.SwapRouted(poolId, hook.CHAIN_UNICHAIN(), "stale_data", 0);

        vm.prank(POOL_MANAGER);
        hook.beforeSwap(address(this), key, params, "");
    }

    function _expectRoute(uint8 destination, string memory reason, uint256 amount) internal {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: 0
        });

        vm.expectEmit(true, false, false, true);
        emit Pathfinder.SwapRouted(poolId, destination, reason, 0);

        vm.prank(POOL_MANAGER);
        hook.beforeSwap(address(this), key, params, "");
    }

    function SMALL_LIMIT_MINUS_ONE() internal pure returns (uint256) {
        return 999;
    }
}
