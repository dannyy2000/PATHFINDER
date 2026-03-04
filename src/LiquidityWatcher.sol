// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// TODO: Reactive Smart Contract deployed on Reactive Kopli
// Subscribes to Swap + ModifyLiquidity events on Uniswap pools across Ethereum, Base, Arbitrum, Optimism
// react() fires on every pool event — updates chain rankings
// Pushes updated LiquiditySnapshot to LiquidityCache on Unichain when best chain changes
// Implements ILiquidityWatcher
