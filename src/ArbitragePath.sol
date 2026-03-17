// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IERC4626} from "./interfaces/IERC4626.sol";
import {IWETH} from "./interfaces/IWETH.sol";

/**
 * @title ArbitragePath
 * @notice Replicates the full arbitrage path from tx 0x9ede...
 *
 * Protocols used:
 * 1. Uniswap V2 - pEMP/pfWETH pair
 * 2. Peapod/Primitive Vault (0x395d) - redeem pfWETH -> WETH
 * 3. Uniswap V3 - WETH/EMP pool
 * 4. Peapod Bond (0x4343) - EMP -> pEMP
 *
 * Path: pEMP -> [V2] -> pfWETH -> [Vault] -> WETH -> [V3] -> EMP -> [Bond] -> pEMP
 * Profit: remaining WETH unwrapped to ETH, sent to user (~0.00643 ETH)
 */
contract ArbitragePath {
    // Uniswap V3 swap callback - signature must match (int256, int256, bytes)
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (amount0Delta > 0) {
            IERC20(IUniswapV3Pool(msg.sender).token0()).transfer(msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            IERC20(IUniswapV3Pool(msg.sender).token1()).transfer(msg.sender, uint256(amount1Delta));
        }
    }

    /**
     * Execute full arbitrage path
     * @param pEMPAmount Amount of pEMP (0x4343) to swap
     * @param v2Pair Uniswap V2 pair - token0=pfWETH, token1=pEMP (address order)
     * @param vault Peapod/Primitive vault (0x395d) = pfWETH, redeem for WETH
     * @param v3Pool Uniswap V3 pool - token0=EMP, token1=WETH
     * @param wethAmountForV3 Amount of WETH to swap on V3 (0 = use all from vault).
     *   Original tx swapped 562611020353505727 WETH (0.5626) to get 17.97 EMP; rest went to user.
     */
    function executePath(uint256 pEMPAmount, address v2Pair, address vault, address v3Pool, uint256 wethAmountForV3)
        external
        returns (uint256 empReceived)
    {
        address pfWETH = IUniswapV2Pair(v2Pair).token0();
        address pEMP = IUniswapV2Pair(v2Pair).token1();

        // Step 1: Uniswap V2 - pEMP (token1) -> pfWETH (token0)
        // pEMP is fee-on-transfer: pair receives less than sent. Use actual balance delta.
        (uint256 r0, uint256 r1,) = IUniswapV2Pair(v2Pair).getReserves();
        IERC20(pEMP).transferFrom(msg.sender, v2Pair, pEMPAmount);
        uint256 balance1 = IERC20(pEMP).balanceOf(v2Pair);
        uint256 amountIn = balance1 - r1; // actual amount received by pair
        uint256 pfWETHOut = _getAmountOut(amountIn, r1, r0);
        IUniswapV2Pair(v2Pair).swap(pfWETHOut, 0, address(this), "");

        // Step 2: Vault redeem - pfWETH shares -> WETH
        IERC20(pfWETH).approve(vault, pfWETHOut);
        uint256 wethReceived = IERC4626(vault).redeem(pfWETHOut, address(this), address(this));

        // Step 3: Uniswap V3 - WETH -> EMP
        // Pool: token0=EMP, token1=WETH. Sell token1 (WETH) for token0 (EMP) => zeroForOne=false
        // amountSpecified: POSITIVE = exact input (we put in WETH), NEGATIVE = exact output
        uint256 wethToSwap =
            wethAmountForV3 == 0 ? wethReceived : (wethAmountForV3 < wethReceived ? wethAmountForV3 : wethReceived);
        address weth = IUniswapV3Pool(v3Pool).token1();
        address emp = IUniswapV3Pool(v3Pool).token0();
        IERC20(weth).approve(v3Pool, wethToSwap);
        IUniswapV3Pool(v3Pool)
            .swap(
                msg.sender,
                false, // zeroForOne=false: sell token1 (WETH) for token0 (EMP)
                int256(wethToSwap), // POSITIVE = exact INPUT of token1 (WETH)
                1461446703485210103287273052203988822378723970341, // MAX_SQRT_RATIO - 1 (price goes UP when selling token1)
                ""
            );
        return IERC20(emp).balanceOf(msg.sender);
    }

    /// Debug: 每步详细错误信息。失败时输出准确位置和原因。
    event DebugStep(uint8 step, string name, uint256 value);
    event DebugStepFail(uint8 step, string name, string reason, uint256 have, uint256 need);

    /**
     * Execute full arbitrage path WITH Bond + User ETH profit (DEBUG 版本)
     * 每步 emit + require，失败时输出 "Step N: 原因 (have: X, need: Y)"
     */
    function executeFullPathWithProfitDebug(
        uint256 pEMPAmount,
        address v2Pair,
        address vault,
        address v3Pool,
        address pEMPContract,
        address empToken,
        address weth,
        address recipient,
        uint256 wethAmountForV3
    ) external returns (uint256 ethProfit) {
        // Step 1: V2 swap
        emit DebugStep(1, "V2: pEMP->pfWETH", pEMPAmount);
        (uint256 r0, uint256 r1,) = IUniswapV2Pair(v2Pair).getReserves();
        address pEMP = IUniswapV2Pair(v2Pair).token1();
        IERC20(pEMP).transferFrom(msg.sender, v2Pair, pEMPAmount);
        uint256 amountIn = IERC20(pEMP).balanceOf(v2Pair) - r1;
        uint256 pfWETHOut = _getAmountOut(amountIn, r1, r0);
        if (pfWETHOut == 0) {
            emit DebugStepFail(1, "V2 swap", "pfWETH output is 0", amountIn, 0);
            revert("Step 1 (V2): pfWETH output is 0. amountIn (pair received) may be too low (pEMP fee-on-transfer?)");
        }
        IUniswapV2Pair(v2Pair).swap(pfWETHOut, 0, address(this), "");
        emit DebugStep(1, "V2 done", pfWETHOut);

        // Step 2: Vault redeem
        emit DebugStep(2, "Vault: pfWETH->WETH", pfWETHOut);
        address pfWETH = IUniswapV2Pair(v2Pair).token0();
        IERC20(pfWETH).approve(vault, pfWETHOut);
        uint256 wethReceived = IERC4626(vault).redeem(pfWETHOut, address(this), address(this));
        if (wethReceived < wethAmountForV3) {
            emit DebugStepFail(2, "Vault redeem", "WETH insufficient for V3", wethReceived, wethAmountForV3);
            revert("Step 2 (Vault): WETH insufficient for V3. See DebugStepFail(have, need) in logs.");
        }
        emit DebugStep(2, "Vault done", wethReceived);

        // Step 3: V3 swap
        emit DebugStep(3, "V3: WETH->EMP", wethAmountForV3);
        uint256 wethToSwap =
            wethAmountForV3 == 0 ? wethReceived : (wethAmountForV3 < wethReceived ? wethAmountForV3 : wethReceived);
        IERC20(weth).approve(v3Pool, wethToSwap);
        IUniswapV3Pool(v3Pool)
            .swap(address(this), false, int256(wethToSwap), 1461446703485210103287273052203988822378723970341, "");
        uint256 empBal = IERC20(empToken).balanceOf(address(this));
        if (empBal == 0) {
            emit DebugStepFail(3, "V3 swap", "EMP output is 0", wethToSwap, 0);
            revert("Step 3 (V3): EMP output is 0");
        }
        emit DebugStep(3, "V3 done", empBal);

        // Step 4: Bond
        emit DebugStep(4, "Bond: EMP->pEMP", empBal);
        IERC20(empToken).approve(pEMPContract, empBal);
        (bool bondOk,) = pEMPContract.call(abi.encodeWithSelector(bytes4(0xb08d0333), empToken, empBal, uint256(0)));
        if (!bondOk) {
            emit DebugStepFail(4, "Bond", "bond() returned false", empBal, 0);
            revert("Step 4 (Bond): bond() failed");
        }
        emit DebugStep(4, "Bond done", 0);

        // Step 5: Send remainder to recipient
        emit DebugStep(5, "Send ETH to recipient", 0);
        uint256 rem = IERC20(weth).balanceOf(address(this));
        if (rem > 0) {
            IWETH(weth).withdraw(rem);
            (bool sent,) = recipient.call{value: rem}("");
            if (!sent) {
                emit DebugStepFail(5, "ETH transfer", "call failed", rem, 0);
                revert("Step 5: ETH transfer to recipient failed");
            }
            return rem;
        }
        emit DebugStep(5, "No remainder", 0);
        return 0;
    }

    /**
     * Execute full arbitrage path WITH Bond + User ETH profit (Option C: deal-to-pair, test-only)
     * Caller must deal pEMP to v2Pair and call v2Pair.sync() before calling this.
     * Bypasses pEMP fee-on-transfer by injecting pEMP directly to pair.
     * @param userAmount 原 tx: 发给 User 的精确 wei (0 则 remainder - builderNet)
     * @param builderNet 原 tx 的 BuilderNet 地址 (0 则跳过)
     * @param builderNetAmount 原 tx: 发给 BuilderNet 的精确 wei
     */
    function executeFullPathWithProfitDealToPair(
        uint256 pfWETHOut,
        address v2Pair,
        address vault,
        address v3Pool,
        address pEMPContract,
        address empToken,
        address weth,
        address recipient,
        uint256 wethAmountForV3,
        uint256 userAmount,
        address builderNet,
        uint256 builderNetAmount
    ) external returns (uint256 ethProfit) {
        // Step 1: V2 - pair already has pEMP (dealt + synced by test)
        IUniswapV2Pair(v2Pair).swap(pfWETHOut, 0, address(this), "");

        // Step 2: Vault
        address pfWETH = IUniswapV2Pair(v2Pair).token0();
        IERC20(pfWETH).approve(vault, pfWETHOut);
        uint256 wethReceived = IERC4626(vault).redeem(pfWETHOut, address(this), address(this));

        // Step 3: V3
        uint256 wethToSwap =
            wethAmountForV3 == 0 ? wethReceived : (wethAmountForV3 < wethReceived ? wethAmountForV3 : wethReceived);
        IERC20(weth).approve(v3Pool, wethToSwap);
        IUniswapV3Pool(v3Pool)
            .swap(address(this), false, int256(wethToSwap), 1461446703485210103287273052203988822378723970341, "");

        // Step 4: Bond
        uint256 empBal = IERC20(empToken).balanceOf(address(this));
        if (empBal > 0) {
            IERC20(empToken).approve(pEMPContract, empBal);
            (bool bondOk,) = pEMPContract.call(abi.encodeWithSelector(bytes4(0xb08d0333), empToken, empBal, uint256(0)));
            require(bondOk, "Bond failed");
        }

        // Step 5: Unwrap WETH -> ETH: 与原 tx 相同分配 (User userAmount, BuilderNet builderNetAmount)
        uint256 rem = IERC20(weth).balanceOf(address(this));
        if (rem > 0) {
            IWETH(weth).withdraw(rem);
            uint256 toUser = userAmount > 0 ? userAmount : (rem - builderNetAmount);
            uint256 toBuilderNet = (builderNet != address(0) && builderNetAmount > 0) ? builderNetAmount : 0;
            require(rem >= toUser + toBuilderNet, "insufficient remainder");
            if (toBuilderNet > 0) {
                (bool sent1,) = builderNet.call{value: toBuilderNet}("");
                require(sent1, "BuilderNet transfer failed");
            }
            if (toUser > 0) {
                (bool sent,) = recipient.call{value: toUser}("");
                require(sent, "ETH transfer failed");
            }
            return rem;
        }
        return 0;
    }

    /**
     * Execute full arbitrage path WITH Bond + User ETH profit
     * Path: pEMP -> V2 -> pfWETH -> Vault -> WETH -> V3 -> EMP -> Bond -> pEMP
     * Profit: remaining WETH unwrapped to ETH, sent to recipient (~0.00643)
     */
    function executeFullPathWithProfit(
        uint256 pEMPAmount,
        address v2Pair,
        address vault,
        address v3Pool,
        address pEMPContract,
        address empToken,
        address weth,
        address recipient,
        uint256 wethAmountForV3
    ) external returns (uint256 ethProfit) {
        // Step 1: V2
        (uint256 r0, uint256 r1,) = IUniswapV2Pair(v2Pair).getReserves();
        IERC20(IUniswapV2Pair(v2Pair).token1()).transferFrom(msg.sender, v2Pair, pEMPAmount);
        uint256 pfWETHOut = _getAmountOut(IERC20(IUniswapV2Pair(v2Pair).token1()).balanceOf(v2Pair) - r1, r1, r0);
        IUniswapV2Pair(v2Pair).swap(pfWETHOut, 0, address(this), "");

        // Step 2: Vault
        IERC20(IUniswapV2Pair(v2Pair).token0()).approve(vault, pfWETHOut);
        uint256 wethReceived = IERC4626(vault).redeem(pfWETHOut, address(this), address(this));

        // Step 3: V3 - POSITIVE amountSpecified = exact input of token1 (WETH)
        // Swap up to wethAmountForV3 (or all if 0). Remainder goes to user.
        uint256 wethToSwap =
            wethAmountForV3 == 0 ? wethReceived : (wethAmountForV3 < wethReceived ? wethAmountForV3 : wethReceived);
        IERC20(weth).approve(v3Pool, wethToSwap);
        IUniswapV3Pool(v3Pool)
            .swap(address(this), false, int256(wethToSwap), 1461446703485210103287273052203988822378723970341, "");

        // Step 4: Bond (EMP -> pEMP). Must succeed - original tx reverts if bond fails
        // Peapod WeightedIndex: bond(address _token, uint256 _amount, uint256 _amountMintMin) = 0xb08d0333
        uint256 empBal = IERC20(empToken).balanceOf(address(this));
        if (empBal > 0) {
            IERC20(empToken).approve(pEMPContract, empBal);
            (bool bondOk,) = pEMPContract.call(abi.encodeWithSelector(bytes4(0xb08d0333), empToken, empBal, uint256(0)));
            require(bondOk, "Bond failed");
        }

        // Step 5: Unwrap WETH -> ETH to recipient
        uint256 rem = IERC20(weth).balanceOf(address(this));
        if (rem > 0) {
            IWETH(weth).withdraw(rem);
            (bool sent,) = recipient.call{value: rem}("");
            require(sent, "ETH transfer failed");
            return rem;
        }
        return 0;
    }

    receive() external payable {}

    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }

    /// Debug: returns (r0, r1, amountIn, pfWETHOut) for V2 swap analysis. Performs transfer (state-changing).
    function debugV2Swap(uint256 pEMPAmount, address v2Pair)
        external
        returns (uint256 r0, uint256 r1, uint256 amountIn, uint256 pfWETHOut)
    {
        address pEMP = IUniswapV2Pair(v2Pair).token1();
        (r0, r1,) = IUniswapV2Pair(v2Pair).getReserves();
        IERC20(pEMP).transferFrom(msg.sender, v2Pair, pEMPAmount);
        uint256 balance1 = IERC20(pEMP).balanceOf(v2Pair);
        amountIn = balance1 - r1;
        pfWETHOut = _getAmountOut(amountIn, r1, r0);
        return (r0, r1, amountIn, pfWETHOut);
    }
}
