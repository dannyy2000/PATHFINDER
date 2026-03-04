// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ILiquidityWatcher {

    /// @notice Called by Reactive Network when a subscribed pool event fires on any monitored chain
    /// @dev Processes event data, updates rankings, pushes to LiquidityCache if best chain changes
    function react(bytes calldata eventData) external;

    /// @notice Set the LiquidityCache address on Unichain that this watcher writes to
    function setCache(address cache) external;
}
