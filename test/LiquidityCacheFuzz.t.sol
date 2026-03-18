// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LiquidityCache} from "../src/LiquidityCache.sol";
import {ILiquidityCache} from "../src/interfaces/ILiquidityCache.sol";

/// @title LiquidityCacheFuzzTest
/// @notice Property-based tests for LiquidityCache. Each test encodes an invariant
///         that should hold for arbitrary token addresses and snapshot values.
contract LiquidityCacheFuzzTest is Test {
    LiquidityCache cache;

    function setUp() public {
        cache = new LiquidityCache();
        cache.setWriter(address(this)); // test contract is the authorized writer
    }

    // -------------------------------------------------------------------------
    // Invariant 1: getSnapshot is commutative — (a,b) and (b,a) always return
    //              the same snapshot because the pair key is normalized.
    // -------------------------------------------------------------------------

    function testFuzz_getSnapshot_isCommutative(
        address a,
        address b,
        uint256 uni,
        uint256 base,
        uint256 opt,
        uint256 ts
    ) public {
        vm.assume(a != b);

        cache.writeSnapshot(a, b, ILiquidityCache.LiquiditySnapshot({
            unichainImpactBps: uni,
            baseImpactBps:     base,
            optimismImpactBps: opt,
            timestamp:         ts
        }));

        ILiquidityCache.LiquiditySnapshot memory fwd = cache.getSnapshot(a, b);
        ILiquidityCache.LiquiditySnapshot memory rev = cache.getSnapshot(b, a);

        assertEq(fwd.unichainImpactBps,  rev.unichainImpactBps,  "unichain mismatch");
        assertEq(fwd.baseImpactBps,      rev.baseImpactBps,      "base mismatch");
        assertEq(fwd.optimismImpactBps,  rev.optimismImpactBps,  "optimism mismatch");
        assertEq(fwd.timestamp,          rev.timestamp,          "timestamp mismatch");
    }

    // -------------------------------------------------------------------------
    // Invariant 2: All four snapshot fields are persisted exactly as written —
    //              no truncation, no partial loss.
    // -------------------------------------------------------------------------

    function testFuzz_writeSnapshot_persistsAllFields(
        address a,
        address b,
        uint256 uni,
        uint256 base,
        uint256 opt,
        uint256 ts
    ) public {
        vm.assume(a != b);

        cache.writeSnapshot(a, b, ILiquidityCache.LiquiditySnapshot({
            unichainImpactBps: uni,
            baseImpactBps:     base,
            optimismImpactBps: opt,
            timestamp:         ts
        }));

        ILiquidityCache.LiquiditySnapshot memory snap = cache.getSnapshot(a, b);
        assertEq(snap.unichainImpactBps,  uni,  "unichain not persisted");
        assertEq(snap.baseImpactBps,      base, "base not persisted");
        assertEq(snap.optimismImpactBps,  opt,  "optimism not persisted");
        assertEq(snap.timestamp,          ts,   "timestamp not persisted");
    }

    // -------------------------------------------------------------------------
    // Invariant 3: The second write to the same pair always overwrites the first —
    //              there is no append, merge, or retention of old values.
    // -------------------------------------------------------------------------

    function testFuzz_multipleWrites_lastWins(
        address a,
        address b,
        uint256 val1,
        uint256 val2,
        uint256 ts1,
        uint256 ts2
    ) public {
        vm.assume(a != b);
        vm.assume(ts2 != ts1); // ensure we can distinguish the writes

        cache.writeSnapshot(a, b, ILiquidityCache.LiquiditySnapshot({
            unichainImpactBps: val1,
            baseImpactBps:     0,
            optimismImpactBps: 0,
            timestamp:         ts1
        }));
        cache.writeSnapshot(a, b, ILiquidityCache.LiquiditySnapshot({
            unichainImpactBps: val2,
            baseImpactBps:     0,
            optimismImpactBps: 0,
            timestamp:         ts2
        }));

        ILiquidityCache.LiquiditySnapshot memory snap = cache.getSnapshot(a, b);
        assertEq(snap.unichainImpactBps, val2, "should reflect last write");
        assertEq(snap.timestamp,         ts2,  "timestamp should be from last write");
    }

    // -------------------------------------------------------------------------
    // Invariant 4: Any address that is not the authorizedWriter cannot write —
    //              writeSnapshot always reverts for non-writers.
    // -------------------------------------------------------------------------

    function testFuzz_onlyAuthorizedWriter_canWrite(address attacker) public {
        vm.assume(attacker != address(this)); // address(this) is the current writer

        ILiquidityCache.LiquiditySnapshot memory snap = ILiquidityCache.LiquiditySnapshot({
            unichainImpactBps: 100,
            baseImpactBps:     50,
            optimismImpactBps: 75,
            timestamp:         block.timestamp
        });

        vm.prank(attacker);
        vm.expectRevert(LiquidityCache.Unauthorized.selector);
        cache.writeSnapshot(address(0x1), address(0x2), snap);
    }

    // -------------------------------------------------------------------------
    // Invariant 5: Pair slots are fully isolated — writing pair (a,b) never
    //              affects the snapshot stored for a different pair (c,d).
    // -------------------------------------------------------------------------

    function testFuzz_pairIsolation_writingOneDoesNotAffectAnother(
        address a, address b,
        address c, address d,
        uint256 uni1, uint256 uni2
    ) public {
        vm.assume(a != b);
        vm.assume(c != d);
        // Ensure the two pairs are distinct (their normalized keys differ)
        (address lo1, address hi1) = a < b ? (a, b) : (b, a);
        (address lo2, address hi2) = c < d ? (c, d) : (d, c);
        vm.assume(lo1 != lo2 || hi1 != hi2);
        vm.assume(uni1 != uni2); // make values distinguishable

        cache.writeSnapshot(a, b, ILiquidityCache.LiquiditySnapshot({
            unichainImpactBps: uni1, baseImpactBps: 0, optimismImpactBps: 0, timestamp: 1
        }));
        cache.writeSnapshot(c, d, ILiquidityCache.LiquiditySnapshot({
            unichainImpactBps: uni2, baseImpactBps: 0, optimismImpactBps: 0, timestamp: 2
        }));

        ILiquidityCache.LiquiditySnapshot memory snap1 = cache.getSnapshot(a, b);
        ILiquidityCache.LiquiditySnapshot memory snap2 = cache.getSnapshot(c, d);

        assertEq(snap1.unichainImpactBps, uni1, "pair 1 was modified");
        assertEq(snap2.unichainImpactBps, uni2, "pair 2 was modified");
    }

    // -------------------------------------------------------------------------
    // Invariant 6: setWriter can only be called by the deployer — any other
    //              caller is rejected regardless of who the current writer is.
    // -------------------------------------------------------------------------

    function testFuzz_setWriter_onlyDeployer(address caller, address newWriter) public {
        vm.assume(caller != address(this)); // address(this) is the deployer

        vm.prank(caller);
        vm.expectRevert(LiquidityCache.Unauthorized.selector);
        cache.setWriter(newWriter);
    }
}
