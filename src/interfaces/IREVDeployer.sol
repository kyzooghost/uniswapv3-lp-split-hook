// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/// @notice Minimal interface for REVDeployer split operator checks.
interface IREVDeployer {
    /// @notice Check if an address is the split operator for a project.
    /// @param projectId The ID of the project.
    /// @param operator The address to check.
    /// @return True if the address is the split operator for the project.
    function isSplitOperatorOf(uint256 projectId, address operator) external view returns (bool);
}
