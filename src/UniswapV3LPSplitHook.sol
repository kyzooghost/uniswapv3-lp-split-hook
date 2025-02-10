// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;
import { IJBController } from "@bananapus/core/interfaces/IJBController.sol";
import { IJBDirectory } from "@bananapus/core/interfaces/IJBDirectory.sol";
import { IJBMultiTerminal } from "@bananapus/core/interfaces/IJBMultiTerminal.sol";
import { IJBRulesets } from "@bananapus/core/interfaces/IJBRulesets.sol";

import { IJBSplitHook } from "@bananapus/core/interfaces/IJBSplitHook.sol";
import { IJBTerminal } from "@bananapus/core/interfaces/IJBTerminal.sol";
import { IJBTerminalStore } from "@bananapus/core/interfaces/IJBTerminalStore.sol";
import { IJBPrices } from "@bananapus/core/interfaces/IJBPrices.sol";

import { JBSplitHookContext } from "@bananapus/core/structs/JBSplitHookContext.sol";
import { JBAccountingContext } from "@bananapus/core/structs/JBAccountingContext.sol";
import { JBRuleset } from "@bananapus/core/structs/JBRuleset.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IUniswapV3LPSplitHook } from "./interfaces/IUniswapV3LPSplitHook.sol";
import { IUniswapV3Factory } from "@uniswap/v3-core/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/interfaces/IUniswapV3Pool.sol";
import { INonfungiblePositionManager } from "@uniswap/v3-periphery-flattened/INonfungiblePositionManager.sol";
import { mulDiv } from "@prb/math/src/Common.sol";

import { JBRulesetMetadataResolver } from "@bananapus/core/libraries/JBRulesetMetadataResolver.sol";
/**
 * @title UniswapV3LPSplitHook
 * @notice JuiceBox v4 Split Hook contract that converts the received split into a Uniswap V3 ETH/Token LP
 * @dev This contract assumes that it is the creator of the terminalToken/projectToken UniswapV3 pool
 * @dev This contract greedily assumes that any tokens it holds can be used to add to a UniswapV3 LP position. 
 * @dev Please withdraw the token/s if you don't want them to be added to a UniswapV3 LP position in the future.
 * @dev This contract uses the UniswapV3 NonfungiblePositionManager as a standard abstraction for a pool position.
 * @dev For any given UniswapV3 pool, this contract will only control at most one single LP position
 */
contract UniswapV3LPSplitHook is IUniswapV3LPSplitHook, IJBSplitHook, Ownable {
    using JBRulesetMetadataResolver for JBRuleset;

    /// @dev JBDirectory (to find important control contracts for given projectId)
    address public immutable jbDirectory;

    /// @dev JBMultiTerminal (assume there is a singleton instance on the chain, and use to find JBDirectory and JBTokens)
    address public immutable jbMultiTerminal;

    /// @dev JBTokens (to find project tokens)
    address public immutable jbTokens;

    /// @dev JBRulesets (The contract storing and managing project rulesets)
    address public immutable jbRulesets;

    /// @dev JBTerminalStore (The contract that stores and manages the terminal's data)
    address public immutable jbTerminalStore;

    /// @dev JBPrices (The contract that exposes price feeds)
    address public immutable jbPrices;

    /// @dev wETH address
    address public immutable weth;

    /// @dev UniswapV3Factory address
    address public immutable uniswapV3Factory;

    /// @dev UniswapV3Factory address
    address public immutable uniswapV3NonfungiblePositionManager;

    /// @dev UniswapV3 pool fee for all created Uniswap V3 pools, 
    /// @dev 3000 => 0.3%
    uint24 public immutable uniswapPoolFee;

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
    */
    constructor(
        address _initialOwner,
        address _jbMultiTerminal,
        address _weth,
        address _uniswapV3Factory,
        address _uniswapV3NonfungiblePositionManager,
        uint24 _uniswapPoolFee
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
        _rebalanceUniswapV3Pool(_context.projectId, defaultTerminalToken, pool);
    }
    
    /// @param _context The context passed by the JuiceBox terminal/controller to the split hook as a `JBSplitHookContext` struct:
    function _processSplitWithTerminalToken(JBSplitHookContext calldata _context) internal {
        // TODO Get from projectId
        address projectToken;

        address pool = poolOf[_context.projectId][_context.token];
        if (pool == address(0)) _createAndInitializeUniswapV3Pool(_context, projectToken, _context.token);
        _rebalanceUniswapV3Pool(_context.projectId, _context.token, pool);

    }

    function _createAndInitializeUniswapV3Pool(JBSplitHookContext calldata _context, address _projectToken, address _terminalToken) internal {
        // TODO Initialize pool price - cast JB price to uint160 sqrtPriceX96
        uint160 sqrtPriceX96;
        // Create new UniswapV3 pool
        address newPool = INonfungiblePositionManager(uniswapV3NonfungiblePositionManager).createAndInitializePoolIfNecessary(_projectToken, _terminalToken, uniswapPoolFee, sqrtPriceX96);
        poolOf[_context.projectId][_terminalToken] = newPool;
        // TODO - Emit event
    }

    function _rebalanceUniswapV3Pool(uint256 _projectId, address _terminalToken, address _pool) internal {
        uint256 tokenId = poolPositionTokenIdOf[_pool];
        // No current position, mint and add liquidity
        if (tokenId == 0) {
            // TODO - INonfungiblePositionManager(uniswapV3NonfungiblePositionManager).mint()
        // Current position => Collect fees
        } else {
            // TODO Collect fees - INonfungiblePositionManager(uniswapV3NonfungiblePositionManager).collect()
            // TODO Check if current project ruleset price is within current tick range of pool position
            // TODO True => Add all available liquidity at current project price
            // TODO False => Withdraw all current liquidity (decreaseLiquidity + burn) -> mint new position
            //      - Inefficiency in that we could remember and later reuse old liquidity position, rather than burning
        }        
    }

    /// @dev Use pricing logic in JBTerminalStore.recordPaymentFrom()
    function _getProjectTokensOutForTerminalTokensIn(
        uint256 _projectId, 
        address _terminalToken, 
        uint256 _reserveTokenInAmount
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

        terminalTokenOutAmount = mulDiv(_reserveTokenInAmount, ruleset.weight, weightRatio);
    }

    /// @dev Use pricing logic in JBTerminalStore.recordPaymentFrom()
    function _getTerminalTokensOutForProjectTokensIn(
        uint256 _projectId, 
        address _terminalToken, 
        uint256 _terminalTokenInAmount
    ) internal view returns (uint256 reserveTokenOutAmount) {
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
        
        reserveTokenOutAmount = mulDiv(_terminalTokenInAmount, weightRatio, ruleset.weight);
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