// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

/**
 * @title IREVDeployer
 * @notice Interface for REVDeployer to check revnet operator status
 */
interface IREVDeployer {
    /// @notice Check if an address is a split operator for a revnet
    /// @param revnetId The revnet ID
    /// @param addr The address to check
    /// @return Whether the address is a split operator
    function isSplitOperatorOf(uint256 revnetId, address addr) external view returns (bool);
}

