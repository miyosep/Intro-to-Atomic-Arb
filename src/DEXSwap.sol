// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {IERC20} from "./interfaces/IERC20.sol";

/**
 * @title DEXSwap
 * @notice Task 6: Contract that interacts with all DEX protocols in the target MEV tx
 * - Uniswap V2 (pair 0x9ff3...)
 * - Peapod Vault (0x395d) - redeem
 * - Uniswap V3 (pool 0xe092...)
 * - Peapod Bond (0x4343) - EMP -> pEMP
 *
 * Tx flow: pEMP -> [V2] -> pfWETH -> [Vault] -> WETH -> [V3] -> EMP -> [Bond] -> pEMP
 */
contract DEXSwap {
    // Uniswap V3 swap callback - pool calls this when we swap
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (amount0Delta > 0) {
            IERC20(IUniswapV3Pool(msg.sender).token0()).transfer(msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            IERC20(IUniswapV3Pool(msg.sender).token1()).transfer(msg.sender, uint256(amount1Delta));
        }
    }

    /**
     * Uniswap V2 swap: swap tokenIn for tokenOut via pair
     * @param pair Uniswap V2 pair address
     * @param amount0Out output amount for token0 (0 if we're selling token0)
     * @param amount1Out output amount for token1 (0 if we're selling token1)
     */
    function swapV2(address pair, uint256 amount0Out, uint256 amount1Out) external {
        IUniswapV2Pair(pair).swap(amount0Out, amount1Out, msg.sender, "");
    }

    /**
     * Uniswap V2 swap: transfer tokenIn to pair, then swap
     * Caller must approve this contract for tokenIn first
     * Handles fee-on-transfer tokens (e.g. pEMP): uses actual balance delta
     */
    function swapV2ExactIn(address pair, address tokenIn, uint256 amountIn, uint256 amountOutMin)
        external
        returns (uint256 amountOut)
    {
        (uint256 reserve0, uint256 reserve1,) = IUniswapV2Pair(pair).getReserves();
        IERC20(tokenIn).transferFrom(msg.sender, pair, amountIn);

        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();

        // Fee-on-transfer: pair receives less than amountIn; use actual balance delta
        uint256 balanceIn =
            tokenIn == token0 ? IERC20(token0).balanceOf(pair) - reserve0 : IERC20(token1).balanceOf(pair) - reserve1;
        uint256 amount0Out;
        uint256 amount1Out;

        if (tokenIn == token0) {
            amount1Out = getAmountOut(balanceIn, reserve0, reserve1);
            amount0Out = 0;
            require(amount1Out >= amountOutMin, "V2: insufficient output");
        } else {
            amount0Out = getAmountOut(balanceIn, reserve1, reserve0);
            amount1Out = 0;
            require(amount0Out >= amountOutMin, "V2: insufficient output");
        }

        IUniswapV2Pair(pair).swap(amount0Out, amount1Out, msg.sender, "");
        return tokenIn == token0 ? amount1Out : amount0Out;
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }

    /**
     * Uniswap V3 swap: exact input single swap
     * @param pool Uniswap V3 pool address
     * @param zeroForOne true = token0 -> token1, false = token1 -> token0
     * @param amountSpecified POSITIVE for exact input (amount of tokenIn to swap)
     * @param sqrtPriceLimitX96 MAX_SQRT_RATIO-1 when selling token1, MIN_SQRT_RATIO+1 when selling token0
     */
    function swapV3ExactIn(address pool, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        external
        returns (int256 amount0, int256 amount1)
    {
        return IUniswapV3Pool(pool).swap(msg.sender, zeroForOne, amountSpecified, sqrtPriceLimitX96, "");
    }

    /**
     * Execute swap on V3 pool - caller must have approved this contract for tokenIn
     */
    function swapV3ExactInWithApproval(
        address pool,
        address tokenIn,
        uint256 amountIn,
        bool zeroForOne,
        uint160 sqrtPriceLimitX96
    ) external returns (int256 amount0, int256 amount1) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).approve(pool, amountIn);

        int256 amountSpecified = int256(amountIn); // POSITIVE = exact input
        return IUniswapV3Pool(pool).swap(msg.sender, zeroForOne, amountSpecified, sqrtPriceLimitX96, "");
    }

    /**
     * Peapod Bond: EMP -> pEMP (0x4343)
     * @param pEMPContract pEMP token contract (0x4343) - has bond()
     * @param empToken EMP token (0x39D5)
     * @param amount EMP amount to bond. Caller must approve this contract for EMP first.
     */
    function bond(address pEMPContract, address empToken, uint256 amount) external returns (bool) {
        IERC20(empToken).transferFrom(msg.sender, address(this), amount);
        IERC20(empToken).approve(pEMPContract, amount);
        (bool ok,) = pEMPContract.call(abi.encodeWithSelector(bytes4(0xb08d0333), empToken, amount, uint256(0)));
        return ok;
    }
}
