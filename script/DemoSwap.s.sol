// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Pathfinder} from "../src/Pathfinder.sol";
import {IPathfinder} from "../src/interfaces/IPathfinder.sol";
import {ILiquidityCache} from "../src/interfaces/ILiquidityCache.sol";
import {LiquidityCache} from "../src/LiquidityCache.sol";

/// @dev Minimal mintable ERC20 for testnet demo.
contract MockERC20 {
    string  public name;
    string  public symbol;
    uint8   public decimals;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory _name, string memory _sym, uint8 _dec) {
        name = _name; symbol = _sym; decimals = _dec;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max)
            allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @notice Full end-to-end demo script for Pathfinder.
///
///   1. Deploys two mock ERC20 tokens (TokenA, TokenB)
///   2. Writes a live snapshot to LiquidityCache (base=40 bps, optimism=25 bps)
///   3. Initializes a new pool with the Pathfinder hook + 1-day staleness config
///   4. Adds seed liquidity
///   5. Executes a swap — triggers beforeSwap → emits SwapRouted(CHAIN_OPTIMISM)
///
/// Usage:
///   forge script script/DemoSwap.s.sol:DemoSwap \
///     --rpc-url $UNICHAIN_SEPOLIA_RPC --broadcast --private-key $PRIVATE_KEY -vvvv
///
/// Required env:
///   POOL_MANAGER_ADDRESS     - Uniswap v4 PoolManager on Unichain Sepolia
///   PATHFINDER_HOOK_ADDRESS  - Deployed Pathfinder hook
///   LIQUIDITY_CACHE_ADDRESS  - Deployed LiquidityCache
contract DemoSwap is Script {
    using PoolIdLibrary for PoolKey;

    uint24  constant FEE          = 500;
    int24   constant TICK_SPACING = 10;

    // 1:1 initial price (both mock tokens, same decimals=18)
    // sqrtPriceX96 = 2^96 = 79228162514264337593543950336
    uint160 constant INITIAL_SQRT_PRICE = 79228162514264337593543950336;

    // Full-range ticks for tickSpacing=10
    int24 constant TICK_LOWER = -887270;
    int24 constant TICK_UPPER =  887270;

    int256  constant LIQUIDITY_DELTA  = 1e18;
    int256  constant SWAP_AMOUNT      = -1e17;           // exactIn 0.1 TokenA
    uint160 constant SQRT_PRICE_LIMIT = 4295128739 + 1; // MIN_SQRT_PRICE+1 (zeroForOne)

    function run() external {
        address poolManagerAddr = vm.envAddress("POOL_MANAGER_ADDRESS");
        address hookAddress     = vm.envAddress("PATHFINDER_HOOK_ADDRESS");
        address cacheAddress    = vm.envAddress("LIQUIDITY_CACHE_ADDRESS");

        vm.startBroadcast();

        // 1. Deploy two mock tokens
        MockERC20 tokenA = new MockERC20("Mock TokenA", "TKA", 18);
        MockERC20 tokenB = new MockERC20("Mock TokenB", "TKB", 18);
        console.log("TokenA:", address(tokenA));
        console.log("TokenB:", address(tokenB));

        // Ensure currency0 < currency1 (required by PoolManager)
        (address addr0, address addr1) = address(tokenA) < address(tokenB)
            ? (address(tokenA), address(tokenB))
            : (address(tokenB), address(tokenA));
        MockERC20 tok0 = MockERC20(addr0);
        MockERC20 tok1 = MockERC20(addr1);

        // 2. Write snapshot for this pair to LiquidityCache
        //    base=40 bps, optimism=25 bps — Optimism wins
        LiquidityCache(cacheAddress).writeSnapshot(
            addr0, addr1,
            ILiquidityCache.LiquiditySnapshot({
                unichainImpactBps: 50,
                baseImpactBps:     40,
                optimismImpactBps: 25,
                timestamp:         block.timestamp
            })
        );
        console.log("Snapshot written: base=40, optimism=25, ts=now");

        // 3. Build PoolKey and register config
        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(addr0),
            currency1:   Currency.wrap(addr1),
            fee:         FEE,
            tickSpacing: TICK_SPACING,
            hooks:       IHooks(hookAddress)
        });

        Pathfinder(hookAddress).registerConfig(key, IPathfinder.PoolConfig({
            routingThreshold: 15,
            maxStaleness:     86400,
            smallTradeLimit:  0,
            whaleTradeLimit:  type(uint256).max
        }));

        // 4. Initialize pool
        IPoolManager(poolManagerAddr).initialize(key, INITIAL_SQRT_PRICE);
        bytes32 poolId = PoolId.unwrap(key.toId());
        console.log("Pool initialized. Pool ID:");
        console.logBytes32(poolId);

        // 5. Mint tokens and deploy router
        tok0.mint(msg.sender, 1000e18);
        tok1.mint(msg.sender, 1000e18);

        PoolActionsRouter router = new PoolActionsRouter(IPoolManager(poolManagerAddr));
        tok0.approve(address(router), type(uint256).max);
        tok1.approve(address(router), type(uint256).max);

        // 6. Add seed liquidity
        console.log("Adding liquidity...");
        router.addLiquidity(key, TICK_LOWER, TICK_UPPER, LIQUIDITY_DELTA);
        console.log("Liquidity added.");

        // 7. Swap — triggers beforeSwap on Pathfinder hook
        console.log("Executing swap (0.1 TK0 -> TK1)...");
        BalanceDelta delta = router.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne:        true,
                amountSpecified:   SWAP_AMOUNT,
                sqrtPriceLimitX96: SQRT_PRICE_LIMIT
            })
        );
        console.log("Swap complete.");
        console.log("delta.amount0:", delta.amount0());
        console.log("delta.amount1:", delta.amount1());

        vm.stopBroadcast();

        console.log("Done. SwapRouted event should show destination=CHAIN_OPTIMISM(2), reason=improvement_route, improvementBps=25");
    }
}

/// @dev Minimal router that handles unlock callbacks for both addLiquidity and swap.
contract PoolActionsRouter is IUnlockCallback {
    IPoolManager public immutable poolManager;
    address       public immutable owner;

    error OnlyPoolManager();
    error OnlyOwner();

    constructor(IPoolManager _pm) {
        poolManager = _pm;
        owner = msg.sender;
    }

    enum Action { ADD_LIQUIDITY, SWAP }

    struct Payload {
        Action   action;
        PoolKey  key;
        int24    tickLower;
        int24    tickUpper;
        int256   liquidityDelta;
        int256   amountSpecified;
        bool     zeroForOne;
        uint160  sqrtPriceLimitX96;
    }

    function addLiquidity(PoolKey memory key, int24 lo, int24 hi, int256 liq) external {
        if (msg.sender != owner) revert OnlyOwner();
        poolManager.unlock(abi.encode(Payload({
            action: Action.ADD_LIQUIDITY, key: key,
            tickLower: lo, tickUpper: hi, liquidityDelta: liq,
            amountSpecified: 0, zeroForOne: false, sqrtPriceLimitX96: 0
        })));
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory p)
        external returns (BalanceDelta delta)
    {
        if (msg.sender != owner) revert OnlyOwner();
        bytes memory result = poolManager.unlock(abi.encode(Payload({
            action: Action.SWAP, key: key,
            tickLower: 0, tickUpper: 0, liquidityDelta: 0,
            amountSpecified: p.amountSpecified,
            zeroForOne: p.zeroForOne,
            sqrtPriceLimitX96: p.sqrtPriceLimitX96
        })));
        delta = abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        Payload memory p = abi.decode(data, (Payload));

        if (p.action == Action.ADD_LIQUIDITY) {
            (BalanceDelta d,) = poolManager.modifyLiquidity(
                p.key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower:      p.tickLower,
                    tickUpper:      p.tickUpper,
                    liquidityDelta: p.liquidityDelta,
                    salt:           bytes32(0)
                }),
                ""
            );
            _settle(p.key.currency0, d.amount0());
            _settle(p.key.currency1, d.amount1());
            return "";
        } else {
            BalanceDelta d = poolManager.swap(
                p.key,
                IPoolManager.SwapParams({
                    zeroForOne:        p.zeroForOne,
                    amountSpecified:   p.amountSpecified,
                    sqrtPriceLimitX96: p.sqrtPriceLimitX96
                }),
                ""
            );
            _settle(p.key.currency0, d.amount0());
            _settle(p.key.currency1, d.amount1());
            return abi.encode(d);
        }
    }

    function _settle(Currency currency, int128 delta) internal {
        if (delta < 0) {
            uint256 amount = uint256(uint128(-delta));
            poolManager.sync(currency);
            MockERC20(Currency.unwrap(currency)).transferFrom(owner, address(poolManager), amount);
            poolManager.settle();
        } else if (delta > 0) {
            poolManager.take(currency, owner, uint256(uint128(delta)));
        }
    }
}
