// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IERC4626} from "./interfaces/IERC4626.sol";
import {IWETH} from "./interfaces/IWETH.sol";

/**
 * @title ArbitragePathOriginalOrder
 * @notice 与原 tx 相同执行顺序: V3 swap -> callback 中 Bond(EMP->pEMP) -> V2 -> Vault -> WETH to V3
 * @dev 从 Bond mint pEMP 使用 (替代 deal()) - fee-on-transfer 不适用
 */
contract ArbitragePathOriginalOrder {
    address public recipient;

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        address v3Pool = msg.sender;
        address emp = IUniswapV3Pool(v3Pool).token0();
        address weth = IUniswapV3Pool(v3Pool).token1();

        // amount0Delta < 0: we receive EMP. amount1Delta > 0: we must send WETH
        uint256 empReceived = amount0Delta < 0 ? uint256(-amount0Delta) : 0;
        uint256 wethRequired = amount1Delta > 0 ? uint256(amount1Delta) : 0;

        if (empReceived == 0) return;

        // 1) Bond: EMP -> pEMP (与原 tx 相同 - 使用 Bond mint 的 pEMP)
        IERC20(emp).approve(_bondContract, empReceived);
        (bool bondOk,) = _bondContract.call(abi.encodeWithSelector(bytes4(0xb08d0333), emp, empReceived, uint256(0)));
        require(bondOk, "Bond failed");

        // 2) V2: pEMP -> pfWETH
        address pEMP = IUniswapV2Pair(_v2Pair).token1();
        uint256 pEMPToSend = _pEMPAmountForV2;
        IERC20(pEMP).transfer(_v2Pair, pEMPToSend);

        (uint256 r0, uint256 r1,) = IUniswapV2Pair(_v2Pair).getReserves();
        uint256 amountIn = IERC20(pEMP).balanceOf(_v2Pair) - r1;
        uint256 pfWETHOut = (amountIn * 997 * r0) / (r1 * 1000 + amountIn * 997);
        IUniswapV2Pair(_v2Pair).swap(pfWETHOut, 0, address(this), "");

        // 3) Vault: pfWETH -> WETH
        address pfWETH = IUniswapV2Pair(_v2Pair).token0();
        IERC20(pfWETH).approve(_vault, pfWETHOut);
        uint256 wethReceived = IERC4626(_vault).redeem(pfWETHOut, address(this), address(this));

        // 4) Send WETH to V3 pool (swap 完成)
        IERC20(weth).transfer(v3Pool, wethRequired);

        // 5) Remainder -> recipient
        uint256 rem = IERC20(weth).balanceOf(address(this));
        if (rem > 0) {
            IWETH(weth).withdraw(rem);
            (bool sent,) = recipient.call{value: rem}("");
            require(sent, "ETH transfer failed");
        }
    }

    address _v2Pair;
    address _vault;
    address _bondContract;
    uint256 _pEMPAmountForV2;

    /**
     * 按原 tx 顺序执行: V3 exact output swap -> callback 中 Bond->V2->Vault->WETH
     * @param empAmountOut V3 收到的 EMP (原: 17975419691953642945)
     * @param pEMPAmountForV2 发给 V2 的 pEMP (原: 17169169459862071375)
     * @param wethAmountForV3 发给 V3 的 WETH (原: 562611020353505727)
     */
    function executeFullPathOriginalOrder(
        uint256 empAmountOut,
        uint256 pEMPAmountForV2,
        uint256 wethAmountForV3,
        address v2Pair,
        address vault,
        address v3Pool,
        address bondContract,
        address _recipient
    ) external returns (uint256 ethProfit) {
        recipient = _recipient;
        _v2Pair = v2Pair;
        _vault = vault;
        _bondContract = bondContract;
        _pEMPAmountForV2 = pEMPAmountForV2;

        // V3 swap: exact output of EMP (NEGATIVE amountSpecified)
        IUniswapV3Pool(v3Pool).swap(
            address(this),
            false,  // zeroForOne=false: sell WETH for EMP
            -int256(empAmountOut),
            1461446703485210103287273052203988822378723970341,
            ""
        );

        return recipient.balance;  // callback 中已发送，返回值仅供参考
    }

    receive() external payable {}
}
