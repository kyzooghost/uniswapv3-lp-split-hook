// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IJBController} from "@bananapus/core/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core/interfaces/IJBMultiTerminal.sol";
import {IJBPermissions} from "@bananapus/core/interfaces/IJBPermissions.sol";
import {JBPermissioned} from "@bananapus/core/abstract/JBPermissioned.sol";
import {IJBSplitHook} from "@bananapus/core/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core/interfaces/IJBTerminalStore.sol";
import {IJBTokens} from "@bananapus/core/interfaces/IJBTokens.sol";
import {JBAccountingContext} from "@bananapus/core/structs/JBAccountingContext.sol";
import {JBRuleset} from "@bananapus/core/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core/structs/JBRulesetMetadata.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core/libraries/JBRulesetMetadataResolver.sol";
import {JBSplitHookContext} from "@bananapus/core/structs/JBSplitHookContext.sol";
import {JBConstants} from "@bananapus/core/libraries/JBConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {mulDiv, sqrt} from "@prb/math/src/Common.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery-flattened/INonfungiblePositionManager.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core-patched/TickMath.sol";
import {JBPermissionIds} from "@bananapus/permission-ids/JBPermissionIds.sol";
import {IUniV3DeploymentSplitHook} from "./interfaces/IUniV3DeploymentSplitHook.sol";
import {IREVDeployer} from "./interfaces/IREVDeployer.sol";

/// @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVS MEAM
/**
 * @title UniV3DeploymentSplitHook
 * @notice JuiceboxV4 IJBSplitHook contract that manages a two-stage deployment process:
 *
 * Before pool deployment:
 * - Accumulate project tokens received via reserved token splits
 * - Pool deployment is triggered manually by the project owner or authorized operator
 *
 * After pool deployment:
 * - Burn any newly received project tokens
 * - Route LP fees back to the project (with configurable fee split)
 * - Support liquidity rebalancing as rates change
 *
 * @dev This contract is the creator of the projectToken/terminalToken UniswapV3 pool.
 * @dev Any tokens held by the contract can be added to a UniswapV3 LP position.
 * @dev For any given UniswapV3 pool, the contract will control a single LP position.
 * @dev Pool deployment requires SET_BUYBACK_POOL permission from the project owner.
 */
contract UniV3DeploymentSplitHook is IUniV3DeploymentSplitHook, IJBSplitHook, JBPermissioned, Ownable {
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

    /// @dev Thrown when terminalToken is not a valid terminal token for the projectId
    error UniV3DeploymentSplitHook_InvalidTerminalToken();

    /// @dev Thrown when pool has already been deployed for this project/token pair
    error UniV3DeploymentSplitHook_PoolAlreadyDeployed();

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice Basis points constant (10000 = 100%)
    uint256 public constant BPS = 10000;

    /// @notice Uniswap V3 pool fee (10000 = 1% fee tier)
    uint24 public constant UNISWAP_V3_POOL_FEE = 10000;

    /// @notice Tick spacing for 1% fee tier (200 ticks)
    int24 public constant TICK_SPACING = 200;

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

    /// @notice ProjectID => whether any pool has been deployed for this project
    /// @dev Set to true when deployPool succeeds; used by processSplitWith to decide accumulate vs burn
    mapping(uint256 projectId => bool deployed) public projectDeployed;

    /// @notice ProjectID => Fee tokens claimable by that project
    mapping(uint256 projectId => uint256 claimableFeeTokens) public claimableFeeTokens;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param initialOwner Initial owner/admin of the contract
    /// @param directory JBDirectory address
    /// @param permissions JBPermissions address
    /// @param tokens JBTokens address
    /// @param uniswapV3Factory UniswapV3Factory address
    /// @param uniswapV3NonfungiblePositionManager UniswapV3 NonfungiblePositionManager address
    /// @param feeProjectId Project ID to receive LP fees
    /// @param feePercent Percentage of LP fees to route to fee project (in basis points, e.g., 3800 = 38%)
    /// @param revDeployer REVDeployer contract address for revnet operator validation
    constructor(
        address initialOwner,
        address directory,
        IJBPermissions permissions,
        address tokens,
        address uniswapV3Factory,
        address uniswapV3NonfungiblePositionManager,
        uint256 feeProjectId,
        uint256 feePercent,
        address revDeployer
    )
        JBPermissioned(permissions)
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
            address feeController = address(IJBDirectory(directory).controllerOf(feeProjectId));
            if (feeController == address(0)) {
                revert UniV3DeploymentSplitHook_InvalidProjectId();
            }
        }
        FEE_PROJECT_ID = feeProjectId;
    }

    /// @notice Accept ETH transfers (needed for WETH unwrap and cashOut with native ETH).
    receive() external payable {}

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

    /// @notice Check if a pool has been deployed for a project/terminal token pair
    /// @param projectId The Juicebox project ID
    /// @param terminalToken The terminal token address
    /// @return deployed True if pool exists
    function isPoolDeployed(uint256 projectId, address terminalToken) public view returns (bool deployed) {
        return poolOf[projectId][terminalToken] != address(0);
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

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
        address controller = address(IJBDirectory(DIRECTORY).controllerOf(projectId));
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);
        
        // Get the accounting context from the primary terminal for the terminal token
        address terminal = address(IJBDirectory(DIRECTORY).primaryTerminalOf({projectId: projectId, token: terminalToken}));
        JBAccountingContext memory context = IJBMultiTerminal(terminal).accountingContextForTokenOf({
            projectId: projectId,
            token: terminalToken
        });

        uint32 baseCurrency = ruleset.baseCurrency();

        // Calculate weight ratio: if currencies match, use 10^decimals; otherwise get price conversion
        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBController(controller).PRICES().pricePerUnitOf({
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
        address controller = address(IJBDirectory(DIRECTORY).controllerOf(projectId));
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);

        // Get the accounting context from the primary terminal for the terminal token
        address terminal = address(IJBDirectory(DIRECTORY).primaryTerminalOf({projectId: projectId, token: terminalToken}));
        JBAccountingContext memory context = IJBMultiTerminal(terminal).accountingContextForTokenOf({
            projectId: projectId,
            token: terminalToken
        });
        
        uint32 baseCurrency = ruleset.baseCurrency();
        
        // Calculate weight ratio: if currencies match, use 10^decimals; otherwise get price conversion
        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBController(controller).PRICES().pricePerUnitOf({
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
        address controller = address(IJBDirectory(DIRECTORY).controllerOf(projectId));
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);

        // Get the accounting context from the primary terminal for the terminal token
        address terminal = address(IJBDirectory(DIRECTORY).primaryTerminalOf({projectId: projectId, token: terminalToken}));
        JBAccountingContext memory context = IJBMultiTerminal(terminal).accountingContextForTokenOf({
            projectId: projectId,
            token: terminalToken
        });
        
        uint32 baseCurrency = ruleset.baseCurrency();
        
        // Calculate weight ratio: if currencies match, use 10^decimals; otherwise get price conversion
        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBController(controller).PRICES().pricePerUnitOf({
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
        address controller = address(IJBDirectory(DIRECTORY).controllerOf(projectId));
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(projectId);

        // Get the accounting context from the primary terminal for the terminal token
        address terminal = address(IJBDirectory(DIRECTORY).primaryTerminalOf({projectId: projectId, token: terminalToken}));
        JBAccountingContext memory context = IJBMultiTerminal(terminal).accountingContextForTokenOf({
            projectId: projectId,
            token: terminalToken
        });
        
        uint32 baseCurrency = ruleset.baseCurrency();
        
        // Calculate weight ratio: if currencies match, use 10^decimals; otherwise get price conversion
        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBController(controller).PRICES().pricePerUnitOf({
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
        address controller = address(IJBDirectory(DIRECTORY).controllerOf(projectId));
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
        // Use the 6-param overload that auto-resolves totalSupply and surplus from terminals
        try IJBMultiTerminal(address(IJBDirectory(DIRECTORY).primaryTerminalOf({projectId: projectId, token: terminalToken}))).STORE().currentReclaimableSurplusOf({
            projectId: projectId,
            cashOutCount: 10 ** 18, // 1 project token (18 decimals)
            terminals: new IJBTerminal[](0), // empty = use all terminals
            accountingContexts: new JBAccountingContext[](0), // empty = use all accounting contexts
            decimals: _getTokenDecimals(terminalToken),
            currency: uint256(uint160(terminalToken))
        }) returns (uint256 reclaimableAmount) {
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
        try IERC20Metadata(token).decimals() returns (uint8 dec) {
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
        if (!IREVDeployer(REV_DEPLOYER).isSplitOperatorOf({projectId: projectId, operator: beneficiary})) {
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
        
        address pool = poolOf[projectId][terminalToken];
        if (pool == address(0)) revert UniV3DeploymentSplitHook_InvalidStageForAction();
        
        uint256 tokenId = tokenIdForPool[pool];
        if (tokenId == 0) revert UniV3DeploymentSplitHook_InvalidStageForAction();
        
        // Collect fees from the LP position (both terminal tokens and project tokens)
        address projectToken = address(IJBTokens(TOKENS).tokenOf(projectId));
        
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
        _routeCollectedFees(projectId, projectToken, terminalToken, amount0, amount1);
        
        // Burn collected project token fees to maintain token economics
        _burnReceivedTokens(projectId, projectToken);
    }

    /// @notice Deploy a UniswapV3 pool for a project using accumulated tokens
    /// @dev Only callable by the project owner or an operator with SET_BUYBACK_POOL permission.
    /// @dev Reverts if pool already exists or no tokens have been accumulated.
    /// @param projectId The Juicebox project ID
    /// @param terminalToken The terminal token address
    /// @param amount0Min Minimum amount of token0 to add (slippage protection, defaults to 0)
    /// @param amount1Min Minimum amount of token1 to add (slippage protection, defaults to 0)
    /// @param minCashOutReturn Minimum terminal tokens from cash-out (slippage protection, 0 = auto 1% tolerance)
    function deployPool(
        uint256 projectId,
        address terminalToken,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 minCashOutReturn
    ) external {
        // Access control: only the project owner or an authorized operator can deploy
        _requirePermissionFrom({
            account: IJBDirectory(DIRECTORY).PROJECTS().ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.SET_BUYBACK_POOL
        });

        // Cannot deploy if pool already exists
        if (poolOf[projectId][terminalToken] != address(0)) revert UniV3DeploymentSplitHook_PoolAlreadyDeployed();

        address projectToken = address(IJBTokens(TOKENS).tokenOf(projectId));
        uint256 projectTokenBalance = accumulatedProjectTokens[projectId];

        if (projectTokenBalance == 0) revert UniV3DeploymentSplitHook_NoTokensAccumulated();

        // Validate that terminalToken is a valid terminal token for this projectId
        address terminal = address(IJBDirectory(DIRECTORY).primaryTerminalOf({projectId: projectId, token: terminalToken}));
        if (terminal == address(0)) revert UniV3DeploymentSplitHook_InvalidTerminalToken();

        // Deploy the pool and add liquidity
        _deployPoolAndAddLiquidity(projectId, projectToken, terminalToken, amount0Min, amount1Min, minCashOutReturn);

        // Mark this project as deployed so processSplitWith knows to burn instead of accumulate
        projectDeployed[projectId] = true;

        emit ProjectDeployed(projectId, terminalToken, poolOf[projectId][terminalToken]);
    }

    /// @notice Rebalance LP position to match current issuance and cash out rates
    /// @dev Removes old liquidity and adds new liquidity with updated tick bounds
    /// @dev This function is permissionless - anyone can call it to rebalance liquidity
    /// @dev This is safe because it only rebalances existing positions and uses current rates
    /// @param projectId The Juicebox project ID
    /// @param terminalToken The terminal token address
    /// @param decreaseAmount0Min Minimum amount of token0 when decreasing liquidity (slippage protection, defaults to 0)
    /// @param decreaseAmount1Min Minimum amount of token1 when decreasing liquidity (slippage protection, defaults to 0)
    /// @param increaseAmount0Min Minimum amount of token0 when adding liquidity (slippage protection, defaults to 0)
    /// @param increaseAmount1Min Minimum amount of token1 when adding liquidity (slippage protection, defaults to 0)
    function rebalanceLiquidity(
        uint256 projectId,
        address terminalToken,
        uint256 decreaseAmount0Min,
        uint256 decreaseAmount1Min,
        uint256 increaseAmount0Min,
        uint256 increaseAmount1Min
    ) external {
        // Validate that terminalToken is a valid terminal token for this projectId
        address terminal = address(IJBDirectory(DIRECTORY).primaryTerminalOf({projectId: projectId, token: terminalToken}));
        if (terminal == address(0)) revert UniV3DeploymentSplitHook_InvalidTerminalToken();

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
        _routeCollectedFees(projectId, projectToken, terminalToken, amount0, amount1);
        
        // Decrease liquidity to zero (removes all liquidity)
        // Use caller-provided min amounts for slippage protection (defaults to 0)
        if (liquidity > 0) {
            INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER).decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidity,
                    amount0Min: decreaseAmount0Min,
                    amount1Min: decreaseAmount1Min,
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
        
        // Calculate and align tick bounds based on current rates
        (int24 tickLower, int24 tickUpper) = _calculateTickBounds(projectId, terminalToken, projectToken);
        
        // Since tick bounds may have changed, we need to remove the old position and create a new one
        // First, burn the old NFT (this removes the position completely)
        INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER).burn(tokenId);
        
        // Convert native ETH to WETH for Uniswap operations
        address uniswapTerminalToken = _toUniswapToken(terminalToken);
        (address token0, address token1) = _sortTokens(projectToken, uniswapTerminalToken);
        
        // Approve tokens for Uniswap operations
        if (projectTokenBalance > 0) {
            IERC20(projectToken).forceApprove(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER, projectTokenBalance);
        }

        // For native ETH, no approval needed - mint will handle wrapping via msg.value
        // For ERC20 terminal tokens, approve the token
        if (terminalTokenBalance > 0 && !_isNativeToken(terminalToken)) {
            // ERC20 token - approve the terminal token
            IERC20(terminalToken).forceApprove(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER, terminalTokenBalance);
        }
        
        // Calculate amounts based on token ordering (using WETH for native ETH)
        uint256 amount0Desired = projectToken == token0 ? projectTokenBalance : terminalTokenBalance;
        uint256 amount1Desired = projectToken == token1 ? projectTokenBalance : terminalTokenBalance;
        
        // Min amounts are already in token0/token1 terms (caller provides them for sorted tokens)
        // No mapping needed - increaseAmount0Min applies to token0, increaseAmount1Min applies to token1
        
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
                    amount0Min: increaseAmount0Min,
                    amount1Min: increaseAmount1Min,
                    recipient: address(this),
                    deadline: block.timestamp
                })
            );
        
        // Handle leftover tokens after mint
        // Calculate leftover amounts (unused tokens remain in contract)
        uint256 amount0Leftover = amount0Desired > amount0Used ? amount0Desired - amount0Used : 0;
        uint256 amount1Leftover = amount1Desired > amount1Used ? amount1Desired - amount1Used : 0;
        
        // Handle leftover tokens: burn project tokens, add terminal tokens to project balance
        _handleLeftoverTokens({
            projectId: projectId,
            projectToken: projectToken,
            terminalToken: terminalToken,
            token0: token0,
            token1: token1,
            amount0Leftover: amount0Leftover,
            amount1Leftover: amount1Leftover
        });
        
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

        // If no pool has been deployed yet, accumulate tokens for future manual deployment
        // If a pool has been deployed, burn newly received tokens to maintain token economics
        if (!projectDeployed[context.projectId]) {
            // Accumulate tokens for future pool deployment via deployPool()
            _accumulateTokens(context.projectId, projectToken, context.amount);
        } else {
            // Pool exists — burn newly received project tokens
            _burnReceivedTokens(context.projectId, projectToken);
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
    /// @dev Computes optimal cash-out fraction based on pool initialization price, then creates LP position
    /// @param projectId JuiceboxV4 projectId
    /// @param projectToken Project token address
    /// @param terminalToken Terminal token address (JBConstants.NATIVE_TOKEN for native ETH)
    /// @param pool UniswapV3 pool address
    /// @param amount0Min Minimum amount of token0 to add (slippage protection)
    /// @param amount1Min Minimum amount of token1 to add (slippage protection)
    /// @param minCashOutReturn Minimum terminal tokens from cash-out (slippage protection, 0 = auto)
    function _addUniswapLiquidity(
        uint256 projectId,
        address projectToken,
        address terminalToken,
        address pool,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 minCashOutReturn
    ) internal {
        uint256 projectTokenBalance = accumulatedProjectTokens[projectId];

        if (projectTokenBalance == 0) return;

        // Calculate tick bounds for the LP position
        (int24 tickLower, int24 tickUpper) = _calculateTickBounds(projectId, terminalToken, projectToken);

        // Compute initial pool price (geometric mean of range)
        uint160 sqrtPriceInit = _computeInitialSqrtPrice(projectId, terminalToken, projectToken);

        // Compute optimal cash-out amount based on LP position geometry
        uint256 cashOutAmount = _computeOptimalCashOutAmount(
            projectId, terminalToken, projectToken,
            projectTokenBalance, sqrtPriceInit, tickLower, tickUpper
        );

        // Cash out the computed fraction to get terminal tokens for pairing
        address terminal = address(IJBDirectory(DIRECTORY).primaryTerminalOf({projectId: projectId, token: terminalToken}));

        // Track terminal token balance before cash out to ensure we only use tokens obtained from this projectId
        uint256 terminalTokenBalanceBefore = !_isNativeToken(terminalToken)
            ? IERC20(terminalToken).balanceOf(address(this))
            : address(this).balance;

        if (terminal != address(0) && cashOutAmount > 0) {
            // Compute slippage floor: use caller-specified minimum, or auto-compute 1% tolerance
            uint256 effectiveMinReturn = minCashOutReturn;
            if (effectiveMinReturn == 0 && cashOutAmount > 0) {
                // Auto-compute: query expected return and apply 1% tolerance
                uint256 cashOutRate = _getCashOutRate(projectId, terminalToken);
                if (cashOutRate > 0) {
                    uint256 expectedReturn = mulDiv(cashOutAmount, cashOutRate, 10 ** 18);
                    effectiveMinReturn = mulDiv(expectedReturn, 99, 100); // 1% tolerance
                }
            }

            // Cash out the optimal fraction of project tokens
            IJBMultiTerminal(terminal).cashOutTokensOf({
                holder: address(this),
                projectId: projectId,
                cashOutCount: cashOutAmount,
                tokenToReclaim: terminalToken,
                minTokensReclaimed: effectiveMinReturn,
                beneficiary: payable(address(this)),
                metadata: ""
            });
        }
        
        // Create the liquidity position with both project tokens and terminal tokens
        // Convert native ETH to WETH for Uniswap operations
        address uniswapTerminalToken = _toUniswapToken(terminalToken);
        (address token0, address token1) = _sortTokens(projectToken, uniswapTerminalToken);

        // Get the actual balances after cash out
        uint256 projectTokenAmount = IERC20(projectToken).balanceOf(address(this));
        
        // Only use the amount obtained from cashing out this projectId's tokens
        // This prevents using terminal tokens from other projects
        uint256 terminalTokenBalanceAfter = !_isNativeToken(terminalToken)
            ? IERC20(terminalToken).balanceOf(address(this))
            : address(this).balance;
        uint256 terminalTokenAmount = terminalTokenBalanceAfter > terminalTokenBalanceBefore
            ? terminalTokenBalanceAfter - terminalTokenBalanceBefore
            : 0;
        
        // Approve NonfungiblePositionManager to spend terminal tokens (ERC20 only)
        if (terminalTokenAmount > 0 && !_isNativeToken(terminalToken)) {
            IERC20(terminalToken).forceApprove(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER, terminalTokenAmount);
        }

        // Approve NonfungiblePositionManager to spend project tokens
        if (projectTokenAmount > 0) {
            IERC20(projectToken).forceApprove(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER, projectTokenAmount);
        }
        
        // Calculate amounts based on token ordering (Uniswap requires token0 < token1)
        uint256 amount0 = projectToken == token0 ? projectTokenAmount : terminalTokenAmount;
        uint256 amount1 = projectToken == token1 ? projectTokenAmount : terminalTokenAmount;
        
        // Min amounts are already in token0/token1 terms (caller provides them for sorted tokens)
        // No mapping needed - amount0Min applies to token0, amount1Min applies to token1
        
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
                    amount0Min: amount0Min,
                    amount1Min: amount1Min,
                    recipient: address(this),
                    deadline: block.timestamp
                })
            );
        tokenIdForPool[pool] = tokenId;
        
        // Handle leftover tokens after mint
        // Calculate leftover amounts (unused tokens remain in contract)
        uint256 amount0Leftover = amount0 > amount0Used ? amount0 - amount0Used : 0;
        uint256 amount1Leftover = amount1 > amount1Used ? amount1 - amount1Used : 0;
        
        // Handle leftover tokens: burn project tokens, add terminal tokens to project balance
        _handleLeftoverTokens({
            projectId: projectId,
            projectToken: projectToken,
            terminalToken: terminalToken,
            token0: token0,
            token1: token1,
            amount0Leftover: amount0Leftover,
            amount1Leftover: amount1Leftover
        });
        
        // Clear accumulated balances after successful LP creation
        accumulatedProjectTokens[projectId] = 0;
    }

    /// @notice Burn received project tokens in deployment stage
    /// @dev In deployment stage, newly received project tokens are burned to maintain token economics
    /// @param projectId The Juicebox project ID
    /// @param projectToken The project token address
    function _burnReceivedTokens(uint256 projectId, address projectToken) internal {
        // Burn any project tokens received using the controller
        uint256 projectTokenBalance = IERC20(projectToken).balanceOf(address(this));
        if (projectTokenBalance > 0) {
            _burnProjectTokens(projectId, projectToken, projectTokenBalance, "Burning additional tokens");
        }
    }

    /// @notice Create and initialize UniswapV3 pool
    /// @dev Initializes pool at geometric mean of [cashOutRate, issuanceRate] in tick space.
    ///      This centers the initial price in the LP range, creating a balanced position.
    ///      Falls back to issuance rate if cash-out rate is 0 or rates are inverted.
    /// @param projectId The Juicebox project ID
    /// @param projectToken Project token address
    /// @param terminalToken Terminal token address (JBConstants.NATIVE_TOKEN for native ETH)
    function _createAndInitializeUniswapV3Pool(uint256 projectId, address projectToken, address terminalToken) internal {
        // Convert native ETH to WETH for Uniswap operations
        address uniswapTerminalToken = _toUniswapToken(terminalToken);
        (address token0, address token1) = _sortTokens(projectToken, uniswapTerminalToken);

        // Compute initial price at geometric mean of [cashOutRate, issuanceRate]
        uint160 sqrtPriceX96 = _computeInitialSqrtPrice(projectId, terminalToken, projectToken);

        // Create pool if it doesn't exist, or initialize if it exists but isn't initialized
        address newPool = INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER).createAndInitializePoolIfNecessary({
            token0: token0,
            token1: token1,
            fee: UNISWAP_V3_POOL_FEE,
            sqrtPriceX96: sqrtPriceX96
        });
        poolOf[projectId][terminalToken] = newPool;
    }

    /// @notice Compute the initial sqrtPriceX96 for pool initialization
    /// @dev Uses geometric mean of cash-out and issuance ticks (center of LP range in log-price space).
    ///      Falls back to issuance rate if cash-out rate is 0 or ticks are inverted.
    /// @param projectId The Juicebox project ID
    /// @param terminalToken Terminal token address
    /// @param projectToken Project token address
    /// @return sqrtPriceX96 The initial sqrt price in X96 format
    function _computeInitialSqrtPrice(
        uint256 projectId,
        address terminalToken,
        address projectToken
    ) internal view returns (uint160 sqrtPriceX96) {
        uint256 cashOutRate = _getCashOutRate(projectId, terminalToken);

        // If no cash-out rate, initialize at issuance rate (single-sided project tokens)
        if (cashOutRate == 0) {
            return _getIssuanceRateSqrtPriceX96(projectId, terminalToken, projectToken);
        }

        uint160 sqrtPriceCashOut = _getCashOutRateSqrtPriceX96(projectId, terminalToken, projectToken);
        uint160 sqrtPriceIssuance = _getIssuanceRateSqrtPriceX96(projectId, terminalToken, projectToken);

        // Get ticks for both boundaries
        int24 tickCashOut = TickMath.getTickAtSqrtRatio(sqrtPriceCashOut);
        int24 tickIssuance = TickMath.getTickAtSqrtRatio(sqrtPriceIssuance);

        // Ensure ticks are ordered (cashOut should be lower for normal range)
        int24 tickLower = tickCashOut < tickIssuance ? tickCashOut : tickIssuance;
        int24 tickUpper = tickCashOut < tickIssuance ? tickIssuance : tickCashOut;

        // If ticks are the same, fall back to issuance rate
        if (tickLower == tickUpper) {
            return sqrtPriceIssuance;
        }

        // Geometric mean in tick space = (tickLower + tickUpper) / 2, aligned to spacing
        int24 tickMid = _alignTickToSpacing((tickLower + tickUpper) / 2, TICK_SPACING);

        // Clamp to valid Uniswap V3 range
        int24 minTick = TickMath.MIN_TICK;
        int24 maxTick = TickMath.MAX_TICK;
        if (tickMid < minTick) tickMid = _alignTickToSpacing(minTick, TICK_SPACING) + TICK_SPACING;
        if (tickMid > maxTick) tickMid = _alignTickToSpacing(maxTick, TICK_SPACING) - TICK_SPACING;

        return TickMath.getSqrtRatioAtTick(tickMid);
    }

    /// @notice Compute optimal cash-out amount based on LP position geometry
    /// @dev For Uniswap V3 concentrated liquidity in range [Pa, Pb] at initial price P:
    ///      The ratio of terminal tokens to project tokens needed is:
    ///        r = sqrtP * sqrtPb * (sqrtP - sqrtPa) / (sqrtPb - sqrtP)
    ///      Given total project tokens T and cash-out rate c (terminal per project):
    ///        cashOutAmount = r * T / (c + r)
    ///      This is typically 15-30% instead of 50%, reducing bonding curve impact.
    /// @param projectId JuiceboxV4 projectId
    /// @param terminalToken Terminal token address
    /// @param projectToken Project token address
    /// @param totalProjectTokens Total project tokens available
    /// @param sqrtPriceInit Initial sqrt price for pool (Q64.96)
    /// @param tickLower Lower tick of LP range
    /// @param tickUpper Upper tick of LP range
    /// @return cashOutAmount The optimal number of project tokens to cash out
    function _computeOptimalCashOutAmount(
        uint256 projectId,
        address terminalToken,
        address projectToken,
        uint256 totalProjectTokens,
        uint160 sqrtPriceInit,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (uint256 cashOutAmount) {
        // Get cash-out rate: terminal tokens per project token (18 decimals)
        uint256 cashOutRate = _getCashOutRate(projectId, terminalToken);

        // If no cash-out rate, no cash-out needed (single-sided project token position)
        if (cashOutRate == 0) return 0;

        // Get sqrtPrice at tick bounds
        uint160 sqrtPriceA = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtPriceB = TickMath.getSqrtRatioAtTick(tickUpper);

        // Determine token ordering: is terminal token token0 or token1?
        address uniswapTerminalToken = _toUniswapToken(terminalToken);
        bool terminalIsToken0 = uniswapTerminalToken < projectToken;

        // Compute the ratio of terminal tokens to project tokens needed for the LP position.
        // For Uniswap V3, given initial price P in range [Pa, Pb]:
        //   If terminal is token0: r = (sqrtP - sqrtPa) * sqrtPb / ((sqrtPb - sqrtP) * sqrtP)
        //   If terminal is token1: r = sqrtP * (sqrtP - sqrtPa) / (sqrtPb - sqrtP)
        // To avoid overflow, we compute numerator and denominator separately with mulDiv.

        uint256 numerator;
        uint256 denominator;

        if (uint160(sqrtPriceInit) <= sqrtPriceA) {
            // Price at or below lower bound: position is 100% terminal tokens (token0 or token1)
            // This means we'd need to cash out ALL project tokens — fall back to 50%
            return totalProjectTokens / 2;
        }
        if (uint160(sqrtPriceInit) >= sqrtPriceB) {
            // Price at or above upper bound: position is 100% project tokens, no cash-out needed
            return 0;
        }

        uint256 diffPriceInit_A = uint256(sqrtPriceInit) - uint256(sqrtPriceA);
        uint256 diffB_PriceInit = uint256(sqrtPriceB) - uint256(sqrtPriceInit);

        if (terminalIsToken0) {
            // terminal is token0: ratio = (sqrtP - sqrtPa) * sqrtPb / ((sqrtPb - sqrtP) * sqrtP)
            // terminal tokens needed per project token in 18-decimal terms
            numerator = mulDiv(diffPriceInit_A, uint256(sqrtPriceB), diffB_PriceInit);
            denominator = uint256(sqrtPriceInit);
            // ratio in 18 decimals: r = numerator * 1e18 / denominator
            // But what we actually need is the terminal-to-project ratio in terms of cash-out rate
        } else {
            // terminal is token1: ratio = sqrtP * (sqrtP - sqrtPa) / (sqrtPb - sqrtP)
            numerator = mulDiv(uint256(sqrtPriceInit), diffPriceInit_A, diffB_PriceInit);
            denominator = 1; // The ratio is already in sqrtPrice units
            // ratio in 18 decimals: r = numerator * 1e18 / (denominator * 1)
        }

        // The ratio r tells us: for 1 unit of project tokens in the position, we need r units of terminal tokens.
        // We have T total project tokens. After cashing out X at rate c, we have:
        //   projectTokensForLP = T - X
        //   terminalTokensForLP = X * c
        // The LP needs: terminalTokensForLP / projectTokensForLP = r (in sqrtPrice ratio)
        // So: X * c / (T - X) = ratio, solving: X = ratio * T / (c + ratio)
        //
        // To keep everything in consistent units, express ratio as terminal per project (18 decimals):
        uint256 ratioE18;
        if (terminalIsToken0) {
            // ratio = numerator / denominator (in sqrtPrice units, need to convert to token amounts)
            // For token0/token1: price = token1/token0, so terminal(token0) per project(token1) = 1/price
            // r (terminal per project) = numerator * 1e18 / denominator
            ratioE18 = mulDiv(numerator, 10 ** 18, denominator);
        } else {
            // For token1 as terminal: terminal(token1) per project(token0) = price
            // r = numerator * 1e18 (numerator already encodes the ratio)
            ratioE18 = mulDiv(numerator, 10 ** 18, 1);
        }

        // Guard against zero ratio (would mean no terminal tokens needed)
        if (ratioE18 == 0) return 0;

        // cashOutAmount = ratioE18 * T / (cashOutRate + ratioE18)
        // Both ratioE18 and cashOutRate are in 18-decimal "terminal tokens per project token" units
        uint256 denom = cashOutRate + ratioE18;
        if (denom == 0) return 0;

        cashOutAmount = mulDiv(totalProjectTokens, ratioE18, denom);

        // Safety cap: never cash out more than 50% (shouldn't happen with geometric mean, but defensive)
        uint256 maxCashOut = totalProjectTokens / 2;
        if (cashOutAmount > maxCashOut) cashOutAmount = maxCashOut;
    }

    /// @notice Deploy pool and add liquidity using accumulated tokens
    /// @param projectId The Juicebox project ID
    /// @param projectToken The project token address
    /// @param terminalToken The terminal token address
    /// @param amount0Min Minimum amount of token0 to add (slippage protection)
    /// @param amount1Min Minimum amount of token1 to add (slippage protection)
    /// @param minCashOutReturn Minimum terminal tokens from cash-out (slippage protection, 0 = auto)
    function _deployPoolAndAddLiquidity(
        uint256 projectId,
        address projectToken,
        address terminalToken,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 minCashOutReturn
    ) internal {
        // Create and initialize the pool if it doesn't exist
        address pool = poolOf[projectId][terminalToken];
        if (pool == address(0)) {
            _createAndInitializeUniswapV3Pool(projectId, projectToken, terminalToken);
            pool = poolOf[projectId][terminalToken];
        }

        // Add liquidity using accumulated tokens
        _addUniswapLiquidity(projectId, projectToken, terminalToken, pool, amount0Min, amount1Min, minCashOutReturn);
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
            INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER).unwrapWETH9({amountMinimum: amount, recipient: address(this)});
            // token is already JBConstants.NATIVE_TOKEN
        }
        
        // Calculate fee amount to send to fee project
        uint256 feeAmount = (amount * FEE_PERCENT) / BPS;
        uint256 remainingAmount = amount - feeAmount;
        
        // Route fee portion to fee project
        uint256 beneficiaryTokenCount = 0;
        if (feeAmount > 0) {
            address feeTerminal = address(IJBDirectory(DIRECTORY).primaryTerminalOf({projectId: FEE_PROJECT_ID, token: token}));
            if (feeTerminal != address(0)) {
                // Get balance before to track minted tokens
                address feeProjectToken = address(IJBTokens(TOKENS).tokenOf(FEE_PROJECT_ID));
                uint256 feeTokensBefore = IERC20(feeProjectToken).balanceOf(address(this));
                
                if (_isNativeToken(terminalToken)) {
                    // Native ETH - send via payable function
                    IJBMultiTerminal(feeTerminal).pay{value: feeAmount}({
                        projectId: FEE_PROJECT_ID,
                        token: token,
                        amount: feeAmount,
                        beneficiary: address(this),
                        minReturnedTokens: 0,
                        memo: "LP Fee",
                        metadata: ""
                    });
                } else {
                    // ERC20 token
                    IERC20(token).forceApprove(feeTerminal, feeAmount);
                    IJBMultiTerminal(feeTerminal).pay({
                        projectId: FEE_PROJECT_ID,
                        token: token,
                        amount: feeAmount,
                        beneficiary: address(this),
                        minReturnedTokens: 0,
                        memo: "LP Fee",
                        metadata: ""
                    });
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
            _addToProjectBalance(projectId, token, remainingAmount, _isNativeToken(terminalToken));
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

    /// @notice Calculate tick bounds for liquidity position based on issuance and cash out rates
    /// @dev Calculates ticks from sqrt prices, aligns to spacing, and handles inverted rates
    /// @param projectId The Juicebox project ID
    /// @param terminalToken The terminal token address
    /// @param projectToken The project token address
    /// @return tickLower The lower tick bound (aligned to spacing)
    /// @return tickUpper The upper tick bound (aligned to spacing)
    function _calculateTickBounds(
        uint256 projectId,
        address terminalToken,
        address projectToken
    ) internal view returns (int24 tickLower, int24 tickUpper) {
        // Calculate tick bounds based on current issuance rate (ceiling) and cash out rate (floor)
        tickLower = TickMath.getTickAtSqrtRatio(_getCashOutRateSqrtPriceX96(projectId, terminalToken, projectToken));
        tickUpper = TickMath.getTickAtSqrtRatio(_getIssuanceRateSqrtPriceX96(projectId, terminalToken, projectToken));
        
        // Enforce tick spacing - use proper floor semantics to handle negative ticks correctly
        tickLower = _alignTickToSpacing(tickLower, TICK_SPACING);
        tickUpper = _alignTickToSpacing(tickUpper, TICK_SPACING);
        
        // Ensure tickLower < tickUpper
        if (tickLower >= tickUpper) {
            // If rates are inverted, use a small range around the current price
            uint160 currentSqrtPrice = _getSqrtPriceX96ForCurrentJuiceboxPrice(projectId, terminalToken, projectToken);
            int24 currentTick = TickMath.getTickAtSqrtRatio(currentSqrtPrice);
            currentTick = _alignTickToSpacing(currentTick, TICK_SPACING);
            tickLower = currentTick - TICK_SPACING; // One tick spacing below
            tickUpper = currentTick + TICK_SPACING; // One tick spacing above
        }
    }

    /// @notice Route collected fees from Uniswap position to project
    /// @dev Determines which collected amounts correspond to terminal tokens and routes them
    /// @param projectId The Juicebox project ID
    /// @param projectToken The project token address
    /// @param terminalToken The terminal token address
    /// @param amount0 Collected amount of token0
    /// @param amount1 Collected amount of token1
    function _routeCollectedFees(
        uint256 projectId,
        address projectToken,
        address terminalToken,
        uint256 amount0,
        uint256 amount1
    ) internal {
        if (amount0 == 0 && amount1 == 0) return;
        
        // Convert native ETH to WETH for Uniswap operations
        address uniswapTerminalToken = _toUniswapToken(terminalToken);
        (address token0, address token1) = _sortTokens(projectToken, uniswapTerminalToken);
        
        // Route fees if terminal tokens were collected
        // Compare with uniswapTerminalToken (WETH) since that's what Uniswap returns
        if (amount0 > 0 && token0 == uniswapTerminalToken) {
            _routeFeesToProject(projectId, terminalToken, amount0);
        }
        if (amount1 > 0 && token1 == uniswapTerminalToken) {
            _routeFeesToProject(projectId, terminalToken, amount1);
        }
    }

    /// @notice Align tick to tick spacing using proper floor semantics for negative ticks
    /// @dev Solidity division rounds toward zero, which breaks floor behavior for negative ticks
    /// @dev For negative ticks, we need to subtract spacing if there's a remainder to get proper floor
    /// @param tick The tick to align
    /// @param spacing The tick spacing (200 for 1% fee tier)
    /// @return alignedTick The tick aligned to spacing
    function _alignTickToSpacing(int24 tick, int24 spacing) internal pure returns (int24 alignedTick) {
        int24 rounded = (tick / spacing) * spacing;
        // For negative ticks, if rounded > tick, we need to floor down further
        if (tick < 0 && rounded > tick) {
            rounded -= spacing;
        }
        return rounded;
    }

    /// @notice Burn project tokens using the controller
    /// @param projectId The Juicebox project ID
    /// @param projectToken The project token address
    /// @param amount The amount of tokens to burn
    /// @param memo Optional memo for the burn operation
    function _burnProjectTokens(uint256 projectId, address projectToken, uint256 amount, string memory memo) internal {
        if (amount == 0) return;
        
        address controller = address(IJBDirectory(DIRECTORY).controllerOf(projectId));
        if (controller != address(0)) {
            IJBController(controller).burnTokensOf({
                holder: address(this),
                projectId: projectId,
                tokenCount: amount,
                memo: memo
            });
            emit TokensBurned(projectId, projectToken, amount);
        }
    }

    /// @notice Add tokens to project balance via terminal
    /// @dev Handles both native ETH and ERC20 tokens
    /// @param projectId The Juicebox project ID
    /// @param token The token address (JBConstants.NATIVE_TOKEN for native ETH)
    /// @param amount The amount to add
    /// @param isNative Whether the token is native ETH
    function _addToProjectBalance(uint256 projectId, address token, uint256 amount, bool isNative) internal {
        if (amount == 0) return;
        
        address terminal = address(IJBDirectory(DIRECTORY).primaryTerminalOf({projectId: projectId, token: token}));
        if (terminal == address(0)) return;

        // Approve ERC20 tokens before calling addToBalanceOf
        if (!isNative) {
            IERC20(token).forceApprove(terminal, amount);
        }
        
        // Call addToBalanceOf once - send value for native ETH, 0 for ERC20
        IJBMultiTerminal(terminal).addToBalanceOf{value: isNative ? amount : 0}({
            projectId: projectId,
            token: token,
            amount: amount,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: ""
        });
    }

    /// @notice Handle leftover tokens after Uniswap V3 mint operation
    /// @dev Burns leftover project tokens and adds leftover terminal tokens to project balance
    /// @param projectId The Juicebox project ID
    /// @param projectToken The project token address
    /// @param terminalToken The terminal token address (JBConstants.NATIVE_TOKEN for native ETH)
    /// @param token0 The first token in the Uniswap pair (sorted)
    /// @param token1 The second token in the Uniswap pair (sorted)
    /// @param amount0Leftover Leftover amount of token0
    /// @param amount1Leftover Leftover amount of token1
    function _handleLeftoverTokens(
        uint256 projectId,
        address projectToken,
        address terminalToken,
        address token0,
        address token1,
        uint256 amount0Leftover,
        uint256 amount1Leftover
    ) internal {
        if (amount0Leftover == 0 && amount1Leftover == 0) return;
        
        // Determine which token is the project token and burn leftover project tokens
        uint256 projectTokenLeftover = (projectToken == token0 && amount0Leftover > 0)
            ? amount0Leftover
            : ((projectToken == token1 && amount1Leftover > 0) ? amount1Leftover : 0);
        
        if (projectTokenLeftover > 0) {
            _burnProjectTokens(projectId, projectToken, projectTokenLeftover, "Burning leftover project tokens");
        }
        
        // Handle leftover terminal tokens - add to project balance
        // Note: token0/token1 may be WETH if terminal token is native ETH
        address uniswapTerminalToken = _toUniswapToken(terminalToken);
        // Determine which leftover amount corresponds to the terminal token
        uint256 terminalTokenLeftover = (projectToken == token0 && uniswapTerminalToken == token1 && amount1Leftover > 0)
            ? amount1Leftover
            : ((projectToken == token1 && uniswapTerminalToken == token0 && amount0Leftover > 0) ? amount0Leftover : 0);
        
        if (terminalTokenLeftover > 0) {
            _addLeftoverTerminalTokensToBalance(projectId, terminalToken, terminalTokenLeftover);
        }
    }

    /// @notice Add leftover terminal tokens to project balance
    /// @dev Handles both native ETH (unwraps WETH) and ERC20 tokens
    /// @param projectId The Juicebox project ID
    /// @param terminalToken The terminal token address (JBConstants.NATIVE_TOKEN for native ETH)
    /// @param amount The amount to add (in WETH if native ETH)
    function _addLeftoverTerminalTokensToBalance(uint256 projectId, address terminalToken, uint256 amount) internal {
        if (amount == 0) return;
        
        address token = terminalToken;
        
        // If terminal token is native ETH, Uniswap returns WETH - unwrap it to ETH
        if (_isNativeToken(terminalToken)) {
            // Unwrap WETH to ETH
            INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER).unwrapWETH9({amountMinimum: amount, recipient: address(this)});
            // token is already JBConstants.NATIVE_TOKEN
        }
        
        // Add to project balance via terminal
        _addToProjectBalance(projectId, token, amount, _isNativeToken(terminalToken));
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
