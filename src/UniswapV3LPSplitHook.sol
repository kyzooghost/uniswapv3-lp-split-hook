// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;
import { IJBController } from "@bananapus/core/interfaces/IJBController.sol";
import { IJBDirectory } from "@bananapus/core/interfaces/IJBDirectory.sol";
import { IJBSplitHook } from "@bananapus/core/interfaces/IJBSplitHook.sol";
import { IJBTerminal } from "@bananapus/core/interfaces/IJBTerminal.sol";
import { JBSplitHookContext } from "@bananapus/core/structs/JBSplitHookContext.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IUniswapV3LPSplitHook } from "./interfaces/IUniswapV3LPSplitHook.sol";

// TODO - Register pool to use, if no pool registered then do nothing

/**
 * @title UniswapV3LPSplitHook
 * @notice JuiceBox v4 Split Hook contract that converts the received split into a Uniswap V3 ETH/Token LP
 */
contract UniswapV3LPSplitHook is IUniswapV3LPSplitHook, IJBSplitHook {
    // Do I need access control?

    /// @dev JuiceBox v4 Directory (to find important control contracts for given projectId)
    address public immutable jbDirectory;

    /// @dev wETH address
    address public immutable weth;

    /// @dev UniswapV3Factory address
    address public immutable uniswapV3Factory;

    /**
    * @param _jbDirectory JuiceBox v4 Directory address
    * @param _weth wETH address
    * @param _uniswapV3Factory UniswapV3Factory address
    */
    constructor(
        address _jbDirectory,
        address _weth,
        address _uniswapV3Factory
    ) {
        if (_jbDirectory == address(0)) revert ZeroAddressNotAllowed();
        if (_weth == address(0)) revert ZeroAddressNotAllowed();
        if (_uniswapV3Factory == address(0)) revert ZeroAddressNotAllowed();
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

        // Validate that token has an ETH/token LP in Uniswap V3


        // Action
            // Add to Uniswap Token/ETH liquidity?
            // Do what with this LP?

        // State changes
    }

    // TODO - What other user features are needed for a good user experience for this?

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