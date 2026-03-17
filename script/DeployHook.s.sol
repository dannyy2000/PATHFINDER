// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {ILiquidityCache} from "../src/interfaces/ILiquidityCache.sol";
import {Pathfinder} from "../src/Pathfinder.sol";

/// @notice Mines a CREATE2 salt and deploys Pathfinder hook on Unichain Sepolia.
///
/// Usage:
///   forge script script/DeployHook.s.sol \
///     --rpc-url $UNICHAIN_SEPOLIA_RPC --broadcast --private-key $PRIVATE_KEY -vvvv
///
/// Required env:
///   POOL_MANAGER_ADDRESS  - Uniswap v4 PoolManager on Unichain Sepolia
///   LIQUIDITY_CACHE_ADDRESS - LiquidityCache on Unichain Sepolia
contract DeployHook is Script {
    // Foundry deterministic CREATE2 factory
    address constant DEPLOY_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Hook flags: afterInitialize | beforeSwap | afterSwap
    // AFTER_INITIALIZE = 1 << 12 = 0x1000
    // BEFORE_SWAP      = 1 << 7  = 0x0080
    // AFTER_SWAP       = 1 << 6  = 0x0040
    uint160 constant HOOK_FLAGS = 0x10C0;

    // Mask for the lower 14 bits (all hook permission bits)
    uint160 constant FLAGS_MASK = 0x3FFF;

    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER_ADDRESS");
        address cache       = vm.envAddress("LIQUIDITY_CACHE_ADDRESS");

        bytes memory creationCode = abi.encodePacked(
            type(Pathfinder).creationCode,
            abi.encode(IPoolManager(poolManager), ILiquidityCache(cache))
        );
        bytes32 creationCodeHash = keccak256(creationCode);

        console.log("Mining CREATE2 salt for hook flags 0x10C0...");
        console.log("PoolManager :", poolManager);
        console.log("Cache       :", cache);

        (bytes32 salt, address hookAddress) = _mineSalt(creationCodeHash, DEPLOY_FACTORY);

        console.log("Salt found  :", vm.toString(salt));
        console.log("Hook address:", hookAddress);

        vm.startBroadcast();
        Pathfinder hook = new Pathfinder{salt: salt}(
            IPoolManager(poolManager),
            ILiquidityCache(cache)
        );
        vm.stopBroadcast();

        require(address(hook) == hookAddress, "Address mismatch");
        console.log("Pathfinder hook deployed at:", address(hook));
    }

    /// @dev Iterates salts until the CREATE2 address has the required lower bits.
    function _mineSalt(bytes32 creationCodeHash, address factory)
        internal
        pure
        returns (bytes32 salt, address hookAddress)
    {
        for (uint256 i = 0; i < 200_000; i++) {
            salt = bytes32(i);
            hookAddress = _computeCreate2Address(factory, salt, creationCodeHash);
            if (uint160(hookAddress) & FLAGS_MASK == HOOK_FLAGS) {
                return (salt, hookAddress);
            }
        }
        revert("Could not find valid salt in 200,000 iterations");
    }

    function _computeCreate2Address(
        address deployer,
        bytes32 salt,
        bytes32 creationCodeHash
    ) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            deployer,
            salt,
            creationCodeHash
        )))));
    }
}
