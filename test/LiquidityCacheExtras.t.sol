// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LiquidityCache} from "../src/LiquidityCache.sol";
import {ILiquidityCache} from "../src/interfaces/ILiquidityCache.sol";

contract LiquidityCacheExtrasTest is Test {
    LiquidityCache internal cache;

    address internal constant TOKEN_A = address(0xAAAA);
    address internal constant TOKEN_B = address(0xBBBB);
    address internal constant TOKEN_C = address(0xCCCC);
    address internal constant WRITER_ONE = address(0x1111);
    address internal constant WRITER_TWO = address(0x2222);

    function setUp() external {
        cache = new LiquidityCache();
    }

    function test_setWriter_canSetZeroAddress() external {
        cache.setWriter(address(0));
        assertEq(cache.authorizedWriter(), address(0));
    }

    function test_setWriter_overwritesExistingWriterAndEmitsOldWriter() external {
        cache.setWriter(WRITER_ONE);

        vm.expectEmit(true, true, false, true);
        emit LiquidityCache.WriterUpdated(WRITER_ONE, WRITER_TWO);

        cache.setWriter(WRITER_TWO);

        assertEq(cache.authorizedWriter(), WRITER_TWO);
    }

    function test_oldWriterLosesAccessAfterWriterRotation() external {
        cache.setWriter(WRITER_ONE);
        cache.setWriter(WRITER_TWO);

        vm.prank(WRITER_ONE);
        vm.expectRevert(LiquidityCache.Unauthorized.selector);
        cache.writeSnapshot(TOKEN_A, TOKEN_B, _snapshot(1, 2, 3, 4));
    }

    function test_newWriterCanWriteAfterWriterRotation() external {
        cache.setWriter(WRITER_ONE);
        cache.setWriter(WRITER_TWO);

        vm.prank(WRITER_TWO);
        cache.writeSnapshot(TOKEN_A, TOKEN_B, _snapshot(1, 2, 3, 4));

        assertEq(cache.getSnapshot(TOKEN_A, TOKEN_B).timestamp, 4);
    }

    function test_writeSnapshot_supportsZeroValuedSnapshot() external {
        cache.setWriter(WRITER_ONE);

        vm.prank(WRITER_ONE);
        cache.writeSnapshot(TOKEN_A, TOKEN_B, _snapshot(0, 0, 0, 0));

        ILiquidityCache.LiquiditySnapshot memory snapshot = cache.getSnapshot(TOKEN_A, TOKEN_B);
        assertEq(snapshot.timestamp, 0);
    }

    function test_getSnapshot_reverseOrderUnsetPairIsStillZero() external view {
        ILiquidityCache.LiquiditySnapshot memory snapshot = cache.getSnapshot(TOKEN_B, TOKEN_A);
        assertEq(snapshot.unichainImpactBps, 0);
        assertEq(snapshot.baseImpactBps, 0);
        assertEq(snapshot.optimismImpactBps, 0);
        assertEq(snapshot.timestamp, 0);
    }

    function test_writeSnapshot_isolatedAcrossMultiplePairs() external {
        cache.setWriter(WRITER_ONE);

        vm.startPrank(WRITER_ONE);
        cache.writeSnapshot(TOKEN_A, TOKEN_B, _snapshot(10, 20, 30, 100));
        cache.writeSnapshot(TOKEN_A, TOKEN_C, _snapshot(40, 50, 60, 200));
        vm.stopPrank();

        assertEq(cache.getSnapshot(TOKEN_A, TOKEN_B).timestamp, 100);
        assertEq(cache.getSnapshot(TOKEN_A, TOKEN_C).timestamp, 200);
    }

    function test_unauthorizedWriterCannotOverwriteExistingSnapshot() external {
        cache.setWriter(WRITER_ONE);

        vm.prank(WRITER_ONE);
        cache.writeSnapshot(TOKEN_A, TOKEN_B, _snapshot(10, 20, 30, 100));

        vm.prank(address(0xDEAD));
        vm.expectRevert(LiquidityCache.Unauthorized.selector);
        cache.writeSnapshot(TOKEN_A, TOKEN_B, _snapshot(40, 50, 60, 200));

        assertEq(cache.getSnapshot(TOKEN_A, TOKEN_B).timestamp, 100);
    }

    function test_resettingWriterToZeroBlocksFormerWriter() external {
        cache.setWriter(WRITER_ONE);
        cache.setWriter(address(0));

        vm.prank(WRITER_ONE);
        vm.expectRevert(LiquidityCache.Unauthorized.selector);
        cache.writeSnapshot(TOKEN_A, TOKEN_B, _snapshot(1, 2, 3, 4));
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
