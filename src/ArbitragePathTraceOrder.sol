// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IERC4626} from "./interfaces/IERC4626.sol";
import {IWETH} from "./interfaces/IWETH.sol";

/**
 * @title ArbitragePathTraceOrder
 * @notice Call order aligned with tx trace: Vault redeem -> V3 -> Bond -> V2 (pEMP->pfWETH).
 * @dev Fund vault shares via deal in tests; live tx uses V2 flash swap first.
 */
contract ArbitragePathTraceOrder {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (amount0Delta > 0) {
            IERC20(IUniswapV3Pool(msg.sender).token0()).transfer(msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            IERC20(IUniswapV3Pool(msg.sender).token1()).transfer(msg.sender, uint256(amount1Delta));
        }
    }

    function executeTraceOrder(
        address v2Pair,
        address vault,
        address v3Pool,
        address bondContract,
        address empToken,
        address weth,
        address recipient,
        uint256 pfWETHSharesToRedeem,
        uint256 wethAmountForV3,
        uint256 userAmountWei,
        address builderNet,
        uint256 builderNetAmountWei
    ) external returns (uint256 wethUnwrappedTotal) {
        address pfWETH = IUniswapV2Pair(v2Pair).token0();
        address pEMP = IUniswapV2Pair(v2Pair).token1();

        IERC20(pfWETH).approve(vault, pfWETHSharesToRedeem);
        uint256 wethReceived = IERC4626(vault).redeem(pfWETHSharesToRedeem, address(this), address(this));

        uint256 wethToSwap =
            wethAmountForV3 == 0 ? wethReceived : (wethAmountForV3 < wethReceived ? wethAmountForV3 : wethReceived);
        IERC20(weth).approve(v3Pool, wethToSwap);
        IUniswapV3Pool(v3Pool)
            .swap(address(this), false, int256(wethToSwap), 1461446703485210103287273052203988822378723970341, "");

        uint256 empBal = IERC20(empToken).balanceOf(address(this));
        require(empBal > 0, "no EMP");
        IERC20(empToken).approve(bondContract, empBal);
        (bool bondOk,) = bondContract.call(abi.encodeWithSelector(bytes4(0xb08d0333), empToken, empBal, uint256(0)));
        require(bondOk, "Bond failed");

        (uint256 r0, uint256 r1,) = IUniswapV2Pair(v2Pair).getReserves();
        IERC20(pEMP).transfer(v2Pair, IERC20(pEMP).balanceOf(address(this)));
        uint256 amountIn = IERC20(pEMP).balanceOf(v2Pair) - r1;
        uint256 pfWETHOut = _getAmountOut(amountIn, r1, r0);
        IUniswapV2Pair(v2Pair).swap(pfWETHOut, 0, address(this), "");

        uint256 rem = IERC20(weth).balanceOf(address(this));
        if (rem > 0) {
            IWETH(weth).withdraw(rem);
            uint256 toUser = userAmountWei > 0 ? userAmountWei : (rem - builderNetAmountWei);
            uint256 toBuilder = (builderNet != address(0) && builderNetAmountWei > 0) ? builderNetAmountWei : 0;
            require(rem >= toUser + toBuilder, "insufficient remainder");
            if (toBuilder > 0) {
                (bool s1,) = builderNet.call{value: toBuilder}("");
                require(s1, "BuilderNet failed");
            }
            if (toUser > 0) {
                (bool s2,) = recipient.call{value: toUser}("");
                require(s2, "User ETH failed");
            }
            return rem;
        }
        return 0;
    }

    function executeVaultRedeemThenV3(
        address v2Pair,
        address vault,
        address v3Pool,
        address weth,
        uint256 pfWETHSharesToRedeem,
        uint256 wethAmountForV3
    ) external returns (uint256 empReceived) {
        address pfWETH = IUniswapV2Pair(v2Pair).token0();
        address emp = IUniswapV3Pool(v3Pool).token0();

        IERC20(pfWETH).approve(vault, pfWETHSharesToRedeem);
        uint256 wethReceived = IERC4626(vault).redeem(pfWETHSharesToRedeem, address(this), address(this));

        uint256 wethToSwap =
            wethAmountForV3 == 0 ? wethReceived : (wethAmountForV3 < wethReceived ? wethAmountForV3 : wethReceived);
        IERC20(weth).approve(v3Pool, wethToSwap);
        IUniswapV3Pool(v3Pool)
            .swap(address(this), false, int256(wethToSwap), 1461446703485210103287273052203988822378723970341, "");

        return IERC20(emp).balanceOf(address(this));
    }

    receive() external payable {}

    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }
}

