// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title IERC4626
 * @notice ERC-4626 Tokenized Vault Standard - used by Peapod/Primitive vaults
 * @dev 0x395d (pfWETH) vault: redeem shares for WETH
 */
interface IERC4626 {
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    function asset() external view returns (address);
}
