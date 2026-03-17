# MEV Tx Re-simulation 指南

## 测试运行 (必需)

原 tx re-simulate 测试需要 **Archive RPC**。LlamaRPC 为 pruned state，会失败。

```powershell
$env:MAINNET_RPC_URL = "https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"   # Alchemy
# 或
$env:MAINNET_RPC_URL = "https://mainnet.infura.io/v3/YOUR_KEY"           # Infura

forge test --match-test "test_Task7_FullPathWithProfit|test_Verify_TxHashFork_OriginalVsOurPath|test_Task7_FullPathWithProfit_BlockStart" -vv
```

## 目标 (Tasks 5–7)

1. **Task 5**: 在指定 block 的指定 index 处 re-simulate tx
2. **Task 6**: 编写与该 tx 中所有 DEX 交互的合约
3. **Task 7**: 使用相同 input 和 DEX pools 进行 re-simulate，验证 output amount 与原 tx 一致

## 目标交易

- **Tx Hash**: `0x9edea0b66aece76f0bc7e185f9ce5cac81ce41bdd1ec4d3cf1907274bc8aa730`
- **Block**: 23042800
- **Block 内 Position**: 182

## 套利路径 (Token = 节点, DEX = 边)

```
                    ┌─────────────────────────────────────────┐
                    │                                         │
                    ▼                                         │
    pEMP (0x4343) ──► [Uniswap V2 0x9FF3] ──► pfWETH (0x395d) │
         ▲                    │                     │         │
         │                    │                     ▼         │
         │                    │              [Vault redeem]    │
         │                    │                     │         │
         │                    │                     ▼         │
         │                    │                   WETH        │
         │                    │                     │         │
         │                    │                     ▼         │
         │                    │              [Uniswap V3 0xe092]│
         │                    │                     │         │
         └────────────────────┴─────────────────────┴─────────┘
                                    EMP (0x39D5)
```

**原 tx 的额外步骤**: EMP → Bond(0x4343) → pEMP + User 0.00643 ETH (gross) + BuilderNet 0.00059 ETH

## 交换流程 (Tx 分析结果)

```
pEMP (0x4343... Peapod) 
  → [Uniswap V2 Pair 0x9FF3...] 
  → pfWETH (0x395d... Peapod/Primitive vault share) 
  → [ERC4626 Vault redeem] 
  → WETH 
  → [Uniswap V3 Pool 0xe092...] 
  → EMP (0x39D5...)
```

## 使用的协议 (已全部实现)

| 协议 | 地址 | 作用 |
|------|------|------|
| Uniswap V2 | 0x9FF3226906eB460E11d88f4780C84457A2f96C3e | pEMP ↔ pfWETH 交换 |
| Peapod/Primitive Vault (ERC4626) | 0x395dA89bDb9431621A75DF4e2E3B993Acc2CaB3D | pfWETH → WETH redeem |
| Uniswap V3 | 0xe092769bc1fa5262D4f48353f90890Dcc339BF80 | WETH → EMP 交换 |
| Peapod Bond (0x4343) | 0x4343A06B930Cf7Ca0459153C62CC5a47582099E1 | EMP → pEMP (bond) |

## 项目结构

```
src/
├── ArbitragePath.sol         # 完整 arbitrage 路径 (V2 + Vault + V3)
├── ArbitragePathFlashSwap.sol # Option A: Uniswap V2 flash swap (满足要求)
├── DEXSwap.sol               # Uniswap V2/V3 单独 swap
├── interfaces/
│   ├── IERC20.sol
│   ├── IERC4626.sol        # Vault redeem (Peapod/Primitive)
│   ├── IUniswapV2Pair.sol
│   ├── IUniswapV3Pool.sol
│   └── IWETH.sol
test/
└── MEVResimulate.t.sol     # Fork + Re-simulate + Full path 测试
```

## 原 tx 结构追踪

分析原 tx 的调用顺序:

```powershell
# 1) cast run 追踪 (输出保存到 trace-output.txt)
.\script\trace-tx.ps1

# 2) 或 forge test replay + 详细 trace
forge test --match-test test_TraceOriginalTx -vvvv
```

`-vvvv` 时输出 call trace、内部调用、revert 等。

## Step-by-step 调试 (失败位置/原因确认)

确认我们的路径在何处、为何失败:

```powershell
forge test --match-test test_DebugPathStepByStep -vvvv
```

失败时输出示例:
- `Step 1 (V2): pfWETH output is 0. amountIn (pair received) may be too low (pEMP fee-on-transfer?)`
- `Step 2 (Vault): WETH insufficient for V3. See DebugStepFail(have, need) in logs.`
- `Step 3 (V3): EMP output is 0`
- `Step 4 (Bond): bond() failed`
- `Step 5: ETH transfer to recipient failed`

每步会输出 `DebugStep(step, name, value)` 事件。

---

## 运行方法

### 1. 前置要求

- **Archive RPC**: 区块 23042800 的 fork 需要 **Archive Node** RPC。
  - 公开 RPC (eth.llamarpc.com 等) 不支持该区块 state
  - 使用 **Alchemy**、**Infura**、**QuickNode** 等 archive 支持套餐

### 2. 环境变量

```powershell
# Windows PowerShell - 复制 .env.example 后替换 YOUR_API_KEY
Copy-Item .env.example .env
# 编辑 .env: MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY

# 或直接设置
$env:MAINNET_RPC_URL = "https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"
```

### 2-1. 测试失败时 (historical state / pruned / 429)

| 错误 | 原因 | 解决 |
|------|------|------|
| `historical state is not available` | 免费 RPC 无 archive | Alchemy/Infura 免费账户 → 申请 API key |
| `state at block is pruned` | 同上 | |
| `HTTP 429` (rate limit) | LlamaRPC 等限制 | 更换 Archive RPC |

**无 Archive RPC 时仅运行可通过的测试:**
```powershell
forge test --no-match-test "test_Verify|test_Task7_FullArbitragePath|test_Task7_ManualResimulate|test_Task7_ResimulateOutput|test_Resimulate|test_ForkAtBlockThenTransact|test_TraceOriginal|test_Task7_FullPathWithProfit|test_DebugPathStepByStep"
```

### 2-2. 缩短验证时间

| 方法 | 命令 | 预计时间 |
|------|------|----------|
| **快速验证** | `forge test --match-test test_QuickVerify_FlashSwap` | ~10s (BLOCK_NUMBER fork) |
| **仅路径** | `forge test --match-test test_Task7_FullArbitragePath_BlockStart` | ~10s |
| **精确验证** | `forge test --match-test test_Verify_TxHashFork_OriginalVsOurPath` | ~60s (TX_HASH replay) |

- **快速验证**: 仅用 BLOCK_NUMBER fork (无 181 tx replay)。仅确认路径可执行。
- **精确验证**: TX_HASH fork 与原 tx 相同 state 下比较。需要时再运行。
- **缓存**: Foundry 在 `~/.foundry/cache/rpc` 缓存 fork 数据。第二次运行起更快。

### 3. Task 5: Re-simulate tx

```bash
# vm.createSelectFork(rpcUrl, txHash) - 在 tx 所在区块 fork，replay 之前所有 tx
# vm.transact(txHash) - 执行该 tx
forge test --match-test test_ResimulateTxWithFork -vvv
```

### 4. Task 7: Output 验证

```bash
# 原 tx replay 后 output 验证
forge test --match-test test_Task7_ResimulateOutputMatchesOriginal -vvv

# DEXSwap 合约手动 re-simulate (V2 swap 验证)
forge test --match-test test_Task7_ManualResimulateWithDEXContract -vvv
```

## Foundry 核心 API

| API | 说明 |
|-----|------|
| `vm.createSelectFork(url, txHash)` | 在 tx 所在区块 fork，replay 之前所有 tx |
| `vm.createSelectFork(url, blockNumber)` | 按区块号 fork (区块开始时的 state) |
| `vm.transact(txHash)` | 从 fork 获取并执行 tx |
| `deal(token, to, amount)` | 设置 ERC20 余额 (测试用) |

## 实现注意事项

| 问题 | 说明 | 处理 |
|------|------|------|
| **pEMP fee-on-transfer** | pEMP transfer 时扣费。pair 实际收到量 < 发送量 | DEXSwap/ArbitragePath: `balanceOf(pair) - reserve` 计算实际收到量 |
| **V3 sqrtPriceLimitX96** | zeroForOne=false 时价格上升。使用 MAX_SQRT_RATIO-1 | ArbitragePath: `1461446703485210103287273052203988822378723970341` |
| **V3 amountSpecified** | POSITIVE = exact input, NEGATIVE = exact output | 使用 +int256 |
| **Archive RPC** | LlamaRPC 无 archive(429)。区块 23042800 fork 需要 | 使用 Alchemy/Infura/QuickNode archive |
| **Bond (0x4343)** | EMP → pEMP。bond(address,uint256,uint256) = 0xb08d0333 | bond(token, amount, amountMintMin)。失败则 tx revert |
| **pEMP fee-on-transfer** | MEV bot 发送时 fee 不适用，test contract 发送时 fee 适用 | **Option A**: Uniswap V2 flash swap of pfWETH → Vault → V3 → Bond → repay with pEMP (Bond mint, 无 fee) |

---

## pEMP Fee-on-Transfer 分析

### pEMP 代币结构

- **代理**: 0x4343A06B930Cf7Ca0459153C62CC5a47582099E1 (Beacon Proxy)
- **实现**: 0x50d2acb0d9ee43c39dcf7cf694e94a0f9187491a (WeightedIndex, Peapod)

### 原 tx ERC-20 转账顺序 (Etherscan)

| 顺序 | From | To | 代币 | 金额 | 含义 |
|------|------|-----|------|------|------|
| 1 | Null | MEV Bot | pEMP | 17.50 | Bond mint (bond fee 除外) |
| 2 | Null | 0x4343 | pEMP | 0.0175 | Bond fee |
| 3 | MEV Bot | Uniswap V2 | pEMP | **17.169** | V2 repay (flash swap 偿还) |
| 4 | Uniswap V2 | MEV Bot | pfWETH | 0.531 | V2 borrow 输出 |

### 关键发现

1. **原 tx 也是 Flash Swap**: MEV bot 并非先持有 pEMP 再发给 V2，而是 **先从 V2 借 pfWETH**，经 Bond 生成 pEMP 后 **偿还**。
2. **Pair 收到量**: Etherscan 显示 Uniswap V2 pair 收到 pEMP = **17.169169459862071375** (全额)。
3. **Bond mint pEMP**: Bond 生成的 pEMP 通过 `_mint()` 发行，不经过 `_update`，**无 transfer fee**。
4. **Option A (Flash Swap)**: 不发送 pEMP，借 pfWETH，经 Bond 生成 pEMP 后偿还，可**完全绕过** transfer/sell fee。

---

## V2 输出差异 (0.52 vs 0.53 pfWETH)

### 现象

| 区分 | 原 tx | 我们的实现 (BLOCK_NUMBER fork) |
|------|--------|-------------------------------|
| V2 输入 | 17.17 pEMP | 17.17 pEMP |
| V2 输出 | **0.5309** pfWETH | **0.5102** pfWETH |

### 原因

1. **pEMP fee-on-transfer**: 17.17 发送时 pair 实际收到 ≈ 16.84 (约 2% 费用)。
2. **Fork 时点差异**:
   - `createSelectFork(TX_HASH)`: tx 前 state (区块内 181 个 tx replay 后)。**需 Archive RPC**。
   - `createSelectFork(BLOCK_NUMBER)`: 区块开始时的 state。
3. 原 tx 为区块 **第 182 个** tx。181 个 tx 之后 pool state 可能已变化。

### 结论

- **BLOCK_NUMBER fork** 使用区块开始时的 state。与原 tx 实际执行时点 (区块内 181 个 tx 之后) 的 pool state 不同。
- 使用 **TX_HASH fork** 可获得与原 tx 相同的 0.53 输出。需要 archive RPC。
