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
    function executePath(
        uint256 pEMPAmount,
        address v2Pair,
        address vault,
        address v3Pool,
        uint256 wethAmountForV3
    ) external returns (uint256 empReceived) {
        address pfWETH = IUniswapV2Pair(v2Pair).token0();
        address pEMP = IUniswapV2Pair(v2Pair).token1();

        // Step 1: Uniswap V2 - pEMP (token1) -> pfWETH (token0)
        // pEMP is fee-on-transfer: pair receives less than sent. Use actual balance delta.
        (uint256 r0, uint256 r1,) = IUniswapV2Pair(v2Pair).getReserves();
        IERC20(pEMP).transferFrom(msg.sender, v2Pair, pEMPAmount);
        uint256 balance1 = IERC20(pEMP).balanceOf(v2Pair);
        uint256 amountIn = balance1 - r1;  // actual amount received by pair
        uint256 pfWETHOut = _getAmountOut(amountIn, r1, r0);
        IUniswapV2Pair(v2Pair).swap(pfWETHOut, 0, address(this), "");

        // Step 2: Vault redeem - pfWETH shares -> WETH
        IERC20(pfWETH).approve(vault, pfWETHOut);
        uint256 wethReceived = IERC4626(vault).redeem(pfWETHOut, address(this), address(this));

        // Step 3: Uniswap V3 - WETH -> EMP
        // Pool: token0=EMP, token1=WETH. Sell token1 (WETH) for token0 (EMP) => zeroForOne=false
        // amountSpecified: POSITIVE = exact input (we put in WETH), NEGATIVE = exact output
        uint256 wethToSwap = wethAmountForV3 == 0 ? wethReceived : (wethAmountForV3 < wethReceived ? wethAmountForV3 : wethReceived);
        address weth = IUniswapV3Pool(v3Pool).token1();
        address emp = IUniswapV3Pool(v3Pool).token0();
        IERC20(weth).approve(v3Pool, wethToSwap);
        IUniswapV3Pool(v3Pool).swap(
            msg.sender,
            false,  // zeroForOne=false: sell token1 (WETH) for token0 (EMP)
            int256(wethToSwap),  // POSITIVE = exact INPUT of token1 (WETH)
            1461446703485210103287273052203988822378723970341,  // MAX_SQRT_RATIO - 1 (price goes UP when selling token1)
            ""
        );
        return IERC20(emp).balanceOf(msg.sender);
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
        uint256 pfWETHOut = _getAmountOut(
            IERC20(IUniswapV2Pair(v2Pair).token1()).balanceOf(v2Pair) - r1, r1, r0
        );
        IUniswapV2Pair(v2Pair).swap(pfWETHOut, 0, address(this), "");

        // Step 2: Vault
        IERC20(IUniswapV2Pair(v2Pair).token0()).approve(vault, pfWETHOut);
        uint256 wethReceived = IERC4626(vault).redeem(pfWETHOut, address(this), address(this));

        // Step 3: V3 - POSITIVE amountSpecified = exact input of token1 (WETH)
        // When wethReceived < wethAmountForV3, we don't have enough to swap full amount AND leave profit.
        // Reserve min profit (~0.00643 ETH) for user by swapping less.
        uint256 minProfit = 6_435_308_948_727_846;  // ~0.00643 ETH from original tx
        uint256 wethToSwap = wethAmountForV3 == 0
            ? wethReceived
            : (wethReceived >= wethAmountForV3 + minProfit
                ? wethAmountForV3
                : (wethReceived > minProfit ? wethReceived - minProfit : 0));
        IERC20(weth).approve(v3Pool, wethToSwap);
        IUniswapV3Pool(v3Pool).swap(address(this), false, int256(wethToSwap), 1461446703485210103287273052203988822378723970341, "");

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
}
