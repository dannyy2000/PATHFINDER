// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {LiquidityWatcher} from "../src/LiquidityWatcher.sol";

/// @notice Deploys LiquidityWatcher on Reactive Lasna.
///         The constructor only needs the live LiquidityCache address on Unichain Sepolia.
///
/// Usage:
///   forge script script/DeployWatcher.s.sol \
///     --rpc-url reactive_lasna --broadcast -vvvv
contract DeployWatcher is Script {
    address internal constant UNICHAIN_SEPOLIA_CALLBACK_PROXY =
        0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4;

    function run() external {
        address cache = vm.envAddress("LIQUIDITY_CACHE_ADDRESS");
        address baseFeed = vm.envOr("MOCK_FEED_BASE", address(0));
        address optimismFeed = vm.envOr("MOCK_FEED_OPTIMISM", address(0));
        uint256 initialFunding = vm.envOr("INITIAL_WATCHER_FUNDS_WEI", uint256(0.1 ether));

        vm.startBroadcast();

        LiquidityWatcher watcher =
            new LiquidityWatcher{value: initialFunding}(cache, baseFeed, optimismFeed);

        vm.stopBroadcast();

        console.log("LiquidityWatcher deployed at:", address(watcher));
        console.log("LiquidityCache target:", cache);
        console.log("Base mock feed:", baseFeed);
        console.log("Optimism mock feed:", optimismFeed);
        console.log("Owner:", watcher.owner());
        console.log("Reactive watcher funding (wei):", initialFunding);
        console.log("");
        console.log("Daniel should call LiquidityCache.setWriter with the");
        console.log("Unichain Sepolia callback proxy address, not the watcher address:");
        console.logAddress(UNICHAIN_SEPOLIA_CALLBACK_PROXY);
    }
}
