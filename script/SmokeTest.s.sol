// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {DemoImpactFeed} from "../src/DemoImpactFeed.sol";
import {ILiquidityCache} from "../src/interfaces/ILiquidityCache.sol";

// Smoke test - publishes impact events on Base and Optimism feeds,
// then reads LiquidityCache on Unichain to verify the snapshot landed.
//
// Step 1 (Base Sepolia):
//   forge script script/SmokeTest.s.sol:PublishBase \
//     --rpc-url $BASE_SEPOLIA_RPC --broadcast --private-key $PRIVATE_KEY -vvvv
//
// Step 2 (Optimism Sepolia):
//   forge script script/SmokeTest.s.sol:PublishOptimism \
//     --rpc-url $OPTIMISM_SEPOLIA_RPC --broadcast --private-key $PRIVATE_KEY -vvvv
//
// Step 3 - wait ~30s for Reactive relay, then check cache (Unichain):
//   forge script script/SmokeTest.s.sol:CheckCache \
//     --rpc-url $UNICHAIN_SEPOLIA_RPC -vvvv

// WETH/USDC — standard OP-stack addresses
address constant WETH = 0x4200000000000000000000000000000000000006;
// Using a single USDC address for the pair key — same on both sides
address constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

/// @notice Publish a Base Sepolia impact reading (chain = 1, impact = 40 bps)
contract PublishBase is Script {
    function run() external {
        address feed = vm.envAddress("MOCK_FEED_BASE");

        console.log("Publishing Base impact to feed:", feed);
        console.log("Pair: WETH/USDC");
        console.log("Impact: 40 bps (0.40%)");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        DemoImpactFeed(feed).publishImpact(WETH, USDC, 40);
        vm.stopBroadcast();

        console.log("Done. Wait ~30s for Reactive relay, then run CheckCache.");
    }
}

/// @notice Publish an Optimism Sepolia impact reading (chain = 2, impact = 25 bps)
contract PublishOptimism is Script {
    function run() external {
        address feed = vm.envAddress("MOCK_FEED_OPTIMISM");

        console.log("Publishing Optimism impact to feed:", feed);
        console.log("Pair: WETH/USDC");
        console.log("Impact: 25 bps (0.25%) - better than Base");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        DemoImpactFeed(feed).publishImpact(WETH, USDC, 25);
        vm.stopBroadcast();

        console.log("Done. Wait ~30s for Reactive relay, then run CheckCache.");
    }
}

/// @notice Read LiquidityCache on Unichain — verify snapshot landed
contract CheckCache is Script {
    function run() external view {
        address cache = vm.envAddress("LIQUIDITY_CACHE_ADDRESS");

        ILiquidityCache.LiquiditySnapshot memory snap =
            ILiquidityCache(cache).getSnapshot(WETH, USDC);

        console.log("=== LiquidityCache Snapshot (WETH/USDC) ===");
        console.log("Unichain impact bps :", snap.unichainImpactBps);
        console.log("Base impact bps     :", snap.baseImpactBps);
        console.log("Optimism impact bps :", snap.optimismImpactBps);
        console.log("Timestamp           :", snap.timestamp);

        if (snap.timestamp == 0) {
            console.log("");
            console.log("RESULT: snapshot not yet written - Reactive relay still pending.");
        } else {
            console.log("");
            console.log("RESULT: snapshot live. End-to-end flow confirmed.");
        }
    }
}
