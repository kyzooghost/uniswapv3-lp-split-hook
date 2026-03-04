// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {MockERC20} from "./MockERC20.sol";

contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    function deposit() external payable {
        MockERC20(this).mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        MockERC20(this).burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "WETH: ETH transfer failed");
    }

    receive() external payable {
        MockERC20(this).mint(msg.sender, msg.value);
    }
}
