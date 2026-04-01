// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {DEXSwap} from "../src/DEXSwap.sol";
import {ArbitragePath} from "../src/ArbitragePath.sol";
import {ArbitragePathFlashSwap} from "../src/ArbitragePathFlashSwap.sol";
import {ArbitragePathTraceOrder} from "../src/ArbitragePathTraceOrder.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IUniswapV2Pair} from "../src/interfaces/IUniswapV2Pair.sol";

/**
 * @title MEVResimulate
 * @notice Task 5 & 7: Fork + Re-simulate MEV tx at specified block
 *
 * Target tx: 0x9edea0b66aece76f0bc7e185f9ce5cac81ce41bdd1ec4d3cf1907274bc8aa730
 * Block: 23042800, Position: 182
 *
 * On-chain inner order (tx trace): Vault redeem -> Uniswap V3 -> Bond -> Uniswap V2 (pEMP->pfWETH).
 * Live tx wraps this in V2 flash swap first; re-sim uses ArbitragePathTraceOrder + deal vault shares.
 */
contract MEVResimulateTest is Test {
    bytes32 constant TX_HASH = 0x9edea0b66aece76f0bc7e185f9ce5cac81ce41bdd1ec4d3cf1907274bc8aa730;
    uint256 constant BLOCK_NUMBER = 23_042_800;

    // Addresses from the tx
    address constant MEV_BOT = 0x50bf20318cE9100ac4374AB4BeD5FE4b1F8cC6B3;
    address constant USER = 0x1b9FcB24c533839dC847235bd8Eb80E37EC42f85;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant EMP = 0x39D5313C3750140E5042887413bA8AA6145a9bd2;

    // Uniswap V2 pair: pfWETH-4-pEMP
    address constant UNISWAP_V2_PAIR = 0x9FF3226906eB460E11d88f4780C84457A2f96C3e;
    // Uniswap V3 pool: EMP/WETH
    address constant UNISWAP_V3_POOL = 0xe092769bc1fa5262D4f48353f90890Dcc339BF80;

    // Token amounts from tx (18 decimals assumed for precision)
    uint256 constant INPUT_TOKEN_AMOUNT = 17_169_169_459_862_071_375; // ~17.17
    uint256 constant UNISWAP_V2_OUTPUT = 530_916_054_946_304_482; // ~0.53
    uint256 constant WETH_INPUT = 562_611_020_353_505_727; // ~0.56 WETH
    uint256 constant EMP_OUTPUT = 17_975_419_691_953_642_945; // ~17.97 EMP

    function setUp() public {}

    /// No fork needed - verifies DEXSwap deploys and has correct interface
    function test_DEXSwapDeploys() public {
        DEXSwap swapper = new DEXSwap();
        assertEq(address(swapper).code.length > 0, true);
    }

    /**
     * Task 5: Re-simulate tx using vm.createSelectFork(txHash)
     * - Fork at the block containing the tx (replays all txs before it)
     * - vm.transact(txHash) executes the tx
     *
     * Run: forge test --match-test test_ResimulateTxWithFork -vvv
     * Requires: MAINNET_RPC_URL env var (e.g. Infura, Alchemy)
     */
    function test_ResimulateTxWithFork() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string("https://eth.llamarpc.com"));

        // createSelectFork(url, txHash): fork at block of tx, replay all prior txs in block
        vm.createSelectFork(rpcUrl, TX_HASH);

        // State is now exactly as it was right before our tx executed
        assertEq(block.number, BLOCK_NUMBER, "Should be at tx block");

        // Record balances before
        uint256 userEthBefore = USER.balance;

        // Re-execute the tx (re-simulate)
        vm.transact(TX_HASH);

        // Verify tx executed (balances changed)
        uint256 userEthAfter = USER.balance;

        // vm.transact replay: User balance delta = net (gross - gas, User 为 tx 签名者)
        assertGt(userEthAfter, userEthBefore, "User should receive ETH");
        assertEq(userEthAfter - userEthBefore, USER_NET, "User net (replay) should match");
    }

    /**
     * Alternative: Fork at block number only (faster, but state = start of block)
     * Use when you don't need exact pre-tx state
     */
    function test_ForkAtBlockThenTransact() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string("https://eth.llamarpc.com"));

        vm.createSelectFork(rpcUrl, BLOCK_NUMBER);
        assertEq(block.number, BLOCK_NUMBER);

        // transact replays the tx - state may differ if prior txs in block mattered
        vm.transact(TX_HASH);
    }

    /**
     * Task 5 variant: Fork at block, then roll to specific tx index
     * Foundry doesn't have direct "tx index" param - use txHash for that
     */
    function test_ForkAtBlockNumber() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string("https://eth.llamarpc.com"));

        vm.createSelectFork(rpcUrl, BLOCK_NUMBER);
        assertEq(block.number, BLOCK_NUMBER);
    }

    // --- Task 7: Re-simulate with same input, same pools, verify output ---

    address constant TOKEN_IN = 0x4343A06B930Cf7Ca0459153C62CC5a47582099E1; // pEMP
    address constant TOKEN_V2_OUT = 0x395dA89bDb9431621A75DF4e2E3B993Acc2CaB3D;
    address constant BUILDERNET = 0xdadB0d80178819F2319190D340ce9A924f783711;
    uint256 constant USER_AMOUNT = 6435308948727846; // 原 tx: MEV bot → User gross 0.006435308948727846 ETH
    uint256 constant USER_NET = 5969877670159834; // User net (gross - gas, vm.transact 时 balance delta)
    uint256 constant BUILDERNET_AMOUNT = 593974446933372; // 原 tx: BuilderNet 收到 0.000593974446933372 ETH

    /// @dev Vault ERC4626 share token = pair token0; same address as TOKEN_V2_OUT
    function _fundVaultSharesForTrace(address path, uint256 shareAmount) internal {
        deal(TOKEN_V2_OUT, path, shareAmount);
    }

    /**
     * Task 7: Verify replayed tx produces same output
     * vm.transact replays the exact tx - output must match
     */
    function test_Task7_ResimulateOutputMatchesOriginal() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string("https://eth.llamarpc.com"));
        vm.createSelectFork(rpcUrl, TX_HASH);

        uint256 userEthBefore = USER.balance;

        vm.transact(TX_HASH);

        uint256 userEthAfter = USER.balance;

        // vm.transact replay: User balance delta = net
        assertEq(userEthAfter - userEthBefore, USER_NET);
    }

    /**
     * Partial leg: Uniswap V2 pEMP->pfWETH only (closing edge of the cycle; full trace uses ArbitragePathTraceOrder)
     */
    function test_Task7_ManualResimulateWithDEXContract() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string("https://eth.llamarpc.com"));
        vm.createSelectFork(rpcUrl, TX_HASH);

        DEXSwap swapper = new DEXSwap();

        deal(TOKEN_IN, address(this), INPUT_TOKEN_AMOUNT);
        IERC20(TOKEN_IN).approve(address(swapper), INPUT_TOKEN_AMOUNT);

        uint256 v2Out = swapper.swapV2ExactIn(UNISWAP_V2_PAIR, TOKEN_IN, INPUT_TOKEN_AMOUNT, UNISWAP_V2_OUTPUT - 1);

        assertApproxEqAbs(v2Out, UNISWAP_V2_OUTPUT, UNISWAP_V2_OUTPUT / 100, "V2 output should match");
    }

    /// Task 7: Full path re-simulate - output MUST match original tx (~17.97 EMP)
    /// Uses TX_HASH fork to get exact pre-tx state (block-start differs: tx was #182 in block)
    /// Requires: MAINNET_RPC_URL with archive support (Alchemy, Infura, etc.)
    ///   LlamaRPC often fails: "state at block is pruned"
    function test_Task7_FullArbitragePath() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string("https://eth.llamarpc.com"));
        vm.createSelectFork(rpcUrl, TX_HASH);

        ArbitragePathTraceOrder path = new ArbitragePathTraceOrder();
        _fundVaultSharesForTrace(address(path), UNISWAP_V2_OUTPUT);

        uint256 empReceived = path.executeVaultRedeemThenV3(
            UNISWAP_V2_PAIR, TOKEN_V2_OUT, UNISWAP_V3_POOL, WETH, UNISWAP_V2_OUTPUT, WETH_INPUT
        );

        assertEq(empReceived, EMP_OUTPUT, "EMP after Vault+V3 must match original tx");
    }

    /// Task 7: Full path — trace order (Vault -> V3 -> Bond -> V2) + User/BuilderNet ETH
    function test_Task7_FullPathWithProfit() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string("https://eth.llamarpc.com"));
        vm.createSelectFork(rpcUrl, TX_HASH);

        ArbitragePathTraceOrder path = new ArbitragePathTraceOrder();
        _fundVaultSharesForTrace(address(path), UNISWAP_V2_OUTPUT);

        uint256 userEthBefore = USER.balance;

        path.executeTraceOrder(
            UNISWAP_V2_PAIR,
            TOKEN_V2_OUT,
            UNISWAP_V3_POOL,
            TOKEN_IN,
            EMP,
            WETH,
            USER,
            UNISWAP_V2_OUTPUT,
            WETH_INPUT,
            USER_AMOUNT,
            BUILDERNET,
            BUILDERNET_AMOUNT
        );

        uint256 userEthAfter = USER.balance;

        assertEq(userEthAfter - userEthBefore, USER_AMOUNT, "User ETH should match original tx");
    }

    /// 原 tx gas 费用 (Etherscan: 0.000465431278568012 ETH)。User 为 tx 签名者故支付。
    uint256 constant TX_GAS_WEI = 465431278568012;

    /// Verify: TX_HASH fork — vm.transact vs trace-order path (ArbitragePathTraceOrder)
    function test_Verify_TxHashFork_OriginalVsOurPath() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string("https://eth.llamarpc.com"));
        vm.createSelectFork(rpcUrl, TX_HASH);

        uint256 userEthBefore = USER.balance;
        uint256 builderNetBefore = BUILDERNET.balance;
        vm.transact(TX_HASH);
        uint256 ethFromOriginalUser = USER.balance - userEthBefore;
        uint256 ethFromOriginalBuilderNet = BUILDERNET.balance - builderNetBefore;

        vm.createSelectFork(rpcUrl, TX_HASH);
        ArbitragePathTraceOrder path = new ArbitragePathTraceOrder();
        _fundVaultSharesForTrace(address(path), UNISWAP_V2_OUTPUT);

        uint256 userEthBefore2 = USER.balance;
        uint256 builderNetBefore2 = BUILDERNET.balance;
        path.executeTraceOrder(
            UNISWAP_V2_PAIR,
            TOKEN_V2_OUT,
            UNISWAP_V3_POOL,
            TOKEN_IN,
            EMP,
            WETH,
            USER,
            UNISWAP_V2_OUTPUT,
            WETH_INPUT,
            USER_AMOUNT,
            BUILDERNET,
            BUILDERNET_AMOUNT
        );
        uint256 ethFromOursUser = USER.balance - userEthBefore2;
        uint256 ethFromOursBuilderNet = BUILDERNET.balance - builderNetBefore2;

        emit log_named_uint("Original (User net)", ethFromOriginalUser);
        emit log_named_uint("Ours (User gross)", ethFromOursUser);
        emit log_named_uint("Original (BuilderNet)", ethFromOriginalBuilderNet);
        emit log_named_uint("Ours (BuilderNet)", ethFromOursBuilderNet);

        assertEq(ethFromOursUser, ethFromOriginalUser + TX_GAS_WEI, "Our path User gross should match original");
        assertEq(ethFromOursBuilderNet, ethFromOriginalBuilderNet, "Our path BuilderNet amount should match original");
    }

    /// Quick check at block start (may differ from tx #182 state). Trace-order path.
    function test_QuickVerify_TraceOrder() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string("https://eth.llamarpc.com"));
        vm.createSelectFork(rpcUrl, BLOCK_NUMBER);

        ArbitragePathTraceOrder path = new ArbitragePathTraceOrder();
        _fundVaultSharesForTrace(address(path), UNISWAP_V2_OUTPUT);
        uint256 userEthBefore = USER.balance;

        path.executeTraceOrder(
            UNISWAP_V2_PAIR,
            TOKEN_V2_OUT,
            UNISWAP_V3_POOL,
            TOKEN_IN,
            EMP,
            WETH,
            USER,
            UNISWAP_V2_OUTPUT,
            WETH_INPUT,
            USER_AMOUNT,
            BUILDERNET,
            BUILDERNET_AMOUNT
        );

        assertGt(USER.balance, userEthBefore, "User should receive ETH");
    }

    /// Optional: V2 flash wrapper — economically similar, different call wrapper than live tx
    function test_OptionFlashSwap_EquivalentProfit() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string("https://eth.llamarpc.com"));
        vm.createSelectFork(rpcUrl, TX_HASH);

        ArbitragePathFlashSwap path = new ArbitragePathFlashSwap();
        uint256 userEthBefore = USER.balance;

        path.executeFullPathWithFlashSwap(
            UNISWAP_V2_PAIR,
            TOKEN_V2_OUT,
            UNISWAP_V3_POOL,
            TOKEN_IN,
            EMP,
            WETH,
            USER,
            WETH_INPUT,
            UNISWAP_V2_OUTPUT,
            USER_AMOUNT,
            BUILDERNET,
            BUILDERNET_AMOUNT
        );

        assertEq(USER.balance - userEthBefore, USER_AMOUNT, "Flash path User ETH");
    }

    /// 原 tx 结构追踪: vm.transact replay 后查看 trace
    /// 运行: forge test --match-test test_TraceOriginalTx -vvvv
    /// -vvvv 时输出 call trace、revert 等详情
    function test_TraceOriginalTx() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string("https://eth.llamarpc.com"));
        vm.createSelectFork(rpcUrl, TX_HASH);
        vm.transact(TX_HASH);
    }

    /// Debug: run trace-order path on TX_HASH fork (-vvvv on failure)
    function test_DebugPathStepByStep() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string("https://eth.llamarpc.com"));
        vm.createSelectFork(rpcUrl, TX_HASH);

        ArbitragePathTraceOrder path = new ArbitragePathTraceOrder();
        _fundVaultSharesForTrace(address(path), UNISWAP_V2_OUTPUT);

        path.executeTraceOrder(
            UNISWAP_V2_PAIR,
            TOKEN_V2_OUT,
            UNISWAP_V3_POOL,
            TOKEN_IN,
            EMP,
            WETH,
            USER,
            UNISWAP_V2_OUTPUT,
            WETH_INPUT,
            USER_AMOUNT,
            BUILDERNET,
            BUILDERNET_AMOUNT
        );
    }

    /// Debug: Log V2 swap params to find why we get 0.52 vs 0.53 pfWETH
    /// Original tx: 17.17 pEMP -> 0.530916054946304482 pfWETH
    /// Set USE_ARCHIVE_FORK=1 + archive RPC for TX_HASH (exact pre-tx state). Default: BLOCK_NUMBER.
    function test_DebugV2SwapParams() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string("https://eth.llamarpc.com"));
        if (vm.envOr("USE_ARCHIVE_FORK", uint256(0)) == 1) {
            vm.createSelectFork(rpcUrl, TX_HASH);
        } else {
            vm.createSelectFork(rpcUrl, BLOCK_NUMBER);
        }

        ArbitragePath path = new ArbitragePath();
        deal(TOKEN_IN, address(this), INPUT_TOKEN_AMOUNT);
        IERC20(TOKEN_IN).approve(address(path), INPUT_TOKEN_AMOUNT);

        (uint256 r0, uint256 r1, uint256 amountIn, uint256 pfWETHOut) =
            path.debugV2Swap(INPUT_TOKEN_AMOUNT, UNISWAP_V2_PAIR);

        // Log for analysis
        emit log_named_uint("r0 (pfWETH reserve)", r0);
        emit log_named_uint("r1 (pEMP reserve)", r1);
        emit log_named_uint("amountIn (actual pEMP received by pair)", amountIn);
        emit log_named_uint("pfWETHOut (our calc)", pfWETHOut);
        emit log_named_uint("UNISWAP_V2_OUTPUT (original)", UNISWAP_V2_OUTPUT);

        // Reverse: what amountIn would give 0.53? amountIn = out * r1 * 1000 / (997 * (r0 - out))
        uint256 amountInForOriginal = (UNISWAP_V2_OUTPUT * r1 * 1000) / (997 * (r0 - UNISWAP_V2_OUTPUT));
        emit log_named_uint("amountIn needed for 0.53 output", amountInForOriginal);

        // Diff: our amountIn vs needed
        emit log_named_uint(
            "diff amountIn (ours - needed)",
            amountIn > amountInForOriginal ? amountIn - amountInForOriginal : amountInForOriginal - amountIn
        );
    }

    /// TX_HASH fork + trace-order full path (exact pre-tx reserves)
    function test_Task7_FullPathWithProfit_BlockStart() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string("https://eth.llamarpc.com"));
        vm.createSelectFork(rpcUrl, TX_HASH);

        ArbitragePathTraceOrder path = new ArbitragePathTraceOrder();
        _fundVaultSharesForTrace(address(path), UNISWAP_V2_OUTPUT);

        uint256 userEthBefore = USER.balance;
        path.executeTraceOrder(
            UNISWAP_V2_PAIR,
            TOKEN_V2_OUT,
            UNISWAP_V3_POOL,
            TOKEN_IN,
            EMP,
            WETH,
            USER,
            UNISWAP_V2_OUTPUT,
            WETH_INPUT,
            USER_AMOUNT,
            BUILDERNET,
            BUILDERNET_AMOUNT
        );
        uint256 userEthAfter = USER.balance;

        assertEq(userEthAfter - userEthBefore, USER_AMOUNT, "User should receive original amount");
    }

    /// Vault+V3 only at block start (reserves differ from tx index 182)
    function test_Task7_FullArbitragePath_BlockStart() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string("https://eth.llamarpc.com"));
        vm.createSelectFork(rpcUrl, BLOCK_NUMBER);

        ArbitragePathTraceOrder path = new ArbitragePathTraceOrder();
        _fundVaultSharesForTrace(address(path), UNISWAP_V2_OUTPUT);

        uint256 empReceived = path.executeVaultRedeemThenV3(
            UNISWAP_V2_PAIR, TOKEN_V2_OUT, UNISWAP_V3_POOL, WETH, UNISWAP_V2_OUTPUT, WETH_INPUT
        );

        assertGt(empReceived, 0.5e18, "Path should yield > 0.5 EMP");
    }
}
