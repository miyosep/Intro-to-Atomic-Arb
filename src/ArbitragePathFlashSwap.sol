// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IERC4626} from "./interfaces/IERC4626.sol";
import {IWETH} from "./interfaces/IWETH.sol";

/**
 * @title ArbitragePathFlashSwap
 * @notice Optional: V2 flash swap wrapper — inner steps match trace (Vault->V3->Bond->V2 repay); outer call differs from live tx.
 * Path: Flash borrow pfWETH -> Vault redeem -> V3 (WETH->EMP) -> Bond (EMP->pEMP) -> V2 repay pEMP
 * Profit: remainder WETH -> ETH to user (~0.00643)
 */
contract ArbitragePathFlashSwap {
    address public recipient;
    uint256 public userAmount; // 原 tx: 发给 User 的精确 wei
    address public builderNet;
    uint256 public builderNetAmount;
    address public v2Pair;
    address public vault;
    address public v3Pool;
    address public bondContract;
    address public empToken;
    address public weth;
    uint256 public wethAmountForV3;
    uint256 public pfWETHBorrowed;

    // Uniswap V3 swap callback
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (amount0Delta > 0) {
            IERC20(IUniswapV3Pool(msg.sender).token0()).transfer(msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            IERC20(IUniswapV3Pool(msg.sender).token1()).transfer(msg.sender, uint256(amount1Delta));
        }
    }

    /**
     * Uniswap V2 flash swap callback - called when we borrow from the pair
     * Must repay borrowed amount + 0.3% fee before returning
     * data: abi.encode(userAmount, builderNet, builderNetAmount) - from executeFullPathWithFlashSwap
     */
    function uniswapV2Call(address, uint256 amount0, uint256 amount1, bytes calldata data) external {
        require(msg.sender == v2Pair, "only pair");
        require(amount0 == 0 || amount1 == 0, "unidirectional");

        address pfWETH = IUniswapV2Pair(v2Pair).token0();
        address pEMP = IUniswapV2Pair(v2Pair).token1();

        uint256 borrowed = amount0 > 0 ? amount0 : amount1;
        require(borrowed > 0, "no borrow");

        // 1) Vault: pfWETH -> WETH
        IERC20(pfWETH).approve(vault, borrowed);
        uint256 wethReceived = IERC4626(vault).redeem(borrowed, address(this), address(this));

        // 2) V3: WETH -> EMP
        uint256 wethToSwap =
            wethAmountForV3 == 0 ? wethReceived : (wethAmountForV3 < wethReceived ? wethAmountForV3 : wethReceived);
        IERC20(weth).approve(v3Pool, wethToSwap);
        IUniswapV3Pool(v3Pool)
            .swap(address(this), false, int256(wethToSwap), 1461446703485210103287273052203988822378723970341, "");

        // 3) Bond: EMP -> pEMP
        uint256 empBal = IERC20(empToken).balanceOf(address(this));
        require(empBal > 0, "no EMP");
        IERC20(empToken).approve(bondContract, empBal);
        (bool bondOk,) = bondContract.call(abi.encodeWithSelector(bytes4(0xb08d0333), empToken, empBal, uint256(0)));
        require(bondOk, "Bond failed");

        // 4) Repay flash loan with pEMP (cannot call swap from within callback - would re-enter)
        // Repay token1 (pEMP): amount1In >= amount0Out * r1 * 1000 / ((r0 - amount0Out) * 997)
        // pEMP is fee-on-transfer: send all we have; pair receives less, must still satisfy K
        (uint256 r0, uint256 r1,) = IUniswapV2Pair(v2Pair).getReserves();
        uint256 borrowAmount = amount0 > 0 ? amount0 : amount1;

        uint256 pEMPToRepayMin = amount0 > 0
            ? (borrowAmount * r1 * 1000) / ((r0 - borrowAmount) * 997) + 1
            : (borrowAmount * r0 * 1000) / ((r1 - borrowAmount) * 997) + 1;

        uint256 pEMPBal = IERC20(pEMP).balanceOf(address(this));
        require(pEMPBal >= pEMPToRepayMin, "insufficient pEMP to repay");
        // Send all pEMP - fee-on-transfer means pair receives less; we need received >= pEMPToRepayMin
        // Bond gives ~17.5 pEMP; with ~2% fee, 17.5*0.98=17.15 received. Min needed ~17.2. Add 5% buffer.
        IERC20(pEMP).transfer(v2Pair, pEMPBal);

        // 5) Remainder -> 与原 tx 相同分配: User userAmount, BuilderNet builderNetAmount
        uint256 rem = IERC20(weth).balanceOf(address(this));
        if (rem > 0) {
            IWETH(weth).withdraw(rem);
            (uint256 _userAmount, address _builderNet, uint256 _builderNetAmount) = data.length >= 96
                ? abi.decode(data, (uint256, address, uint256))
                : (userAmount, builderNet, builderNetAmount);
            uint256 toUser = _userAmount > 0 ? _userAmount : (rem - _builderNetAmount);
            uint256 toBuilderNet = (_builderNet != address(0) && _builderNetAmount > 0) ? _builderNetAmount : 0;
            require(rem >= toUser + toBuilderNet, "insufficient remainder");
            if (toBuilderNet > 0) {
                (bool sent1,) = _builderNet.call{value: toBuilderNet}("");
                require(sent1, "BuilderNet transfer failed");
            }
            if (toUser > 0) {
                (bool sent,) = recipient.call{value: toUser}("");
                require(sent, "ETH transfer failed");
            }
        }
    }

    /**
     * Execute full path via flash swap
     * @param _userAmount 原 tx: 发给 User 的精确 wei (0 则 remainder - builderNet)
     * @param _builderNet 原 tx 的 BuilderNet 地址 (0 则跳过)
     * @param _builderNetAmount 原 tx: 发给 BuilderNet 的精确 wei
     */
    function executeFullPathWithFlashSwap(
        address _v2Pair,
        address _vault,
        address _v3Pool,
        address _bondContract,
        address _empToken,
        address _weth,
        address _recipient,
        uint256 _wethAmountForV3,
        uint256 pfWETHToBorrow,
        uint256 _userAmount,
        address _builderNet,
        uint256 _builderNetAmount
    ) external returns (uint256 ethProfit) {
        recipient = _recipient;
        userAmount = _userAmount;
        builderNet = _builderNet;
        builderNetAmount = _builderNetAmount;
        v2Pair = _v2Pair;
        vault = _vault;
        v3Pool = _v3Pool;
        bondContract = _bondContract;
        empToken = _empToken;
        weth = _weth;
        wethAmountForV3 = _wethAmountForV3;
        pfWETHBorrowed = pfWETHToBorrow;

        // Trigger flash swap: borrow pfWETH (token0), pass userAmount/builderNet via data for callback
        IUniswapV2Pair(_v2Pair)
            .swap(pfWETHToBorrow, 0, address(this), abi.encode(_userAmount, _builderNet, _builderNetAmount));

        return recipient.balance;
    }

    receive() external payable {}
}
