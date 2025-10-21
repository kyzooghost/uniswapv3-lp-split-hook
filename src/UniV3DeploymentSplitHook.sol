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

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { mulDiv, sqrt } from "@prb/math/src/Common.sol";

import { INonfungiblePositionManager } from "@uniswap/v3-periphery-flattened/INonfungiblePositionManager.sol";
import { IUniswapV3Factory } from "@uniswap/v3-core/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/interfaces/IUniswapV3Pool.sol";
import { TickMath } from "@uniswap/v3-core-patched/TickMath.sol";

import { IUniV3DeploymentSplitHook } from "./interfaces/IUniV3DeploymentSplitHook.sol";

// Interface for REVDeployer to check revnet operator status
interface IREVDeployer {
    function isSplitOperatorOf(uint256 revnetId, address addr) external view returns (bool);
}

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

    /// @notice JBDirectory (to find important control contracts for given projectId)
    address public immutable jbDirectory;

    /// @notice JBTokens (to find project tokens)
    address public immutable jbTokens;

    /// @notice UniswapV3Factory address
    address public immutable uniswapV3Factory;

    /// @notice UniswapV3 NonFungiblePositionManager address
    address public immutable uniswapV3NonfungiblePositionManager;

    /// @notice Single immutable 'fee' value for all created UniswapV3 pools.
    uint24 public immutable uniswapPoolFee;

    /// @notice Tick range to use for UniswapV3 LP position
    /// @dev Liquidity positions will be created with `lowerTick = currentJbRulsetPrice - tickRange / 2` and `upperTick = currentJbRulsetPrice + tickRange / 2`
    int24 public immutable tickRange;

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

    /// @notice Project ID to receive LP fees
    uint256 public immutable feeProjectId;

    /// @notice Percentage of LP fees to route to fee project (in basis points, e.g., 3800 = 38%)
    uint256 public immutable feePercent;

    /// @notice REVDeployer contract address for revnet operator validation
    address public immutable revDeployer;

    /**
    * @param _initialOwner Initial owner/admin of the contract
    * @param _jbDirectory JBDirectory address
    * @param _jbTokens JBTokens address
    * @param _uniswapV3Factory UniswapV3Factory address
    * @param _uniswapV3NonfungiblePositionManager UniswapV3 NonfungiblePositionManager address
    * @param _uniswapPoolFee Uniswap pool fee (cannot be changed after deployment)
    * @param _tickRange Uniswap LP tick range (cannot be changed after deployment)
    * @param _feeProjectId Project ID to receive LP fees
    * @param _feePercent Percentage of LP fees to route to fee project (in basis points, e.g., 3800 = 38%)
    * @param _revDeployer REVDeployer contract address for revnet operator validation
    */
    constructor(
        address _initialOwner,
        address _jbDirectory,
        address _jbTokens,
        address _uniswapV3Factory,
        address _uniswapV3NonfungiblePositionManager,
        uint24 _uniswapPoolFee,
        int24 _tickRange,
        uint256 _feeProjectId,
        uint256 _feePercent,
        address _revDeployer
    ) 
        Ownable(_initialOwner)
    {
        if (_jbDirectory == address(0)) revert ZeroAddressNotAllowed();
        if (_jbTokens == address(0)) revert ZeroAddressNotAllowed();
        if (_uniswapV3Factory == address(0)) revert ZeroAddressNotAllowed();
        if (_uniswapV3NonfungiblePositionManager == address(0)) revert ZeroAddressNotAllowed();
        if (_revDeployer == address(0)) revert ZeroAddressNotAllowed();
        if (_feePercent > 10000) revert InvalidFeePercent(); // Max 100% in basis points

        // TODO - Input validation of _uniswapPoolFee
        // TODO - Input validation of _tickRange

        jbDirectory = _jbDirectory;
        jbTokens = _jbTokens;

        uniswapV3Factory = _uniswapV3Factory;
        uniswapV3NonfungiblePositionManager = _uniswapV3NonfungiblePositionManager;
        uniswapPoolFee = _uniswapPoolFee;
        tickRange = _tickRange;
        feeProjectId = _feeProjectId;
        feePercent = _feePercent;
        revDeployer = _revDeployer;
    }

    /**
    * @notice As per ERC-165 to declare supported interfaces
    * @param _interfaceId Interface ID as specified by `type(interface).interfaceId`
    */
    function supportsInterface(bytes4 _interfaceId) public pure override returns (bool) {
        return _interfaceId == type(IUniV3DeploymentSplitHook).interfaceId
            || _interfaceId == type(IJBSplitHook).interfaceId;
    }

    /**
    * @notice Get the current stage for a project based on ruleset weight
    * @param _projectId The Juicebox project ID
    * @return isAccumulationStage True if current weight >= 0.1x first ruleset weight (accumulation stage), false if < 0.1x (deployment stage)
    */
    function isAccumulationStage(uint256 _projectId) public view returns (bool isAccumulationStage) {
        address controller = IJBDirectory(jbDirectory).controllerOf(_projectId);
        if (controller == address(0)) return true; // Default to accumulation if no controller
        
        uint256 firstWeight = _getFirstRulesetWeight(_projectId);
        if (firstWeight == 0) return true; // Default to accumulation if no first weight
        
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(_projectId);
        uint256 threshold = firstWeight / 10; // 0.1x = 10% of first weight
        
        return ruleset.weight >= threshold;
    }

    /**
    * @notice Get the weight from the first ever ruleset
    * @param _projectId The Juicebox project ID
    * @return weight The weight from the first ruleset, or 0 if none found
    */
    function _getFirstRulesetWeight(uint256 _projectId) internal view returns (uint256 weight) {
        address controller = IJBDirectory(jbDirectory).controllerOf(_projectId);
        if (controller == address(0)) return 0;
        
        // Get all rulesets sorted from latest to earliest
        JBRulesetWithMetadata[] memory rulesets = IJBController(controller).allRulesetsOf(_projectId, 0, 10);
        
        // The last element in the array is the first ever ruleset
        if (rulesets.length > 0) {
            return rulesets[rulesets.length - 1].ruleset.weight;
        }
        
        return 0;
    }

    /**
    * @notice Find the latest ruleset weight before going under 0.1x the first ruleset weight
    * @param _projectId The Juicebox project ID
    * @return weight The weight from the last ruleset before going under 0.1x threshold, or 0 if none found
    */
    function _getLatestPositiveWeight(uint256 _projectId) internal view returns (uint256 weight) {
        address controller = IJBDirectory(jbDirectory).controllerOf(_projectId);
        if (controller == address(0)) return 0;
        
        uint256 firstWeight = _getFirstRulesetWeight(_projectId);
        if (firstWeight == 0) return 0;
        
        uint256 threshold = firstWeight / 10; // 0.1x = 10% of first weight
        
        // Get all rulesets sorted from latest to earliest
        JBRulesetWithMetadata[] memory rulesets = IJBController(controller).allRulesetsOf(_projectId, 0, 10);
        
        // Find the latest ruleset with weight >= 0.1x first weight
        // Since weight decreases over time, we iterate from most recent to oldest
        for (uint256 i = 0; i < rulesets.length; i++) {
            if (rulesets[i].ruleset.weight >= threshold) {
                return rulesets[i].ruleset.weight;
            }
        }
        
        // If no ruleset meets the threshold, return 0
        return 0;
    }


    /**
    * @notice IJbSplitHook function called by JuiceboxV4 terminal/controller when sending funds to designated split hook contract.
    * @dev Tokens are optimistically transferred to this split hook contract
    * @param _context Contextual data passed by JuiceboxV4 terminal/controller
    */
    function processSplitWith(JBSplitHookContext calldata _context) external payable {
        if (address(_context.split.hook) != address(this)) revert NotHookSpecifiedInContext();
        // Validate that msg.sender is the project's controller
        address controller = address(IJBDirectory(jbDirectory).controllerOf(_context.projectId));
        if (controller == address(0)) revert InvalidProjectId();
        if (controller != msg.sender) revert SplitSenderNotValidControllerOrTerminal();
        /// @dev Key trust assumption: If the sender is the verified Controller, then we can trust the remaining fields in the _context

        // Only handle reserved tokens (groupId == 1), revert on terminal tokens from payouts
        if (_context.groupId != 1) revert TerminalTokensNotAllowed();
        
        address projectToken = _context.token;

        bool isAccumulation = isAccumulationStage(_context.projectId);
        
        if (isAccumulation) {
            // Accumulation stage: Accumulate tokens (weight > 0)
            _accumulateTokens(_context.projectId, projectToken);
        } else {
            // Get a terminal with an accounting context to use as the terminal token for pool creation
            address[] memory terminals = IJBDirectory(jbDirectory).terminalsOf(_context.projectId);
            address terminalToken = address(0);
            
            // Find the first terminal that has an accounting context
            for (uint256 i = 0; i < terminals.length; i++) {
                try IJBMultiTerminal(terminals[i]).accountingContextsOf(_context.projectId, _context.token) returns (JBAccountingContext memory context) {
                    if (context.token != address(0)) {
                        // Use uniswap's native ETH if needed.
                        terminalToken = context.token == JBConstants.NATIVE_TOKEN ? address(0) : context.token;
                        break;
                    }
                } catch {
                    // Continue to next terminal if this one doesn't have the context
                    continue;
                }
            }

            // Deployment stage: Deploy pool if not already deployed, then burn newly received tokens
            _handleDeploymentStage(_context.projectId, projectToken, terminalToken);
        }
    }

    /**
    * @notice Manually trigger deployment for a project (only works in accumulation stage)
    * @param _projectId The Juicebox project ID
    * @param _terminalToken The terminal token address
    */
    function deployPool(uint256 _projectId, address _terminalToken) external {
        if (!isAccumulationStage(_projectId)) revert InvalidStageForAction();
        
        address projectToken = address(IJBTokens(jbTokens).tokenOf(_projectId));
        uint256 projectTokenBalance = accumulatedProjectTokens[_projectId];
        
        if (projectTokenBalance == 0) revert NoTokensAccumulated();
        
        // Deploy the pool and add liquidity
        _deployPoolAndAddLiquidity(_projectId, projectToken, _terminalToken);
        
        emit ProjectDeployed(_projectId, _terminalToken, poolOf[_projectId][_terminalToken]);
    }

    /**
    * @notice Collect LP fees and route them back to the project
    * @param _projectId The Juicebox project ID
    * @param _terminalToken The terminal token address
    */
    function collectAndRouteLPFees(uint256 _projectId, address _terminalToken) external {
        if (isAccumulationStage(_projectId)) revert InvalidStageForAction();
        
        address pool = poolOf[_projectId][_terminalToken];
        if (pool == address(0)) revert InvalidStageForAction();
        
        uint256 tokenId = tokenIdForPool[pool];
        if (tokenId == 0) revert InvalidStageForAction();
        
        // Collect fees from the LP position
        (uint256 amount0, uint256 amount1) = INonfungiblePositionManager(uniswapV3NonfungiblePositionManager).collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        
        // Route fees back to the project via addToBalance
        address projectToken = address(IJBTokens(jbTokens).tokenOf(_projectId));
        (address token0, address token1) = _sortTokens(projectToken, _terminalToken);
        
        if (amount0 > 0) {
            address token = token0 == projectToken ? projectToken : _terminalToken;
            uint256 amount = token0 == projectToken ? amount0 : amount1;
            _routeFeesToProject(_projectId, token, amount);
        }
        
        if (amount1 > 0) {
            address token = token1 == projectToken ? projectToken : _terminalToken;
            uint256 amount = token1 == projectToken ? amount1 : amount0;
            _routeFeesToProject(_projectId, token, amount);
        }
    }

    /**
    * @notice Accumulate project tokens in accumulation stage
    * @param _projectId The Juicebox project ID
    * @param _projectToken The project token address
    */
    function _accumulateTokens(uint256 _projectId, address _projectToken) internal {
        // Only accumulate project tokens (reserved tokens)
        uint256 projectTokenBalance = IERC20(_projectToken).balanceOf(address(this));
        accumulatedProjectTokens[_projectId] += projectTokenBalance;
    }

    /**
    * @notice Handle deployment stage: deploy pool if not deployed, then burn newly received tokens
    * @param _projectId The Juicebox project ID
    * @param _projectToken The project token address
    * @param _terminalToken The terminal token address
    */
    function _handleDeploymentStage(uint256 _projectId, address _projectToken, address _terminalToken) internal {
        // If pool doesn't exist yet, deploy it using accumulated project tokens
        address pool = poolOf[_projectId][_terminalToken];
        if (pool == address(0)) {
            uint256 projectTokenBalance = accumulatedProjectTokens[_projectId];
            
            if (projectTokenBalance > 0) {
                _deployPoolAndAddLiquidity(_projectId, _projectToken, _terminalToken);
                emit ProjectDeployed(_projectId, _terminalToken, poolOf[_projectId][_terminalToken]);
            }
        }
        
        // Burn any newly received project tokens
        _burnReceivedTokens(_projectId, _projectToken, _terminalToken);
    }

    /**
    * @notice Burn received project tokens in deployment stage
    * @param _projectId The Juicebox project ID
    * @param _projectToken The project token address
    * @param _terminalToken The terminal token address (unused, kept for interface consistency)
    */
    function _burnReceivedTokens(uint256 _projectId, address _projectToken, address _terminalToken) internal {
        // Burn any project tokens received using the controller
        uint256 projectTokenBalance = IERC20(_projectToken).balanceOf(address(this));
        if (projectTokenBalance > 0) {
            // Use the controller to burn project tokens
            address controller = IJBDirectory(jbDirectory).controllerOf(_projectId);
            if (controller != address(0)) {
                IJBController(controller).burnTokensOf(
                    address(this),
                    _projectId,
                    projectTokenBalance,
                    "Deployment stage: Burning additional reserved tokens"
                );
                emit TokensBurned(_projectId, _projectToken, projectTokenBalance);
            }
        }
    }

    /**
    * @notice Deploy pool and add liquidity using accumulated tokens
    * @param _projectId The Juicebox project ID
    * @param _projectToken The project token address
    * @param _terminalToken The terminal token address
    */
    function _deployPoolAndAddLiquidity(uint256 _projectId, address _projectToken, address _terminalToken) internal {
        // Create and initialize the pool if it doesn't exist
        address pool = poolOf[_projectId][_terminalToken];
        if (pool == address(0)) {
            _createAndInitializeUniswapV3Pool(_projectId, _projectToken, _terminalToken);
            pool = poolOf[_projectId][_terminalToken];
        }
        
        // Add liquidity using accumulated tokens
        _addUniswapLiquidity(_projectId, _projectToken, _terminalToken, pool);
    }

    /**
    * @notice Create and initialize UniswapV3 pool
    * @param _projectId The Juicebox project ID
    * @param _projectToken Project token
    * @param _terminalToken Terminal token
    */
    function _createAndInitializeUniswapV3Pool(uint256 _projectId, address _projectToken, address _terminalToken) internal {
        (address token0, address token1) = _sortTokens(_projectToken, _terminalToken);
        uint160 sqrtPriceX96 = _getSqrtPriceX96ForLatestPositiveWeight(_projectId, _projectToken, _terminalToken);
        address newPool = INonfungiblePositionManager(uniswapV3NonfungiblePositionManager).createAndInitializePoolIfNecessary(token0, token1, uniswapPoolFee, sqrtPriceX96);
        poolOf[_projectId][_terminalToken] = newPool;
    }

    /**
    * @notice Add liquidity to a UniswapV3 pool using accumulated tokens
    * @param _projectId JuiceboxV4 projectId
    * @param _projectToken Project token
    * @param _terminalToken Terminal token
    * @param _pool UniswapV3 pool
    */
    function _addUniswapLiquidity(uint256 _projectId, address _projectToken, address _terminalToken, address _pool) internal {
        uint256 projectTokenBalance = accumulatedProjectTokens[_projectId];
        
        if (projectTokenBalance == 0) return;
        
        // Create the liquidity position with only project tokens
        (address token0, address token1) = _sortTokens(_projectToken, _terminalToken);
        int24 currentJuiceboxPriceTick = TickMath.getTickAtSqrtRatio(_getSqrtPriceX96ForLatestPositiveWeight(_projectId, _projectToken, _terminalToken));
        
        // Calculate amounts based on current pool price
        uint256 amount0 = _projectToken == token0 ? projectTokenBalance : 0;
        uint256 amount1 = _projectToken == token1 ? projectTokenBalance : 0;
        
        (uint256 tokenId,,,) = INonfungiblePositionManager(uniswapV3NonfungiblePositionManager).mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: uniswapPoolFee,
                tickLower: currentJuiceboxPriceTick - (tickRange / 2),
                tickUpper: currentJuiceboxPriceTick + (tickRange / 2),
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        tokenIdForPool[_pool] = tokenId;
        
        // Clear accumulated balances
        accumulatedProjectTokens[_projectId] = 0;
    }

    /**
    * @notice Route fees back to the project via addToBalance
    * @param _projectId The Juicebox project ID
    * @param _token The token to route
    * @param _amount The amount to route
    */
    function _routeFeesToProject(uint256 _projectId, address _token, uint256 _amount) internal {
        if (_amount == 0) return;
        
        // Calculate fee amount to send to fee project
        uint256 feeAmount = (_amount * feePercent) / 10000;
        uint256 remainingAmount = _amount - feeAmount;
        
        // Route fee portion to fee project
        if (feeAmount > 0) {
            address feeTerminal = IJBDirectory(jbDirectory).primaryTerminalOf(feeProjectId, _token);
            if (feeTerminal != address(0)) {
                IERC20(_token).safeApprove(feeTerminal, feeAmount);
                uint256 beneficiaryTokenCount = IJBMultiTerminal(feeTerminal).pay(
                    feeProjectId,
                    _token,
                    feeAmount,
                    address(this), // beneficiary
                    0, // minReturnedTokens
                    "LP Fee", // memo
                    "" // metadata
                );
                
                // Track the fee tokens returned for this project
                claimableFeeTokens[_projectId] += beneficiaryTokenCount;
            }
        }
        
        // Route remaining amount to original project
        if (remainingAmount > 0) {
            address terminal = IJBDirectory(jbDirectory).primaryTerminalOf(_projectId, _token);
            if (terminal != address(0)) {
                IERC20(_token).safeApprove(terminal, remainingAmount);
                IJBMultiTerminal(terminal).addToBalanceOf(
                    _projectId,
                    _token,
                    remainingAmount,
                    false, // shouldReturnHeldFees
                    "",
                    ""
                );
            }
        }
        
        emit LPFeesRouted(_projectId, _token, _amount);
    }

    /**
    * @notice Claim fee tokens for a beneficiary (must be the project's revnet operator)
    * @param _projectId The Juicebox project ID
    * @param _beneficiary The beneficiary address to claim tokens for
    */
    function claimFeeTokensFor(uint256 _projectId, address _beneficiary) external {
        // Validate that the beneficiary is the revnet operator for this project
        if (!IREVDeployer(revDeployer).isSplitOperatorOf(_projectId, _beneficiary)) {
            revert UnauthorizedBeneficiary();
        }
        
        // Get the claimable amount for this project
        uint256 claimableAmount = claimableFeeTokens[_projectId];
        
        // Reset the claimable amount for this project
        claimableFeeTokens[_projectId] = 0;

        if (claimableAmount > 0) {
            // Get the fee project token (all projects receive the same token from fee project)
            address feeProjectToken = address(IJBTokens(jbTokens).tokenOf(feeProjectId));
            
            // Transfer the tokens to the beneficiary
            IERC20(feeProjectToken).safeTransfer(_beneficiary, claimableAmount);
        }
    }

    /**
    * @notice Sort input tokens in order expected by `INonfungiblePositionManager.createAndInitializePoolIfNecessary`
    */
    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    /**
    * @notice Compute UniswapV3 SqrtPriceX96 for current JuiceboxV4 price
    * @param _projectId JuiceboxV4 projectId
    * @param _projectToken Project token
    * @param _terminalToken Terminal token
    */
    function _getSqrtPriceX96ForCurrentJuiceboxPrice(
        uint256 _projectId,
        address _terminalToken,
        address _projectToken
    ) internal view returns (uint160 sqrtPriceX96) {
        (address token0, address token1) = _sortTokens(_terminalToken, _projectToken);
        // Use standard denominator of 1 ether or 10**18
        uint256 token0Amount = 1 ether;
        uint256 token1Amount;
        if (token0 == _terminalToken) {
            token1Amount = _getProjectTokensOutForTerminalTokensIn(_projectId, _terminalToken, token0Amount);
        } else {
            token1Amount = _getTerminalTokensOutForProjectTokensIn(_projectId, _terminalToken, token0Amount);
        }
        /// @dev `sqrtPriceX96 = sqrt(token1/token0) * (2 ** 96)`
        /// @dev price = token1/token0 = What amount of token1 has equivalent value to 1 token0
        /// @dev See https://ethereum.stackexchange.com/questions/98685/computing-the-uniswap-v3-pair-price-from-q64-96-number
        /// @dev Also see https://blog.uniswap.org/uniswap-v3-math-primer
        return uint160(mulDiv(sqrt(token1Amount), 2**96,sqrt(token0Amount)));
    }

    /**
    * @notice Get sqrtPriceX96 using the latest positive weight from ruleset history
    * @param _projectId JuiceboxV4 projectId
    * @param _terminalToken Terminal token
    * @param _projectToken Project token
    */
    function _getSqrtPriceX96ForLatestPositiveWeight(
        uint256 _projectId,
        address _terminalToken,
        address _projectToken
    ) internal view returns (uint160 sqrtPriceX96) {
        uint256 latestWeight = _getLatestPositiveWeight(_projectId);
        if (latestWeight == 0) {
            // Fallback to current price if no positive weight found
            return _getSqrtPriceX96ForCurrentJuiceboxPrice(_projectId, _terminalToken, _projectToken);
        }
        
        (address token0, address token1) = _sortTokens(_terminalToken, _projectToken);
        // Use standard denominator of 1 ether or 10**18
        uint256 token0Amount = 1 ether;
        uint256 token1Amount;
        
        if (token0 == _terminalToken) {
            token1Amount = _getProjectTokensOutForTerminalTokensInWithWeight(_projectId, _terminalToken, token0Amount, latestWeight);
        } else {
            token1Amount = _getTerminalTokensOutForProjectTokensInWithWeight(_projectId, _terminalToken, token0Amount, latestWeight);
        }
        
        /// @dev `sqrtPriceX96 = sqrt(token1/token0) * (2 ** 96)`
        return uint160(mulDiv(sqrt(token1Amount), 2**96, sqrt(token0Amount)));
    }

    /**
    * @notice For given terminalToken amount, compute equivalent projectToken amount at current JuiceboxV4 price
    * @dev Use pricing logic in JBTerminalStore.recordPaymentFrom()
    * @param _projectId JuiceboxV4 projectId
    * @param _terminalToken Terminal token
    * @param _terminalTokenInAmount Terminal token in amount
    */
    function _getProjectTokensOutForTerminalTokensIn(
        uint256 _projectId, 
        address _terminalToken,
        uint256 _terminalTokenInAmount
    ) internal view returns (uint256 projectTokenOutAmount) {
        address controller = IJBDirectory(jbDirectory).controllerOf(_projectId);
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(_projectId);
        // Get the accounting context from the primary terminal for the terminal token
        address terminal = IJBDirectory(jbDirectory).primaryTerminalOf(_projectId, _terminalToken);
        JBAccountingContext memory context = IJBMultiTerminal(terminal).accountingContextForTokenOf(_projectId, _terminalToken);
        uint32 baseCurrency = ruleset.baseCurrency();
        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBController(controller).pricePerUnitOf({
                projectId: _projectId,
                pricingCurrency: context.currency,
                unitCurrency: baseCurrency,
                decimals: context.decimals
            });
        projectTokenOutAmount = mulDiv(_terminalTokenInAmount, ruleset.weight, weightRatio);
    }

    /**
    * @notice For given terminalToken amount, compute equivalent projectToken amount using a specific weight
    * @param _projectId JuiceboxV4 projectId
    * @param _terminalToken Terminal token
    * @param _terminalTokenInAmount Terminal token in amount
    * @param _weight The weight to use for calculation
    */
    function _getProjectTokensOutForTerminalTokensInWithWeight(
        uint256 _projectId, 
        address _terminalToken,
        uint256 _terminalTokenInAmount,
        uint256 _weight
    ) internal view returns (uint256 projectTokenOutAmount) {
        address controller = IJBDirectory(jbDirectory).controllerOf(_projectId);
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(_projectId);
        // Get the accounting context from the primary terminal for the terminal token
        address terminal = IJBDirectory(jbDirectory).primaryTerminalOf(_projectId, _terminalToken);
        JBAccountingContext memory context = IJBMultiTerminal(terminal).accountingContextForTokenOf(_projectId, _terminalToken);
        uint32 baseCurrency = ruleset.baseCurrency();
        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBController(controller).pricePerUnitOf({
                projectId: _projectId,
                pricingCurrency: context.currency,
                unitCurrency: baseCurrency,
                decimals: context.decimals
            });
        projectTokenOutAmount = mulDiv(_terminalTokenInAmount, _weight, weightRatio);
    }

    /**
    * @notice For given projectToken amount, compute equivalent terminalToken amount at current JuiceboxV4 price
    * @dev Use pricing logic in JBTerminalStore.recordPaymentFrom()
    * @param _projectId JuiceboxV4 projectId
    * @param _terminalToken Terminal token
    * @param _projectTokenInAmount Project token in amount
    */
    function _getTerminalTokensOutForProjectTokensIn(
        uint256 _projectId, 
        address _terminalToken, 
        uint256 _projectTokenInAmount
    ) internal view returns (uint256 terminalTokenOutAmount) {
        address controller = IJBDirectory(jbDirectory).controllerOf(_projectId);
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(_projectId);
        // Get the accounting context from the primary terminal for the terminal token
        address terminal = IJBDirectory(jbDirectory).primaryTerminalOf(_projectId, _terminalToken);
        JBAccountingContext memory context = IJBMultiTerminal(terminal).accountingContextForTokenOf(_projectId, _terminalToken);
        uint32 baseCurrency = ruleset.baseCurrency();
        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBController(controller).pricePerUnitOf({
                projectId: _projectId,
                pricingCurrency: context.currency,
                unitCurrency: baseCurrency,
                decimals: context.decimals
            });
        terminalTokenOutAmount = mulDiv(_projectTokenInAmount, weightRatio, ruleset.weight);
    }

    /**
    * @notice For given projectToken amount, compute equivalent terminalToken amount using a specific weight
    * @param _projectId JuiceboxV4 projectId
    * @param _terminalToken Terminal token
    * @param _projectTokenInAmount Project token in amount
    * @param _weight The weight to use for calculation
    */
    function _getTerminalTokensOutForProjectTokensInWithWeight(
        uint256 _projectId, 
        address _terminalToken, 
        uint256 _projectTokenInAmount,
        uint256 _weight
    ) internal view returns (uint256 terminalTokenOutAmount) {
        address controller = IJBDirectory(jbDirectory).controllerOf(_projectId);
        (JBRuleset memory ruleset,) = IJBController(controller).currentRulesetOf(_projectId);
        // Get the accounting context from the primary terminal for the terminal token
        address terminal = IJBDirectory(jbDirectory).primaryTerminalOf(_projectId, _terminalToken);
        JBAccountingContext memory context = IJBMultiTerminal(terminal).accountingContextForTokenOf(_projectId, _terminalToken);
        uint32 baseCurrency = ruleset.baseCurrency();
        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBController(controller).pricePerUnitOf({
                projectId: _projectId,
                pricingCurrency: context.currency,
                unitCurrency: baseCurrency,
                decimals: context.decimals
            });
        terminalTokenOutAmount = mulDiv(_projectTokenInAmount, weightRatio, _weight);
    }
}
