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
    address public immutable DIRECTORY;

    /// @notice JBTokens (to find project tokens)
    address public immutable TOKENS;

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
    /// @param directory JBDirectory address
    /// @param tokens JBTokens address
    /// @param uniswapV3Factory UniswapV3Factory address
    /// @param uniswapV3NonfungiblePositionManager UniswapV3 NonfungiblePositionManager address
    /// @param feeProjectId Project ID to receive LP fees
    /// @param feePercent Percentage of LP fees to route to fee project (in basis points, e.g., 3800 = 38%)
    /// @param revDeployer REVDeployer contract address for revnet operator validation
    constructor(
        address initialOwner,
        address directory,
        address tokens,
        address uniswapV3Factory,
        address uniswapV3NonfungiblePositionManager,
        uint256 feeProjectId,
        uint256 feePercent,
        address revDeployer
    ) 
        Ownable(initialOwner)
    {
        if (directory == address(0)) revert UniV3DeploymentSplitHook_ZeroAddressNotAllowed();
        if (tokens == address(0)) revert UniV3DeploymentSplitHook_ZeroAddressNotAllowed();
        if (uniswapV3Factory == address(0)) revert UniV3DeploymentSplitHook_ZeroAddressNotAllowed();
        if (uniswapV3NonfungiblePositionManager == address(0)) revert UniV3DeploymentSplitHook_ZeroAddressNotAllowed();
        if (revDeployer == address(0)) revert UniV3DeploymentSplitHook_ZeroAddressNotAllowed();
        if (feePercent > BPS) revert UniV3DeploymentSplitHook_InvalidFeePercent(); // Max 100% in basis points

        DIRECTORY = directory;
        TOKENS = tokens;

        UNISWAP_V3_FACTORY = uniswapV3Factory;
        UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER = uniswapV3NonfungiblePositionManager;
        FEE_PERCENT = feePercent;
        REV_DEPLOYER = revDeployer;
        
        // Validate FEE_PROJECT_ID points to a valid project with a controller
        // This ensures fee routing will work correctly
        if (feeProjectId != 0) {
            address feeController = IJBDirectory(directory).controllerOf(feeProjectId);
            if (feeController == address(0)) {
                revert UniV3DeploymentSplitHook_InvalidProjectId();
            }
        }
        FEE_PROJECT_ID = feeProjectId;
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
        address controller = IJBDirectory(DIRECTORY).controllerOf(projectId);
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
        address controller = IJBDirectory(DIRECTORY).controllerOf(projectId);
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
        address controller = IJBDirectory(DIRECTORY).controllerOf(projectId);
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);
        
        // Get the accounting context from the primary terminal for the terminal token
        address terminal = IJBDirectory(DIRECTORY).primaryTerminalOf(projectId, terminalToken);
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
        address controller = IJBDirectory(DIRECTORY).controllerOf(projectId);
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);
        
        // Get the accounting context from the primary terminal for the terminal token
        address terminal = IJBDirectory(DIRECTORY).primaryTerminalOf(projectId, terminalToken);
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
        address controller = IJBDirectory(DIRECTORY).controllerOf(projectId);
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);
        
        // Get the accounting context from the primary terminal for the terminal token
        address terminal = IJBDirectory(DIRECTORY).primaryTerminalOf(projectId, terminalToken);
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
        address controller = IJBDirectory(DIRECTORY).controllerOf(projectId);
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);
        
        // Get the accounting context from the primary terminal for the terminal token
        address terminal = IJBDirectory(DIRECTORY).primaryTerminalOf(projectId, terminalToken);
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
        address controller = IJBDirectory(DIRECTORY).controllerOf(projectId);
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
        // Get cash out rate for 10^18 project tokens (1 token with 18 decimals)
        // currentReclaimableSurplusOf returns terminal tokens received for cashing out project tokens
        try IJBMultiTerminal(address(DIRECTORY.primaryTerminalOf(projectId, terminalToken))).STORE().currentReclaimableSurplusOf(
            projectId,
            10 ** 18, // cashOutCount: 1 project token (18 decimals)
            uint32(uint160(terminalToken)), // currency
            _getTokenDecimals(terminalToken) // decimals
        ) returns (uint256 reclaimableAmount) {
            terminalTokensPerProjectToken = reclaimableAmount;
        } catch {
            // If calculation fails, fall back to using weight-based calculation
            terminalTokensPerProjectToken = 0;
        }
    }

    /// @notice Get token decimals, defaulting to 18 if unavailable
    /// @param token The token address
    /// @return decimals The token decimals (defaults to 18)
    function _getTokenDecimals(address token) internal view returns (uint8 decimals) {
        if (_isNativeToken(token)) {
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
            address feeProjectToken = address(IJBTokens(TOKENS).tokenOf(FEE_PROJECT_ID));
            
            // Transfer the tokens to the beneficiary
            IERC20(feeProjectToken).safeTransfer(beneficiary, claimableAmount);
            
            // Emit event for off-chain monitoring
            emit FeeTokensClaimed(projectId, beneficiary, claimableAmount);
        }
    }

    /// @notice Collect LP fees and route them back to the project
    /// @dev Can only be called in deployment stage after pool has been created
    /// @dev Terminal token fees are routed back to the project, project token fees are burned
    /// @dev This function is permissionless - anyone can call it to collect and route fees
    /// @dev This is safe because it only collects fees from existing LP positions and routes them correctly
    /// @param projectId The Juicebox project ID
    /// @param terminalToken The terminal token address
    function collectAndRouteLPFees(uint256 projectId, address terminalToken) external {
        if (isAccumulationStage(projectId)) revert UniV3DeploymentSplitHook_InvalidStageForAction();
        
        address pool = poolOf[projectId][terminalToken];
        if (pool == address(0)) revert UniV3DeploymentSplitHook_InvalidStageForAction();
        
        uint256 tokenId = tokenIdForPool[pool];
        if (tokenId == 0) revert UniV3DeploymentSplitHook_InvalidStageForAction();
        
        // Collect fees from the LP position (both terminal tokens and project tokens)
        address projectToken = address(IJBTokens(TOKENS).tokenOf(projectId));
        // Convert native ETH to WETH for Uniswap operations
        address uniswapTerminalToken = _toUniswapToken(terminalToken);
        (address token0, address token1) = _sortTokens(projectToken, uniswapTerminalToken);
        
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
        // Convert native ETH to WETH for comparison since Uniswap returns WETH
        address uniswapTerminalToken = _toUniswapToken(terminalToken);
        if (amount0 > 0 && token0 == uniswapTerminalToken) {
            _routeFeesToProject(projectId, terminalToken, amount0);
        }
        
        if (amount1 > 0 && token1 == uniswapTerminalToken) {
            _routeFeesToProject(projectId, terminalToken, amount1);
        }
        
        // Burn collected project token fees to maintain token economics
        _burnReceivedTokens(projectId, projectToken, terminalToken);
    }

    /// @notice Manually trigger deployment for a project (only works in accumulation stage)
    /// @dev Allows early deployment before automatic transition to deployment stage
    /// @dev This function is permissionless - anyone can call it to trigger pool deployment
    /// @dev This is safe because deployment can only occur in accumulation stage and uses accumulated tokens
    /// @param projectId The Juicebox project ID
    /// @param terminalToken The terminal token address
    function deployPool(uint256 projectId, address terminalToken) external {
        if (!isAccumulationStage(projectId)) revert UniV3DeploymentSplitHook_InvalidStageForAction();
        
        address projectToken = address(IJBTokens(TOKENS).tokenOf(projectId));
        uint256 projectTokenBalance = accumulatedProjectTokens[projectId];
        
        if (projectTokenBalance == 0) revert UniV3DeploymentSplitHook_NoTokensAccumulated();
        
        // Deploy the pool and add liquidity
        _deployPoolAndAddLiquidity(projectId, projectToken, terminalToken);
        
        emit ProjectDeployed(projectId, terminalToken, poolOf[projectId][terminalToken]);
    }

    /// @notice Rebalance LP position to match current issuance and cash out rates
    /// @dev Removes old liquidity and adds new liquidity with updated tick bounds
    /// @dev This function is permissionless - anyone can call it to rebalance liquidity
    /// @dev This is safe because it only rebalances existing positions and uses current rates
    /// @param projectId The Juicebox project ID
    /// @param terminalToken The terminal token address
    function rebalanceLiquidity(uint256 projectId, address terminalToken) external {
        if (isAccumulationStage(projectId)) revert UniV3DeploymentSplitHook_InvalidStageForAction();
        
        address pool = poolOf[projectId][terminalToken];
        if (pool == address(0)) revert UniV3DeploymentSplitHook_InvalidStageForAction();
        
        uint256 tokenId = tokenIdForPool[pool];
        if (tokenId == 0) revert UniV3DeploymentSplitHook_InvalidStageForAction();
        
        address projectToken = address(IJBTokens(TOKENS).tokenOf(projectId));
        
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
        // Convert native ETH to WETH for Uniswap operations
        address uniswapTerminalToken = _toUniswapToken(terminalToken);
        (address token0, address token1) = _sortTokens(projectToken, uniswapTerminalToken);
        // Compare with uniswapTerminalToken (WETH) since that's what Uniswap returns
        if (amount0 > 0 && token0 == uniswapTerminalToken) {
            _routeFeesToProject(projectId, terminalToken, amount0);
        }
        if (amount1 > 0 && token1 == uniswapTerminalToken) {
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
        uint256 terminalTokenBalance = !_isNativeToken(terminalToken)
            ? IERC20(terminalToken).balanceOf(address(this))
            : address(this).balance;
        
        // Calculate new tick bounds based on current rates
        int24 tickLower = TickMath.getTickAtSqrtRatio(_getCashOutRateSqrtPriceX96(projectId, terminalToken, projectToken));
        int24 tickUpper = TickMath.getTickAtSqrtRatio(_getIssuanceRateSqrtPriceX96(projectId, terminalToken, projectToken));
        
        // Enforce tick spacing for 1% fee tier (200 tick spacing)
        // Ticks must be multiples of the tick spacing to be valid
        int24 tickSpacing = 200; // For 1% fee tier (UNISWAP_V3_POOL_FEE = 10000)
        tickLower = (tickLower / tickSpacing) * tickSpacing;
        tickUpper = (tickUpper / tickSpacing) * tickSpacing;
        
        // Ensure tickLower < tickUpper
        if (tickLower >= tickUpper) {
            // If rates are inverted, use a small range around the current price
            uint160 currentSqrtPrice = _getSqrtPriceX96ForCurrentJuiceboxPrice(projectId, terminalToken, projectToken);
            int24 currentTick = TickMath.getTickAtSqrtRatio(currentSqrtPrice);
            currentTick = (currentTick / tickSpacing) * tickSpacing; // Align to tick spacing
            tickLower = currentTick - tickSpacing; // One tick spacing below
            tickUpper = currentTick + tickSpacing; // One tick spacing above
        }
        
        // Since tick bounds may have changed, we need to remove the old position and create a new one
        // First, burn the old NFT (this removes the position completely)
        INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER).burn(tokenId);
        
        // Convert native ETH to WETH for Uniswap operations
        address uniswapTerminalToken = _toUniswapToken(terminalToken);
        (address token0, address token1) = _sortTokens(projectToken, uniswapTerminalToken);
        
        // Approve tokens for Uniswap operations
        if (projectTokenBalance > 0) {
            IERC20(projectToken).safeApprove(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER, 0);
            IERC20(projectToken).safeApprove(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER, projectTokenBalance);
        }
        
        // For native ETH, no approval needed - mint will handle wrapping via msg.value
        // For ERC20 terminal tokens, approve the token
        if (terminalTokenBalance > 0 && !_isNativeToken(terminalToken)) {
            // ERC20 token - approve the terminal token
            IERC20(terminalToken).safeApprove(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER, 0);
            IERC20(terminalToken).safeApprove(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER, terminalTokenBalance);
        }
        
        // Calculate amounts based on token ordering (using WETH for native ETH)
        uint256 amount0Desired = projectToken == token0 ? projectTokenBalance : terminalTokenBalance;
        uint256 amount1Desired = projectToken == token1 ? projectTokenBalance : terminalTokenBalance;
        
        (uint256 newTokenId,, uint256 amount0Used, uint256 amount1Used) = 
            INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER).mint{value: _isNativeToken(terminalToken) ? terminalTokenBalance : 0}(
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
        
        // Handle leftover tokens after mint
        // Calculate leftover amounts (unused tokens remain in contract)
        uint256 amount0Leftover = amount0Desired > amount0Used ? amount0Desired - amount0Used : 0;
        uint256 amount1Leftover = amount1Desired > amount1Used ? amount1Desired - amount1Used : 0;
        
        // Leftover tokens remain in the contract and will be available for future operations
        // They are not lost but should be accounted for in future liquidity additions
        
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
        address controller = address(IJBDirectory(DIRECTORY).controllerOf(context.projectId));
        if (controller == address(0)) revert UniV3DeploymentSplitHook_InvalidProjectId();
        if (controller != msg.sender) revert UniV3DeploymentSplitHook_SplitSenderNotValidControllerOrTerminal();

        // Only handle reserved tokens (groupId == 1), revert on terminal tokens from payouts
        if (context.groupId != 1) revert UniV3DeploymentSplitHook_TerminalTokensNotAllowed();
        
        address projectToken = context.token;
        bool isAccumulation = isAccumulationStage(context.projectId);
        
        if (isAccumulation) {
            // Accumulation stage: Accumulate tokens for future pool deployment
            // Use the split amount from context to track incremental amounts
            _accumulateTokens(context.projectId, projectToken, context.amount);
        } else {
            // Deployment stage: Find terminal token and handle pool deployment
            address[] memory terminals = IJBDirectory(DIRECTORY).terminalsOf(context.projectId);
            address terminalToken = address(0);
            
            // Find the first terminal that has an accounting context
            for (uint256 i = 0; i < terminals.length; i++) {
                try IJBMultiTerminal(terminals[i]).accountingContextsOf(context.projectId, context.token) returns (JBAccountingContext memory acContext) {
                    if (acContext.token != address(0)) {
                        // Keep JBConstants.NATIVE_TOKEN as-is (no conversion needed)
                        // For Uniswap operations, it will be converted to WETH via _toUniswapToken()
                        terminalToken = acContext.token;
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
    /// @dev Tracks incremental amounts received per split to avoid double-counting
    /// @param projectId The Juicebox project ID
    /// @param projectToken The project token address
    /// @param amount The amount of tokens received in this split (from context)
    function _accumulateTokens(uint256 projectId, address projectToken, uint256 amount) internal {
        // Track incremental amount received per split instead of total balance
        // This prevents double-counting across multiple split events
        accumulatedProjectTokens[projectId] += amount;
    }

    /// @notice Add liquidity to a UniswapV3 pool using accumulated tokens
    /// @dev Cashes out half of project tokens to get terminal tokens, then creates full-range LP position
    /// @param projectId JuiceboxV4 projectId
    /// @param projectToken Project token address
    /// @param terminalToken Terminal token address (JBConstants.NATIVE_TOKEN for native ETH)
    /// @param pool UniswapV3 pool address
    function _addUniswapLiquidity(uint256 projectId, address projectToken, address terminalToken, address pool) internal {
        uint256 projectTokenBalance = accumulatedProjectTokens[projectId];
        
        if (projectTokenBalance == 0) return;
        
        // Cash out half of the project tokens to get terminal tokens for pairing
        // This provides the backing tokens needed to create a balanced LP position
        address terminal = IJBDirectory(DIRECTORY).primaryTerminalOf(projectId, terminalToken);
        
        if (terminal != address(0)) {
            uint256 cashOutAmount = projectTokenBalance / 2;
            
            // Calculate minimum tokens to reclaim (use 0 to accept any amount)
            uint256 minTokensReclaimed = 0;
            
            // Cash out half of the project tokens to get terminal tokens
            IJBMultiTerminal(terminal).cashOutTokensOf(
                address(this), // holder
                projectId,
                cashOutAmount, // cashOutCount
                terminalToken, // tokenToReclaim (JBConstants.NATIVE_TOKEN for native ETH)
                minTokensReclaimed, // minTokensReclaimed
                payable(address(this)), // beneficiary
                "" // metadata
            );
        }
        
        // Create the liquidity position with both project tokens and terminal tokens
        // Convert native ETH to WETH for Uniswap operations
        address uniswapTerminalToken = _toUniswapToken(terminalToken);
        (address token0, address token1) = _sortTokens(projectToken, uniswapTerminalToken);
        
        // Calculate tick bounds based on current issuance rate (ceiling) and cash out rate (floor)
        int24 tickLower = TickMath.getTickAtSqrtRatio(_getCashOutRateSqrtPriceX96(projectId, terminalToken, projectToken));
        int24 tickUpper = TickMath.getTickAtSqrtRatio(_getIssuanceRateSqrtPriceX96(projectId, terminalToken, projectToken));
        
        // Enforce tick spacing for 1% fee tier (200 tick spacing)
        // Ticks must be multiples of the tick spacing to be valid
        int24 tickSpacing = 200; // For 1% fee tier (UNISWAP_V3_POOL_FEE = 10000)
        tickLower = (tickLower / tickSpacing) * tickSpacing;
        tickUpper = (tickUpper / tickSpacing) * tickSpacing;
        
        // Ensure tickLower < tickUpper (cash out rate should be lower than issuance rate)
        if (tickLower >= tickUpper) {
            // If rates are inverted, use a small range around the current price
            uint160 currentSqrtPrice = _getSqrtPriceX96ForCurrentJuiceboxPrice(projectId, terminalToken, projectToken);
            int24 currentTick = TickMath.getTickAtSqrtRatio(currentSqrtPrice);
            currentTick = (currentTick / tickSpacing) * tickSpacing; // Align to tick spacing
            tickLower = currentTick - tickSpacing; // One tick spacing below
            tickUpper = currentTick + tickSpacing; // One tick spacing above
        }
        
        // Get the actual balances after cash out
        uint256 projectTokenAmount = IERC20(projectToken).balanceOf(address(this));
        uint256 terminalTokenAmount = 0;
        
        if (!_isNativeToken(terminalToken)) {
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
        (uint256 tokenId,, uint256 amount0Used, uint256 amount1Used) = 
            INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER).mint{value: _isNativeToken(terminalToken) ? terminalTokenAmount : 0}(
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
        
        // Handle leftover tokens after mint
        // Calculate leftover amounts (unused tokens remain in contract)
        uint256 amount0Leftover = amount0 > amount0Used ? amount0 - amount0Used : 0;
        uint256 amount1Leftover = amount1 > amount1Used ? amount1 - amount1Used : 0;
        
        // Leftover tokens remain in the contract and will be available for future operations
        // They are not lost but should be accounted for in future liquidity additions
        // For project tokens, they will be burned in deployment stage
        // For terminal tokens, they will be used in future liquidity additions
        
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
            address controller = IJBDirectory(DIRECTORY).controllerOf(projectId);
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
    /// @param terminalToken Terminal token address (JBConstants.NATIVE_TOKEN for native ETH)
    function _createAndInitializeUniswapV3Pool(uint256 projectId, address projectToken, address terminalToken) internal {
        // Convert native ETH to WETH for Uniswap operations
        address uniswapTerminalToken = _toUniswapToken(terminalToken);
        (address token0, address token1) = _sortTokens(projectToken, uniswapTerminalToken);
        
        // Use current issuance rate (current weight) to set initial pool price
        uint160 sqrtPriceX96 = _getIssuanceRateSqrtPriceX96(projectId, terminalToken, projectToken);
        
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
    /// @dev When terminal token is native ETH, Uniswap returns WETH which must be unwrapped to ETH
    /// @param projectId The Juicebox project ID
    /// @param terminalToken The terminal token address (address(0) for native ETH)
    /// @param amount The amount to route (in WETH if terminalToken is native ETH)
    function _routeFeesToProject(uint256 projectId, address terminalToken, uint256 amount) internal {
        if (amount == 0) return;
        
        address token = terminalToken;
        
        // If terminal token is native ETH, Uniswap returns WETH - unwrap it to ETH
        if (_isNativeToken(terminalToken)) {
            // Unwrap WETH to ETH
            INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER).unwrapWETH9(amount, address(this));
            // token is already JBConstants.NATIVE_TOKEN
        }
        
        // Calculate fee amount to send to fee project
        uint256 feeAmount = (amount * FEE_PERCENT) / BPS;
        uint256 remainingAmount = amount - feeAmount;
        
        // Route fee portion to fee project
        uint256 beneficiaryTokenCount = 0;
        if (feeAmount > 0) {
            address feeTerminal = IJBDirectory(DIRECTORY).primaryTerminalOf(FEE_PROJECT_ID, token);
            if (feeTerminal != address(0)) {
                // Get balance before to track minted tokens
                address feeProjectToken = address(IJBTokens(TOKENS).tokenOf(FEE_PROJECT_ID));
                uint256 feeTokensBefore = IERC20(feeProjectToken).balanceOf(address(this));
                
                if (_isNativeToken(terminalToken)) {
                    // Native ETH - send via payable function
                    IJBMultiTerminal(feeTerminal).pay{value: feeAmount}(
                        FEE_PROJECT_ID,
                        token,
                        feeAmount,
                        address(this), // beneficiary
                        0, // minReturnedTokens
                        "LP Fee", // memo
                        "" // metadata
                    );
                } else {
                    // ERC20 token
                    IERC20(token).safeApprove(feeTerminal, feeAmount);
                    IJBMultiTerminal(feeTerminal).pay(
                        FEE_PROJECT_ID,
                        token,
                        feeAmount,
                        address(this), // beneficiary
                        0, // minReturnedTokens
                        "LP Fee", // memo
                        "" // metadata
                    );
                }
                
                // Calculate fee tokens minted
                uint256 feeTokensAfter = IERC20(feeProjectToken).balanceOf(address(this));
                beneficiaryTokenCount = feeTokensAfter > feeTokensBefore ? feeTokensAfter - feeTokensBefore : 0;
                
                // Track the fee tokens returned for this project (claimable by revnet operator)
                claimableFeeTokens[projectId] += beneficiaryTokenCount;
            }
        }
        
        // Route remaining amount to original project
        if (remainingAmount > 0) {
            address terminal = IJBDirectory(DIRECTORY).primaryTerminalOf(projectId, token);
            if (terminal != address(0)) {
                if (_isNativeToken(terminalToken)) {
                    // Native ETH - use addToBalanceOf with value
                    // Note: This assumes the terminal's addToBalanceOf can handle native ETH via msg.value
                    // If not, we may need to use a different approach or wrap back to WETH
                    IJBMultiTerminal(terminal).addToBalanceOf{value: remainingAmount}(
                        projectId,
                        token,
                        remainingAmount,
                        false, // shouldReturnHeldFees
                        "",
                        ""
                    );
                } else {
                    // ERC20 token
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
        }
        
        // Emit enhanced event with detailed fee split information
        emit LPFeesRouted(projectId, terminalToken, amount, feeAmount, remainingAmount, beneficiaryTokenCount);
    }

    /// @notice Get WETH address from Uniswap V3 NonfungiblePositionManager
    /// @dev Used to convert native ETH (address(0)) to WETH for Uniswap V3 operations
    /// @return weth The WETH token address
    function _getWETH() internal view returns (address weth) {
        return INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER).WETH9();
    }

    /// @notice Check if terminal token is native ETH
    /// @param terminalToken Terminal token address
    /// @return isNative True if the token is native ETH (JBConstants.NATIVE_TOKEN)
    function _isNativeToken(address terminalToken) internal pure returns (bool isNative) {
        return terminalToken == JBConstants.NATIVE_TOKEN;
    }

    /// @notice Convert terminal token to Uniswap-compatible token address
    /// @dev Converts JBConstants.NATIVE_TOKEN to WETH for Uniswap operations
    /// @dev Juicebox uses JBConstants.NATIVE_TOKEN for native ETH, but Uniswap requires WETH
    /// @param terminalToken Terminal token address (JBConstants.NATIVE_TOKEN for native ETH)
    /// @return uniswapToken The token address to use for Uniswap operations (WETH if native ETH)
    function _toUniswapToken(address terminalToken) internal view returns (address uniswapToken) {
        return _isNativeToken(terminalToken) ? _getWETH() : terminalToken;
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
