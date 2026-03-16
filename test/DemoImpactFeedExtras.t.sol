// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DemoImpactFeed} from "../src/DemoImpactFeed.sol";

contract DemoImpactFeedExtrasTest is Test {
    DemoImpactFeed internal baseFeed;
    DemoImpactFeed internal optimismFeed;

    address internal constant TOKEN_A = address(0xAAAA);
    address internal constant TOKEN_B = address(0xBBBB);
    address internal constant TOKEN_C = address(0xCCCC);

    function setUp() external {
        baseFeed = new DemoImpactFeed(1);
        optimismFeed = new DemoImpactFeed(2);
    }

    function test_optimismFeed_setsSourceChainTwo() external view {
        assertEq(optimismFeed.sourceChain(), 2);
    }

    function test_publishImpact_zeroImpactStillEmits() external {
        vm.expectEmit(false, false, false, true);
        emit DemoImpactFeed.ImpactUpdated(TOKEN_A, TOKEN_B, 1, 0);
        baseFeed.publishImpact(TOKEN_A, TOKEN_B, 0);
    }

    function test_publishImpact_onOptimismFeedUsesChainTwo() external {
        vm.expectEmit(false, false, false, true);
        emit DemoImpactFeed.ImpactUpdated(TOKEN_A, TOKEN_B, 2, 25);
        optimismFeed.publishImpact(TOKEN_A, TOKEN_B, 25);
    }

    function test_publishImpact_recordsIndependentEvents() external {
        vm.recordLogs();
        baseFeed.publishImpact(TOKEN_A, TOKEN_B, 10);
        baseFeed.publishImpact(TOKEN_A, TOKEN_C, 20);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 2);
    }

    function test_publishImpact_acceptsDifferentTokenPairs() external {
        vm.expectEmit(false, false, false, true);
        emit DemoImpactFeed.ImpactUpdated(TOKEN_A, TOKEN_C, 1, 77);
        baseFeed.publishImpact(TOKEN_A, TOKEN_C, 77);
    }

    function test_ownerDoesNotChangeAfterPublishing() external {
        address originalOwner = baseFeed.owner();
        baseFeed.publishImpact(TOKEN_A, TOKEN_B, 10);
        assertEq(baseFeed.owner(), originalOwner);
    }

    function test_baseFeed_remainsChainOneAfterMultiplePublishes() external {
        baseFeed.publishImpact(TOKEN_A, TOKEN_B, 10);
        baseFeed.publishImpact(TOKEN_B, TOKEN_C, 20);
        assertEq(baseFeed.sourceChain(), 1);
    }

    function test_optimismFeed_ownerMatchesDeployer() external view {
        assertEq(optimismFeed.owner(), address(this));
    }
}
