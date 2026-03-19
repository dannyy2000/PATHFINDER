# PATHFINDER

> A Uniswap v4 hook that identifies the chain with the best liquidity and signals the optimal routing decision on-chain — automatically, from a single transaction on Unichain.

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

PATHFINDER is a Uniswap v4 hook on Unichain that intercepts every swap before execution, checks real-time liquidity conditions across all major chains, and signals the optimal routing decision on-chain — all from the single transaction the user already submitted.

No manual chain-checking. No multiple transactions. The hook reads live cross-chain data and emits the best venue — the foundation for a settlement layer to execute there automatically.

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

If Base or Optimism is meaningfully better — PATHFINDER emits `SwapRouted` signalling that chain as the best venue. A settlement layer consuming this signal can execute there via Superchain native interop (M2).

Ethereum and Arbitrum data informs the snapshot (Reactive watches their pools) but PATHFINDER never routes execution there — bridging to non-Superchain chains is slow, multi-transaction, and not atomic.

### Step 5 — Routing Decision Is Emitted

When `beforeSwap` completes, PATHFINDER emits a `SwapRouted` event with:
- `destination` — which chain has the best execution (0 = Unichain, 1 = Base, 2 = Optimism)
- `reason` — why this route was chosen (`"local_best"`, `"small_trade"`, `"whale_route"`, `"improvement_route"`, `"stale_data"`)
- `improvementBps` — how many basis points better the cross-chain venue is

```
SwapRouted(poolId, destination=1, reason="improvement_route", improvementBps=30)
```

This event is the output of the routing intelligence layer — the data a settlement layer needs to execute the cross-chain swap. The natural next step is for an execution layer to consume this event and settle via `L2ToL2CrossDomainMessenger` and `SuperchainERC20` (available natively on all Superchain members including Unichain, Base, and Optimism). PATHFINDER is architected so this settlement layer can be added without changing the hook itself.

PATHFINDER only considers **Base and Optimism** as routing destinations — both Superchain members. Ethereum and Arbitrum data informs the snapshot but are never routed to, as doing so would require a non-atomic external bridge.

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
│   - Emits SwapRouted(destination, reason, improvementBps)               │
│   - destination=0 → executes locally on Unichain                       │
│   - destination=1/2 → signals Base or Optimism as best venue           │
│   - Ethereum and Arbitrum never considered for routing                  │
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │   Settlement layer (roadmap)                                    │   │
│   │   L2ToL2CrossDomainMessenger + SuperchainERC20                  │   │
│   │   Consumes SwapRouted signal → executes cross-chain atomically  │   │
│   └─────────────────────────────────────────────────────────────────┘   │
└───────────────────────┬─────────────────────────────────────────────────┘
                        │  SwapRouted signal (implemented)
                        │  Cross-chain settlement (roadmap — Superchain native)
          ┌─────────────┴─────────────┐
          ▼                           ▼
        BASE                      OPTIMISM
   [Best venue]               [Best venue]
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
  → emits SwapRouted(destination, reason, improvementBps)
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

**Where in the code:**
- `src/Pathfinder.sol` — hook deployed on Unichain. `_bestExecutableChain()` only ever considers `CHAIN_BASE` (1) and `CHAIN_OPTIMISM` (2) as routing destinations because they are Superchain members. `CHAIN_UNICHAIN` (0) is the local fallback.
- `src/LiquidityCache.sol` — storage contract deployed on Unichain, read by the hook inside `beforeSwap` as a local call
- `script/DeployHook.s.sol`, `script/DeployLiquidityCache.s.sol`, `script/InitializePool.s.sol` — deployment to Unichain Sepolia

**What the integration does:**

**1. Superchain-Aware Routing Targets**
The hook hardcodes only Base and Optimism as cross-chain destinations (`CHAIN_BASE = 1`, `CHAIN_OPTIMISM = 2` in `src/Pathfinder.sol`). Ethereum and Arbitrum are explicitly excluded — they are not Superchain members and routing there would require a non-atomic external bridge. The `SwapRouted` event signals the optimal Superchain venue so a settlement layer can consume it and execute via `L2ToL2CrossDomainMessenger` without changing the hook.

**2. Speed**
Unichain's 1-second blocks mean the routing decision runs before liquidity conditions shift. The hook reads `LiquidityCache` locally — no cross-chain call happens during the swap.

**3. Low Gas**
The `beforeSwap` computation is a single storage read + comparison. On Unichain gas costs are negligible — routing intelligence adds no meaningful overhead per swap.

---

### Reactive Network

**Where in the code:**
- `src/LiquidityWatcher.sol` — Reactive Smart Contract deployed on Reactive Lasna. Subscribes to `ImpactUpdated` events from `DemoImpactFeed` contracts on Base Sepolia and Optimism Sepolia. `react()` is the Reactive-called entry point that updates chain rankings and pushes to `LiquidityCache` when the best chain changes.
- `src/DemoImpactFeed.sol` — origin-chain event emitter deployed on Base Sepolia and Optimism Sepolia. Publishes `ImpactUpdated(tokenA, tokenB, chain, impactBps)` which Reactive subscribes to.
- `src/LiquidityCache.sol` — receives the callback write from the watcher via `writeSnapshot()`
- `script/DeployWatcher.s.sol`, `script/DeployMocks.s.sol`, `script/SubscribeMocks.s.sol` — deployment and subscription to Reactive Lasna

**What the integration does:**

`LiquidityWatcher.react()` is triggered automatically by Reactive Network every time an `ImpactUpdated` event fires on Base or Optimism. The watcher compares the new impact against its stored rankings — if the best chain changes, it calls `LiquidityCache.writeSnapshot()` on Unichain, keeping the cache continuously fresh. PATHFINDER's hook reads this cache at swap time. Without Reactive, the hook has no cross-chain data and cannot make routing decisions — the entire value proposition depends on this integration.

**Why not a traditional oracle:**
Traditional price oracles report a price. Reactive reports liquidity conditions — impact, depth, freshness — for a specific pair at this specific moment. That is the data type routing decisions require.

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
