# MEV 原子套利 Tx Re-simulation

给定原子套利 tx，在 Foundry fork 下 re-simulate，复刻套利路径，得到与原 tx 一致的 profit。

**目标 Tx**: [0x9edea0b66aece76f0bc7e185f9ce5cac81ce41bdd1ec4d3cf1907274bc8aa730](https://etherscan.io/tx/0x9edea0b66aece76f0bc7e185f9ce5cac81ce41bdd1ec4d3cf1907274bc8aa730)  
**Block**: 23042800 | **Position**: 182

## Re-simulate

1. **Fork**: 用 `vm.createSelectFork(rpcUrl, txHash)` 在 tx 所在区块 fork，replay 该 tx 之前的所有交易，得到与原 tx 执行前完全相同的链上 state。
2. **执行**: 用合约 `ArbitragePathFlashSwap` 执行相同路径（Flash borrow pfWETH → Vault → V3 → Bond → V2 repay）。
3. **验证**: 比较 User、BuilderNet 收到的 ETH 与原 tx 一致。

## 套利路径

```
Flash borrow pfWETH (V2) → Vault redeem → V3 (WETH→EMP) → Bond (EMP→pEMP) → V2 repay
Profit: User ~0.00643 ETH, BuilderNet ~0.00059 ETH
```

涉及协议：Uniswap V2 (0x9FF3), Peapod Vault (0x395d), Uniswap V3 (0xe092), Peapod Bond (0x4343)。

## 如何运行

需要 **Archive RPC**（Alchemy/Infura 等）。免费 RPC 无 archive 会报 `state at block is pruned`。

```powershell
$env:MAINNET_RPC_URL = "https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"

# 完整验证 (原 tx vs 我们的路径)
forge test --match-test test_Verify_TxHashFork_OriginalVsOurPath -vvv

# 仅 replay 原 tx ~20min
forge test --match-test test_ResimulateTxWithFork -vvv

## 相关测试

| 测试 | 作用 |
|------|------|
| `test_Verify_TxHashFork_OriginalVsOurPath` | 完整验证，输出与原 tx 一致 |
| `test_ResimulateTxWithFork` | 直接 replay 原 tx |
| `test_Task7_FullPathWithProfit` | 我们的路径执行 |
| `test_QuickVerify_FlashSwap` | 快速验证 |

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
# 查看原 tx call trace
forge test --match-test test_TraceOriginalTx -vvvv

# 逐步调试路径失败位置
forge test --match-test test_DebugPathStepByStep -vvvv
```

## 项目结构

```
src/ArbitragePathFlashSwap.sol   # Re-simulate 使用的合约
test/MEVResimulate.t.sol         # Fork + Re-simulate 测试
```
