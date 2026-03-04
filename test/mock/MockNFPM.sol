// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery-flattened/INonfungiblePositionManager.sol";
import {MockWETH} from "./MockWETH.sol";

/// @notice Mock NonfungiblePositionManager for testing UniV3DeploymentSplitHook
/// @dev Simulates mint/collect/decreaseLiquidity/burn operations
contract MockNFPM {
    address public immutable WETH9;
    address public immutable factory;

    uint256 private _nextTokenId = 1;

    // Configurable usage percent (how much of desired amounts are used in mint)
    // Default 100% = 10000 bps
    uint256 public usagePercent = 10000;

    struct Position {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bool exists;
    }

    mapping(uint256 tokenId => Position) public _positions;

    // Pre-configured collectable fees per tokenId
    mapping(uint256 tokenId => uint256 amount0) public collectableAmount0;
    mapping(uint256 tokenId => uint256 amount1) public collectableAmount1;

    // Pre-configured decrease liquidity return amounts
    mapping(uint256 tokenId => uint256 amount0) public decreaseAmount0;
    mapping(uint256 tokenId => uint256 amount1) public decreaseAmount1;

    // Created pools
    mapping(bytes32 => address) public createdPools;

    // Track calls for verification
    uint256 public mintCallCount;
    uint256 public collectCallCount;
    uint256 public decreaseLiquidityCallCount;
    uint256 public burnCallCount;
    uint256 public lastMintTokenId;

    constructor(address weth, address _factory) {
        WETH9 = weth;
        factory = _factory;
    }

    function setUsagePercent(uint256 percent) external {
        usagePercent = percent;
    }

    function setCollectableFees(uint256 tokenId, uint256 amount0, uint256 amount1) external {
        collectableAmount0[tokenId] = amount0;
        collectableAmount1[tokenId] = amount1;
    }

    function setDecreaseLiquidityAmounts(uint256 tokenId, uint256 amount0, uint256 amount1) external {
        decreaseAmount0[tokenId] = amount0;
        decreaseAmount1[tokenId] = amount1;
    }

    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 /* sqrtPriceX96 */
    ) external payable returns (address pool) {
        bytes32 poolKey = keccak256(abi.encodePacked(token0, token1, fee));
        pool = createdPools[poolKey];
        if (pool == address(0)) {
            // Create a deterministic "pool" address
            pool = address(uint160(uint256(poolKey)));
            createdPools[poolKey] = pool;
        }
        return pool;
    }

    function getPool(address token0, address token1, uint24 fee) external view returns (address) {
        bytes32 poolKey = keccak256(abi.encodePacked(token0, token1, fee));
        return createdPools[poolKey];
    }

    function mint(INonfungiblePositionManager.MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        mintCallCount++;
        tokenId = _nextTokenId++;
        lastMintTokenId = tokenId;

        // Calculate amounts used based on usagePercent
        amount0 = (params.amount0Desired * usagePercent) / 10000;
        amount1 = (params.amount1Desired * usagePercent) / 10000;

        // Handle native ETH sent as msg.value — wrap to WETH like the real NFPM does
        if (msg.value > 0) {
            MockWETH(payable(WETH9)).deposit{value: msg.value}();
        }

        // Transfer tokens from caller (skip WETH transferFrom when msg.value covered it)
        if (amount0 > 0) {
            if (params.token0 == WETH9 && msg.value >= amount0) {
                // Already have WETH from deposit above
            } else {
                IERC20(params.token0).transferFrom(msg.sender, address(this), amount0);
            }
        }
        if (amount1 > 0) {
            if (params.token1 == WETH9 && msg.value >= amount1) {
                // Already have WETH from deposit above
            } else {
                IERC20(params.token1).transferFrom(msg.sender, address(this), amount1);
            }
        }

        liquidity = uint128(amount0 + amount1); // Simplified liquidity

        _positions[tokenId] = Position({
            token0: params.token0,
            token1: params.token1,
            fee: params.fee,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: liquidity,
            exists: true
        });

        return (tokenId, liquidity, amount0, amount1);
    }

    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1)
    {
        collectCallCount++;

        amount0 = collectableAmount0[params.tokenId];
        amount1 = collectableAmount1[params.tokenId];

        // Cap to max requested
        if (amount0 > params.amount0Max) amount0 = params.amount0Max;
        if (amount1 > params.amount1Max) amount1 = params.amount1Max;

        // Transfer collected fees to recipient
        Position memory pos = _positions[params.tokenId];
        if (pos.exists) {
            if (amount0 > 0 && IERC20(pos.token0).balanceOf(address(this)) >= amount0) {
                IERC20(pos.token0).transfer(params.recipient, amount0);
            }
            if (amount1 > 0 && IERC20(pos.token1).balanceOf(address(this)) >= amount1) {
                IERC20(pos.token1).transfer(params.recipient, amount1);
            }
        }

        // Clear collected amounts
        collectableAmount0[params.tokenId] = 0;
        collectableAmount1[params.tokenId] = 0;

        return (amount0, amount1);
    }

    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1)
    {
        decreaseLiquidityCallCount++;

        Position storage pos = _positions[params.tokenId];
        require(pos.exists, "Position does not exist");

        amount0 = decreaseAmount0[params.tokenId];
        amount1 = decreaseAmount1[params.tokenId];

        // If no pre-configured amounts, calculate from liquidity
        if (amount0 == 0 && amount1 == 0) {
            // Simple proportional calculation
            amount0 = uint256(params.liquidity) / 2;
            amount1 = uint256(params.liquidity) / 2;
        }

        // Decrease tracked liquidity
        if (params.liquidity >= pos.liquidity) {
            pos.liquidity = 0;
        } else {
            pos.liquidity -= params.liquidity;
        }

        // Make these amounts collectable on next collect call
        collectableAmount0[params.tokenId] += amount0;
        collectableAmount1[params.tokenId] += amount1;

        return (amount0, amount1);
    }

    function burn(uint256 tokenId) external payable {
        burnCallCount++;
        require(_positions[tokenId].exists, "Position does not exist");
        require(_positions[tokenId].liquidity == 0, "Position has liquidity");
        delete _positions[tokenId];
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        Position memory pos = _positions[tokenId];
        return (
            0, // nonce
            address(0), // operator
            pos.token0,
            pos.token1,
            pos.fee,
            pos.tickLower,
            pos.tickUpper,
            pos.liquidity,
            0, // feeGrowthInside0LastX128
            0, // feeGrowthInside1LastX128
            0, // tokensOwed0
            0  // tokensOwed1
        );
    }

    function unwrapWETH9(uint256 amountMinimum, address recipient) external payable {
        uint256 wethBalance = IERC20(WETH9).balanceOf(address(this));
        require(wethBalance >= amountMinimum, "Insufficient WETH9");

        MockWETH(payable(WETH9)).withdraw(amountMinimum);
        (bool success,) = recipient.call{value: amountMinimum}("");
        require(success, "ETH transfer failed");
    }

    // Accept ETH from WETH withdraw
    receive() external payable {}
}
