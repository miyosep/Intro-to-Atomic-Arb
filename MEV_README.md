# MEV Tx Re-simulation Guide

## 목표 (Tasks 5–7)

1. **Task 5**: 지정 block의 지정 index에서 tx re-simulate
2. **Task 6**: 해당 tx에서 사용하는 모든 DEX와 상호작용하는 컨트랙트 작성
3. **Task 7**: 동일한 input과 DEX pools로 re-simulate 후, output amount가 원본 tx와 일치하는지 검증

## 대상 트랜잭션

- **Tx Hash**: `0x9edea0b66aece76f0bc7e185f9ce5cac81ce41bdd1ec4d3cf1907274bc8aa730`
- **Block**: 23042800
- **Block 내 Position**: 182

## 아비트라지 경로 (Token = 노드, DEX = 엣지)

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

**원본 tx의 추가 단계**: EMP → Bond(0x4343) → pEMP + User에게 ETH 0.00643 전송

## 스왑 흐름 (Tx 분석 결과)

```
pEMP (0x4343... Peapod) 
  → [Uniswap V2 Pair 0x9FF3...] 
  → pfWETH (0x395d... Peapod/Primitive vault share) 
  → [ERC4626 Vault redeem] 
  → WETH 
  → [Uniswap V3 Pool 0xe092...] 
  → EMP (0x39D5...)
```

## 사용된 프로토콜 (전체 구현 완료)

| 프로토콜 | 주소 | 역할 |
|----------|------|------|
| Uniswap V2 | 0x9FF3226906eB460E11d88f4780C84457A2f96C3e | pEMP ↔ pfWETH 스왑 |
| Peapod/Primitive Vault (ERC4626) | 0x395dA89bDb9431621A75DF4e2E3B993Acc2CaB3D | pfWETH → WETH redeem |
| Uniswap V3 | 0xe092769bc1fa5262D4f48353f90890Dcc339BF80 | WETH → EMP 스왑 |
| Peapod Bond (0x4343) | 0x4343A06B930Cf7Ca0459153C62CC5a47582099E1 | EMP → pEMP (bond) |

## 프로젝트 구조

```
src/
├── ArbitragePath.sol       # 전체 arbitrage 경로 실행 (V2 + Vault + V3)
├── DEXSwap.sol             # Uniswap V2/V3 개별 스왑
├── interfaces/
│   ├── IERC20.sol
│   ├── IERC4626.sol        # Vault redeem (Peapod/Primitive)
│   ├── IUniswapV2Pair.sol
│   ├── IUniswapV3Pool.sol
│   └── IWETH.sol
test/
└── MEVResimulate.t.sol     # Fork + Re-simulate + Full path 테스트
```

## 실행 방법

### 1. 사전 요구사항

- **Archive RPC**: 블록 23042800의 fork를 위해 **Archive Node** RPC가 필요합니다.
  - 공개 RPC(eth.llamarpc.com 등)는 해당 블록의 state를 지원하지 않음
  - **Alchemy**, **Infura**, **QuickNode** 등에서 archive 지원 플랜 사용

### 2. 환경 변수 설정

```bash
# Windows PowerShell
$env:MAINNET_RPC_URL = "https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"

# 또는 .env 파일
echo "MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY" > .env
```

### 3. Task 5: Re-simulate tx

```bash
# vm.createSelectFork(rpcUrl, txHash) - tx가 포함된 블록에서 fork, 그 전까지의 tx를 모두 replay
# vm.transact(txHash) - 해당 tx 실행
forge test --match-test test_ResimulateTxWithFork -vvv
```

### 4. Task 7: Output 검증

```bash
# 원본 tx replay 후 output 검증
forge test --match-test test_Task7_ResimulateOutputMatchesOriginal -vvv

# DEXSwap 컨트랙트로 수동 re-simulate (V2 swap 검증)
forge test --match-test test_Task7_ManualResimulateWithDEXContract -vvv
```

## Foundry 핵심 API

| API | 설명 |
|-----|------|
| `vm.createSelectFork(url, txHash)` | tx가 포함된 블록에서 fork, 그 전까지의 tx를 모두 replay |
| `vm.createSelectFork(url, blockNumber)` | 블록 번호에서 fork (블록 시작 시점 state) |
| `vm.transact(txHash)` | fork에서 tx를 가져와 실행 |
| `deal(token, to, amount)` | ERC20 토큰 잔액 설정 (테스트용) |

## DEXSwap 컨트랙트 사용법

```solidity
// Uniswap V2: exact input swap
swapper.swapV2ExactIn(pair, tokenIn, amountIn, amountOutMin);

// Uniswap V3: exact input swap
swapper.swapV3ExactInWithApproval(pool, tokenIn, amountIn, zeroForOne, sqrtPriceLimitX96);
```

## ArbitragePath 사용법

```solidity
// 경로만 (EMP output 검증)
path.executePath(pEMPAmount, UNISWAP_V2_PAIR, TOKEN_V2_OUT, UNISWAP_V3_POOL, WETH_INPUT);
// Returns: EMP received

// 전체 경로 + Bond + User ETH profit (~0.00643)
path.executeFullPathWithProfit(
    pEMPAmount,
    UNISWAP_V2_PAIR,
    TOKEN_V2_OUT,
    UNISWAP_V3_POOL,
    TOKEN_IN,   // pEMP = 0x4343 (Bond contract)
    EMP,
    WETH,
    userAddress,
    WETH_INPUT
);
// Returns: ETH sent to user
```

## 참고: 0x395d Vault

0x395d... (pfWETH)는 ERC4626 호환 vault로, `redeem(shares, receiver, owner)`로 WETH를 받습니다.

## 구현 시 주의사항 (수정 완료)

| 이슈 | 설명 | 수정 |
|------|------|------|
| **pEMP fee-on-transfer** | pEMP는 transfer 시 수수료 차감. pair가 받는 양 < 전송량 | DEXSwap/ArbitragePath: `balanceOf(pair) - reserve`로 실제 수신량 계산 |
| **V3 sqrtPriceLimitX96** | zeroForOne=false(토큰1→토큰0)일 때 가격 상승. MAX_SQRT_RATIO-1 사용 | ArbitragePath: `1461446703485210103287273052203988822378723970341` |
| **V3 amountSpecified** | POSITIVE = exact input (넣는 양 지정), NEGATIVE = exact output (받는 양 지정) | 기존 -int256 사용 시 0.5589 EMP만 받음. +int256으로 수정 |
| **V3 callback 시그니처** | Uniswap 표준: `(int256, int256, bytes)` 3개 인자 | DEXSwap: 잘못된 `address` 파라미터 제거 |
| **Archive RPC** | LlamaRPC는 archive 미지원(429). 블록 23042800 fork 필요 | Alchemy/Infura/QuickNode archive 플랜 사용 |
| **Bond (0x4343)** | EMP → pEMP. bond(address,uint256,uint256) = 0xb08d0333 | bond(token, amount, amountMintMin). 실패 시 전체 tx revert |
