// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;
import { IJBSplitHook } from "@bananapus/core/interfaces/IJBSplitHook.sol";

contract UniswapV3LPSplitHook is IJBSplitHook {
    uint256 public number;

    function setNumber(uint256 newNumber) public {
        number = newNumber;
    }

    function increment() public {
        number++;
    }
}
