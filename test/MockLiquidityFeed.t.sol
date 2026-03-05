// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockLiquidityFeed} from "../src/MockLiquidityFeed.sol";
import {ILiquidityCache} from "../src/interfaces/ILiquidityCache.sol";

contract MockLiquidityFeedTest is Test {
    MockLiquidityFeed internal feed;

    address internal constant TOKEN_A = address(0x1111);
    address internal constant TOKEN_B = address(0x2222);

    function setUp() external {
        feed = new MockLiquidityFeed();
    }

    function test_setSnapshot_readsBackSnapshot() external {
        ILiquidityCache.LiquiditySnapshot memory snapshot = ILiquidityCache.LiquiditySnapshot({
            unichainImpactBps: 50,
            baseImpactBps: 20,
            optimismImpactBps: 35,
            timestamp: 1_700_000_000
        });

        feed.setSnapshot(TOKEN_A, TOKEN_B, snapshot);
        ILiquidityCache.LiquiditySnapshot memory read = feed.getSnapshot(TOKEN_A, TOKEN_B);

        assertEq(read.unichainImpactBps, 50);
        assertEq(read.baseImpactBps, 20);
        assertEq(read.optimismImpactBps, 35);
        assertEq(read.timestamp, 1_700_000_000);
    }

    function test_writeSnapshot_normalizesTokenOrder() external {
        ILiquidityCache.LiquiditySnapshot memory snapshot = ILiquidityCache.LiquiditySnapshot({
            unichainImpactBps: 42,
            baseImpactBps: 17,
            optimismImpactBps: 19,
            timestamp: block.timestamp
        });

        feed.writeSnapshot(TOKEN_A, TOKEN_B, snapshot);
        ILiquidityCache.LiquiditySnapshot memory reverseRead = feed.getSnapshot(TOKEN_B, TOKEN_A);

        assertEq(reverseRead.unichainImpactBps, 42);
        assertEq(reverseRead.baseImpactBps, 17);
        assertEq(reverseRead.optimismImpactBps, 19);
    }
}
