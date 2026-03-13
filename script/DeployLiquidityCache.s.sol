// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {LiquidityCache} from "../src/LiquidityCache.sol";

/// @notice Deploys LiquidityCache on Unichain.
///         After deployment, call setWriter(watcherCallbackAddress) once
///         Ola has deployed LiquidityWatcher on Reactive.
///
/// Usage:
///   Deploy (broadcast):
///     forge script script/DeployLiquidityCache.s.sol \
///       --rpc-url unichain_sepolia --broadcast --verify -vvvv
///
///   Fork test (no broadcast):
///     forge script script/DeployLiquidityCache.s.sol \
///       --rpc-url unichain_sepolia -vvvv
contract DeployLiquidityCache is Script {
    function run() external {
        vm.startBroadcast();

        LiquidityCache cache = new LiquidityCache();

        vm.stopBroadcast();

        console.log("LiquidityCache deployed at:", address(cache));
        console.log("Deployer (owner):", cache.deployer());
        console.log("");
        console.log("Next step: once Ola deploys LiquidityWatcher,");
        console.log("call cache.setWriter(<watcher callback address>)");
    }
}
