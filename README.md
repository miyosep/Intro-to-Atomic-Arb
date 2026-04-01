# MEV 原子套利 Tx Re-simulation

给定原子套利 tx，在 Foundry fork 下 re-simulate，按 **链上 call trace 的内层顺序** 复刻交互，得到与原 tx 一致的套利 profit。

**目标 Tx**: [0x9edea0b66aece76f0bc7e185f9ce5cac81ce41bdd1ec4d3cf1907274bc8aa730](https://etherscan.io/tx/0x9edea0b66aece76f0bc7e185f9ce5cac81ce41bdd1ec4d3cf1907274bc8aa730)  
**Block**: 23042800 | **Position**: 182  
**Tx.value**: 0 ETH（用户仅支付 gas）

## Re-simulate

1. **Fork**: 用 `vm.createSelectFork(rpcUrl, txHash)` 在 tx 所在区块 fork，replay 该 tx 之前的所有交易，得到与原 tx 执行前完全相同的链上 state。
2. **执行**: 用合约 [`ArbitragePathTraceOrder.sol`](src/ArbitragePathTraceOrder.sol) 按 trace 顺序调用：**Vault redeem (pfWETH→WETH) → Uniswap V3 (WETH→EMP) → Peapod Bond (EMP→pEMP) → Uniswap V2 (pEMP→pfWETH)**，最后将剩余 WETH unwrap 分给 User / BuilderNet。测试里用 `deal` 注入与 flash 借入量相同的 vault shares，等价于原 tx 在 V2 flash 回调内的资金需求。
3. **验证**: `vm.transact(txHash)` 与上述路径对比 User、BuilderNet 收到的 ETH（见 `test_Verify_TxHashFork_OriginalVsOurPath`）。

## 套利路径（token 为节点，pool 为边）

闭包上的协议与顺序（**内层执行**，与 Etherscan 事件顺序一致）：

```
pfWETH --[Vault redeem]--> WETH --[Uniswap V3]--> EMP --[Bond]--> pEMP --[Uniswap V2]--> pfWETH
```

原 tx 在 **最外层** 还会先对 Uniswap V2 调 `swap` 触发 flash；回调内执行与上表相同的 DeFi 步骤。可选对照实现：[`ArbitragePathFlashSwap.sol`](src/ArbitragePathFlashSwap.sol)（V2 flash 包装）及 `test_OptionFlashSwap_EquivalentProfit`。

涉及协议：Uniswap V2 (`0x9FF3…`), Peapod Vault (`0x395d…`), Uniswap V3 (`0xe092…`), Peapod Bond / pEMP (`0x4343…`)。

## 如何运行

需要 **Archive RPC**（Alchemy/Infura 等）。免费 RPC 无 archive 会报 `state at block is pruned`。

```powershell
$env:MAINNET_RPC_URL = "https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"

# 完整验证 (原 tx vs trace-order 路径)
forge test --match-test test_Verify_TxHashFork_OriginalVsOurPath -vvv

# 仅 replay 原 tx
forge test --match-test test_ResimulateTxWithFork -vvv
```

## 相关测试

| 测试 | 作用 |
|------|------|
| `test_Verify_TxHashFork_OriginalVsOurPath` | 原 tx 与 `ArbitragePathTraceOrder` 分账一致 |
| `test_ResimulateTxWithFork` | 直接 replay 原 tx |
| `test_Task7_FullPathWithProfit` | 全路径 + 利润 |
| `test_Task7_FullArbitragePath` | Vault+V3 后 EMP 数量与原 tx 一致 |
| `test_QuickVerify_TraceOrder` | 区块头 state 快速冒烟（金额可能略异于 #182） |
| `test_OptionFlashSwap_EquivalentProfit` | 可选：V2 flash 等价路径 |

## Foundry API

| API | 说明 |
|-----|------|
| `vm.createSelectFork(url, txHash)` | Fork 到 tx 所在区块，replay 该 tx 之前所有交易 |
| `vm.createSelectFork(url, blockNumber)` | Fork 到区块号（区块开始时的 state） |
| `vm.transact(txHash)` | 在 fork 上执行该 tx |

## 常见问题

| 错误 | 原因 | 解决 |
|------|------|------|
| `state at block is pruned` | RPC 无 archive | 使用 Alchemy/Infura archive |
| `HTTP 429` | 限流 | 更换 RPC |

## 调试

```powershell
forge test --match-test test_TraceOriginalTx -vvvv
forge test --match-test test_DebugPathStepByStep -vvvv
```

## 项目结构

```
src/ArbitragePathTraceOrder.sol   # Trace 顺序复刻（主路径）
src/ArbitragePathFlashSwap.sol    # V2 flash 包装（可选对照）
src/ArbitragePath.sol             # 旧版 V2-first 分步（遗留/调试）
test/MEVResimulate.t.sol          # Fork + Re-simulate 测试
```