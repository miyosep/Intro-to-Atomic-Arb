// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}
