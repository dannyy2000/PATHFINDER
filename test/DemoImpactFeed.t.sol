// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DemoImpactFeed} from "../src/DemoImpactFeed.sol";

contract DemoImpactFeedTest is Test {
    DemoImpactFeed internal baseFeed;

    address internal constant TOKEN_A = address(0x1111);
    address internal constant TOKEN_B = address(0x2222);

    function setUp() external {
        baseFeed = new DemoImpactFeed(1);
    }

    function test_constructor_setsOwnerAndSourceChain() external view {
        assertEq(baseFeed.owner(), address(this));
        assertEq(baseFeed.sourceChain(), 1);
    }

    function test_publishImpact_emitsConfiguredChain() external {
        vm.expectEmit(false, false, false, true);
        emit DemoImpactFeed.ImpactUpdated(TOKEN_A, TOKEN_B, 1, 22);

        baseFeed.publishImpact(TOKEN_A, TOKEN_B, 22);
    }

    function test_publishImpact_onlyOwner() external {
        vm.prank(address(0xBEEF));
        vm.expectRevert(DemoImpactFeed.Unauthorized.selector);
        baseFeed.publishImpact(TOKEN_A, TOKEN_B, 22);
    }

    function test_constructor_revertsOnInvalidChain() external {
        vm.expectRevert(DemoImpactFeed.InvalidChain.selector);
        new DemoImpactFeed(0);
    }

    function test_constructor_revertsWhenChainIsAboveSupportedRange() external {
        vm.expectRevert(DemoImpactFeed.InvalidChain.selector);
        new DemoImpactFeed(3);
    }
}
