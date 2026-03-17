# MEV 原子套利 Tx Re-simulation

给定原子套利 tx，复刻套利路径，在 Foundry fork 下 re-simulate 得到与原 tx 一致的套利 profit。

**目标 Tx**: [0x9edea0b66aece76f0bc7e185f9ce5cac81ce41bdd1ec4d3cf1907274bc8aa730](https://etherscan.io/tx/0x9edea0b66aece76f0bc7e185f9ce5cac81ce41bdd1ec4d3cf1907274bc8aa730)  
**Block**: 23042800 | **Position**: 182

## 套利路径 (Token=节点, DEX=边)

```
    pEMP (0x4343) ──► [Uniswap V2 0x9FF3] ──► pfWETH (0x395d)
         ▲                    │                     │
         │                    │                     ▼
         │                    │              [Vault redeem]
         │                    │                     │
         │                    │                     ▼
         │                    │                   WETH
         │                    │                     │
         │                    │              [Uniswap V3 0xe092]
         │                    │                     │
         └────────────────────┴─────────────────────┘
                                    EMP (0x39D5)
```

**路径**: Flash borrow pfWETH → Vault redeem → V3 (WETH→EMP) → Bond (EMP→pEMP) → V2 repay  
**Profit**: User ~0.00643 ETH, BuilderNet ~0.00059 ETH

## 快速开始

### 1. 环境变量

```powershell
# 需要 Archive RPC (Alchemy/Infura)
$env:MAINNET_RPC_URL = "https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"
```

### 2. 运行验证测试

```powershell
# 完整验证 (原 tx vs 我们的路径，输出一致)
forge test --match-test test_Verify_TxHashFork_OriginalVsOurPath -vvv
```

### 3. 验证时间

| 命令 | 预计时间 |
|------|----------|
| `forge test --match-test test_QuickVerify_FlashSwap` | ~10s |
| `forge test --match-test test_Verify_TxHashFork_OriginalVsOurPath` | ~20min (首次，需 archive) |

## 项目结构

```
src/
├── ArbitragePath.sol          # 完整路径 (V2 + Vault + V3)
├── ArbitragePathFlashSwap.sol # Flash swap 实现 (与原 tx 一致)
├── DEXSwap.sol                # V2/V3 单独 swap
└── interfaces/
test/
└── MEVResimulate.t.sol        # Fork + Re-simulate 测试
```

## 涉及的协议

| 协议 | 地址 | 作用 |
|------|------|------|
| Uniswap V2 | 0x9FF3... | pEMP ↔ pfWETH |
| Peapod Vault (ERC4626) | 0x395d... | pfWETH → WETH redeem |
| Uniswap V3 | 0xe092... | WETH → EMP |
| Peapod Bond | 0x4343... | EMP → pEMP |

## 常见错误

| 错误 | 原因 | 解决 |
|------|------|------|
| `state at block is pruned` | 免费 RPC 无 archive | 使用 Alchemy/Infura archive |
| `HTTP 429` | 限流 | 更换 RPC |

## 详细文档

参见 [MEV_README.md](./MEV_README.md) 获取完整说明、pEMP fee-on-transfer 分析、调试方法等。
