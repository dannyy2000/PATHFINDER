// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LiquidityCache} from "../src/LiquidityCache.sol";
import {ILiquidityCache} from "../src/interfaces/ILiquidityCache.sol";

contract LiquidityCacheTest is Test {
    LiquidityCache internal cache;

    address internal constant TOKEN_A = address(0x1111);
    address internal constant TOKEN_B = address(0x2222);
    address internal constant WRITER = address(0xBEEF);

    function setUp() external {
        cache = new LiquidityCache();
    }

    function test_constructor_setsDeployer() external view {
        assertEq(cache.deployer(), address(this));
    }

    function test_setWriter_updatesAuthorizedWriter() external {
        vm.expectEmit(true, true, false, true);
        emit LiquidityCache.WriterUpdated(address(0), WRITER);

        cache.setWriter(WRITER);

        assertEq(cache.authorizedWriter(), WRITER);
    }

    function test_setWriter_onlyDeployer() external {
        vm.prank(address(0xCAFE));
        vm.expectRevert(LiquidityCache.Unauthorized.selector);
        cache.setWriter(WRITER);
    }

    function test_getSnapshot_returnsZeroStructWhenUnset() external view {
        ILiquidityCache.LiquiditySnapshot memory snapshot = cache.getSnapshot(TOKEN_A, TOKEN_B);

        assertEq(snapshot.unichainImpactBps, 0);
        assertEq(snapshot.baseImpactBps, 0);
        assertEq(snapshot.optimismImpactBps, 0);
        assertEq(snapshot.timestamp, 0);
    }

    function test_writeSnapshot_onlyAuthorizedWriter() external {
        ILiquidityCache.LiquiditySnapshot memory snapshot = _snapshot(10, 20, 30, 100);

        vm.expectRevert(LiquidityCache.Unauthorized.selector);
        cache.writeSnapshot(TOKEN_A, TOKEN_B, snapshot);
    }

    function test_writeSnapshot_persistsData() external {
        cache.setWriter(WRITER);

        ILiquidityCache.LiquiditySnapshot memory snapshot = _snapshot(10, 20, 30, 100);

        vm.expectEmit(true, true, false, true);
        emit LiquidityCache.SnapshotWritten(TOKEN_A, TOKEN_B, 100);

        vm.prank(WRITER);
        cache.writeSnapshot(TOKEN_A, TOKEN_B, snapshot);

        ILiquidityCache.LiquiditySnapshot memory written = cache.getSnapshot(TOKEN_A, TOKEN_B);
        assertEq(written.unichainImpactBps, 10);
        assertEq(written.baseImpactBps, 20);
        assertEq(written.optimismImpactBps, 30);
        assertEq(written.timestamp, 100);
    }

    function test_writeSnapshot_normalizesTokenOrder() external {
        cache.setWriter(WRITER);

        ILiquidityCache.LiquiditySnapshot memory snapshot = _snapshot(11, 22, 33, 123);

        vm.prank(WRITER);
        cache.writeSnapshot(TOKEN_B, TOKEN_A, snapshot);

        ILiquidityCache.LiquiditySnapshot memory readForward = cache.getSnapshot(TOKEN_A, TOKEN_B);
        ILiquidityCache.LiquiditySnapshot memory readReverse = cache.getSnapshot(TOKEN_B, TOKEN_A);

        assertEq(readForward.baseImpactBps, 22);
        assertEq(readReverse.baseImpactBps, 22);
        assertEq(readForward.timestamp, 123);
        assertEq(readReverse.timestamp, 123);
    }

    function test_writeSnapshot_overwritesPreviousSnapshot() external {
        cache.setWriter(WRITER);

        vm.startPrank(WRITER);
        cache.writeSnapshot(TOKEN_A, TOKEN_B, _snapshot(10, 20, 30, 100));
        cache.writeSnapshot(TOKEN_A, TOKEN_B, _snapshot(40, 50, 60, 200));
        vm.stopPrank();

        ILiquidityCache.LiquiditySnapshot memory written = cache.getSnapshot(TOKEN_A, TOKEN_B);
        assertEq(written.unichainImpactBps, 40);
        assertEq(written.baseImpactBps, 50);
        assertEq(written.optimismImpactBps, 60);
        assertEq(written.timestamp, 200);
    }

    /// @dev Deployer is NOT automatically the authorized writer — initial writer is address(0)
    function test_deployer_isNotAutomaticallyWriter() external {
        assertEq(cache.authorizedWriter(), address(0));

        // Deployer calling writeSnapshot before setWriter must revert
        vm.expectRevert(LiquidityCache.Unauthorized.selector);
        cache.writeSnapshot(TOKEN_A, TOKEN_B, _snapshot(1, 2, 3, 4));
    }

    /// @dev Deployer can call setWriter(self) and then write normally
    function test_deployer_canSetSelfAsWriter() external {
        cache.setWriter(address(this));
        assertEq(cache.authorizedWriter(), address(this));

        cache.writeSnapshot(TOKEN_A, TOKEN_B, _snapshot(10, 20, 30, 100));
        ILiquidityCache.LiquiditySnapshot memory snap = cache.getSnapshot(TOKEN_A, TOKEN_B);
        assertEq(snap.unichainImpactBps, 10);
    }

    /// @dev setWriter emits WriterUpdated with old and new addresses
    function test_setWriter_emitsOldAndNewWriter() external {
        cache.setWriter(WRITER);

        address newWriter = address(0xABCD);
        vm.expectEmit(true, true, false, false);
        emit LiquidityCache.WriterUpdated(WRITER, newWriter);
        cache.setWriter(newWriter);

        assertEq(cache.authorizedWriter(), newWriter);
    }

    /// @dev writeSnapshot emits SnapshotWritten with correct tokenA, tokenB, timestamp
    function test_writeSnapshot_emitsCorrectEvent() external {
        cache.setWriter(WRITER);

        vm.expectEmit(true, true, false, true);
        emit LiquidityCache.SnapshotWritten(TOKEN_A, TOKEN_B, 999);

        vm.prank(WRITER);
        cache.writeSnapshot(TOKEN_A, TOKEN_B, _snapshot(5, 10, 15, 999));
    }

    /// @dev getSnapshot for an unwritten pair returns all-zero struct — no partial data leaks
    function test_getSnapshot_unknownPairIsFullyZero() external view {
        ILiquidityCache.LiquiditySnapshot memory snap =
            cache.getSnapshot(address(0xAAAA), address(0xBBBB));
        assertEq(snap.unichainImpactBps, 0);
        assertEq(snap.baseImpactBps, 0);
        assertEq(snap.optimismImpactBps, 0);
        assertEq(snap.timestamp, 0);
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
