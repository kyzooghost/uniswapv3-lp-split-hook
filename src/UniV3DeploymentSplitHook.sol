// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import { IJBController } from "@bananapus/core/interfaces/IJBController.sol";
import { IJBDirectory } from "@bananapus/core/interfaces/IJBDirectory.sol";
import { IJBMultiTerminal } from "@bananapus/core/interfaces/IJBMultiTerminal.sol";
import { IJBSplitHook } from "@bananapus/core/interfaces/IJBSplitHook.sol";
import { IJBTerminal } from "@bananapus/core/interfaces/IJBTerminal.sol";
import { IJBTokens } from "@bananapus/core/interfaces/IJBTokens.sol";
import { JBAccountingContext } from "@bananapus/core/structs/JBAccountingContext.sol";
import { JBRuleset } from "@bananapus/core/structs/JBRuleset.sol";
import { JBRulesetWithMetadata } from "@bananapus/core/structs/JBRulesetWithMetadata.sol";
import { JBRulesetMetadataResolver } from "@bananapus/core/libraries/JBRulesetMetadataResolver.sol";
import { JBSplitHookContext } from "@bananapus/core/structs/JBSplitHookContext.sol";
import { JBConstants } from "@bananapus/core/libraries/JBConstants.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { mulDiv, sqrt } from "@prb/math/src/Common.sol";

import { INonfungiblePositionManager } from "@uniswap/v3-periphery-flattened/INonfungiblePositionManager.sol";
import { IUniswapV3Factory } from "@uniswap/v3-core/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/interfaces/IUniswapV3Pool.sol";
import { TickMath } from "@uniswap/v3-core-patched/TickMath.sol";

import { IUniV3DeploymentSplitHook } from "./interfaces/IUniV3DeploymentSplitHook.sol";
import { IREVDeployer } from "./interfaces/IREVDeployer.sol";

/**
 * @title UniV3DeploymentSplitHook
 * @notice JuiceboxV4 IJBSplitHook contract that manages a two-stage deployment process:
 * 
 * Stage 1 (Accumulation): Current ruleset weight >= 0.1x first ruleset weight
 * - Accumulate project tokens without deploying UniswapV3 pool
 * - Tokens are held by the contract for future pool deployment
 * 
 * Stage 2 (Deployment): Current ruleset weight < 0.1x first ruleset weight  
 * - Deploy UniswapV3 pool using accumulated project tokens
 * - Set initial pool price based on the last ruleset weight before dropping below 0.1x threshold
 * - Route LP fees back to the project (with configurable fee split)
 * - Burn any newly received project tokens
 * 
 * Key assumptions include:
 * @dev This contract is the creator of the projectToken/terminalToken UniswapV3 pool.
 * @dev Any tokens held by the contract can be added to a UniswapV3 LP position.
 * @dev For any given UniswapV3 pool, the contract will control a single LP position.
 * @dev Stage transitions are determined by ruleset weight relative to the first ruleset weight.
 * @dev Issuance weight decreases over time, so we detect when it drops below 10% of original.
 * @dev Pool deployment uses the weight from the last "high" ruleset before the threshold drop.
 */
contract UniV3DeploymentSplitHook is IUniV3DeploymentSplitHook, IJBSplitHook, Ownable {
    using JBRulesetMetadataResolver for JBRuleset;
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @dev Thrown when a parameter is the zero address.
    error UniV3DeploymentSplitHook_ZeroAddressNotAllowed();

    /// @dev Thrown when a projectId does not exist in the JBDirectory
    error UniV3DeploymentSplitHook_InvalidProjectId();

    /// @dev Thrown when `processSplitWith` is called and this contract is not the hook specified in the JBSplitHookContext
    error UniV3DeploymentSplitHook_NotHookSpecifiedInContext();

    /// @dev Thrown when `processSplitWith` is not called by the project's controller
    error UniV3DeploymentSplitHook_SplitSenderNotValidControllerOrTerminal();

    /// @dev Thrown when trying to deploy pool but no tokens have been accumulated
    error UniV3DeploymentSplitHook_NoTokensAccumulated();

    /// @dev Thrown when trying to perform an action that's not allowed in the current stage
    error UniV3DeploymentSplitHook_InvalidStageForAction();

    /// @dev Thrown when the split hook receives terminal tokens from payouts (should only receive reserved tokens)
    error UniV3DeploymentSplitHook_TerminalTokensNotAllowed();

    /// @dev Thrown when fee percent exceeds 100% (10000 basis points)
    error UniV3DeploymentSplitHook_InvalidFeePercent();

    /// @dev Thrown when trying to claim tokens for a non-revnet operator
    error UniV3DeploymentSplitHook_UnauthorizedBeneficiary();

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice Basis points constant (10000 = 100%)
    uint256 public constant BPS = 10000;

    /// @notice Uniswap V3 pool fee (10000 = 1% fee tier)
    uint24 public constant UNISWAP_V3_POOL_FEE = 10000;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice JBDirectory (to find important control contracts for given projectId)
    address public immutable JB_DIRECTORY;

    /// @notice JBTokens (to find project tokens)
    address public immutable JB_TOKENS;

    /// @notice UniswapV3Factory address
    address public immutable UNISWAP_V3_FACTORY;

    /// @notice UniswapV3 NonFungiblePositionManager address
    address public immutable UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER;

    /// @notice Project ID to receive LP fees
    uint256 public immutable FEE_PROJECT_ID;

    /// @notice Percentage of LP fees to route to fee project (in basis points, e.g., 3800 = 38%)
    uint256 public immutable FEE_PERCENT;

    /// @notice REVDeployer contract address for revnet operator validation
    address public immutable REV_DEPLOYER;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice ProjectID => Terminal token => UniswapV3 terminalToken/projectToken pool address
    /// @dev One project has one projectToken (distributed by project)
    /// @dev One project can have many terminalTokens (accepted for terminal payment)
    mapping(uint256 projectId => mapping(address terminalToken => address pool)) public poolOf;

    /// @notice UniswapV3 pool => NonfungiblePositionManager tokenId
    /// @dev The contract will only control a single position for a given pool
    mapping(address pool => uint256 tokenId) public tokenIdForPool;

    /// @notice ProjectID => Accumulated project token balance
    mapping(uint256 projectId => uint256 accumulatedProjectTokens) public accumulatedProjectTokens;

    /// @notice ProjectID => Fee tokens claimable by that project
    mapping(uint256 projectId => uint256 claimableFeeTokens) public claimableFeeTokens;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param initialOwner Initial owner/admin of the contract
    /// @param jbDirectory JBDirectory address
    /// @param jbTokens JBTokens address
    /// @param uniswapV3Factory UniswapV3Factory address
    /// @param uniswapV3NonfungiblePositionManager UniswapV3 NonfungiblePositionManager address
    /// @param feeProjectId Project ID to receive LP fees
    /// @param feePercent Percentage of LP fees to route to fee project (in basis points, e.g., 3800 = 38%)
    /// @param revDeployer REVDeployer contract address for revnet operator validation
    constructor(
        address initialOwner,
        address jbDirectory,
        address jbTokens,
        address uniswapV3Factory,
        address uniswapV3NonfungiblePositionManager,
        uint256 feeProjectId,
        uint256 feePercent,
        address revDeployer
    ) 
        Ownable(initialOwner)
    {
        if (jbDirectory == address(0)) revert UniV3DeploymentSplitHook_ZeroAddressNotAllowed();
        if (jbTokens == address(0)) revert UniV3DeploymentSplitHook_ZeroAddressNotAllowed();
        if (uniswapV3Factory == address(0)) revert UniV3DeploymentSplitHook_ZeroAddressNotAllowed();
        if (uniswapV3NonfungiblePositionManager == address(0)) revert UniV3DeploymentSplitHook_ZeroAddressNotAllowed();
        if (revDeployer == address(0)) revert UniV3DeploymentSplitHook_ZeroAddressNotAllowed();
        if (feePercent > BPS) revert UniV3DeploymentSplitHook_InvalidFeePercent(); // Max 100% in basis points

        JB_DIRECTORY = jbDirectory;
        JB_TOKENS = jbTokens;

        UNISWAP_V3_FACTORY = uniswapV3Factory;
        UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER = uniswapV3NonfungiblePositionManager;
        FEE_PROJECT_ID = feeProjectId;
        FEE_PERCENT = feePercent;
        REV_DEPLOYER = revDeployer;
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice As per ERC-165 to declare supported interfaces
    /// @param interfaceId Interface ID as specified by `type(interface).interfaceId`
    /// @return Whether the interface is supported
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IUniV3DeploymentSplitHook).interfaceId
            || interfaceId == type(IJBSplitHook).interfaceId;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Get the current stage for a project based on ruleset weight
    /// @param projectId The Juicebox project ID
    /// @return isAccumulationStage True if current weight >= 0.1x first ruleset weight (accumulation stage), false if < 0.1x (deployment stage)
    function isAccumulationStage(uint256 projectId) public view returns (bool isAccumulationStage) {
        address controller = IJBDirectory(JB_DIRECTORY).controllerOf(projectId);
        if (controller == address(0)) return true; // Default to accumulation if no controller
        
        uint256 firstWeight = _getFirstRulesetWeight(projectId);
        if (firstWeight == 0) return true; // Default to accumulation if no first weight
        
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);
        uint256 threshold = firstWeight / 10; // 0.1x = 10% of first weight
        
        return ruleset.weight >= threshold;
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @notice Get the weight from the first ever ruleset
    /// @param projectId The Juicebox project ID
    /// @return weight The weight from the first ruleset, or 0 if none found
    function _getFirstRulesetWeight(uint256 projectId) internal view returns (uint256 weight) {
        address controller = IJBDirectory(JB_DIRECTORY).controllerOf(projectId);
        if (controller == address(0)) return 0;
        
        // Get all rulesets sorted from latest to earliest
        JBRulesetWithMetadata[] memory rulesets = IJBController(controller).allRulesetsOf(projectId, 0, 1);
        
        // The first element in the array is the first ever ruleset
        if (rulesets.length > 0) {
            return rulesets[0].ruleset.weight;
        }
        
        return 0;
    }

    /// @notice Find the latest ruleset weight before going under 0.1x the first ruleset weight
    /// @param projectId The Juicebox project ID
    /// @return weight The weight from the last ruleset before going under 0.1x threshold, or 0 if none found
    function _getLatestPositiveWeight(uint256 projectId) internal view returns (uint256 weight) {
        address controller = IJBDirectory(JB_DIRECTORY).controllerOf(projectId);
        if (controller == address(0)) return 0;
        
        uint256 firstWeight = _getFirstRulesetWeight(projectId);
        if (firstWeight == 0) return 0;
        
        uint256 threshold = firstWeight / 10; // 0.1x = 10% of first weight
        
        // Get all rulesets sorted from latest to earliest
        JBRulesetWithMetadata[] memory rulesets = IJBController(controller).allRulesetsOf(projectId, 0, 10);
        
        // Find the latest ruleset with weight >= 0.1x first weight
        // Since weight decreases over time, we iterate from most recent to oldest
        for (uint256 i = rulesets.length - 1; i >= 0; i--) {
            if (rulesets[i].ruleset.weight >= threshold) {
                return rulesets[i].ruleset.weight;
            }
        }
        
        // If no ruleset meets the threshold, return 0
        return 0;
    }

    /// @notice For given terminalToken amount, compute equivalent projectToken amount at current JuiceboxV4 price
    /// @dev Use pricing logic in JBTerminalStore.recordPaymentFrom()
    /// @param projectId JuiceboxV4 projectId
    /// @param terminalToken Terminal token
    /// @param terminalTokenInAmount Terminal token in amount
    /// @return projectTokenOutAmount The equivalent project token amount
    function _getProjectTokensOutForTerminalTokensIn(
        uint256 projectId, 
        address terminalToken,
        uint256 terminalTokenInAmount
    ) internal view returns (uint256 projectTokenOutAmount) {
        address controller = IJBDirectory(JB_DIRECTORY).controllerOf(projectId);
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);
        // Get the accounting context from the primary terminal for the terminal token
        address terminal = IJBDirectory(JB_DIRECTORY).primaryTerminalOf(projectId, terminalToken);
        JBAccountingContext memory context = IJBMultiTerminal(terminal).accountingContextForTokenOf(projectId, terminalToken);
        uint32 baseCurrency = ruleset.baseCurrency();
        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBController(controller).pricePerUnitOf({
                projectId: projectId,
                pricingCurrency: context.currency,
                unitCurrency: baseCurrency,
                decimals: context.decimals
            });
        projectTokenOutAmount = mulDiv(terminalTokenInAmount, ruleset.weight, weightRatio);
    }

    /// @notice For given terminalToken amount, compute equivalent projectToken amount using a specific weight
    /// @param projectId JuiceboxV4 projectId
    /// @param terminalToken Terminal token
    /// @param terminalTokenInAmount Terminal token in amount
    /// @param weight The weight to use for calculation
    /// @return projectTokenOutAmount The equivalent project token amount
    function _getProjectTokensOutForTerminalTokensInWithWeight(
        uint256 projectId, 
        address terminalToken,
        uint256 terminalTokenInAmount,
        uint256 weight
    ) internal view returns (uint256 projectTokenOutAmount) {
        address controller = IJBDirectory(JB_DIRECTORY).controllerOf(projectId);
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);
        // Get the accounting context from the primary terminal for the terminal token
        address terminal = IJBDirectory(JB_DIRECTORY).primaryTerminalOf(projectId, terminalToken);
        JBAccountingContext memory context = IJBMultiTerminal(terminal).accountingContextForTokenOf(projectId, terminalToken);
        uint32 baseCurrency = ruleset.baseCurrency();
        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBController(controller).pricePerUnitOf({
                projectId: projectId,
                pricingCurrency: context.currency,
                unitCurrency: baseCurrency,
                decimals: context.decimals
            });
        projectTokenOutAmount = mulDiv(terminalTokenInAmount, weight, weightRatio);
    }

    /// @notice Compute UniswapV3 SqrtPriceX96 for current JuiceboxV4 price
    /// @param projectId JuiceboxV4 projectId
    /// @param terminalToken Terminal token
    /// @param projectToken Project token
    /// @return sqrtPriceX96 The sqrt price in X96 format
    function _getSqrtPriceX96ForCurrentJuiceboxPrice(
        uint256 projectId,
        address terminalToken,
        address projectToken
    ) internal view returns (uint160 sqrtPriceX96) {
        (address token0, address token1) = _sortTokens(terminalToken, projectToken);
        // Use standard denominator of 1 ether or 10**18
        uint256 token0Amount = 1 ether;
        uint256 token1Amount;
        if (token0 == terminalToken) {
            token1Amount = _getProjectTokensOutForTerminalTokensIn(projectId, terminalToken, token0Amount);
        } else {
            token1Amount = _getTerminalTokensOutForProjectTokensIn(projectId, terminalToken, token0Amount);
        }
        /// @dev `sqrtPriceX96 = sqrt(token1/token0) * (2 ** 96)`
        /// @dev price = token1/token0 = What amount of token1 has equivalent value to 1 token0
        /// @dev See https://ethereum.stackexchange.com/questions/98685/computing-the-uniswap-v3-pair-price-from-q64-96-number
        /// @dev Also see https://blog.uniswap.org/uniswap-v3-math-primer
        return uint160(mulDiv(sqrt(token1Amount), 2**96,sqrt(token0Amount)));
    }

    /// @notice Get sqrtPriceX96 using the latest positive weight from ruleset history
    /// @param projectId JuiceboxV4 projectId
    /// @param terminalToken Terminal token
    /// @param projectToken Project token
    /// @return sqrtPriceX96 The sqrt price in X96 format
    function _getSqrtPriceX96ForLatestPositiveWeight(
        uint256 projectId,
        address terminalToken,
        address projectToken
    ) internal view returns (uint160 sqrtPriceX96) {
        uint256 latestWeight = _getLatestPositiveWeight(projectId);
        if (latestWeight == 0) {
            // Fallback to current price if no positive weight found
            return _getSqrtPriceX96ForCurrentJuiceboxPrice(projectId, terminalToken, projectToken);
        }
        
        (address token0, address token1) = _sortTokens(terminalToken, projectToken);
        // Use standard denominator of 1 ether or 10**18
        uint256 token0Amount = 1 ether;
        uint256 token1Amount;
        
        if (token0 == terminalToken) {
            token1Amount = _getProjectTokensOutForTerminalTokensInWithWeight(projectId, terminalToken, token0Amount, latestWeight);
        } else {
            token1Amount = _getTerminalTokensOutForProjectTokensInWithWeight(projectId, terminalToken, token0Amount, latestWeight);
        }
        
        /// @dev `sqrtPriceX96 = sqrt(token1/token0) * (2 ** 96)`
        return uint160(mulDiv(sqrt(token1Amount), 2**96, sqrt(token0Amount)));
    }

    /// @notice For given projectToken amount, compute equivalent terminalToken amount at current JuiceboxV4 price
    /// @dev Use pricing logic in JBTerminalStore.recordPaymentFrom()
    /// @param projectId JuiceboxV4 projectId
    /// @param terminalToken Terminal token
    /// @param projectTokenInAmount Project token in amount
    /// @return terminalTokenOutAmount The equivalent terminal token amount
    function _getTerminalTokensOutForProjectTokensIn(
        uint256 projectId, 
        address terminalToken, 
        uint256 projectTokenInAmount
    ) internal view returns (uint256 terminalTokenOutAmount) {
        address controller = IJBDirectory(JB_DIRECTORY).controllerOf(projectId);
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);
        // Get the accounting context from the primary terminal for the terminal token
        address terminal = IJBDirectory(JB_DIRECTORY).primaryTerminalOf(projectId, terminalToken);
        JBAccountingContext memory context = IJBMultiTerminal(terminal).accountingContextForTokenOf(projectId, terminalToken);
        uint32 baseCurrency = ruleset.baseCurrency();
        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBController(controller).pricePerUnitOf({
                projectId: projectId,
                pricingCurrency: context.currency,
                unitCurrency: baseCurrency,
                decimals: context.decimals
            });
        terminalTokenOutAmount = mulDiv(projectTokenInAmount, weightRatio, ruleset.weight);
    }

    /// @notice For given projectToken amount, compute equivalent terminalToken amount using a specific weight
    /// @param projectId JuiceboxV4 projectId
    /// @param terminalToken Terminal token
    /// @param projectTokenInAmount Project token in amount
    /// @param weight The weight to use for calculation
    /// @return terminalTokenOutAmount The equivalent terminal token amount
    function _getTerminalTokensOutForProjectTokensInWithWeight(
        uint256 projectId, 
        address terminalToken, 
        uint256 projectTokenInAmount,
        uint256 weight
    ) internal view returns (uint256 terminalTokenOutAmount) {
        address controller = IJBDirectory(JB_DIRECTORY).controllerOf(projectId);
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);
        // Get the accounting context from the primary terminal for the terminal token
        address terminal = IJBDirectory(JB_DIRECTORY).primaryTerminalOf(projectId, terminalToken);
        JBAccountingContext memory context = IJBMultiTerminal(terminal).accountingContextForTokenOf(projectId, terminalToken);
        uint32 baseCurrency = ruleset.baseCurrency();
        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBController(controller).pricePerUnitOf({
                projectId: projectId,
                pricingCurrency: context.currency,
                unitCurrency: baseCurrency,
                decimals: context.decimals
            });
        terminalTokenOutAmount = mulDiv(projectTokenInAmount, weightRatio, weight);
    }

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Claim fee tokens for a beneficiary (must be the project's revnet operator)
    /// @param projectId The Juicebox project ID
    /// @param beneficiary The beneficiary address to claim tokens for
    function claimFeeTokensFor(uint256 projectId, address beneficiary) external {
        // Validate that the beneficiary is the revnet operator for this project
        if (!IREVDeployer(REV_DEPLOYER).isSplitOperatorOf(projectId, beneficiary)) {
            revert UniV3DeploymentSplitHook_UnauthorizedBeneficiary();
        }
        
        // Get the claimable amount for this project
        uint256 claimableAmount = claimableFeeTokens[projectId];
        
        // Reset the claimable amount for this project
        claimableFeeTokens[projectId] = 0;

        if (claimableAmount > 0) {
            // Get the fee project token (all projects receive the same token from fee project)
            address feeProjectToken = address(IJBTokens(JB_TOKENS).tokenOf(FEE_PROJECT_ID));
            
            // Transfer the tokens to the beneficiary
            IERC20(feeProjectToken).safeTransfer(beneficiary, claimableAmount);
        }
    }

    /// @notice Collect LP fees and route them back to the project
    /// @param projectId The Juicebox project ID
    /// @param terminalToken The terminal token address
    function collectAndRouteLPFees(uint256 projectId, address terminalToken) external {
        if (isAccumulationStage(projectId)) revert UniV3DeploymentSplitHook_InvalidStageForAction();
        
        address pool = poolOf[projectId][terminalToken];
        if (pool == address(0)) revert UniV3DeploymentSplitHook_InvalidStageForAction();
        
        uint256 tokenId = tokenIdForPool[pool];
        if (tokenId == 0) revert UniV3DeploymentSplitHook_InvalidStageForAction();
        
        // Collect fees from the LP position (both terminal tokens and project tokens)
        address projectToken = address(IJBTokens(JB_TOKENS).tokenOf(projectId));
        (address token0, address token1) = _sortTokens(projectToken, terminalToken);
        
        // Set max amounts to collect all fees for both tokens
        uint128 maxAmount = type(uint128).max;
        
        (uint256 amount0, uint256 amount1) = INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER).collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: maxAmount,
                amount1Max: maxAmount
            })
        );
        
        // Route terminal token fees back to the project via addToBalance
        if (amount0 > 0 && token0 == terminalToken) {
            _routeFeesToProject(projectId, terminalToken, amount0);
        }
        
        if (amount1 > 0 && token1 == terminalToken) {
            _routeFeesToProject(projectId, terminalToken, amount1);
        }
        
        // Burn collected project token fees
        _burnReceivedTokens(projectId, projectToken, terminalToken);
    }

    /// @notice Manually trigger deployment for a project (only works in accumulation stage)
    /// @param projectId The Juicebox project ID
    /// @param terminalToken The terminal token address
    function deployPool(uint256 projectId, address terminalToken) external {
        if (!isAccumulationStage(projectId)) revert UniV3DeploymentSplitHook_InvalidStageForAction();
        
        address projectToken = address(IJBTokens(JB_TOKENS).tokenOf(projectId));
        uint256 projectTokenBalance = accumulatedProjectTokens[projectId];
        
        if (projectTokenBalance == 0) revert UniV3DeploymentSplitHook_NoTokensAccumulated();
        
        // Deploy the pool and add liquidity
        _deployPoolAndAddLiquidity(projectId, projectToken, terminalToken);
        
        emit ProjectDeployed(projectId, terminalToken, poolOf[projectId][terminalToken]);
    }

    /// @notice IJbSplitHook function called by JuiceboxV4 terminal/controller when sending funds to designated split hook contract.
    /// @dev Tokens are optimistically transferred to this split hook contract
    /// @param context Contextual data passed by JuiceboxV4 terminal/controller
    function processSplitWith(JBSplitHookContext calldata context) external payable {
        if (address(context.split.hook) != address(this)) revert UniV3DeploymentSplitHook_NotHookSpecifiedInContext();
        // Validate that msg.sender is the project's controller
        address controller = address(IJBDirectory(JB_DIRECTORY).controllerOf(context.projectId));
        if (controller == address(0)) revert UniV3DeploymentSplitHook_InvalidProjectId();
        if (controller != msg.sender) revert UniV3DeploymentSplitHook_SplitSenderNotValidControllerOrTerminal();
        /// @dev Key trust assumption: If the sender is the verified Controller, then we can trust the remaining fields in the context

        // Only handle reserved tokens (groupId == 1), revert on terminal tokens from payouts
        if (context.groupId != 1) revert UniV3DeploymentSplitHook_TerminalTokensNotAllowed();
        
        address projectToken = context.token;

        bool isAccumulation = isAccumulationStage(context.projectId);
        
        if (isAccumulation) {
            // Accumulation stage: Accumulate tokens (weight > 0)
            _accumulateTokens(context.projectId, projectToken);
        } else {
            // Get a terminal with an accounting context to use as the terminal token for pool creation
            address[] memory terminals = IJBDirectory(JB_DIRECTORY).terminalsOf(context.projectId);
            address terminalToken = address(0);
            
            // Find the first terminal that has an accounting context
            for (uint256 i = 0; i < terminals.length; i++) {
                try IJBMultiTerminal(terminals[i]).accountingContextsOf(context.projectId, context.token) returns (JBAccountingContext memory acContext) {
                    if (acContext.token != address(0)) {
                        // Use uniswap's native ETH if needed.
                        terminalToken = acContext.token == JBConstants.NATIVE_TOKEN ? address(0) : acContext.token;
                        break;
                    }
                } catch {
                    // Continue to next terminal if this one doesn't have the context
                    continue;
                }
            }

            // Deployment stage: Deploy pool if not already deployed, then burn newly received tokens
            _handleDeploymentStage(context.projectId, projectToken, terminalToken);
        }
    }

    //*********************************************************************//
    // ------------------------ internal functions ----------------------- //
    //*********************************************************************//

    /// @notice Accumulate project tokens in accumulation stage
    /// @param projectId The Juicebox project ID
    /// @param projectToken The project token address
    function _accumulateTokens(uint256 projectId, address projectToken) internal {
        // Only accumulate project tokens (reserved tokens)
        uint256 projectTokenBalance = IERC20(projectToken).balanceOf(address(this));
        accumulatedProjectTokens[projectId] += projectTokenBalance;
    }

    /// @notice Add liquidity to a UniswapV3 pool using accumulated tokens
    /// @param projectId JuiceboxV4 projectId
    /// @param projectToken Project token
    /// @param terminalToken Terminal token
    /// @param pool UniswapV3 pool
    function _addUniswapLiquidity(uint256 projectId, address projectToken, address terminalToken, address pool) internal {
        uint256 projectTokenBalance = accumulatedProjectTokens[projectId];
        
        if (projectTokenBalance == 0) return;
        
        // Create the liquidity position with only project tokens
        (address token0, address token1) = _sortTokens(projectToken, terminalToken);
        int24 currentJuiceboxPriceTick = TickMath.getTickAtSqrtRatio(_getSqrtPriceX96ForLatestPositiveWeight(projectId, projectToken, terminalToken));
        
        // Calculate amounts based on current pool price
        uint256 amount0 = projectToken == token0 ? projectTokenBalance : 0;
        uint256 amount1 = projectToken == token1 ? projectTokenBalance : 0;
        
        (uint256 tokenId,,,) = INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER).mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: UNISWAP_V3_POOL_FEE,
                tickLower: currentJuiceboxPriceTick, // No downward price movement allowed
                tickUpper: TickMath.MAX_TICK, // Infinite upward price movement
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        tokenIdForPool[pool] = tokenId;
        
        // Clear accumulated balances
        accumulatedProjectTokens[projectId] = 0;
    }

    /// @notice Burn received project tokens in deployment stage
    /// @param projectId The Juicebox project ID
    /// @param projectToken The project token address
    /// @param terminalToken The terminal token address (unused, kept for interface consistency)
    function _burnReceivedTokens(uint256 projectId, address projectToken, address terminalToken) internal {
        // Burn any project tokens received using the controller
        uint256 projectTokenBalance = IERC20(projectToken).balanceOf(address(this));
        if (projectTokenBalance > 0) {
            // Use the controller to burn project tokens
            address controller = IJBDirectory(JB_DIRECTORY).controllerOf(projectId);
            if (controller != address(0)) {
                IJBController(controller).burnTokensOf(
                    address(this),
                    projectId,
                    projectTokenBalance,
                    "Burning additional tokens"
                );
                emit TokensBurned(projectId, projectToken, projectTokenBalance);
            }
        }
    }

    /// @notice Create and initialize UniswapV3 pool
    /// @param projectId The Juicebox project ID
    /// @param projectToken Project token
    /// @param terminalToken Terminal token
    function _createAndInitializeUniswapV3Pool(uint256 projectId, address projectToken, address terminalToken) internal {
        (address token0, address token1) = _sortTokens(projectToken, terminalToken);
        uint160 sqrtPriceX96 = _getSqrtPriceX96ForLatestPositiveWeight(projectId, projectToken, terminalToken);
        address newPool = INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER).createAndInitializePoolIfNecessary(token0, token1, UNISWAP_V3_POOL_FEE, sqrtPriceX96);
        poolOf[projectId][terminalToken] = newPool;
    }

    /// @notice Deploy pool and add liquidity using accumulated tokens
    /// @param projectId The Juicebox project ID
    /// @param projectToken The project token address
    /// @param terminalToken The terminal token address
    function _deployPoolAndAddLiquidity(uint256 projectId, address projectToken, address terminalToken) internal {
        // Create and initialize the pool if it doesn't exist
        address pool = poolOf[projectId][terminalToken];
        if (pool == address(0)) {
            _createAndInitializeUniswapV3Pool(projectId, projectToken, terminalToken);
            pool = poolOf[projectId][terminalToken];
        }
        
        // Add liquidity using accumulated tokens
        _addUniswapLiquidity(projectId, projectToken, terminalToken, pool);
    }

    /// @notice Handle deployment stage: deploy pool if not deployed, then burn newly received tokens
    /// @param projectId The Juicebox project ID
    /// @param projectToken The project token address
    /// @param terminalToken The terminal token address
    function _handleDeploymentStage(uint256 projectId, address projectToken, address terminalToken) internal {
        // If pool doesn't exist yet, deploy it using accumulated project tokens
        address pool = poolOf[projectId][terminalToken];
        if (pool == address(0)) {
            uint256 projectTokenBalance = accumulatedProjectTokens[projectId];
            
            if (projectTokenBalance > 0) {
                _deployPoolAndAddLiquidity(projectId, projectToken, terminalToken);
                emit ProjectDeployed(projectId, terminalToken, poolOf[projectId][terminalToken]);
            }
        }
        
        // Burn any newly received project tokens
        _burnReceivedTokens(projectId, projectToken, terminalToken);
    }

    /// @notice Route fees back to the project via addToBalance
    /// @param projectId The Juicebox project ID
    /// @param token The token to route
    /// @param amount The amount to route
    function _routeFeesToProject(uint256 projectId, address token, uint256 amount) internal {
        if (amount == 0) return;
        
        // Calculate fee amount to send to fee project
        uint256 feeAmount = (amount * FEE_PERCENT) / BPS;
        uint256 remainingAmount = amount - feeAmount;
        
        // Route fee portion to fee project
        if (feeAmount > 0) {
            address feeTerminal = IJBDirectory(JB_DIRECTORY).primaryTerminalOf(FEE_PROJECT_ID, token);
            if (feeTerminal != address(0)) {
                IERC20(token).safeApprove(feeTerminal, feeAmount);
                uint256 beneficiaryTokenCount = IJBMultiTerminal(feeTerminal).pay(
                    FEE_PROJECT_ID,
                    token,
                    feeAmount,
                    address(this), // beneficiary
                    0, // minReturnedTokens
                    "LP Fee", // memo
                    "" // metadata
                );
                
                // Track the fee tokens returned for this project
                claimableFeeTokens[projectId] += beneficiaryTokenCount;
            }
        }
        
        // Route remaining amount to original project
        if (remainingAmount > 0) {
            address terminal = IJBDirectory(JB_DIRECTORY).primaryTerminalOf(projectId, token);
            if (terminal != address(0)) {
                IERC20(token).safeApprove(terminal, remainingAmount);
                IJBMultiTerminal(terminal).addToBalanceOf(
                    projectId,
                    token,
                    remainingAmount,
                    false, // shouldReturnHeldFees
                    "",
                    ""
                );
            }
        }
        
        emit LPFeesRouted(projectId, token, amount);
    }

    /// @notice Sort input tokens in order expected by `INonfungiblePositionManager.createAndInitializePoolIfNecessary`
    /// @param tokenA First token address
    /// @param tokenB Second token address
    /// @return token0 The lower address token
    /// @return token1 The higher address token
    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }
}
