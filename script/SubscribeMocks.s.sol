// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ILiquidityWatcher} from "../src/interfaces/ILiquidityWatcher.sol";

/// @notice Registers the demo Base and Optimism feed subscriptions on the live Reactive watcher.
contract SubscribeMocks is Script {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 internal constant OPTIMISM_SEPOLIA_CHAIN_ID = 11155420;
    uint256 internal constant REACTIVE_IGNORE =
        0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    uint256 internal constant IMPACT_UPDATED_TOPIC0 =
        uint256(keccak256("ImpactUpdated(address,address,uint8,uint256)"));

    function run() external {
        address watcherAddress = vm.envAddress("REACTIVE_LIQUIDITY_WATCHER_ADDRESS");
        address baseFeed = vm.envAddress("MOCK_FEED_BASE");
        address optimismFeed = vm.envAddress("MOCK_FEED_OPTIMISM");

        ILiquidityWatcher watcher = ILiquidityWatcher(watcherAddress);

        vm.startBroadcast();
        watcher.subscribe(
            BASE_SEPOLIA_CHAIN_ID,
            baseFeed,
            IMPACT_UPDATED_TOPIC0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        watcher.subscribe(
            OPTIMISM_SEPOLIA_CHAIN_ID,
            optimismFeed,
            IMPACT_UPDATED_TOPIC0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        vm.stopBroadcast();

        console.log("Watcher:", watcherAddress);
        console.log("Base Sepolia feed subscribed:", baseFeed);
        console.log("Optimism Sepolia feed subscribed:", optimismFeed);
    }
}
