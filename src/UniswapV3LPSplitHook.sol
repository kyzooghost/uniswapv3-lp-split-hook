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

    /// @dev JBMultiTerminal (used to find JBDirectory and JBTokens)
    /// @dev We assume there a single instance of this contract
    address public immutable jbMultiTerminal;

    /// @dev JBDirectory (to find important control contracts for given projectId)
    address public immutable jbDirectory;

    /// @dev JBTokens (to find project tokens)
    address public immutable jbTokens;

    /// @dev JBRulesets (Stores and manages project rulesets)
    address public immutable jbRulesets;

    /// @dev JBTerminalStore (Stores and manages terminal data)
    address public immutable jbTerminalStore;

    /// @dev JBPrices (Price feeds)
    address public immutable jbPrices;

    /// @dev wETH address
    address public immutable weth;

    /// @dev UniswapV3Factory address
    address public immutable uniswapV3Factory;

    /// @dev UniswapV3 NonFungiblePositionManager address
    address public immutable uniswapV3NonfungiblePositionManager;

    /// @dev Single immutable 'fee' value for all created UniswapV3 pools.
    uint24 public immutable uniswapPoolFee;

    /// @dev Max variance tolerated between current pool LP tick, and current JuiceBox ruleset price
    /// @dev If value is exceeded, then this contract will burn current liquidity and create a new LP position at the current JuiceBox ruleset price
    int24 public immutable maxTickVarianceFromCurrentRulesetPrice;

    /// @dev Tick range to use for UniswapV3 LP position
    int24 public immutable tickRange;

    /// @notice ProjectID => Terminal token => UniswapV3 terminalToken/projectToken pool address
    /// @dev One project has one projectToken, but can have many terminalTokens
    /// @dev The project accepts terminalTokens for payment, and rewards projectTokens
    mapping(uint256 projectId => mapping(address terminalToken => address pool)) public poolOf;

    /// @notice UniswapV3 pool => NonfungiblePosition TokenId representing LP
    /// @dev The contract will only control a single position for a given pool
    mapping(address pool => uint256 poolPositionTokenId) public poolPositionTokenIdOf;

    /// @notice ProjectID => Project token
    mapping(uint256 projectId => address projectToken) public projectTokenOf;

    /// @notice ProjectID => Default terminal token
    /// @dev Default terminal token defined from the first list element of IJBMultiTerminal.accountingContextsOf()
    /// @dev We assume that the list returned by IJBMultiTerminal.accountingContextsOf() is append-only, and is never re-ordered
    mapping(uint256 projectId => address defaultTerminalToken) public defaultTerminalTokenOf;

    /**
    * @param _initialOwner Initial admin of the contract
    * @param _jbMultiTerminal JBMultiTerminal address
    * @param _weth wETH address
    * @param _uniswapV3Factory UniswapV3Factory address
    * @param _uniswapV3NonfungiblePositionManager UniswapV3 NonfungiblePositionManager address
    * @param _uniswapPoolFee Uniswap pool fee (cannot be changed after deployment)
    * @param _maxTickVarianceFromCurrentRulesetPrice Max tolerated variance between LP tick and current JB ruleset price (cannot be changed after deployment)
    * @param _tickRange Uniswap LP tick range (cannot be changed after deployment)
    */
    constructor(
        address _initialOwner,
        address _jbMultiTerminal,
        address _weth,
        address _uniswapV3Factory,
        address _uniswapV3NonfungiblePositionManager,
        uint24 _uniswapPoolFee,
        int24 _maxTickVarianceFromCurrentRulesetPrice,
        int24 _tickRange
    ) 
        Ownable(_initialOwner)
    {
        if (_jbMultiTerminal == address(0)) revert ZeroAddressNotAllowed();
        if (_weth == address(0)) revert ZeroAddressNotAllowed();
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
        // TODO - Input validation of _maxTickVarianceFromCurrentRulesetPrice
        // TODO - Input validation of _tickRange

        jbMultiTerminal = _jbMultiTerminal;
        jbDirectory = _jbDirectory;
        jbRulesets = _jbRulesets;
        jbTokens = _jbTokens;
        jbTerminalStore = _jbTerminalStore;
        jbPrices = _jbPrices;

        weth = _weth;
        uniswapV3Factory = _uniswapV3Factory;
        uniswapV3NonfungiblePositionManager = _uniswapV3NonfungiblePositionManager;
        uniswapPoolFee = _uniswapPoolFee;
        maxTickVarianceFromCurrentRulesetPrice = _maxTickVarianceFromCurrentRulesetPrice;
        tickRange = _tickRange;
    }

    /// @dev Tokens are optimistically transferred to this split hook contract
    /// @param _context The context passed by the JuiceBox terminal/controller to the split hook as a `JBSplitHookContext` struct:
    function processSplitWith(JBSplitHookContext calldata _context) external payable {
        if (address(_context.split.hook) != address(this)) revert NotHookSpecifiedInContext();

        // Validate that msg.sender == Terminal or Controller as per the Directory
        address controller = address(IJBDirectory(jbDirectory).controllerOf(_context.projectId));
        if (controller == address(0)) revert InvalidProjectId();
        if (controller != msg.sender && !IJBDirectory(jbDirectory).isTerminalOf(_context.projectId, IJBTerminal(msg.sender))) revert SplitSenderNotValidControllerOrTerminal();

        // Key trust assumption - If the sender is a verified Terminal or Controller, then we can trust the remaining fields in the _context

        // Reserve split, received project tokens
        if (_context.groupId == 1) _processSplitWithProjectToken(_context);
        // Payout split, received terminal tokens
        else _processSplitWithTerminalToken(_context);

        // TODO Emit event
    }

    /// @param _context The context passed by the JuiceBox terminal/controller to the split hook as a `JBSplitHookContext` struct:
    function _processSplitWithProjectToken(JBSplitHookContext calldata _context) internal {
        address defaultTerminalToken = defaultTerminalTokenOf[_context.projectId];
        if (defaultTerminalToken == address(0)) {
            // Assume that first element of 'accountingContextsOf' contains the default terminal token
            defaultTerminalToken = IJBMultiTerminal(jbMultiTerminal).accountingContextsOf(_context.projectId)[0].token;
        }
        address pool = poolOf[_context.projectId][defaultTerminalToken];
        if (pool == address(0)) _createAndInitializeUniswapV3Pool(_context, _context.token, defaultTerminalToken);
        _rebalanceUniswapV3Pool(_context.projectId, _context.token, defaultTerminalToken, pool);
    }
    
    /// @param _context The context passed by the JuiceBox terminal/controller to the split hook as a `JBSplitHookContext` struct:
    function _processSplitWithTerminalToken(JBSplitHookContext calldata _context) internal {
        // TODO Get projectToken from projectId
        address projectToken;

        address pool = poolOf[_context.projectId][_context.token];
        if (pool == address(0)) _createAndInitializeUniswapV3Pool(_context, projectToken, _context.token);
        _rebalanceUniswapV3Pool(_context.projectId, projectToken, _context.token, pool);

    }

    function _createAndInitializeUniswapV3Pool(JBSplitHookContext calldata _context, address _projectToken, address _terminalToken) internal {
        // TODO Initialize pool price - cast JB price to uint160 sqrtPriceX96
        (address token0, address token1) = _sortTokens(_projectToken, _terminalToken);
        uint160 sqrtPriceX96 = _getSqrtPriceX96ForCurrentJBRulesetPrice(_context.projectId, _projectToken, _terminalToken);
        // Create new UniswapV3 pool
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
        uint256 tokenId = poolPositionTokenIdOf[_pool];
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
        poolPositionTokenIdOf[_pool] = tokenId;
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

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IUniswapV3LPSplitHook).interfaceId
            || interfaceId == type(IJBSplitHook).interfaceId;
    }
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