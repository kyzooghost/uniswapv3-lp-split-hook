// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

/**
 * @title IUniV3DeploymentSplitHook
 * @notice JuiceBox v4 Split Hook contract that manages a two-stage deployment process:
 * Stage 1: Accumulate project tokens without deploying Uniswap V3 pool
 * Stage 2: Deploy pool with accumulated tokens and route LP fees back to project
 */
interface IUniV3DeploymentSplitHook {

    /// @dev Emitted when a project transitions from Stage 1 to Stage 2
    event ProjectDeployed(uint256 indexed projectId, address indexed terminalToken, address indexed pool);

    /// @dev Emitted when LP fees are routed back to the project
    /// @param feeAmount Amount sent to fee project
    /// @param remainingAmount Amount sent to original project
    /// @param feeTokensMinted Number of fee project tokens minted
    event LPFeesRouted(
        uint256 indexed projectId,
        address indexed terminalToken,
        uint256 totalAmount,
        uint256 feeAmount,
        uint256 remainingAmount,
        uint256 feeTokensMinted
    );

    /// @dev Emitted when tokens are burned in Stage 2
    event TokensBurned(uint256 indexed projectId, address indexed token, uint256 amount);

    /// @dev Emitted when fee tokens are claimed by a revnet operator
    event FeeTokensClaimed(uint256 indexed projectId, address indexed beneficiary, uint256 amount);

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
     * @param _amount0Min Minimum amount of token0 to add (slippage protection, defaults to 0)
     * @param _amount1Min Minimum amount of token1 to add (slippage protection, defaults to 0)
     */
    function deployPool(
        uint256 _projectId,
        address _terminalToken,
        uint256 _amount0Min,
        uint256 _amount1Min
    ) external;

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
