// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {LiquidityCache} from "../src/LiquidityCache.sol";

/// @notice Authorizes the Reactive callback proxy to write snapshots into LiquidityCache.
///         Run this after Ola has deployed LiquidityWatcher and the callback proxy address is known.
///
/// Usage:
///   Broadcast:
///     forge script script/SetWriter.s.sol \
///       --rpc-url unichain_sepolia --broadcast --private-key $PRIVATE_KEY -vvvv
///
///   Fork test (no broadcast):
///     forge script script/SetWriter.s.sol \
///       --rpc-url unichain_sepolia -vvvv
contract SetWriter is Script {
    // From DEPLOYMENT.md
    address constant LIQUIDITY_CACHE   = 0x81f972eF7A8D5f5F043573A42cccA590DC8e203a;
    address constant CALLBACK_PROXY    = 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4;

    function run() external {
        LiquidityCache cache = LiquidityCache(LIQUIDITY_CACHE);

        console.log("LiquidityCache:  ", LIQUIDITY_CACHE);
        console.log("Authorizing:     ", CALLBACK_PROXY);
        console.log("Current writer:  ", cache.authorizedWriter());

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        cache.setWriter(CALLBACK_PROXY);
        vm.stopBroadcast();

        console.log("Done. authorizedWriter is now:", cache.authorizedWriter());
    }
}
