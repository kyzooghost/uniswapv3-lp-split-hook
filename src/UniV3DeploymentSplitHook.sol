// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import { IJBController } from "@bananapus/core/interfaces/IJBController.sol";
import { IJBDirectory } from "@bananapus/core/interfaces/IJBDirectory.sol";
import { IJBMultiTerminal } from "@bananapus/core/interfaces/IJBMultiTerminal.sol";
import { IJBSplitHook } from "@bananapus/core/interfaces/IJBSplitHook.sol";
import { IJBTerminal } from "@bananapus/core/interfaces/IJBTerminal.sol";
import { IJBTerminalStore } from "@bananapus/core/interfaces/IJBTerminalStore.sol";
import { IJBTokens } from "@bananapus/core/interfaces/IJBTokens.sol";
import { JBAccountingContext } from "@bananapus/core/structs/JBAccountingContext.sol";
import { JBRuleset } from "@bananapus/core/structs/JBRuleset.sol";
import { JBRulesetMetadata } from "@bananapus/core/structs/JBRulesetMetadata.sol";
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

    /// @notice JBTerminalStore (to get cash out rates)
    address public immutable JB_TERMINAL_STORE;

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
    /// @param jbTerminalStore JBTerminalStore address
    /// @param uniswapV3Factory UniswapV3Factory address
    /// @param uniswapV3NonfungiblePositionManager UniswapV3 NonfungiblePositionManager address
    /// @param feeProjectId Project ID to receive LP fees
    /// @param feePercent Percentage of LP fees to route to fee project (in basis points, e.g., 3800 = 38%)
    /// @param revDeployer REVDeployer contract address for revnet operator validation
    constructor(
        address initialOwner,
        address jbDirectory,
        address jbTokens,
        address jbTerminalStore,
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
        if (jbTerminalStore == address(0)) revert UniV3DeploymentSplitHook_ZeroAddressNotAllowed();
        if (uniswapV3Factory == address(0)) revert UniV3DeploymentSplitHook_ZeroAddressNotAllowed();
        if (uniswapV3NonfungiblePositionManager == address(0)) revert UniV3DeploymentSplitHook_ZeroAddressNotAllowed();
        if (revDeployer == address(0)) revert UniV3DeploymentSplitHook_ZeroAddressNotAllowed();
        if (feePercent > BPS) revert UniV3DeploymentSplitHook_InvalidFeePercent(); // Max 100% in basis points

        JB_DIRECTORY = jbDirectory;
        JB_TOKENS = jbTokens;
        JB_TERMINAL_STORE = jbTerminalStore;

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
    /// @dev Projects start in accumulation stage and transition to deployment stage when weight drops below 10% of initial
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
    /// @dev Used to determine the baseline weight for stage transition calculations
    /// @param projectId The Juicebox project ID
    /// @return weight The weight from the first ruleset, or 0 if none found
    function _getFirstRulesetWeight(uint256 projectId) internal view returns (uint256 weight) {
        address controller = IJBDirectory(JB_DIRECTORY).controllerOf(projectId);
        if (controller == address(0)) return 0;
        
        // Get all rulesets sorted from latest to earliest
        // Requesting 1 ruleset starting from index 0 gives us the first (oldest) ruleset
        JBRulesetWithMetadata[] memory rulesets = IJBController(controller).allRulesetsOf(projectId, 0, 1);
        
        // The first element in the array is the first ever ruleset
        if (rulesets.length > 0) {
            return rulesets[0].ruleset.weight;
        }
        
        return 0;
    }

    /// @notice Find the latest ruleset weight before going under 0.1x the first ruleset weight
    /// @dev This weight is used to set the initial pool price, capturing the "high" valuation before the drop
    /// @param projectId The Juicebox project ID
    /// @return weight The weight from the last ruleset before going under 0.1x threshold, or 0 if none found
    function _getLatestPositiveWeight(uint256 projectId) internal view returns (uint256 weight) {
        address controller = IJBDirectory(JB_DIRECTORY).controllerOf(projectId);
        if (controller == address(0)) return 0;
        
        uint256 firstWeight = _getFirstRulesetWeight(projectId);
        if (firstWeight == 0) return 0;
        
        uint256 threshold = firstWeight / 10; // 0.1x = 10% of first weight
        
        // Get up to 10 most recent rulesets sorted from latest to earliest
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
    /// @dev Uses pricing logic from JBTerminalStore.recordPaymentFrom() to calculate token conversion
    /// @param projectId JuiceboxV4 projectId
    /// @param terminalToken Terminal token address
    /// @param terminalTokenInAmount Terminal token input amount
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
        
        // Calculate weight ratio: if currencies match, use 10^decimals; otherwise get price conversion
        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBController(controller).pricePerUnitOf({
                projectId: projectId,
                pricingCurrency: context.currency,
                unitCurrency: baseCurrency,
                decimals: context.decimals
            });
        
        // Convert using formula: projectTokens = (terminalTokens * weight) / weightRatio
        projectTokenOutAmount = mulDiv(terminalTokenInAmount, ruleset.weight, weightRatio);
    }

    /// @notice For given terminalToken amount, compute equivalent projectToken amount using a specific weight
    /// @dev Allows using a historical weight instead of the current ruleset weight
    /// @param projectId JuiceboxV4 projectId
    /// @param terminalToken Terminal token address
    /// @param terminalTokenInAmount Terminal token input amount
    /// @param weight The weight to use for calculation (typically from a historical ruleset)
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
        
        // Calculate weight ratio: if currencies match, use 10^decimals; otherwise get price conversion
        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBController(controller).pricePerUnitOf({
                projectId: projectId,
                pricingCurrency: context.currency,
                unitCurrency: baseCurrency,
                decimals: context.decimals
            });
        
        // Convert using provided weight instead of current ruleset weight
        projectTokenOutAmount = mulDiv(terminalTokenInAmount, weight, weightRatio);
    }

    /// @notice Compute UniswapV3 SqrtPriceX96 for current JuiceboxV4 price
    /// @dev Converts Juicebox pricing to Uniswap V3's sqrt price format (Q64.96 fixed point)
    /// @param projectId JuiceboxV4 projectId
    /// @param terminalToken Terminal token address
    /// @param projectToken Project token address
    /// @return sqrtPriceX96 The sqrt price in X96 format
    function _getSqrtPriceX96ForCurrentJuiceboxPrice(
        uint256 projectId,
        address terminalToken,
        address projectToken
    ) internal view returns (uint160 sqrtPriceX96) {
        (address token0, address token1) = _sortTokens(terminalToken, projectToken);
        
        // Use standard denominator of 10^18 as base amount
        uint256 token0Amount = 10 ** 18;
        uint256 token1Amount;
        
        // Calculate equivalent amount of token1 for 1 token0 based on Juicebox pricing
        if (token0 == terminalToken) {
            token1Amount = _getProjectTokensOutForTerminalTokensIn(projectId, terminalToken, token0Amount);
        } else {
            token1Amount = _getTerminalTokensOutForProjectTokensIn(projectId, terminalToken, token0Amount);
        }
        
        // Calculate sqrt price: sqrtPriceX96 = sqrt(token1/token0) * (2^96)
        // Price = token1/token0 represents how much token1 equals 1 token0 in value
        // See: https://ethereum.stackexchange.com/questions/98685/computing-the-uniswap-v3-pair-price-from-q64-96-number
        // See: https://blog.uniswap.org/uniswap-v3-math-primer
        return uint160(mulDiv(sqrt(token1Amount), 2**96, sqrt(token0Amount)));
    }

    /// @notice Get sqrtPriceX96 using the latest positive weight from ruleset history
    /// @dev Uses the weight from the last "high" ruleset before dropping below threshold for pool initialization
    /// @param projectId JuiceboxV4 projectId
    /// @param terminalToken Terminal token address
    /// @param projectToken Project token address
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
        
        // Use standard denominator of 10^18 as base amount
        uint256 token0Amount = 10 ** 18;
        uint256 token1Amount;
        
        // Calculate equivalent amount using historical weight
        if (token0 == terminalToken) {
            token1Amount = _getProjectTokensOutForTerminalTokensInWithWeight(projectId, terminalToken, token0Amount, latestWeight);
        } else {
            token1Amount = _getTerminalTokensOutForProjectTokensInWithWeight(projectId, terminalToken, token0Amount, latestWeight);
        }
        
        // Calculate sqrt price: sqrtPriceX96 = sqrt(token1/token0) * (2^96)
        return uint160(mulDiv(sqrt(token1Amount), 2**96, sqrt(token0Amount)));
    }

    /// @notice For given projectToken amount, compute equivalent terminalToken amount at current JuiceboxV4 price
    /// @dev Uses pricing logic from JBTerminalStore.recordPaymentFrom() to calculate reverse token conversion
    /// @param projectId JuiceboxV4 projectId
    /// @param terminalToken Terminal token address
    /// @param projectTokenInAmount Project token input amount
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
        
        // Calculate weight ratio: if currencies match, use 10^decimals; otherwise get price conversion
        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBController(controller).pricePerUnitOf({
                projectId: projectId,
                pricingCurrency: context.currency,
                unitCurrency: baseCurrency,
                decimals: context.decimals
            });
        
        // Convert using formula: terminalTokens = (projectTokens * weightRatio) / weight
        terminalTokenOutAmount = mulDiv(projectTokenInAmount, weightRatio, ruleset.weight);
    }

    /// @notice For given projectToken amount, compute equivalent terminalToken amount using a specific weight
    /// @dev Allows using a historical weight instead of the current ruleset weight
    /// @param projectId JuiceboxV4 projectId
    /// @param terminalToken Terminal token address
    /// @param projectTokenInAmount Project token input amount
    /// @param weight The weight to use for calculation (typically from a historical ruleset)
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
        
        // Calculate weight ratio: if currencies match, use 10^decimals; otherwise get price conversion
        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBController(controller).pricePerUnitOf({
                projectId: projectId,
                pricingCurrency: context.currency,
                unitCurrency: baseCurrency,
                decimals: context.decimals
            });
        
        // Convert using provided weight instead of current ruleset weight
        terminalTokenOutAmount = mulDiv(projectTokenInAmount, weightRatio, weight);
    }

    /// @notice Calculate the issuance rate (price ceiling) - tokens received per terminal token paid
    /// @dev Accounts for reserved rate - only non-reserved tokens are issued to payers
    /// @param projectId JuiceboxV4 projectId
    /// @param terminalToken Terminal token address
    /// @return projectTokensPerTerminalToken The number of project tokens issued per terminal token (in 18 decimals)
    function _getIssuanceRate(uint256 projectId, address terminalToken) internal view returns (uint256 projectTokensPerTerminalToken) {
        address controller = IJBDirectory(JB_DIRECTORY).controllerOf(projectId);
        (JBRuleset memory ruleset, JBRulesetMetadata memory metadata) = IJBController(controller).currentRulesetOf(projectId);
        
        // Get reserved percent from ruleset metadata
        uint16 reservedPercent = JBRulesetMetadataResolver.reservedPercent(ruleset);
        
        // Calculate tokens per terminal token (without reserved rate)
        uint256 tokensPerTerminalToken = _getProjectTokensOutForTerminalTokensIn(projectId, terminalToken, 10 ** 18);
        
        // Apply reserved rate: only (1 - reservedPercent) of tokens go to payers
        if (reservedPercent > 0) {
            projectTokensPerTerminalToken = mulDiv(
                tokensPerTerminalToken,
                uint256(JBConstants.MAX_RESERVED_PERCENT - reservedPercent),
                uint256(JBConstants.MAX_RESERVED_PERCENT)
            );
        } else {
            projectTokensPerTerminalToken = tokensPerTerminalToken;
        }
    }

    /// @notice Calculate the cash out rate (price floor) - terminal tokens received per project token cashed out
    /// @dev Uses currentReclaimableSurplusOf to get the actual cash out rate
    /// @param projectId JuiceboxV4 projectId
    /// @param terminalToken Terminal token address
    /// @return terminalTokensPerProjectToken The number of terminal tokens received per project token (in 18 decimals)
    function _getCashOutRate(uint256 projectId, address terminalToken) internal view returns (uint256 terminalTokensPerProjectToken) {
        // Normalize terminal token for TerminalStore (native ETH -> JB_NATIVE_TOKEN)
        address tokenToReclaim = terminalToken == address(0) ? JBConstants.NATIVE_TOKEN : terminalToken;
        
        // Get cash out rate for 10^18 project tokens (1 token with 18 decimals)
        // currentReclaimableSurplusOf returns terminal tokens received for cashing out project tokens
        try IJBTerminalStore(JB_TERMINAL_STORE).currentReclaimableSurplusOf(
            projectId,
            10 ** 18, // cashOutCount: 1 project token (18 decimals)
            uint32(uint160(tokenToReclaim)), // currency
            _getTokenDecimals(tokenToReclaim) // decimals
        ) returns (uint256 reclaimableAmount) {
            terminalTokensPerProjectToken = reclaimableAmount;
        } catch {
            // If calculation fails, fall back to using weight-based calculation
            terminalTokensPerProjectToken = _getTerminalTokensOutForProjectTokensIn(projectId, terminalToken, 10 ** 18);
        }
    }

    /// @notice Get token decimals, defaulting to 18 if unavailable
    /// @param token The token address
    /// @return decimals The token decimals (defaults to 18)
    function _getTokenDecimals(address token) internal view returns (uint8 decimals) {
        if (token == JBConstants.NATIVE_TOKEN || token == address(0)) {
            return 18; // Native ETH has 18 decimals
        }
        try IERC20(token).decimals() returns (uint8 dec) {
            return dec;
        } catch {
            return 18; // Default to 18 if unavailable
        }
    }

    /// @notice Convert issuance rate to sqrtPriceX96 (price ceiling)
    /// @param projectId JuiceboxV4 projectId
    /// @param terminalToken Terminal token address
    /// @param projectToken Project token address
    /// @return sqrtPriceX96 The sqrt price in X96 format representing the issuance rate
    function _getIssuanceRateSqrtPriceX96(uint256 projectId, address terminalToken, address projectToken) internal view returns (uint160 sqrtPriceX96) {
        (address token0, address token1) = _sortTokens(terminalToken, projectToken);
        
        // Get issuance rate: project tokens per terminal token
        uint256 projectTokensPerTerminalToken = _getIssuanceRate(projectId, terminalToken);
        
        // Calculate price based on token ordering
        uint256 token0Amount = 10 ** 18;
        uint256 token1Amount;
        
        if (token0 == terminalToken) {
            // Price = projectTokens / terminalToken = token1 / token0
            token1Amount = projectTokensPerTerminalToken;
        } else {
            // Price = terminalToken / projectTokens = token0 / token1
            // So token1Amount = token0Amount / projectTokensPerTerminalToken
            token1Amount = mulDiv(token0Amount, 10 ** 18, projectTokensPerTerminalToken);
        }
        
        // Calculate sqrt price: sqrtPriceX96 = sqrt(token1/token0) * (2^96)
        return uint160(mulDiv(sqrt(token1Amount), 2**96, sqrt(token0Amount)));
    }

    /// @notice Convert cash out rate to sqrtPriceX96 (price floor)
    /// @param projectId JuiceboxV4 projectId
    /// @param terminalToken Terminal token address
    /// @param projectToken Project token address
    /// @return sqrtPriceX96 The sqrt price in X96 format representing the cash out rate
    function _getCashOutRateSqrtPriceX96(uint256 projectId, address terminalToken, address projectToken) internal view returns (uint160 sqrtPriceX96) {
        (address token0, address token1) = _sortTokens(terminalToken, projectToken);
        
        // Get cash out rate: terminal tokens per project token
        uint256 terminalTokensPerProjectToken = _getCashOutRate(projectId, terminalToken);
        
        // Calculate price based on token ordering
        uint256 token0Amount = 10 ** 18;
        uint256 token1Amount;
        
        if (token0 == terminalToken) {
            // Price = terminalToken / projectTokens = token0 / token1
            // So token1Amount = token0Amount / terminalTokensPerProjectToken
            token1Amount = mulDiv(token0Amount, 10 ** 18, terminalTokensPerProjectToken);
        } else {
            // Price = projectTokens / terminalToken = token1 / token0
            token1Amount = terminalTokensPerProjectToken;
        }
        
        // Calculate sqrt price: sqrtPriceX96 = sqrt(token1/token0) * (2^96)
        return uint160(mulDiv(sqrt(token1Amount), 2**96, sqrt(token0Amount)));
    }

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Claim fee tokens for a beneficiary (must be the project's revnet operator)
    /// @dev Only the revnet operator for a project can claim fee tokens earned from LP fees
    /// @param projectId The Juicebox project ID
    /// @param beneficiary The beneficiary address to claim tokens for (must be revnet operator)
    function claimFeeTokensFor(uint256 projectId, address beneficiary) external {
        // Validate that the beneficiary is the revnet operator for this project
        if (!IREVDeployer(REV_DEPLOYER).isSplitOperatorOf(projectId, beneficiary)) {
            revert UniV3DeploymentSplitHook_UnauthorizedBeneficiary();
        }
        
        // Get the claimable amount for this project
        uint256 claimableAmount = claimableFeeTokens[projectId];
        
        // Reset the claimable amount for this project (prevents reentrancy)
        claimableFeeTokens[projectId] = 0;

        if (claimableAmount > 0) {
            // Get the fee project token (all projects receive the same token from fee project)
            address feeProjectToken = address(IJBTokens(JB_TOKENS).tokenOf(FEE_PROJECT_ID));
            
            // Transfer the tokens to the beneficiary
            IERC20(feeProjectToken).safeTransfer(beneficiary, claimableAmount);
        }
    }

    /// @notice Collect LP fees and route them back to the project
    /// @dev Can only be called in deployment stage after pool has been created
    /// @dev Terminal token fees are routed back to the project, project token fees are burned
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
        
        // Burn collected project token fees to maintain token economics
        _burnReceivedTokens(projectId, projectToken, terminalToken);
    }

    /// @notice Manually trigger deployment for a project (only works in accumulation stage)
    /// @dev Allows early deployment before automatic transition to deployment stage
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

    /// @notice Rebalance LP position to match current issuance and cash out rates
    /// @dev Removes old liquidity and adds new liquidity with updated tick bounds
    /// @param projectId The Juicebox project ID
    /// @param terminalToken The terminal token address
    function rebalanceLiquidity(uint256 projectId, address terminalToken) external {
        if (isAccumulationStage(projectId)) revert UniV3DeploymentSplitHook_InvalidStageForAction();
        
        address pool = poolOf[projectId][terminalToken];
        if (pool == address(0)) revert UniV3DeploymentSplitHook_InvalidStageForAction();
        
        uint256 tokenId = tokenIdForPool[pool];
        if (tokenId == 0) revert UniV3DeploymentSplitHook_InvalidStageForAction();
        
        address projectToken = address(IJBTokens(JB_TOKENS).tokenOf(projectId));
        
        // Get current position info
        (,, address positionToken0, address positionToken1,,,, uint128 liquidity,,,,) = 
            INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER).positions(tokenId);
        
        // Collect all fees first
        (uint256 amount0, uint256 amount1) = INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER).collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        
        // Route fees if terminal tokens were collected
        (address token0, address token1) = _sortTokens(projectToken, terminalToken);
        if (amount0 > 0 && token0 == terminalToken) {
            _routeFeesToProject(projectId, terminalToken, amount0);
        }
        if (amount1 > 0 && token1 == terminalToken) {
            _routeFeesToProject(projectId, terminalToken, amount1);
        }
        
        // Decrease liquidity to zero (removes all liquidity)
        if (liquidity > 0) {
            INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER).decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
        }
        
        // Collect remaining tokens from the position
        INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER).collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        
        // Get current balances
        uint256 projectTokenBalance = IERC20(projectToken).balanceOf(address(this));
        uint256 terminalTokenBalance = terminalToken != address(0) 
            ? IERC20(terminalToken).balanceOf(address(this))
            : address(this).balance;
        
        // Calculate new tick bounds based on current rates
        int24 tickLower = TickMath.getTickAtSqrtRatio(_getCashOutRateSqrtPriceX96(projectId, terminalToken, projectToken));
        int24 tickUpper = TickMath.getTickAtSqrtRatio(_getIssuanceRateSqrtPriceX96(projectId, terminalToken, projectToken));
        
        // Ensure tickLower < tickUpper
        if (tickLower >= tickUpper) {
            // If rates are inverted, use a small range around the current price
            uint160 currentSqrtPrice = _getSqrtPriceX96ForCurrentJuiceboxPrice(projectId, terminalToken, projectToken);
            int24 currentTick = TickMath.getTickAtSqrtRatio(currentSqrtPrice);
            tickLower = currentTick - 100; // 1% below
            tickUpper = currentTick + 100; // 1% above
        }
        
        // Approve tokens
        if (projectTokenBalance > 0) {
            IERC20(projectToken).safeApprove(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER, 0);
            IERC20(projectToken).safeApprove(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER, projectTokenBalance);
        }
        
        if (terminalTokenBalance > 0 && terminalToken != address(0)) {
            IERC20(terminalToken).safeApprove(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER, 0);
            IERC20(terminalToken).safeApprove(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER, terminalTokenBalance);
        }
        
        // Calculate amounts based on token ordering
        uint256 amount0Desired = projectToken == token0 ? projectTokenBalance : terminalTokenBalance;
        uint256 amount1Desired = projectToken == token1 ? projectTokenBalance : terminalTokenBalance;
        
        // Since tick bounds may have changed, we need to remove the old position and create a new one
        // First, burn the old NFT (this removes the position completely)
        INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER).burn(tokenId);
        
        // Create new position with updated tick bounds
        (uint256 newTokenId,,,) = INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER).mint{value: terminalToken == address(0) ? terminalTokenBalance : 0}(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: UNISWAP_V3_POOL_FEE,
                tickLower: tickLower, // Price floor: cash out rate
                tickUpper: tickUpper, // Price ceiling: issuance rate
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        
        // Update the tokenId mapping
        tokenIdForPool[pool] = newTokenId;
    }

    /// @notice IJbSplitHook function called by JuiceboxV4 terminal/controller when sending funds to designated split hook contract
    /// @dev Tokens are optimistically transferred to this split hook contract before this function is called
    /// @dev Key trust assumption: If the sender is the verified Controller, then we can trust the remaining fields in the context
    /// @param context Contextual data passed by JuiceboxV4 terminal/controller
    function processSplitWith(JBSplitHookContext calldata context) external payable {
        if (address(context.split.hook) != address(this)) revert UniV3DeploymentSplitHook_NotHookSpecifiedInContext();
        
        // Validate that msg.sender is the project's controller
        address controller = address(IJBDirectory(JB_DIRECTORY).controllerOf(context.projectId));
        if (controller == address(0)) revert UniV3DeploymentSplitHook_InvalidProjectId();
        if (controller != msg.sender) revert UniV3DeploymentSplitHook_SplitSenderNotValidControllerOrTerminal();

        // Only handle reserved tokens (groupId == 1), revert on terminal tokens from payouts
        if (context.groupId != 1) revert UniV3DeploymentSplitHook_TerminalTokensNotAllowed();
        
        address projectToken = context.token;
        bool isAccumulation = isAccumulationStage(context.projectId);
        
        if (isAccumulation) {
            // Accumulation stage: Accumulate tokens for future pool deployment
            _accumulateTokens(context.projectId, projectToken);
        } else {
            // Deployment stage: Find terminal token and handle pool deployment
            address[] memory terminals = IJBDirectory(JB_DIRECTORY).terminalsOf(context.projectId);
            address terminalToken = address(0);
            
            // Find the first terminal that has an accounting context
            for (uint256 i = 0; i < terminals.length; i++) {
                try IJBMultiTerminal(terminals[i]).accountingContextsOf(context.projectId, context.token) returns (JBAccountingContext memory acContext) {
                    if (acContext.token != address(0)) {
                        // Convert JBConstants.NATIVE_TOKEN to address(0) for Uniswap compatibility
                        terminalToken = acContext.token == JBConstants.NATIVE_TOKEN ? address(0) : acContext.token;
                        break;
                    }
                } catch {
                    // Continue to next terminal if this one doesn't have the context
                    continue;
                }
            }

            // Deploy pool if not already deployed, then burn newly received tokens
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
    /// @dev Cashes out half of project tokens to get terminal tokens, then creates full-range LP position
    /// @param projectId JuiceboxV4 projectId
    /// @param projectToken Project token address
    /// @param terminalToken Terminal token address (address(0) for native ETH)
    /// @param pool UniswapV3 pool address
    function _addUniswapLiquidity(uint256 projectId, address projectToken, address terminalToken, address pool) internal {
        uint256 projectTokenBalance = accumulatedProjectTokens[projectId];
        
        if (projectTokenBalance == 0) return;
        
        // Cash out half of the project tokens to get terminal tokens for pairing
        // This provides the backing tokens needed to create a balanced LP position
        address tokenToReclaim = terminalToken == address(0) ? JBConstants.NATIVE_TOKEN : terminalToken;
        address terminal = IJBDirectory(JB_DIRECTORY).primaryTerminalOf(projectId, tokenToReclaim);
        
        if (terminal != address(0)) {
            uint256 cashOutAmount = projectTokenBalance / 2;
            
            // Calculate minimum tokens to reclaim (use 0 to accept any amount)
            uint256 minTokensReclaimed = 0;
            
            // Cash out half of the project tokens to get terminal tokens
            IJBMultiTerminal(terminal).cashOutTokensOf(
                address(this), // holder
                projectId,
                cashOutAmount, // cashOutCount
                tokenToReclaim, // tokenToReclaim (uses NATIVE_TOKEN constant for native ETH)
                minTokensReclaimed, // minTokensReclaimed
                payable(address(this)), // beneficiary
                "" // metadata
            );
        }
        
        // Create the liquidity position with both project tokens and terminal tokens
        (address token0, address token1) = _sortTokens(projectToken, terminalToken);
        
        // Calculate tick bounds based on current issuance rate (ceiling) and cash out rate (floor)
        int24 tickLower = TickMath.getTickAtSqrtRatio(_getCashOutRateSqrtPriceX96(projectId, terminalToken, projectToken));
        int24 tickUpper = TickMath.getTickAtSqrtRatio(_getIssuanceRateSqrtPriceX96(projectId, terminalToken, projectToken));
        
        // Ensure tickLower < tickUpper (cash out rate should be lower than issuance rate)
        if (tickLower >= tickUpper) {
            // If rates are inverted, use a small range around the current price
            uint160 currentSqrtPrice = _getSqrtPriceX96ForCurrentJuiceboxPrice(projectId, terminalToken, projectToken);
            int24 currentTick = TickMath.getTickAtSqrtRatio(currentSqrtPrice);
            tickLower = currentTick - 100; // 1% below
            tickUpper = currentTick + 100; // 1% above
        }
        
        // Get the actual balances after cash out
        uint256 projectTokenAmount = IERC20(projectToken).balanceOf(address(this));
        uint256 terminalTokenAmount = 0;
        
        if (terminalToken != address(0)) {
            // For ERC20 terminal tokens, get the balance after cash out
            terminalTokenAmount = IERC20(terminalToken).balanceOf(address(this));
            
            // Approve NonfungiblePositionManager to spend terminal tokens
            if (terminalTokenAmount > 0) {
                // Reset approval first to avoid SafeERC20 issues with tokens that don't allow changing non-zero approvals
                IERC20(terminalToken).safeApprove(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER, 0);
                IERC20(terminalToken).safeApprove(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER, terminalTokenAmount);
            }
        } else {
            // For native ETH, get the contract's ETH balance after cash out
            terminalTokenAmount = address(this).balance;
        }
        
        // Approve NonfungiblePositionManager to spend project tokens
        if (projectTokenAmount > 0) {
            // Reset approval first to avoid SafeERC20 issues
            IERC20(projectToken).safeApprove(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER, 0);
            IERC20(projectToken).safeApprove(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER, projectTokenAmount);
        }
        
        // Calculate amounts based on token ordering (Uniswap requires token0 < token1)
        uint256 amount0 = projectToken == token0 ? projectTokenAmount : terminalTokenAmount;
        uint256 amount1 = projectToken == token1 ? projectTokenAmount : terminalTokenAmount;
        
        // Create liquidity position with tick bounds set to issuance rate (ceiling) and cash out rate (floor)
        // For native ETH, the mint function is payable and will handle wrapping to WETH
        (uint256 tokenId,,,) = INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER).mint{value: terminalToken == address(0) ? terminalTokenAmount : 0}(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: UNISWAP_V3_POOL_FEE,
                tickLower: tickLower, // Price floor: cash out rate
                tickUpper: tickUpper, // Price ceiling: issuance rate
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        tokenIdForPool[pool] = tokenId;
        
        // Clear accumulated balances after successful LP creation
        accumulatedProjectTokens[projectId] = 0;
    }

    /// @notice Burn received project tokens in deployment stage
    /// @dev In deployment stage, newly received project tokens are burned to maintain token economics
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
    /// @dev Initializes pool with price based on latest positive weight from ruleset history
    /// @param projectId The Juicebox project ID
    /// @param projectToken Project token address
    /// @param terminalToken Terminal token address
    function _createAndInitializeUniswapV3Pool(uint256 projectId, address projectToken, address terminalToken) internal {
        (address token0, address token1) = _sortTokens(projectToken, terminalToken);
        uint160 sqrtPriceX96 = _getSqrtPriceX96ForLatestPositiveWeight(projectId, projectToken, terminalToken);
        
        // Create pool if it doesn't exist, or initialize if it exists but isn't initialized
        address newPool = INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER).createAndInitializePoolIfNecessary(
            token0,
            token1,
            UNISWAP_V3_POOL_FEE,
            sqrtPriceX96
        );
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
    /// @dev Splits fees between the fee project and the original project based on FEE_PERCENT
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
                
                // Pay fee project and receive fee project tokens in return
                uint256 beneficiaryTokenCount = IJBMultiTerminal(feeTerminal).pay(
                    FEE_PROJECT_ID,
                    token,
                    feeAmount,
                    address(this), // beneficiary
                    0, // minReturnedTokens
                    "LP Fee", // memo
                    "" // metadata
                );
                
                // Track the fee tokens returned for this project (claimable by revnet operator)
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
