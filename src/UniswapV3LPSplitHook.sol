// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;
import { IJBController } from "@bananapus/core/interfaces/IJBController.sol";
import { IJBDirectory } from "@bananapus/core/interfaces/IJBDirectory.sol";
import { IJBMultiTerminal } from "@bananapus/core/interfaces/IJBMultiTerminal.sol";
import { IJBSplitHook } from "@bananapus/core/interfaces/IJBSplitHook.sol";
import { IJBTerminal } from "@bananapus/core/interfaces/IJBTerminal.sol";
import { JBSplitHookContext } from "@bananapus/core/structs/JBSplitHookContext.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IUniswapV3LPSplitHook } from "./interfaces/IUniswapV3LPSplitHook.sol";
import { IUniswapV3Factory } from "@uniswap/v3-core/interfaces/IUniswapV3Factory.sol";

/**
 * @title UniswapV3LPSplitHook
 * @notice JuiceBox v4 Split Hook contract that converts the received split into a Uniswap V3 ETH/Token LP
 * @dev This contract assumes that it is the creator of the terminalToken/projectToken LP
 */
contract UniswapV3LPSplitHook is IUniswapV3LPSplitHook, IJBSplitHook, Ownable {
    /// @dev JBDirectory (to find important control contracts for given projectId)
    address public immutable jbDirectory;

    /// @dev JBMultiTerminal (assume there is a singleton instance on the chain, and use to find JBDirectory and JBTokens)
    address public immutable jbMultiTerminal;

    /// @dev JBTokens (to find project tokens)
    address public immutable jbTokens;

    /// @dev wETH address
    address public immutable weth;

    /// @dev UniswapV3Factory address
    address public immutable uniswapV3Factory;

    /// @dev UniswapV3 pool fee for all created Uniswap V3 pools, 
    uint256 public immutable uniswapPoolFee;

    /// @notice ProjectID => Terminal token => UniswapV3 terminalToken/projectToken pool address
    mapping(uint256 projectId => mapping(address terminalToken => address pool)) public poolOf;

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
    */
    constructor(
        address _initialOwner,
        address _jbMultiTerminal,
        address _weth,
        address _uniswapV3Factory
    ) 
        Ownable(_initialOwner)
    {
        if (_jbMultiTerminal == address(0)) revert ZeroAddressNotAllowed();
        if (_weth == address(0)) revert ZeroAddressNotAllowed();
        if (_uniswapV3Factory == address(0)) revert ZeroAddressNotAllowed();
        address _jbDirectory = address(IJBMultiTerminal(_jbMultiTerminal).DIRECTORY());
        if (_jbDirectory == address(0)) revert ZeroAddressNotAllowed();
        address _jbTokens = address(IJBMultiTerminal(_jbMultiTerminal).TOKENS());
        
        jbMultiTerminal = _jbMultiTerminal;
        jbDirectory = _jbDirectory;
        weth = _weth;
        uniswapV3Factory = _uniswapV3Factory;
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
            // defaultTerminalToken = 
        }
        // Get default terminal token
        // Does pool exist?
        // No -> Create pool, add 50:50 LP at current project price
        // Yes -> Do swap, rebalance pool at current project prize
        // Do swap
        // Add to LP
    }
    
    /// @param _context The context passed by the JuiceBox terminal/controller to the split hook as a `JBSplitHookContext` struct:
    function _processSplitWithTerminalToken(JBSplitHookContext calldata _context) internal {}

    // TODO - What other user features are needed for a good user experience for this?
    // ? Harvest LP fees - but what does LP fee accrue in?
    // ? Withdraw LP into terminal token or project token

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