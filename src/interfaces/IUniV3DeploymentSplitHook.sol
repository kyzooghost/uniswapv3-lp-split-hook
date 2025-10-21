// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

/**
 * @title IUniV3DeploymentSplitHook
 * @notice JuiceBox v4 Split Hook contract that manages a two-stage deployment process:
 * Stage 1: Accumulate project tokens without deploying Uniswap V3 pool
 * Stage 2: Deploy pool with accumulated tokens and route LP fees back to project
 */
interface IUniV3DeploymentSplitHook {
    /// @dev Thrown when a parameter is the zero address.
    error ZeroAddressNotAllowed();

    /// @dev Thrown when a projectId does not exist in the JBDirectory
    error InvalidProjectId();

    /// @dev Thrown when `processSplitWith` is called and this contract is not the hook specified in the JBSplitHookContext
    error NotHookSpecifiedInContext();

    /// @dev Thrown when `processSplitWith` is not called by the project's controller
    error SplitSenderNotValidControllerOrTerminal();

    /// @dev Thrown when trying to deploy pool but no tokens have been accumulated
    error NoTokensAccumulated();

    /// @dev Thrown when trying to perform an action that's not allowed in the current stage
    error InvalidStageForAction();

    /// @dev Thrown when the split hook receives terminal tokens from payouts (should only receive reserved tokens)
    error TerminalTokensNotAllowed();

    /// @dev Thrown when fee percent exceeds 100% (10000 basis points)
    error InvalidFeePercent();

    /// @dev Thrown when trying to claim tokens for a non-revnet operator
    error UnauthorizedBeneficiary();

    /// @dev Emitted when a project transitions from Stage 1 to Stage 2
    event ProjectDeployed(uint256 indexed projectId, address indexed terminalToken, address indexed pool);

    /// @dev Emitted when LP fees are routed back to the project
    event LPFeesRouted(uint256 indexed projectId, address indexed terminalToken, uint256 amount);

    /// @dev Emitted when tokens are burned in Stage 2
    event TokensBurned(uint256 indexed projectId, address indexed token, uint256 amount);

    /**
     * @notice Check if project is in accumulation stage based on ruleset weight
     * @param _projectId The Juicebox project ID
     * @return isAccumulationStage True if weight > 0 (accumulation stage), false if weight == 0 (deployment stage)
     */
    function isAccumulationStage(uint256 _projectId) external view returns (bool isAccumulationStage);


    /**
     * @notice Manually trigger deployment for a project (only works in accumulation stage)
     * @param _projectId The Juicebox project ID
     * @param _terminalToken The terminal token address
     */
    function deployPool(uint256 _projectId, address _terminalToken) external;

    /**
     * @notice Collect LP fees and route them back to the project
     * @param _projectId The Juicebox project ID
     * @param _terminalToken The terminal token address
     */
    function collectAndRouteLPFees(uint256 _projectId, address _terminalToken) external;

    /**
     * @notice Claim fee tokens for a beneficiary (must be the project's revnet operator)
     * @param _projectId The Juicebox project ID
     * @param _beneficiary The beneficiary address to claim tokens for
     */
    function claimFeeTokensFor(uint256 _projectId, address _beneficiary) external;
}
