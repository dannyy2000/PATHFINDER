# Deployment

## Networks

- Unichain Sepolia: chain ID `1301`
- Reactive Lasna: chain ID `5318007`

## Live Addresses

- `LiquidityCache` on Unichain Sepolia: `0x81f972eF7A8D5f5F043573A42cccA590DC8e203a`
- `LiquidityWatcher` on Reactive Lasna: `0xAd6c53ED6933027bAF1c860050df46BA5CaDD975` (owner: Daniel)
- Unichain Sepolia Callback Proxy: `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4`
- `DemoImpactFeed` on Base Sepolia: `0xAd6c53ED6933027bAF1c860050df46BA5CaDD975` (owner: Daniel)
- `DemoImpactFeed` on Optimism Sepolia: `0xAd6c53ED6933027bAF1c860050df46BA5CaDD975` (owner: Daniel)
- `Pathfinder` hook on Unichain Sepolia: `0xCcDDC149c1C8C811d00794B340c8f316d9A550C0` (salt: `0x...0f33`, tx: `0xce3ecf4dc46f3ec2ca74a1ef08d9a8571d28e207c015e9a77ded9abc03413b75`)
- USDC/WETH pool with Pathfinder hook: pool ID `0xe96c6fdde38277e9a9e22fa90d1aa2ed327cfbf517af405a67f497ce5e7e0d2d` (fee=3000, tickSpacing=60, maxStaleness=86400)

## Current Handoff

- Daniel deployed `LiquidityCache` and shared the address.
- Ola deployed `LiquidityWatcher` (original, blocked by subscription revert).
- Daniel called `LiquidityCache.setWriter(0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4)` — callback proxy authorized.
- Ola deployed demo impact feeds on Base Sepolia and Optimism Sepolia.
- Daniel redeployed `LiquidityWatcher` (0xAd6c53...) owned by his wallet and subscribed to both feeds — Base Sepolia and Optimism Sepolia subscriptions confirmed live on Lasna.
- `setWriter` unchanged — same Lasna callback proxy serves all reactive contracts targeting Unichain Sepolia.
- Daniel redeployed DemoImpactFeeds (0xAd6c53...) on Base and Optimism Sepolia owned by his wallet.
- Subscribed watcher to new feeds. publishImpact fired on both chains — ImpactUpdated events confirmed on-chain.
- Reactive relay fired: callback proxy (0x9299...) called LiquidityCache.writeSnapshot on Unichain Sepolia. Confirmed via tx 0x9b24417d2de8478eb7c7add5838fd87814fb6d3ba1a056dc64cd35eecc309d45. Note: Lasna testnet bug replaces log.data[0] (tokenA) with tx.origin; snapshot was written with incorrect pair key.
- Daniel called `LiquidityCache.setWriter(0x02AF376f...)` to authorize his wallet as writer.
- Daniel called `LiquidityCache.writeSnapshot(WETH, USDC, {base: 40, optimism: 25})` directly — snapshot confirmed live. CheckCache shows Base=40 bps, Optimism=25 bps, Optimism wins routing.
- Deployed Pathfinder hook (0xCcDDC149...) via CREATE2 factory on Unichain Sepolia.
- Initialized USDC/WETH pool (pool ID 0xe96c6f...) with Pathfinder hook, fee=3000, maxStaleness=86400. Pool config confirmed live via getPoolConfig.

## References

- Unichain deployment artifact: [broadcast/DeployLiquidityCache.s.sol/1301/run-latest.json](/home/ola/Documents/hackathon/uniswap/uniswap2.0/PATHFINDER/broadcast/DeployLiquidityCache.s.sol/1301/run-latest.json)
- Reactive deployment artifact: [broadcast/DeployWatcher.s.sol/5318007/run-latest.json](/home/ola/Documents/hackathon/uniswap/uniswap2.0/PATHFINDER/broadcast/DeployWatcher.s.sol/5318007/run-latest.json)
- Base mock feed deployment artifact: [broadcast/DeployMocks.s.sol/84532/run-latest.json](/home/ola/Documents/hackathon/uniswap/uniswap2.0/PATHFINDER/broadcast/DeployMocks.s.sol/84532/run-latest.json)
- Optimism mock feed deployment artifact: [broadcast/DeployMocks.s.sol/11155420/run-latest.json](/home/ola/Documents/hackathon/uniswap/uniswap2.0/PATHFINDER/broadcast/DeployMocks.s.sol/11155420/run-latest.json)
