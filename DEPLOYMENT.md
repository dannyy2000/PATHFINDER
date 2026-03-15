# Deployment

## Networks

- Unichain Sepolia: chain ID `1301`
- Reactive Lasna: chain ID `5318007`

## Live Addresses

- `LiquidityCache` on Unichain Sepolia: `0x81f972eF7A8D5f5F043573A42cccA590DC8e203a`
- `LiquidityWatcher` on Reactive Lasna: `0xeB26B1c46D552807253Fd93aB2F63C0A37f3Fc79`
- Unichain Sepolia Callback Proxy: `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4`
- `DemoImpactFeed` on Base Sepolia: `0xf2cdD5a3dE69E3E0e7f1a04Fd48F771C63b32C32`
- `DemoImpactFeed` on Optimism Sepolia: `0xeB26B1c46D552807253Fd93aB2F63C0A37f3Fc79`

## Current Handoff

- Daniel deployed `LiquidityCache` and shared the address.
- Ola deployed `LiquidityWatcher` pointing at that cache.
- Daniel called `LiquidityCache.setWriter(0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4)` — callback proxy is now authorized to write snapshots.
- Ola deployed demo impact feeds on Base Sepolia and Optimism Sepolia for the fast demo path.
- Current blocker: Reactive `subscribe(...)` is reverting inside the Lasna system contract, so mock feed subscriptions are not live yet.

## References

- Unichain deployment artifact: [broadcast/DeployLiquidityCache.s.sol/1301/run-latest.json](/home/ola/Documents/hackathon/uniswap/uniswap2.0/PATHFINDER/broadcast/DeployLiquidityCache.s.sol/1301/run-latest.json)
- Reactive deployment artifact: [broadcast/DeployWatcher.s.sol/5318007/run-latest.json](/home/ola/Documents/hackathon/uniswap/uniswap2.0/PATHFINDER/broadcast/DeployWatcher.s.sol/5318007/run-latest.json)
- Base mock feed deployment artifact: [broadcast/DeployMocks.s.sol/84532/run-latest.json](/home/ola/Documents/hackathon/uniswap/uniswap2.0/PATHFINDER/broadcast/DeployMocks.s.sol/84532/run-latest.json)
- Optimism mock feed deployment artifact: [broadcast/DeployMocks.s.sol/11155420/run-latest.json](/home/ola/Documents/hackathon/uniswap/uniswap2.0/PATHFINDER/broadcast/DeployMocks.s.sol/11155420/run-latest.json)
