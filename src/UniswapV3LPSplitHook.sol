// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;
import { IJBSplitHook } from "@bananapus/core/interfaces/IJBSplitHook.sol";
import { JBSplitHookContext } from "@bananapus/core/structs/JBSplitHookContext.sol";

contract UniswapV3LPSplitHook is IJBSplitHook {
    /// @notice If a split has a split hook, payment terminals and controllers call this function while processing the
    /// split.
    /// @dev Critical business logic should be protected by appropriate access control. The tokens and/or native tokens
    /// are optimistically transferred to the split hook when this function is called.
    /// @param context The context passed by the terminal/controller to the split hook as a `JBSplitHookContext` struct:
    function processSplitWith(JBSplitHookContext calldata context) external payable {

    }

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IJBSplitHook).interfaceId;
    }

}
