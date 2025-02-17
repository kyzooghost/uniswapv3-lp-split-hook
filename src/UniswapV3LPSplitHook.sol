// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import { IJBController } from "@bananapus/core/interfaces/IJBController.sol";
import { IJBDirectory } from "@bananapus/core/interfaces/IJBDirectory.sol";
import { IJBMultiTerminal } from "@bananapus/core/interfaces/IJBMultiTerminal.sol";
import { IJBPrices } from "@bananapus/core/interfaces/IJBPrices.sol";
import { IJBRulesets } from "@bananapus/core/interfaces/IJBRulesets.sol";
import { IJBSplitHook } from "@bananapus/core/interfaces/IJBSplitHook.sol";
import { IJBTerminal } from "@bananapus/core/interfaces/IJBTerminal.sol";
import { IJBTerminalStore } from "@bananapus/core/interfaces/IJBTerminalStore.sol";
import { IJBTokens } from "@bananapus/core/interfaces/IJBTokens.sol";
import { JBAccountingContext } from "@bananapus/core/structs/JBAccountingContext.sol";
import { JBRuleset } from "@bananapus/core/structs/JBRuleset.sol";
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

import { IUniswapV3LPSplitHook } from "./interfaces/IUniswapV3LPSplitHook.sol";

/**
 * @title UniswapV3LPSplitHook
 * @notice JuiceBoxV4 IJBSplitHook contract that converts a received split into a UniswapV3 projectToken/terminalToken LP.
 * 
 * Key assumptions include:
 * @dev This contract is the creator of the projectToken/terminalToken UniswapV3 pool.
 * @dev Any tokens held by the contract can be added to a UniswapV3 LP position.
 * @dev For any given UniswapV3 pool, the contract will control a single LP position.
 */
contract UniswapV3LPSplitHook is IUniswapV3LPSplitHook, IJBSplitHook, Ownable {
    using JBRulesetMetadataResolver for JBRuleset;

    /// @notice JBMultiTerminal (used to find JBDirectory and JBTokens)
    /// @dev We assume there a single instance of this contract
    address public immutable jbMultiTerminal;

    /// @notice JBDirectory (to find important control contracts for given projectId)
    address public immutable jbDirectory;

    /// @notice JBTokens (to find project tokens)
    address public immutable jbTokens;

    /// @notice JBRulesets (Stores and manages project rulesets)
    address public immutable jbRulesets;

    /// @notice JBTerminalStore (Stores and manages terminal data)
    address public immutable jbTerminalStore;

    /// @notice JBPrices (Price feeds)
    address public immutable jbPrices;

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

    /**
    * @param _initialOwner Initial owner/admin of the contract
    * @param _jbMultiTerminal JBMultiTerminal address
    * @param _uniswapV3Factory UniswapV3Factory address
    * @param _uniswapV3NonfungiblePositionManager UniswapV3 NonfungiblePositionManager address
    * @param _uniswapPoolFee Uniswap pool fee (cannot be changed after deployment)
    * @param _tickRange Uniswap LP tick range (cannot be changed after deployment)
    */
    constructor(
        address _initialOwner,
        address _jbMultiTerminal,
        address _uniswapV3Factory,
        address _uniswapV3NonfungiblePositionManager,
        uint24 _uniswapPoolFee,
        int24 _tickRange
    ) 
        Ownable(_initialOwner)
    {
        if (_jbMultiTerminal == address(0)) revert ZeroAddressNotAllowed();
        if (_uniswapV3Factory == address(0)) revert ZeroAddressNotAllowed();
        if (_uniswapV3NonfungiblePositionManager == address(0)) revert ZeroAddressNotAllowed();
        address _jbDirectory = address(IJBMultiTerminal(_jbMultiTerminal).DIRECTORY());
        address _jbRulesets = address(IJBMultiTerminal(_jbMultiTerminal).RULESETS());
        address _jbTokens = address(IJBMultiTerminal(_jbMultiTerminal).TOKENS());
        address _jbTerminalStore = address(IJBMultiTerminal(_jbMultiTerminal).STORE());
        address _jbPrices = address(IJBTerminalStore(_jbTerminalStore).PRICES());
        if (_jbDirectory == address(0)) revert ZeroAddressNotAllowed();
        if (_jbRulesets == address(0)) revert ZeroAddressNotAllowed();
        if (_jbTokens == address(0)) revert ZeroAddressNotAllowed();
        if (_jbTerminalStore == address(0)) revert ZeroAddressNotAllowed();
        if (_jbPrices == address(0)) revert ZeroAddressNotAllowed();

        // TODO - Input validation of _uniswapPoolFee
        // TODO - Input validation of _tickRange

        jbMultiTerminal = _jbMultiTerminal;
        jbDirectory = _jbDirectory;
        jbRulesets = _jbRulesets;
        jbTokens = _jbTokens;
        jbTerminalStore = _jbTerminalStore;
        jbPrices = _jbPrices;

        uniswapV3Factory = _uniswapV3Factory;
        uniswapV3NonfungiblePositionManager = _uniswapV3NonfungiblePositionManager;
        uniswapPoolFee = _uniswapPoolFee;
        tickRange = _tickRange;
    }

    /**
    * @notice As per ERC-165 to declare supported interfaces
    * @param _interfaceId Interface ID as specified by `type(interface).interfaceId`
    */
    function supportsInterface(bytes4 _interfaceId) public pure override returns (bool) {
        return _interfaceId == type(IUniswapV3LPSplitHook).interfaceId
            || _interfaceId == type(IJBSplitHook).interfaceId;
    }

    /**
    * @notice IJbSplitHook function called by JuiceBoxV4 terminal/controller when sending funds to designated split hook contract.
    * @dev Tokens are optimistically transferred to this split hook contract
    * @param _context Contextual data passed by JuiceBoxV4 terminal/controller
    */
    function processSplitWith(JBSplitHookContext calldata _context) external payable {
        if (address(_context.split.hook) != address(this)) revert NotHookSpecifiedInContext();
        // Validate that msg.sender is a JuiceBoxV4 Terminal or Controller (using Directory as the source of truth)
        address controller = address(IJBDirectory(jbDirectory).controllerOf(_context.projectId));
        if (controller == address(0)) revert InvalidProjectId();
        if (controller != msg.sender && !IJBDirectory(jbDirectory).isTerminalOf(_context.projectId, IJBTerminal(msg.sender))) revert SplitSenderNotValidControllerOrTerminal();
        /// @dev Key trust assumption: If the sender is a verified Terminal or Controller, then we can trust the remaining fields in the _context

        address projectToken;
        address terminalToken;
        if (_context.groupId == 1) {
            // Reserve split, received project tokens
            projectToken = _context.token;
            // Assume that first element of 'accountingContextsOf' represents the default terminal token
            // TO DISCUSS - We could save up to 2600 gas ('CALL' for cold address) after the first query for a project by caching in a storage mapping.
            terminalToken = IJBMultiTerminal(jbMultiTerminal).accountingContextsOf(_context.projectId)[0].token;
        } else {
            // Payout split, received terminal tokens
            projectToken = address(IJBTokens(jbTokens).tokenOf(_context.projectId));
            terminalToken = _context.token;
        }
        
        address pool = poolOf[_context.projectId][terminalToken];
        if (pool == address(0)) _createAndInitializeUniswapV3Pool(_context, projectToken, terminalToken);
        _rebalanceUniswapV3Pool(_context.projectId, projectToken, terminalToken, pool);
        // TODO Emit event
    }

    /**
    * @notice Create and initialize UniswapV3 pool
    * @param _context Contextual data passed by JuiceBoxV4 terminal/controller
    * @param _projectToken Project token
    * @param _terminalToken Terminal token
    */
    function _createAndInitializeUniswapV3Pool(JBSplitHookContext calldata _context, address _projectToken, address _terminalToken) internal {
        (address token0, address token1) = _sortTokens(_projectToken, _terminalToken);
        uint160 sqrtPriceX96 = _getSqrtPriceX96ForCurrentJBRulesetPrice(_context.projectId, _projectToken, _terminalToken);
        address newPool = INonfungiblePositionManager(uniswapV3NonfungiblePositionManager).createAndInitializePoolIfNecessary(token0, token1, uniswapPoolFee, sqrtPriceX96);
        poolOf[_context.projectId][_terminalToken] = newPool;
        // TODO - Emit event
    }

    function _rebalanceUniswapV3Pool(
        uint256 _projectId, 
        address _projectToken,
        address _terminalToken,
        address _pool
    ) internal {
        uint256 tokenId = tokenIdForPool[_pool];
        int24 currentRulesetTick = TickMath.getTickAtSqrtRatio(_getSqrtPriceX96ForCurrentJBRulesetPrice(_projectId, _projectToken, _terminalToken));
        // No current position, mint and add liquidity
        if (tokenId == 0) {
            _mintAndAddNewLiquidityPosition(_pool, _projectId, _projectToken, _terminalToken, currentRulesetTick);
        // Current position => Collect fees
        } else {
            // Collect fees
            INonfungiblePositionManager(uniswapV3NonfungiblePositionManager).collect(
                INonfungiblePositionManager.CollectParams ({
                    tokenId: tokenId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
            }));

            // Check if current project ruleset price is within current tick range of pool position
            (,,,,,int24 tickLower,int24 tickUpper,uint128 liquidity,,,,) = INonfungiblePositionManager(uniswapV3NonfungiblePositionManager).positions(tokenId);
            // TODO True => Add all available liquidity at current project price
            if ((currentRulesetTick >= tickLower) && (currentRulesetTick <= tickUpper)) {
                (uint256 amount0, uint256 amount1) = _getAddLiquidityAmounts(_projectId, _projectToken, _terminalToken);
                INonfungiblePositionManager(uniswapV3NonfungiblePositionManager).increaseLiquidity(
                    INonfungiblePositionManager.IncreaseLiquidityParams ({
                        tokenId: tokenId,
                        amount0Desired: amount0,
                        amount1Desired: amount1,
                        amount0Min: 0,
                        amount1Min: 0,
                        deadline: block.timestamp
                }));

            // TODO False => Withdraw all current liquidity (decreaseLiquidity + burn) -> mint new position
            //      - Inefficiency in that we could remember and later reuse old liquidity position, rather than burning
            } else {
                INonfungiblePositionManager(uniswapV3NonfungiblePositionManager).decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams ({
                        tokenId: tokenId,
                        liquidity: liquidity,
                        amount0Min: 0,
                        amount1Min: 0,
                        deadline: block.timestamp
                }));
                INonfungiblePositionManager(uniswapV3NonfungiblePositionManager).burn(tokenId);
                _mintAndAddNewLiquidityPosition(_pool, _projectId, _projectToken, _terminalToken, currentRulesetTick);
            }
        }        
    }
    
    function _mintAndAddNewLiquidityPosition(address _pool, uint256 _projectId, address _projectToken, address _terminalToken, int24 _currentRulesetTick) internal {
        (address token0, address token1) = _sortTokens(_projectToken, _terminalToken);
        (uint256 amount0, uint256 amount1) = _getAddLiquidityAmounts(_projectId, _projectToken, _terminalToken);
        (uint256 tokenId,,,) = INonfungiblePositionManager(uniswapV3NonfungiblePositionManager).mint(
            INonfungiblePositionManager.MintParams ({
                token0: token0,
                token1: token1,
                fee: uniswapPoolFee,
                tickLower: _currentRulesetTick - (tickRange / 2),
                tickUpper: _currentRulesetTick + (tickRange / 2),
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
        }));
        tokenIdForPool[_pool] = tokenId;
    }

    /// @dev Sort tokens because INonfungiblePositionManager.createAndInitializePoolIfNecessary does not do it for us
    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function _getAddLiquidityAmounts(
        uint256 _projectId,
        address _terminalToken,
        address _projectToken
    ) internal returns (uint256 token0Amount, uint256 token1Amount) {
        uint256 terminalTokenBalance = IERC20(_terminalToken).balanceOf(address(this));
        uint256 projectTokenBalance = IERC20(_projectToken).balanceOf(address(this));
        uint256 terminalTokenBalanceToProjectToken = _getProjectTokensOutForTerminalTokensIn(_projectId, _terminalToken, terminalTokenBalance);
        (address token0, address token1) = _sortTokens(_terminalToken, _projectToken);
        // terminalToken is the limiting amount
        if (terminalTokenBalanceToProjectToken <= projectTokenBalance) {
            return _terminalToken == token0 ? (terminalTokenBalance, terminalTokenBalanceToProjectToken) : (terminalTokenBalanceToProjectToken, terminalTokenBalance);
        // projectToken is the limiting amount
        } else {
            uint256 terminalTokenDownScaled = terminalTokenBalance * projectTokenBalance / terminalTokenBalanceToProjectToken;
            return _terminalToken == token0 ? (terminalTokenDownScaled, projectTokenBalance) : (projectTokenBalance, terminalTokenDownScaled);
        }
    }

    /// @dev `sqrtPriceX96 = sqrt(token1/token0) * (2 ** 96)`
    /// @dev price = token1/token0 = What amount of token1 has equivalent value to 1 token0
    /// @dev See https://ethereum.stackexchange.com/questions/98685/computing-the-uniswap-v3-pair-price-from-q64-96-number
    /// @dev Also see https://blog.uniswap.org/uniswap-v3-math-primer
    function _getSqrtPriceX96ForCurrentJBRulesetPrice(
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
        return uint160(mulDiv(sqrt(token1Amount), 2**96,sqrt(token0Amount)));
    }

    /// @dev Use pricing logic in JBTerminalStore.recordPaymentFrom()
    function _getProjectTokensOutForTerminalTokensIn(
        uint256 _projectId, 
        address _terminalToken,
        uint256 _terminalTokenInAmount
    ) internal view returns (uint256 projectTokenOutAmount) {
        JBRuleset memory ruleset = IJBRulesets(jbRulesets).currentOf(_projectId);
        JBAccountingContext memory context = IJBMultiTerminal(jbMultiTerminal).accountingContextForTokenOf(_projectId, _terminalToken);
        uint32 baseCurrency = ruleset.baseCurrency();

        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBPrices(jbPrices).pricePerUnitOf({
                projectId: _projectId,
                pricingCurrency: context.currency,
                unitCurrency: baseCurrency,
                decimals: context.decimals
            });

        projectTokenOutAmount = mulDiv(_terminalTokenInAmount, ruleset.weight, weightRatio);
    }

    /// @dev Use pricing logic in JBTerminalStore.recordPaymentFrom()
    function _getTerminalTokensOutForProjectTokensIn(
        uint256 _projectId, 
        address _terminalToken, 
        uint256 _projectTokenInAmount
    ) internal view returns (uint256 terminalTokenOutAmount) {
        JBRuleset memory ruleset = IJBRulesets(jbRulesets).currentOf(_projectId);
        JBAccountingContext memory context = IJBMultiTerminal(jbMultiTerminal).accountingContextForTokenOf(_projectId, _terminalToken);
        uint32 baseCurrency = ruleset.baseCurrency();

        uint256 weightRatio = context.currency == baseCurrency
            ? 10 ** context.decimals
            : IJBPrices(jbPrices).pricePerUnitOf({
                projectId: _projectId,
                pricingCurrency: context.currency,
                unitCurrency: baseCurrency,
                decimals: context.decimals
            });
        
        terminalTokenOutAmount = mulDiv(_projectTokenInAmount, weightRatio, ruleset.weight);
    }

    // TODO - What other user features are needed for a good user experience for this?
    // TODO - Collect LP fees (given projectId, terminalToken)
    // TODO - Protected withdraw LP function (with flag to withdraw directly into specified token)
    // TODO - Protected withdraw token function
}

/**
    JBSplitHookContext fields
    ---
    address token; Token sent to split hook
    uint256 amount; Amount sent to split hook
    uint256 decimals;
    uint256 projectId; 
    uint256 groupId; '1' for reserved token, `uint256(uint160(tokenAddress))` for payouts
    JBSplit split;
 */

/**
    JBSplit fields
    ---
    uint32 percent; % of total token amount that split sends
    uint64 projectId;
    address payable beneficiary;
    bool preferAddToBalance; If split were to 'pay' a project through its terminal, indicate if use `addToBalance`
    uint48 lockedUntil; Split cannot be changed until this timestamp, can be increased while a split is locked
    IJBSplitHook hook; The hook contract
 */