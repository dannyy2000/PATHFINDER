// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {DemoImpactFeed} from "../src/DemoImpactFeed.sol";

/// @notice Deploys demo impact feeds on Base Sepolia and Optimism Sepolia.
///         Run once per chain with the matching `TARGET_CHAIN` env value.
///
/// Example:
///   TARGET_CHAIN=base forge script script/DeployMocks.s.sol --rpc-url $BASE_SEPOLIA_RPC --broadcast
///   TARGET_CHAIN=optimism forge script script/DeployMocks.s.sol --rpc-url $OPTIMISM_SEPOLIA_RPC --broadcast
contract DeployMocks is Script {
    uint8 internal constant CHAIN_BASE = 1;
    uint8 internal constant CHAIN_OPTIMISM = 2;

    function run() external {
        string memory target = vm.envString("TARGET_CHAIN");
        (uint8 sourceChain, string memory label) = _targetConfig(target);

        vm.startBroadcast();
        DemoImpactFeed feed = new DemoImpactFeed(sourceChain);
        vm.stopBroadcast();

        console.log(label, "DemoImpactFeed deployed at:", address(feed));
        console.log("Source chain tag:", sourceChain);
    }

    function _targetConfig(string memory target) internal pure returns (uint8 sourceChain, string memory label) {
        bytes32 targetHash = keccak256(bytes(target));

        if (targetHash == keccak256("base")) {
            return (CHAIN_BASE, "Base Sepolia");
        }
        if (targetHash == keccak256("optimism")) {
            return (CHAIN_OPTIMISM, "Optimism Sepolia");
        }

        revert("TARGET_CHAIN must be base or optimism");
    }
}
