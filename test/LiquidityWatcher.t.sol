// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LiquidityWatcher} from "../src/LiquidityWatcher.sol";
import {LiquidityCache} from "../src/LiquidityCache.sol";
import {ILiquidityCache} from "../src/interfaces/ILiquidityCache.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";

contract LiquidityWatcherTest is Test {
    LiquidityCache internal cache;
    LiquidityWatcher internal watcher;

    address internal constant TOKEN_A = address(0x1111);
    address internal constant TOKEN_B = address(0x2222);
    address internal constant TOKEN_C = address(0x3333);

    function setUp() external {
        cache = new LiquidityCache();
        watcher = new LiquidityWatcher(address(cache));
        cache.setWriter(address(watcher));
    }

    function test_react_updatesBaseImpact() external {
        vm.warp(100);
        _react(TOKEN_A, TOKEN_B, 1, 20);

        ILiquidityCache.LiquiditySnapshot memory snapshot = watcher.getSnapshot(TOKEN_A, TOKEN_B);
        assertEq(snapshot.baseImpactBps, 20);
        assertEq(snapshot.timestamp, 100);
    }

    function test_react_updatesOptimismImpact() external {
        vm.warp(101);
        _react(TOKEN_A, TOKEN_B, 2, 34);

        ILiquidityCache.LiquiditySnapshot memory snapshot = watcher.getSnapshot(TOKEN_A, TOKEN_B);
        assertEq(snapshot.optimismImpactBps, 34);
        assertEq(snapshot.timestamp, 101);
    }

    function test_react_updatesUnichainImpact() external {
        vm.warp(102);
        _react(TOKEN_A, TOKEN_B, 0, 55);

        ILiquidityCache.LiquiditySnapshot memory snapshot = watcher.getSnapshot(TOKEN_A, TOKEN_B);
        assertEq(snapshot.unichainImpactBps, 55);
        assertEq(snapshot.timestamp, 102);
    }

    function test_react_pushesSnapshotWhenBestChainChanges() external {
        vm.warp(100);
        _react(TOKEN_A, TOKEN_B, 0, 50); // best=unichain

        vm.warp(110);
        _react(TOKEN_A, TOKEN_B, 1, 20); // best changes to base

        ILiquidityCache.LiquiditySnapshot memory written = cache.getSnapshot(TOKEN_A, TOKEN_B);
        assertEq(written.unichainImpactBps, 50);
        assertEq(written.baseImpactBps, 20);
        assertEq(written.timestamp, 110);

        (uint8 bestChain, uint256 bestImpact,, uint256 timestamp) =
            watcher.getBestChainSnapshot(TOKEN_A, TOKEN_B);
        assertEq(bestChain, 1);
        assertEq(bestImpact, 20);
        assertEq(timestamp, 110);
    }

    function test_reactivePath_emitsCallbackWhenBestChainChanges() external {
        vm.warp(500);

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: 84532,
            _contract: address(0xBEEF),
            topic_0: 0,
            topic_1: 0,
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(TOKEN_A, TOKEN_B, uint8(1), uint256(18)),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        bytes memory payload = abi.encodeCall(
            ILiquidityCache.writeSnapshot,
            (
                TOKEN_A,
                TOKEN_B,
                ILiquidityCache.LiquiditySnapshot({
                    unichainImpactBps: 0,
                    baseImpactBps: 18,
                    optimismImpactBps: 0,
                    timestamp: 500
                })
            )
        );

        vm.expectEmit(true, true, true, true);
        emit IReactive.Callback(1301, address(cache), 800_000, payload);

        watcher.react(log);
    }

    function test_react_doesNotPushWhenRankingUnchanged() external {
        vm.warp(200);
        _react(TOKEN_A, TOKEN_B, 0, 40); // write
        ILiquidityCache.LiquiditySnapshot memory firstWrite = cache.getSnapshot(TOKEN_A, TOKEN_B);

        vm.warp(250);
        _react(TOKEN_A, TOKEN_B, 0, 30); // ranking remains unichain => no write
        ILiquidityCache.LiquiditySnapshot memory secondRead = cache.getSnapshot(TOKEN_A, TOKEN_B);

        assertEq(firstWrite.timestamp, 200);
        assertEq(secondRead.timestamp, 200);
        assertEq(secondRead.unichainImpactBps, 40);
    }

    function test_timestampUpdatesOnEveryCacheWrite() external {
        vm.warp(300);
        _react(TOKEN_A, TOKEN_B, 0, 60); // write at 300
        assertEq(cache.getSnapshot(TOKEN_A, TOKEN_B).timestamp, 300);

        vm.warp(320);
        _react(TOKEN_A, TOKEN_B, 1, 25); // write at 320 due to ranking change
        assertEq(cache.getSnapshot(TOKEN_A, TOKEN_B).timestamp, 320);
    }

    function test_perPairIsolation() external {
        vm.warp(400);
        _react(TOKEN_A, TOKEN_B, 1, 22);
        _react(TOKEN_A, TOKEN_C, 2, 19);

        ILiquidityCache.LiquiditySnapshot memory pairAB = watcher.getSnapshot(TOKEN_A, TOKEN_B);
        ILiquidityCache.LiquiditySnapshot memory pairAC = watcher.getSnapshot(TOKEN_A, TOKEN_C);

        assertEq(pairAB.baseImpactBps, 22);
        assertEq(pairAB.optimismImpactBps, 0);
        assertEq(pairAC.baseImpactBps, 0);
        assertEq(pairAC.optimismImpactBps, 19);
    }

    function test_setCache_onlyOwner() external {
        vm.prank(address(0xBEEF));
        vm.expectRevert(LiquidityWatcher.Unauthorized.selector);
        watcher.setCache(address(0x1234));
    }

    function test_react_revertsOnInvalidChain() external {
        bytes memory payload = abi.encode(TOKEN_A, TOKEN_B, uint8(3), uint256(10));
        vm.expectRevert(LiquidityWatcher.InvalidChain.selector);
        watcher.react(payload);
    }

    function _react(address tokenA, address tokenB, uint8 chain, uint256 impactBps) internal {
        watcher.react(abi.encode(tokenA, tokenB, chain, impactBps));
    }
}
