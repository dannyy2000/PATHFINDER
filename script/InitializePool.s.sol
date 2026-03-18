
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Pathfinder} from "../src/Pathfinder.sol";
import {IPathfinder} from "../src/interfaces/IPathfinder.sol";

/// @notice Initializes a USDC/WETH pool on Unichain Sepolia with the Pathfinder hook.
///
/// Usage:
///   forge script script/InitializePool.s.sol \
///     --rpc-url $UNICHAIN_SEPOLIA_RPC --broadcast --private-key $PRIVATE_KEY -vvvv
///
/// Required env:
///   POOL_MANAGER_ADDRESS    - Uniswap v4 PoolManager on Unichain Sepolia
///   PATHFINDER_HOOK_ADDRESS - Deployed Pathfinder hook address
contract InitializePool is Script {
    using PoolIdLibrary for PoolKey;

    // Unichain Sepolia canonical tokens
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x31d0220469e10c4E71834a79b1f276d740d3768F;

    // Pool parameters
    uint24  constant FEE          = 3000;   // 0.3%
    int24   constant TICK_SPACING = 60;

    // Initial price: ~3000 USDC per WETH
    // currency0=USDC (6 dec), currency1=WETH (18 dec)
    // price_raw = 1e18 / (3000 * 1e6) = 333333333.33...
    // sqrtPriceX96 = sqrt(333333333.33) * 2^96 ≈ 1446604449849817285854646000000
    uint160 constant INITIAL_SQRT_PRICE = 1446604449849817285854646000000;

    // Demo-friendly config: 1-day staleness so the existing snapshot stays valid
    uint256 constant MAX_STALENESS = 86400;

    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER_ADDRESS");
        address hookAddress = vm.envAddress("PATHFINDER_HOOK_ADDRESS");

        // currency0 must be the lower address — USDC (0x036...) < WETH (0x420...)
        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(USDC),
            currency1:   Currency.wrap(WETH),
            fee:         FEE,
            tickSpacing: TICK_SPACING,
            hooks:       IHooks(hookAddress)
        });

        bytes32 poolId = PoolId.unwrap(key.toId());
        console.log("Pool ID:");
        console.logBytes32(poolId);
        console.log("Hook    :", hookAddress);
        console.log("token0  :", USDC);
        console.log("token1  :", WETH);

        IPathfinder.PoolConfig memory cfg = IPathfinder.PoolConfig({
            routingThreshold: 15,       // 0.15% improvement needed to route cross-chain
            maxStaleness:     MAX_STALENESS,
            smallTradeLimit:  0,
            whaleTradeLimit:  type(uint256).max
        });

        vm.startBroadcast();

        // 1. Pre-register config so afterInitialize picks it up
        Pathfinder(hookAddress).registerConfig(key, cfg);
        console.log("Config registered (maxStaleness=86400)");

        // 2. Initialize the pool
        int24 tick = IPoolManager(poolManager).initialize(key, INITIAL_SQRT_PRICE);
        console.log("Pool initialized at tick:", tick);

        vm.stopBroadcast();

        console.log("Done. Pool ID:");
        console.logBytes32(poolId);
    }
}
