// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title IUniV3DeploymentSplitHook
 * @notice JuiceBox v4 Split Hook contract that manages a two-stage deployment process:
 * Stage 1: Accumulate project tokens without deploying Uniswap V3 pool
 * Stage 2: Deploy pool with accumulated tokens (triggered manually by project owner or operator)
 * After deployment: Route LP fees back to project, burn newly received project tokens
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
     * @notice Check if a pool has been deployed for a project/terminal token pair
     * @param projectId The Juicebox project ID
     * @param terminalToken The terminal token address
     * @return deployed True if pool exists
     */
    function isPoolDeployed(uint256 projectId, address terminalToken) external view returns (bool deployed);

    /**
     * @notice Deploy a UniswapV3 pool using accumulated project tokens
     * @dev Only callable by the project owner or an operator with SET_BUYBACK_POOL permission
     * @param projectId The Juicebox project ID
     * @param terminalToken The terminal token address
     * @param amount0Min Minimum amount of token0 to add (slippage protection, defaults to 0)
     * @param amount1Min Minimum amount of token1 to add (slippage protection, defaults to 0)
     * @param minCashOutReturn Minimum terminal tokens from cash-out (slippage protection, 0 = auto 1% tolerance)
     */
    function deployPool(
        uint256 projectId,
        address terminalToken,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 minCashOutReturn
    ) external;

    /**
     * @notice Collect LP fees and route them back to the project
     * @param projectId The Juicebox project ID
     * @param terminalToken The terminal token address
     */
    function collectAndRouteLPFees(uint256 projectId, address terminalToken) external;

    /**
     * @notice Claim fee tokens for a beneficiary (must be the project's revnet operator)
     * @param projectId The Juicebox project ID
     * @param beneficiary The beneficiary address to claim tokens for
     */
    function claimFeeTokensFor(uint256 projectId, address beneficiary) external;
}
