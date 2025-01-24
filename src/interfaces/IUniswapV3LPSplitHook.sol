// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

/**
 * @title IUniswapV3LPSplitHook
 * @notice JuiceBox v4 Split Hook contract that converts the received split into a Uniswap V3 ETH/Token LP
 */
interface IUniswapV3LPSplitHook {
    /// @dev Thrown when a parameter is the zero address.
    error ZeroAddressNotAllowed();

    /// @dev Thrown when `processSplitWith` is called and this contract is not the hook specified in the JBSplitHookContext
    error NotHookSpecifiedInContext();
}
