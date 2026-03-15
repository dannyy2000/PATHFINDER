// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title DemoImpactFeed
/// @notice Simple origin-chain event emitter for the hackathon demo flow.
///         Reactive subscribes to `ImpactUpdated` and forwards the payload to LiquidityWatcher.
contract DemoImpactFeed {
    address public immutable owner;
    uint8 public immutable sourceChain;

    error Unauthorized();
    error InvalidChain();

    event ImpactUpdated(address tokenA, address tokenB, uint8 chain, uint256 impactBps);

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(uint8 sourceChain_) {
        if (sourceChain_ == 0 || sourceChain_ > 2) revert InvalidChain();
        owner = msg.sender;
        sourceChain = sourceChain_;
    }

    function publishImpact(address tokenA, address tokenB, uint256 impactBps) external onlyOwner {
        emit ImpactUpdated(tokenA, tokenB, sourceChain, impactBps);
    }
}
