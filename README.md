# PATHFINDER

> A Uniswap v4 hook that routes every swap to the chain with the best liquidity — automatically, atomically, from a single transaction on Unichain.

---

## The Problem

DeFi liquidity is fragmented. The same token pair — ETH/USDC, WBTC/USDC, any major pair — exists simultaneously across Ethereum, Base, Arbitrum, Optimism, and Unichain. Each pool on each chain has different depth, different spreads, and different price impact at any given moment.

This fragmentation silently costs traders every single day.

**A real example:**

You want to swap 10 ETH for USDC on Unichain. The Unichain pool is thin right now — your swap causes 0.5% price impact. You lose $250 on a $50,000 swap just from slippage.

At that exact same moment, the Base pool is deep. The same swap there would have caused only 0.2% impact — saving you $150.

But you had no way to know that without manually checking every chain yourself, bridging your tokens, and executing there. That process takes multiple transactions, costs gas on each step, and by the time you are done the opportunity has likely closed.

**So most traders just accept the bad price. Every time.**

The problem is not that good liquidity does not exist — it is that your swap has no intelligence about where that liquidity is. It just executes wherever you happen to be.

**PATHFINDER solves this.**

---

## The Solution

PATHFINDER is a Uniswap v4 hook on Unichain that intercepts every swap before execution, checks real-time liquidity conditions across all major chains, and routes the trade to where it gets the best price — all from the single transaction the user already submitted.

No manual chain-checking. No bridging. No multiple transactions. One swap, best price, whatever chain it is on.

---

## How It Works

### Step 1 — You Submit A Swap On Unichain

You send a standard swap transaction to a PATHFINDER-protected pool on Unichain. From your side it looks like any other swap.

### Step 2 — The Hook Intercepts It

Before execution, the `beforeSwap` hook fires. PATHFINDER pauses and queries the latest liquidity snapshot from Reactive Network.

### Step 3 — Reactive Network Provides The Intelligence

Reactive Network has a smart contract continuously monitoring liquidity events — pool reserves, spreads, recent swap volume — across Uniswap pools on Ethereum, Base, Arbitrum, and Optimism.

It maintains a live ranking of which chain currently offers the best execution for each major pair and trade size range.

When PATHFINDER queries it, Reactive responds immediately with:
- Which chain has the best price impact for this specific swap size
- The current spread on each chain
- Confidence level of the data freshness

### Step 4 — Route Decision

```
PATHFINDER receives liquidity data:

  Unichain:  0.50% price impact
  Base:      0.20% price impact  ← BEST
  Arbitrum:  0.35% price impact
  Ethereum:  0.45% price impact

Routing threshold: improvement must exceed 0.15% to justify cross-chain route
Result: Route to Base (0.30% improvement — worth routing)
```

If Unichain is already the best — the swap executes locally, no routing needed.

If another chain is meaningfully better — PATHFINDER initiates cross-chain execution via Unichain's Superchain native interoperability.

### Step 5 — Unichain Superchain Executes The Route

Because Unichain is part of the Optimism Superchain, cross-chain execution to Base or Optimism happens with **native single-block message passing** — not a slow multi-step bridge.

The swap executes on the destination chain. The output token is returned to the user on Unichain.

From the user's perspective: they submitted one swap, got a better price, done.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                      EXTERNAL CHAINS                             │
│                                                                  │
│  Ethereum         Base          Arbitrum        Optimism         │
│  [Pool Events]    [Pool Events] [Pool Events]   [Pool Events]    │
│       │               │              │               │           │
└───────┼───────────────┼──────────────┼───────────────┼───────────┘
        │               │              │               │
        └───────────────┴──────────────┴───────────────┘
                                │
                                ▼
┌──────────────────────────────────────────────────────────────────┐
│                     REACTIVE NETWORK                             │
│                                                                  │
│   LiquidityWatcher.sol                                           │
│   - Subscribes to swap + liquidity events on all 4 chains        │
│   - Tracks pool reserves and recent price impact per chain       │
│   - Maintains live best-execution ranking per pair + trade size  │
│   - Responds to queries from PATHFINDER hook instantly           │
└────────────────────────────┬─────────────────────────────────────┘
                             │  liquidity snapshot
                             │  (best chain + impact data)
                             ▼
┌──────────────────────────────────────────────────────────────────┐
│                      UNICHAIN                                    │
│                                                                  │
│   Pathfinder.sol — Uniswap v4 Hook                               │
│   - beforeSwap: query Reactive, decide route                     │
│   - Local execution if Unichain is best                          │
│   - Cross-chain execution via Superchain if another chain wins   │
│   - Returns output token to user on Unichain                     │
│                                                                  │
│   ┌──────────────────────────────────────────────────────────┐   │
│   │          Uniswap v4 Pool (ETH/USDC, etc.)                │   │
│   │          Protected and routed by PATHFINDER              │   │
│   └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│   ┌──────────────────────────────────────────────────────────┐   │
│   │          Superchain Bridge (native interop)              │   │
│   │          Single-block cross-chain execution              │   │
│   └──────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

---

## Routing Logic

PATHFINDER does not route blindly. It uses a routing threshold to ensure cross-chain execution is only triggered when the benefit genuinely outweighs the overhead.

```
Route cross-chain IF:
  (best_chain_impact - unichain_impact) > ROUTING_THRESHOLD
  AND
  data_freshness < MAX_STALENESS_SECONDS

Otherwise:
  Execute locally on Unichain
```

The routing threshold is configurable per pool. A pool optimized for large trades may set a lower threshold (route even for small improvements). A pool for retail-sized swaps may set a higher threshold to avoid unnecessary cross-chain hops.

This is the "bespoke liquidity tailored to specific assets and trade sizes" principle in practice.

---

## Trade Size Segmentation

Different trade sizes have different routing needs. PATHFINDER handles them differently:

| Trade Size | Routing Behaviour |
|---|---|
| Small (< $1,000) | Execute locally on Unichain — cross-chain overhead not worth it |
| Medium ($1,000 – $50,000) | Route if improvement exceeds 0.15% |
| Large ($50,000 – $500,000) | Route if improvement exceeds 0.05% — even small improvements matter |
| Whale (> $500,000) | Always route — split across multiple chains if needed |

This segmentation means PATHFINDER is genuinely tailored to trade size, not just a one-size-fits-all router.

---

## Contract Structure

```
pathfinder/
├── src/
│   ├── Pathfinder.sol              # Main Uniswap v4 hook — routing logic
│   ├── LiquidityWatcher.sol        # Reactive Network contract — cross-chain monitor
│   ├── MockLiquidityFeed.sol       # Mock liquidity feed for testing and demo
│   └── interfaces/
│       ├── IPathfinder.sol         # Hook interface
│       └── ILiquidityWatcher.sol   # Reactive watcher interface
├── test/
│   ├── Pathfinder.t.sol            # Unit tests for hook and routing logic
│   ├── LiquidityWatcher.t.sol      # Unit tests for Reactive contract
│   └── Integration.t.sol           # End-to-end routing integration tests
├── script/
│   ├── Deploy.s.sol                # Full deployment script
│   ├── DeployMocks.s.sol           # Deploy mock liquidity feeds for demo
│   └── SimulateRoute.s.sol         # Demo script — simulate cross-chain routing
├── lib/                            # Forge dependencies
├── foundry.toml
├── .env.example
└── README.md
```

---

## Tech Stack

| Technology | Role |
|---|---|
| Uniswap v4 | Core AMM — hook intercepts swaps for routing decisions |
| Unichain | Deployment chain + Superchain routing hub |
| Reactive Network | Real-time cross-chain liquidity intelligence |
| Optimism Superchain | Native single-block cross-chain execution |
| Foundry | Development, testing, deployment |
| Solidity 0.8.26 | Smart contract language |

---

## Partner Integrations

### Unichain

PATHFINDER is built specifically around Unichain's unique position in the ecosystem and relies on two of its properties:

**1. Superchain Native Interoperability**
Unichain is part of the Optimism Superchain. This means cross-chain execution to Base, Optimism, and other Superchain members happens via native single-block message passing — not a traditional multi-step bridge. When PATHFINDER routes a swap to Base, it happens atomically in a single transaction from the user's perspective. This is only possible because of Unichain's Superchain membership. No other chain offers this for cross-chain routing today.

**2. Speed**
Unichain's 1-second blocks mean the routing decision and execution happen before liquidity conditions change. A 12-second block window on Ethereum mainnet is long enough for conditions to shift between when Reactive provides its snapshot and when the swap actually executes. Unichain's speed keeps the routing data fresh and the execution accurate.

**3. Low Gas**
PATHFINDER's `beforeSwap` hook adds a routing computation step to every swap. On Ethereum mainnet this extra computation would meaningfully increase swap costs. On Unichain the gas cost is negligible — routing intelligence comes essentially for free.

### Reactive Network

Reactive Network is the intelligence layer that makes routing decisions possible.

**What it does:**
- Deploys a Reactive Smart Contract (LiquidityWatcher) that subscribes to swap and liquidity events on Uniswap pools across Ethereum, Base, Arbitrum, and Optimism simultaneously
- Tracks pool reserves, recent price impact, and volume for each major pair
- Maintains a continuously updated ranking of best execution per pair and trade size range
- Responds to queries from the PATHFINDER hook with a fresh liquidity snapshot

**Why it is essential:**
The PATHFINDER hook on Unichain is completely blind to what is happening on other chains. It cannot natively read the state of a Base pool or an Arbitrum pool. Reactive Network bridges that gap — it is the eyes of the system. Without it, PATHFINDER has no data to route with and becomes an ordinary hook. The entire value proposition — best execution across chains — only exists because of Reactive.

**Why not a traditional oracle:**
Traditional price oracles tell you the price. Reactive tells you the liquidity conditions — depth, impact, spread, freshness — for a specific trade size at this specific moment. That is a fundamentally different and more useful data type for routing decisions.

---

## Deployment

### Prerequisites

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Clone the repo
git clone https://github.com/yourusername/pathfinder
cd pathfinder

# Install dependencies
forge install

# Copy and fill environment variables
cp .env.example .env
```

### Deploy to Unichain Sepolia

```bash
# Deploy mock liquidity feeds first (testnet demo)
forge script script/DeployMocks.s.sol \
  --rpc-url unichain_sepolia \
  --broadcast \
  --verify

# Deploy the main PATHFINDER hook
forge script script/Deploy.s.sol \
  --rpc-url unichain_sepolia \
  --broadcast \
  --verify
```

### Deploy Liquidity Watcher on Reactive

```bash
# Deploy to Reactive Kopli testnet
forge script script/Deploy.s.sol:DeployLiquidityWatcher \
  --rpc-url reactive_kopli \
  --broadcast
```

---

## Running the Demo

The demo shows PATHFINDER detecting a better execution chain in real time and routing a swap there automatically.

**Step 1 — Verify baseline**
```bash
cast call $PATHFINDER_HOOK_ADDRESS "getBestChain(address,address,uint256)" \
  $USDC $ETH 10000000000000000000 \
  --rpc-url unichain_sepolia
# Returns: 0 (Unichain) — currently local is best
```

**Step 2 — Simulate thin liquidity on Unichain**
```bash
forge script script/SimulateRoute.s.sol:DrainUnichain \
  --rpc-url unichain_sepolia \
  --broadcast
# Simulates large swaps making Unichain pool thin
```

**Step 3 — Simulate deep liquidity on Base**
```bash
forge script script/SimulateRoute.s.sol:DeepBase \
  --rpc-url base_sepolia \
  --broadcast
# Pushes mock liquidity data showing Base as deep
```

**Step 4 — Watch Reactive update its ranking**
```bash
cast call $REACTIVE_WATCHER_ADDRESS "getBestChainSnapshot(address,address)" \
  $USDC $ETH \
  --rpc-url reactive_kopli
# Returns: Base with 0.20% impact vs Unichain 0.50%
```

**Step 5 — Submit a swap and watch it route to Base**
```bash
forge script script/SimulateRoute.s.sol:SubmitSwap \
  --rpc-url unichain_sepolia \
  --broadcast
# PATHFINDER intercepts, detects Base is better, routes cross-chain
# User receives USDC on Unichain with Base-level execution
```

**Step 6 — Compare prices**
```bash
forge script script/SimulateRoute.s.sol:CompareOutputs \
  --rpc-url unichain_sepolia
# Shows side-by-side: local execution vs PATHFINDER-routed execution
# Demonstrates the savings
```

---

## Testing

```bash
# Run all tests
forge test

# Run with detailed output
forge test -vvvv

# Run only routing logic tests
forge test --match-path test/Pathfinder.t.sol

# Run integration tests
forge test --match-path test/Integration.t.sol

# Gas report
forge test --gas-report
```

---

## Hook Permissions

PATHFINDER uses the following Uniswap v4 hook flags:

| Hook | Used | Purpose |
|------|------|---------|
| `beforeInitialize` | No | — |
| `afterInitialize` | Yes | Register pool with routing system |
| `beforeAddLiquidity` | No | — |
| `afterAddLiquidity` | No | — |
| `beforeRemoveLiquidity` | No | — |
| `afterRemoveLiquidity` | No | — |
| `beforeSwap` | Yes | Intercept swap, query Reactive, decide route |
| `afterSwap` | Yes | Record routing outcome for analytics |

---

## Routing Threshold Configuration

Each pool deployed with PATHFINDER can configure its own routing parameters at initialization:

| Parameter | Description | Default |
|---|---|---|
| `routingThreshold` | Minimum improvement required to trigger cross-chain route | 0.15% |
| `maxStaleness` | Maximum age of Reactive data accepted for routing decisions | 30 seconds |
| `smallTradeLimit` | Trade size below which routing is skipped | $1,000 |
| `whaleTradeLimit` | Trade size above which routing is always attempted | $500,000 |
| `enabledChains` | Which chains Reactive monitors for this pool | All |

---

## Security Considerations

- **Routing Threshold Guard** — cross-chain routing only triggers when improvement meaningfully exceeds overhead, preventing unnecessary routes on marginal gains
- **Data Freshness Check** — stale Reactive data is rejected; swap falls back to local execution rather than routing on outdated information
- **Atomic Execution** — Superchain native interop ensures cross-chain swaps are atomic, not split across multiple transactions that could fail mid-way
- **No Admin Keys** — routing parameters are set at pool initialization and cannot be changed, removing admin risk
- **Slippage Protection** — user-specified slippage tolerance is enforced on the destination chain, not just locally

---

## Hackathon

Built for the **UHI8 Hookathon — Specialized Markets** track.

Partner integrations: **Unichain** + **Reactive Network**

Category: **Chain-Localized Routing**

---

## License

MIT
