// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {Pathfinder} from "../src/Pathfinder.sol";
import {IPathfinder} from "../src/interfaces/IPathfinder.sol";
import {ILiquidityCache} from "../src/interfaces/ILiquidityCache.sol";

/// @dev Single-slot feed — returns one fixed snapshot for any pair.
///      Simpler than a keyed mock for fuzz scenarios where pair identity doesn't matter.
contract SingleSlotFeed is ILiquidityCache {
    LiquiditySnapshot private _snap;

    function set(LiquiditySnapshot calldata s) external { _snap = s; }

    function getSnapshot(address, address) external view returns (LiquiditySnapshot memory) {
        return _snap;
    }

    function writeSnapshot(address, address, LiquiditySnapshot calldata) external {}
}

/// @title PathfinderFuzzTest
/// @notice Property-based tests that verify high-level routing invariants hold for
///         arbitrary inputs. Each test encodes a claim about how Pathfinder must
///         behave across the full input space.
contract PathfinderFuzzTest is Test {
    using PoolIdLibrary for PoolKey;

    SingleSlotFeed feed;
    Pathfinder hook;

    address constant POOL_MANAGER = address(0xDEAD);
    address constant TOKEN_A      = address(0x1000);
    address constant TOKEN_B      = address(0x2000);

    uint256 constant THRESHOLD     = 15;
    uint256 constant MAX_STALENESS = 60;
    uint256 constant SMALL_LIMIT   = 1_000;
    uint256 constant WHALE_LIMIT   = 1_000_000;

    PoolKey  key;
    bytes32  poolId;

    function setUp() public {
        feed = new SingleSlotFeed();
        hook = new Pathfinder(IPoolManager(POOL_MANAGER), ILiquidityCache(address(feed)));

        key = PoolKey({
            currency0:   Currency.wrap(TOKEN_A),
            currency1:   Currency.wrap(TOKEN_B),
            fee:         3000,
            tickSpacing: 60,
            hooks:       IHooks(address(hook))
        });
        poolId = PoolId.unwrap(key.toId());

        hook.registerConfig(key, IPathfinder.PoolConfig({
            routingThreshold: THRESHOLD,
            maxStaleness:     MAX_STALENESS,
            smallTradeLimit:  SMALL_LIMIT,
            whaleTradeLimit:  WHALE_LIMIT
        }));
        vm.prank(POOL_MANAGER);
        hook.afterInitialize(address(this), key, 0, 0);
    }

    // -------------------------------------------------------------------------
    // Invariant 1: When Unichain already has the best (or equal) price impact,
    //              the swap ALWAYS executes locally — never cross-chain.
    // -------------------------------------------------------------------------

    function testFuzz_unichainIsBest_alwaysExecutesLocally(
        uint256 uni,
        uint256 base,
        uint256 opt,
        uint256 amount
    ) public {
        // Unichain has the lowest (or equal) impact
        uni    = bound(uni,    0, 5_000);
        base   = bound(base,   uni, 10_000);
        opt    = bound(opt,    uni, 10_000);
        // Medium-sized trade: not small, not whale
        amount = bound(amount, SMALL_LIMIT, WHALE_LIMIT - 1);

        feed.set(ILiquidityCache.LiquiditySnapshot({
            unichainImpactBps: uni,
            baseImpactBps:     base,
            optimismImpactBps: opt,
            timestamp:         block.timestamp
        }));

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: 0
        });

        vm.recordLogs();
        vm.prank(POOL_MANAGER);
        hook.beforeSwap(address(this), key, params, "");

        // Extract SwapRouted event and assert destination is CHAIN_UNICHAIN (0)
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("SwapRouted(bytes32,uint8,string,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                (uint8 destination,,) = abi.decode(logs[i].data, (uint8, string, uint256));
                assertEq(destination, hook.CHAIN_UNICHAIN(), "should route locally when unichain is best");
                return;
            }
        }
        fail(); // SwapRouted must always be emitted
    }

    // -------------------------------------------------------------------------
    // Invariant 2: Small trades ALWAYS execute locally regardless of how much
    //              better a cross-chain venue is.
    // -------------------------------------------------------------------------

    function testFuzz_smallTrade_alwaysLocal(uint256 amount, uint256 uni, uint256 base) public {
        // Trade is below the small trade limit
        amount = bound(amount, 1, SMALL_LIMIT - 1);
        // Cross-chain is clearly better to ensure the threshold isn't what's stopping routing
        uni  = bound(uni,  THRESHOLD + 1, 10_000);
        base = bound(base, 0, uni - THRESHOLD - 1);

        feed.set(ILiquidityCache.LiquiditySnapshot({
            unichainImpactBps: uni,
            baseImpactBps:     base,
            optimismImpactBps: uni + 1, // optimism is worse
            timestamp:         block.timestamp
        }));

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: 0
        });

        vm.expectEmit(true, false, false, true);
        emit Pathfinder.SwapRouted(poolId, hook.CHAIN_UNICHAIN(), "small_trade", 0);

        vm.prank(POOL_MANAGER);
        hook.beforeSwap(address(this), key, params, "");
    }

    // -------------------------------------------------------------------------
    // Invariant 3: Whale trades ALWAYS route to the best cross-chain venue
    //              when that venue has strictly lower impact than Unichain.
    // -------------------------------------------------------------------------

    function testFuzz_whaleTrade_alwaysRoutesCrossChain(uint256 uni, uint256 base) public {
        // Base is strictly better than Unichain
        uni  = bound(uni,  1, 10_000);
        base = bound(base, 0, uni - 1);

        feed.set(ILiquidityCache.LiquiditySnapshot({
            unichainImpactBps: uni,
            baseImpactBps:     base,
            optimismImpactBps: uni + 1, // optimism worse than unichain so base wins
            timestamp:         block.timestamp
        }));

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(WHALE_LIMIT), // at exactly the whale limit
            sqrtPriceLimitX96: 0
        });

        uint256 expectedImprovement = uni - base;

        vm.expectEmit(true, false, false, true);
        emit Pathfinder.SwapRouted(poolId, hook.CHAIN_BASE(), "whale_route", expectedImprovement);

        vm.prank(POOL_MANAGER);
        hook.beforeSwap(address(this), key, params, "");
    }

    // -------------------------------------------------------------------------
    // Invariant 4: Stale cache data ALWAYS falls back to local execution,
    //              no matter how attractive the cross-chain venue appears.
    // -------------------------------------------------------------------------

    function testFuzz_staleData_alwaysLocal(
        uint256 excessAge,
        uint256 uni,
        uint256 base
    ) public {
        // Snapshot is older than maxStaleness
        excessAge = bound(excessAge, 1, 10_000);
        uni  = bound(uni,  1, 10_000);
        base = bound(base, 0, 10_000);

        uint256 snapshotAge = MAX_STALENESS + excessAge;
        vm.warp(snapshotAge + 1);

        feed.set(ILiquidityCache.LiquiditySnapshot({
            unichainImpactBps: uni,
            baseImpactBps:     base,
            optimismImpactBps: base,
            timestamp:         block.timestamp - snapshotAge
        }));

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -int256(SMALL_LIMIT + 1), sqrtPriceLimitX96: 0
        });

        vm.expectEmit(true, false, false, true);
        emit Pathfinder.SwapRouted(poolId, hook.CHAIN_UNICHAIN(), "stale_data", 0);

        vm.prank(POOL_MANAGER);
        hook.beforeSwap(address(this), key, params, "");
    }

    // -------------------------------------------------------------------------
    // Invariant 5: registerConfig stores all four fields with exact precision —
    //              no truncation, no default override when both fields are non-zero.
    // -------------------------------------------------------------------------

    function testFuzz_configRoundtrip(
        uint256 threshold,
        uint256 staleness,
        uint256 small,
        uint256 whale
    ) public {
        // Both threshold and staleness must be non-zero to avoid default override
        threshold = bound(threshold, 1, type(uint128).max);
        staleness = bound(staleness, 1, type(uint128).max);

        Pathfinder h = new Pathfinder(IPoolManager(POOL_MANAGER), ILiquidityCache(address(feed)));
        PoolKey memory k = PoolKey({
            currency0:   Currency.wrap(address(0x7000)),
            currency1:   Currency.wrap(address(0x8000)),
            fee:         500,
            tickSpacing: 10,
            hooks:       IHooks(address(h))
        });
        bytes32 pid = PoolId.unwrap(k.toId());

        h.registerConfig(k, IPathfinder.PoolConfig({
            routingThreshold: threshold,
            maxStaleness:     staleness,
            smallTradeLimit:  small,
            whaleTradeLimit:  whale
        }));
        vm.prank(POOL_MANAGER);
        h.afterInitialize(address(this), k, 0, 0);

        IPathfinder.PoolConfig memory cfg = h.getPoolConfig(pid);
        assertEq(cfg.routingThreshold, threshold, "threshold mismatch");
        assertEq(cfg.maxStaleness,     staleness,  "staleness mismatch");
        assertEq(cfg.smallTradeLimit,  small,      "smallLimit mismatch");
        assertEq(cfg.whaleTradeLimit,  whale,      "whaleLimit mismatch");
    }

    // -------------------------------------------------------------------------
    // Invariant 6: Below-threshold improvements ALWAYS execute locally when
    //              the trade is in the medium range (not small, not whale).
    // -------------------------------------------------------------------------

    function testFuzz_belowThreshold_alwaysLocal(uint256 improvement, uint256 amount) public {
        // Improvement is <= routingThreshold (15 bps)
        improvement = bound(improvement, 0, THRESHOLD);
        uint256 uni  = bound(improvement + 50, 50, 10_000);
        uint256 base = uni - improvement; // exactly `improvement` bps better
        amount = bound(amount, SMALL_LIMIT, WHALE_LIMIT - 1);

        feed.set(ILiquidityCache.LiquiditySnapshot({
            unichainImpactBps: uni,
            baseImpactBps:     base,
            optimismImpactBps: uni + 1, // optimism is worse
            timestamp:         block.timestamp
        }));

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: 0
        });

        vm.recordLogs();
        vm.prank(POOL_MANAGER);
        hook.beforeSwap(address(this), key, params, "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("SwapRouted(bytes32,uint8,string,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                (uint8 destination,,) = abi.decode(logs[i].data, (uint8, string, uint256));
                assertEq(destination, hook.CHAIN_UNICHAIN(), "below-threshold must stay local");
                return;
            }
        }
        fail();
    }
}
