// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockLiquidityFeed} from "../src/MockLiquidityFeed.sol";
import {ILiquidityCache} from "../src/interfaces/ILiquidityCache.sol";

contract MockLiquidityFeedExtrasTest is Test {
    MockLiquidityFeed internal feed;

    address internal constant TOKEN_A = address(0xAAAA);
    address internal constant TOKEN_B = address(0xBBBB);
    address internal constant TOKEN_C = address(0xCCCC);

    function setUp() external {
        feed = new MockLiquidityFeed();
    }

    function test_getSnapshot_returnsZeroWhenUnset() external view {
        ILiquidityCache.LiquiditySnapshot memory snapshot = feed.getSnapshot(TOKEN_A, TOKEN_B);
        assertEq(snapshot.timestamp, 0);
    }

    function test_setSnapshot_overwritesPreviousValue() external {
        feed.setSnapshot(TOKEN_A, TOKEN_B, _snapshot(1, 2, 3, 10));
        feed.setSnapshot(TOKEN_A, TOKEN_B, _snapshot(4, 5, 6, 20));

        assertEq(feed.getSnapshot(TOKEN_A, TOKEN_B).timestamp, 20);
        assertEq(feed.getSnapshot(TOKEN_A, TOKEN_B).baseImpactBps, 5);
    }

    function test_writeSnapshot_overwritesPreviousValue() external {
        feed.writeSnapshot(TOKEN_A, TOKEN_B, _snapshot(1, 2, 3, 10));
        feed.writeSnapshot(TOKEN_A, TOKEN_B, _snapshot(7, 8, 9, 30));

        assertEq(feed.getSnapshot(TOKEN_A, TOKEN_B).timestamp, 30);
        assertEq(feed.getSnapshot(TOKEN_A, TOKEN_B).optimismImpactBps, 9);
    }

    function test_setSnapshot_normalizesReverseOrder() external {
        feed.setSnapshot(TOKEN_B, TOKEN_A, _snapshot(11, 22, 33, 44));
        assertEq(feed.getSnapshot(TOKEN_A, TOKEN_B).timestamp, 44);
    }

    function test_writeSnapshot_normalizesReverseOrder() external {
        feed.writeSnapshot(TOKEN_B, TOKEN_A, _snapshot(11, 22, 33, 55));
        assertEq(feed.getSnapshot(TOKEN_A, TOKEN_B).timestamp, 55);
    }

    function test_setSnapshot_and_writeSnapshot_shareSameStorage() external {
        feed.setSnapshot(TOKEN_A, TOKEN_B, _snapshot(1, 2, 3, 10));
        feed.writeSnapshot(TOKEN_A, TOKEN_B, _snapshot(7, 8, 9, 20));

        ILiquidityCache.LiquiditySnapshot memory snapshot = feed.getSnapshot(TOKEN_A, TOKEN_B);
        assertEq(snapshot.unichainImpactBps, 7);
        assertEq(snapshot.timestamp, 20);
    }

    function test_pairIsolation_acrossMultiplePairs() external {
        feed.setSnapshot(TOKEN_A, TOKEN_B, _snapshot(1, 2, 3, 10));
        feed.setSnapshot(TOKEN_A, TOKEN_C, _snapshot(4, 5, 6, 20));

        assertEq(feed.getSnapshot(TOKEN_A, TOKEN_B).timestamp, 10);
        assertEq(feed.getSnapshot(TOKEN_A, TOKEN_C).timestamp, 20);
    }

    function test_snapshotCanStoreAllZeroFields() external {
        feed.setSnapshot(TOKEN_A, TOKEN_B, _snapshot(0, 0, 0, 0));
        assertEq(feed.getSnapshot(TOKEN_A, TOKEN_B).baseImpactBps, 0);
    }

    function test_reverseReadMatchesAfterWriteSnapshot() external {
        feed.writeSnapshot(TOKEN_A, TOKEN_B, _snapshot(3, 4, 5, 6));
        assertEq(feed.getSnapshot(TOKEN_B, TOKEN_A).optimismImpactBps, 5);
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
