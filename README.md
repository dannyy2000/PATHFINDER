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

Before execution, the `beforeSwap` hook fires. PATHFINDER reads the latest liquidity snapshot from `LiquidityCache.sol` — a storage contract on Unichain that Reactive Network keeps continuously updated in the background.

This is a local read on Unichain. No cross-chain call happens at swap time.

### Step 3 — How Reactive Network Keeps The Cache Fresh

This is a background process running 24/7, completely independent of any user swap.

Reactive Network has a Reactive Smart Contract (`LiquidityWatcher.sol`) deployed on the Reactive Lasna network. It subscribes to `ImpactUpdated` events emitted by `DemoImpactFeed` contracts deployed on Base Sepolia and Optimism Sepolia. Every time a new impact reading is published on either feed, Reactive detects the event and calls `react()` on the watcher automatically.

In production this subscription would point directly at `Swap` and `ModifyLiquidity` events from Uniswap pools on Ethereum, Base, Arbitrum, and Optimism — the `DemoImpactFeed` contracts are a testnet stand-in that let the demo publish controlled impact values without needing to drive real pool activity.

Inside `react()`, the watcher updates its picture of each chain — reserves, price impact, volume. When the best-chain ranking changes, the watcher sends a callback transaction to `LiquidityCache.sol` on Unichain, writing the latest snapshot.

By the time a user submits a swap, the answer is already sitting in the cache. PATHFINDER just reads it.

The snapshot contains:
- Which chain has the best price impact for this specific swap size
- The current impact on Unichain (for comparison)
- Timestamp of when the data was last written (for staleness check)

### Step 4 — Route Decision

```
PATHFINDER reads liquidity snapshot from cache:

  Unichain:  0.50% price impact
  Base:      0.20% price impact  ← BEST (Superchain — executable)
  Optimism:  0.38% price impact  (Superchain — executable)
  Arbitrum:  0.35% price impact  (monitored for intelligence only)
  Ethereum:  0.45% price impact  (monitored for intelligence only)

Routing threshold: improvement must exceed 0.15% to justify cross-chain route
Result: Route to Base (0.30% improvement — worth routing)
```

If Unichain is already the best — the swap executes on Unichain, no routing needed.

If Base or Optimism is meaningfully better — PATHFINDER routes there via Superchain native interop.

Ethereum and Arbitrum data informs the snapshot (Reactive watches their pools) but PATHFINDER never routes execution there — bridging to non-Superchain chains is slow, multi-transaction, and not atomic.

### Step 5 — Unichain Superchain Executes The Route

PATHFINDER only routes execution to **Base and Optimism** — both Superchain members like Unichain. Ethereum and Arbitrum are monitored for price intelligence but never routed to, because doing so would require an external bridge: slow, multi-transaction, and not atomic. That defeats the purpose.

For Base or Optimism, PATHFINDER calls `L2ToL2CrossDomainMessenger` — a contract built into every Superchain member — and sends a message to the destination chain:

> "Swap this ETH for USDC, return the USDC to this address on Unichain."

The token movement works as follows:

```
1. User's ETH burns on Unichain              (SuperchainERC20 native transfer)
2. ETH mints on destination chain
3. Swap executes on destination Uniswap pool (better price impact)
4. Output token burns on destination chain
5. Output token mints on Unichain
6. User receives output token on Unichain
```

This works because Unichain, Base, and Optimism share native asset bridging via `SuperchainERC20`. There is no external bridge. The burn-and-mint is a protocol-level operation that happens in a single block.

From the user's perspective: they submitted one swap, got a better price, done.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│              MONITORED CHAINS  (price intelligence only)                │
│                                                                         │
│   Ethereum          Base           Arbitrum          Optimism           │
│   [Pool Events]     [Pool Events]  [Pool Events]     [Pool Events]      │
│        │                │               │                 │             │
└────────┼────────────────┼───────────────┼─────────────────┼─────────────┘
         │                │               │                 │
         └────────────────┴───────────────┴─────────────────┘
                                    │
                     Reactive subscribes to all pool events
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        REACTIVE NETWORK                                 │
│                                                                         │
│   LiquidityWatcher.sol                                                  │
│   - react() fires on every pool event across all 4 chains               │
│   - Tracks reserves, price impact, volume per chain per pair            │
│   - Maintains live best-execution ranking                               │
│   - When ranking changes → pushes updated snapshot to Unichain          │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │  callback transaction
                                 │  pushes snapshot proactively
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                            UNICHAIN                                     │
│                                                                         │
│   LiquidityCache.sol                                                    │
│   - Stores latest snapshot per token pair                               │
│   - Written by Reactive, read by Pathfinder                             │
│   - Local read — no cross-chain call at swap time                       │
│                          │                                              │
│                          │ beforeSwap reads cache                       │
│                          ▼                                              │
│   Pathfinder.sol — Uniswap v4 Hook                                      │
│   - Reads LiquidityCache, runs routing decision                         │
│   - Executes locally if Unichain is best                                │
│   - Routes to Base or Optimism via Superchain if they are better        │
│   - Ethereum and Arbitrum never routed to (not Superchain)              │
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │   L2ToL2CrossDomainMessenger + SuperchainERC20                  │   │
│   │   Tokens burn on Unichain → mint on destination                 │   │
│   │   Swap executes → output burns → mints back on Unichain         │   │
│   └─────────────────────────────────────────────────────────────────┘   │
└───────────────────────┬─────────────────────────────────────────────────┘
                        │  Superchain execution only
                        │  (single block, atomic, no external bridge)
          ┌─────────────┴─────────────┐
          ▼                           ▼
        BASE                      OPTIMISM
   [Swap executes]             [Swap executes]
```

---

## Two Independent Processes

PATHFINDER relies on two processes that run completely independently of each other.

**Process 1 — Background intelligence (runs 24/7)**

This has nothing to do with any user swap. Reactive Network is continuously watching pool events on Ethereum, Base, Arbitrum, and Optimism. Every real swap on those chains updates the watcher's picture of liquidity. When the best-chain ranking changes, the watcher pushes a fresh snapshot to `LiquidityCache.sol` on Unichain.

```
Real swaps happening on Base, Arbitrum, Ethereum, Optimism
  → Reactive detects pool events
  → react() updates rankings
  → LiquidityCache on Unichain gets updated
  → cache sits there, always fresh, waiting
```

**Process 2 — User swap (happens on demand)**

When a user submits a swap, PATHFINDER reads the cache that was already updated by Process 1. The routing decision is made from that cached data — no cross-chain call happens mid-transaction.

```
User submits swap on Unichain
  → beforeSwap fires
  → Pathfinder reads LiquidityCache (local, same chain)
  → routing decision made
  → executes locally or routes to Base/Optimism
```

These two processes never block each other. The cache is the handoff point between them.

---

## Routing Logic

PATHFINDER does not route blindly. It uses a routing threshold to ensure cross-chain execution is only triggered when the benefit genuinely outweighs the overhead.

```
Route cross-chain IF:
  (unichain_impact - best_chain_impact) > ROUTING_THRESHOLD
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
│   ├── Pathfinder.sol              # Uniswap v4 hook — routing logic (deployed on Unichain)
│   ├── LiquidityCache.sol          # Storage contract — holds latest snapshot per pair (deployed on Unichain)
│   ├── LiquidityWatcher.sol        # Reactive Smart Contract — cross-chain monitor (deployed on Reactive Lasna)
│   ├── DemoImpactFeed.sol          # Publishable impact feed for testnet demos
│   ├── MockLiquidityFeed.sol       # Replaces LiquidityCache during local testing — returns controllable data
│   └── interfaces/
│       ├── IPathfinder.sol         # Hook + config interface
│       ├── ILiquidityCache.sol     # Cache read/write interface
│       └── ILiquidityWatcher.sol   # Reactive watcher interface
├── test/
│   ├── Pathfinder.t.sol            # Unit tests — routing decisions, thresholds, hook guards
│   ├── PathfinderMore.t.sol        # Extended unit tests — boundary conditions, config edge cases
│   ├── PathfinderExtras.t.sol      # Extra unit tests — pool isolation, selector and fee checks
│   ├── PathfinderFuzz.t.sol        # Fuzz tests — routing invariants across arbitrary inputs
│   ├── LiquidityCache.t.sol        # Unit tests — writer access control, pair normalization, events
│   ├── LiquidityCacheExtras.t.sol  # Extra unit tests — writer rotation, pair isolation
│   ├── LiquidityCacheFuzz.t.sol    # Fuzz tests — commutativity, persistence, access control
│   ├── LiquidityWatcher.t.sol      # Unit tests — react() updates, chain ranking, Reactive path
│   ├── DemoImpactFeed.t.sol        # Unit tests for DemoImpactFeed origin-chain emitter
│   ├── DemoImpactFeedExtras.t.sol  # Extended tests for DemoImpactFeed
│   ├── MockLiquidityFeed.t.sol     # Unit tests for MockLiquidityFeed test helper
│   ├── MockLiquidityFeedExtras.t.sol
│   ├── Integration.t.sol           # End-to-end — watcher → cache → Pathfinder → routing decision
│   └── IntegrationExtras.t.sol     # Extended integration — small trade, whale, pair isolation
├── script/
│   ├── DeployLiquidityCache.s.sol  # Deploy LiquidityCache to Unichain Sepolia
│   ├── DeployHook.s.sol            # Mine CREATE2 salt and deploy Pathfinder hook to Unichain Sepolia
│   ├── DeployWatcher.s.sol         # Deploy LiquidityWatcher to Reactive Lasna
│   ├── DeployMocks.s.sol           # Deploy DemoImpactFeed on Base Sepolia and Optimism Sepolia
│   ├── SetWriter.s.sol             # Authorize LiquidityWatcher callback proxy in LiquidityCache
│   ├── SubscribeMocks.s.sol        # Subscribe LiquidityWatcher to deployed mock feeds
│   ├── InitializePool.s.sol        # Initialize USDC/WETH pool with Pathfinder hook
│   ├── SmokeTest.s.sol             # Publish impact events and verify cache snapshot end-to-end
│   └── DemoSwap.s.sol              # Full end-to-end demo — deploys tokens, writes snapshot, swaps
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
- Deploys `LiquidityWatcher.sol` on Reactive Lasna — a Reactive Smart Contract that subscribes to `ImpactUpdated` events emitted by `DemoImpactFeed` contracts on Base Sepolia and Optimism Sepolia
- Every time a pool event fires on any of those chains, Reactive calls `react()` on the watcher with the event data
- The watcher tracks reserves, price impact, and volume per chain per pair and maintains a live best-execution ranking
- When the ranking changes, the watcher sends a callback transaction to `LiquidityCache.sol` on Unichain, writing the updated snapshot
- This runs continuously in the background — it is not triggered by user swaps

**Why it is essential:**
The PATHFINDER hook on Unichain is completely blind to what is happening on other chains. It cannot natively read the state of a Base pool or an Arbitrum pool. Reactive Network bridges that gap — it is the eyes of the system. Without it, PATHFINDER has no data to route with and becomes an ordinary hook. The entire value proposition — best execution across chains — only exists because of Reactive.

**Why not a traditional oracle:**
Traditional price oracles tell you the price. Reactive tells you the liquidity conditions — depth, impact, spread, freshness — for a specific trade size at this specific moment. That is a fundamentally different and more useful data type for routing decisions.

---

## Deployed Contracts

### Unichain Sepolia

| Contract | Address |
|---|---|
| `LiquidityCache` | [`0x81f972eF7A8D5f5F043573A42cccA590DC8e203a`](https://sepolia.uniscan.xyz/address/0x81f972eF7A8D5f5F043573A42cccA590DC8e203a) |
| `Pathfinder` (hook) | [`0xCcDDC149c1C8C811d00794B340c8f316d9A550C0`](https://sepolia.uniscan.xyz/address/0xCcDDC149c1C8C811d00794B340c8f316d9A550C0) |
| Uniswap v4 `PoolManager` | [`0x00B036B58a818B1BC34d502D3fE730Db729e62AC`](https://sepolia.uniscan.xyz/address/0x00B036B58a818B1BC34d502D3fE730Db729e62AC) |

### Reactive Lasna

| Contract | Address |
|---|---|
| `LiquidityWatcher` | [`0xAd6c53ED6933027bAF1c860050df46BA5CaDD975`](https://lasna.rnk.dev/address/0xAd6c53ED6933027bAF1c860050df46BA5CaDD975) |

### Demo Feeds

| Chain | Contract | Address |
|---|---|---|
| Base Sepolia | `DemoImpactFeed` | [`0xAd6c53ED6933027bAF1c860050df46BA5CaDD975`](https://sepolia.basescan.org/address/0xAd6c53ED6933027bAF1c860050df46BA5CaDD975) |
| Optimism Sepolia | `DemoImpactFeed` | [`0xAd6c53ED6933027bAF1c860050df46BA5CaDD975`](https://sepolia-optimism.etherscan.io/address/0xAd6c53ED6933027bAF1c860050df46BA5CaDD975) |

---

## Deployment

### Prerequisites

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Clone the repo
git clone https://github.com/dannyy2000/PATHFINDER
cd PATHFINDER

# Install dependencies
forge install

# Copy and fill environment variables
cp .env.example .env
```

### Deploy to Unichain Sepolia

```bash
# 1. Deploy LiquidityCache
forge script script/DeployLiquidityCache.s.sol \
  --rpc-url $UNICHAIN_SEPOLIA_RPC --broadcast --private-key $PRIVATE_KEY

# 2. Mine CREATE2 salt and deploy Pathfinder hook
forge script script/DeployHook.s.sol \
  --rpc-url $UNICHAIN_SEPOLIA_RPC --broadcast --private-key $PRIVATE_KEY

# 3. Authorize the watcher callback proxy to write to the cache
forge script script/SetWriter.s.sol \
  --rpc-url $UNICHAIN_SEPOLIA_RPC --broadcast --private-key $PRIVATE_KEY

# 4. Initialize a USDC/WETH pool with the Pathfinder hook
forge script script/InitializePool.s.sol \
  --rpc-url $UNICHAIN_SEPOLIA_RPC --broadcast --private-key $PRIVATE_KEY
```

### Deploy Liquidity Watcher on Reactive Lasna

```bash
# 1. Deploy DemoImpactFeed on Base Sepolia and Optimism Sepolia
TARGET_CHAIN=base forge script script/DeployMocks.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC --broadcast --private-key $PRIVATE_KEY

TARGET_CHAIN=optimism forge script script/DeployMocks.s.sol \
  --rpc-url $OPTIMISM_SEPOLIA_RPC --broadcast --private-key $PRIVATE_KEY

# 2. Deploy LiquidityWatcher to Reactive Lasna
forge script script/DeployWatcher.s.sol \
  --rpc-url $REACTIVE_LASNA_RPC --broadcast --private-key $PRIVATE_KEY

# 3. Subscribe the watcher to the deployed mock feeds
forge script script/SubscribeMocks.s.sol \
  --rpc-url $REACTIVE_LASNA_RPC --broadcast --private-key $PRIVATE_KEY
```

---

## Running the Demo

The demo shows PATHFINDER detecting a better execution chain in real time and routing a swap there automatically.

**Option A — Fully self-contained local demo (no live feeds needed)**

`DemoSwap.s.sol` deploys its own mock tokens, writes a snapshot directly to `LiquidityCache`, initialises a pool, and executes a swap — confirming the `SwapRouted` event fires with `destination=CHAIN_OPTIMISM`.

```bash
forge script script/DemoSwap.s.sol:DemoSwap \
  --rpc-url $UNICHAIN_SEPOLIA_RPC \
  --broadcast --private-key $PRIVATE_KEY -vvvv
# Look for: SwapRouted(destination=2, reason="improvement_route", improvementBps=25)
```

**Option B — End-to-end with Reactive relay (live cross-chain flow)**

**Step 1 — Publish impact readings on Base and Optimism**
```bash
forge script script/SmokeTest.s.sol:PublishBase \
  --rpc-url $BASE_SEPOLIA_RPC --broadcast --private-key $PRIVATE_KEY

forge script script/SmokeTest.s.sol:PublishOptimism \
  --rpc-url $OPTIMISM_SEPOLIA_RPC --broadcast --private-key $PRIVATE_KEY
```

**Step 2 — Wait ~30 seconds for the Reactive relay to fire**

Reactive Network detects the `ImpactUpdated` events, calls `react()` on `LiquidityWatcher`, which pushes a fresh snapshot to `LiquidityCache` on Unichain.

**Step 3 — Verify the snapshot landed**
```bash
forge script script/SmokeTest.s.sol:CheckCache \
  --rpc-url $UNICHAIN_SEPOLIA_RPC -vvvv
# Shows: Base impact bps, Optimism impact bps, timestamp
# RESULT: snapshot live. End-to-end flow confirmed.
```

**Step 4 — Inspect the live pool config**
```bash
cast call $PATHFINDER_HOOK_ADDRESS \
  "getPoolConfig(bytes32)(uint256,uint256,uint256,uint256)" \
  $POOL_ID \
  --rpc-url $UNICHAIN_SEPOLIA_RPC
# Returns: routingThreshold, maxStaleness, smallTradeLimit, whaleTradeLimit
```

---

## Testing

```bash
# Run all tests (131 tests across 14 suites)
forge test

# Run with verbose output
forge test -vvvv

# Coverage report — scripts excluded automatically via foundry.toml
# All 5 source contracts: 100% lines, 100% statements, 100% branches
forge coverage --report summary

# Run only Pathfinder routing tests
forge test --match-path test/Pathfinder.t.sol

# Run only fuzz tests
forge test --match-path "test/*Fuzz*"

# Run integration tests
forge test --match-path test/Integration.t.sol

# Gas report
forge test --gas-report
```

**Test suite breakdown:**

| Suite | Tests | What it covers |
|---|---|---|
| `PathfinderTest` | 22 | Core routing decisions, thresholds, hook guards |
| `PathfinderMoreTest` | 14 | Boundary conditions, config edge cases |
| `PathfinderExtrasTest` | 4 | Pool isolation, selector and fee return values |
| `PathfinderFuzzTest` | 6 | Routing invariants under arbitrary inputs |
| `LiquidityCacheTest` | 13 | Writer access, normalization, event emission |
| `LiquidityCacheExtrasTest` | 9 | Writer rotation, pair isolation |
| `LiquidityCacheFuzzTest` | 6 | Commutativity, persistence, access control |
| `LiquidityWatcherTest` | 25 | react() updates, chain ranking, Reactive path |
| `IntegrationTest` | 3 | End-to-end watcher → cache → routing |
| `IntegrationExtrasTest` | 5 | Small trade, whale, pair isolation flows |
| `DemoImpactFeedTest` | 5 | Origin-chain feed construction and publishing |
| `DemoImpactFeedExtrasTest` | 8 | Extended feed scenarios |
| `MockLiquidityFeedTest` | 2 | Test helper correctness |
| `MockLiquidityFeedExtrasTest` | 9 | Extended mock scenarios |

**Coverage (scripts excluded via `foundry.toml`):**

| Contract | Lines | Statements | Branches | Functions |
|---|---|---|---|---|
| `Pathfinder.sol` | 100% (64/64) | 100% (64/64) | 100% (11/11) | 100% (15/15) |
| `LiquidityWatcher.sol` | 100% (78/78) | 100% (82/82) | 100% (19/19) | 100% (13/13) |
| `LiquidityCache.sol` | 100% (15/15) | 100% (14/14) | 100% (2/2) | 100% (5/5) |
| `DemoImpactFeed.sol` | 100% (8/8) | 100% (9/9) | 100% (2/2) | 100% (3/3) |
| `MockLiquidityFeed.sol` | 100% (12/12) | 100% (9/9) | 100% (0/0) | 100% (5/5) |

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
| `beforeSwap` | Yes | Intercept swap, read LiquidityCache, decide route |
| `afterSwap` | Yes | Record routing outcome for analytics |

---

## Routing Threshold Configuration

Each pool deployed with PATHFINDER can configure its own routing parameters at initialization:

| Parameter | Description | Default |
|---|---|---|
| `routingThreshold` | Minimum improvement (in bps) required to trigger cross-chain route | 15 bps (0.15%) |
| `maxStaleness` | Maximum age of Reactive data accepted for routing decisions | 30 seconds |
| `smallTradeLimit` | Trade size below which routing is skipped entirely | 0 (disabled) |
| `whaleTradeLimit` | Trade size at or above which routing is always attempted regardless of threshold | `type(uint256).max` (disabled) |

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
