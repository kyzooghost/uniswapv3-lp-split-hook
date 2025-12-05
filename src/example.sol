// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// WETH interface for wrapping/unwrapping
interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
}
// Uniswap v3 interfaces
import {IUniswapV3Factory} from "./interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "../lib/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";

// v3 oracle data is read via interface calls, no library imports needed

// Import Oracle library for TWAP
import {Oracle} from "./libraries/Oracle.sol";

// Import Juicebox protocol interfaces
import {IJBTokens} from "@bananapus/core-v5/interfaces/IJBTokens.sol";
import {IJBToken} from "@bananapus/core-v5/interfaces/IJBToken.sol";
import {IJBDirectory} from "@bananapus/core-v5/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v5/interfaces/IJBMultiTerminal.sol";
import {IJBController} from "@bananapus/core-v5/interfaces/IJBController.sol";
import {IJBTerminal} from "@bananapus/core-v5/interfaces/IJBTerminal.sol";

import {IJBPrices} from "@bananapus/core-v5/interfaces/IJBPrices.sol";
import {IJBTerminalStore} from "@bananapus/core-v5/interfaces/IJBTerminalStore.sol";

import {JBRuleset} from "@bananapus/core-v5/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v5/structs/JBRulesetMetadata.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v5/libraries/JBRulesetMetadataResolver.sol";
import {JBConstants} from "@bananapus/core-v5/libraries/JBConstants.sol";

// Import PRB Math for logarithmic functions
import {UD60x18} from "../lib/prb-math/src/ud60x18/ValueType.sol";
import {log2} from "../lib/prb-math/src/ud60x18/Math.sol";

/// @title JBUniswapV4Hook
/// @notice Official Juicebox integration for Uniswap v4 that provides intelligent price comparison and optimal routing
/// @dev This hook compares prices between Uniswap V4 pools, Uniswap V3 pools, and Juicebox projects, then routes to the option
///      that gives users the most tokens. It uses TWAP (Time-Weighted Average Price) oracles to protect against manipulation.
///      The route with the highest expected output is automatically selected.
contract JBUniswapV4Hook is BaseHook, IUniswapV3SwapCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;
    using Oracle for Oracle.Observation[65535];

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Reverts when an exact-output swap is attempted
    /// @dev Only exact-input swaps are supported
    error JBUniswapV4Hook_ExactOutputSwapsNotSupported();

    /// @notice Reverts when secondsAgo is zero in _consult()
    error JBUniswapV4Hook_SecondsAgoCannotBeZero();

    /// @notice Reverts when observation cardinality is zero
    error JBUniswapV4Hook_ObservationCardinalityZero();

    /// @notice Reverts when v3 pool is not found
    error JBUniswapV4Hook_V3PoolNotFound();

    /// @notice Reverts when v3 pool is locked
    error JBUniswapV4Hook_V3PoolLocked();

    /// @notice Reverts when swap callback has no valid swap (both deltas <= 0)
    error JBUniswapV4Hook_NoSwap();

    /// @notice Reverts when swap callback is called from invalid sender
    error JBUniswapV4Hook_InvalidCallback();

    //*********************************************************************//
    // ---------------------------- structs ------------------------------ //
    //*********************************************************************//

    /// @notice Tracks the oracle observation state for a pool
    /// @custom:member index The index of the last written observation for the pool
    /// @custom:member cardinality The cardinality of the observations array for the pool
    /// @custom:member cardinalityNext The cardinality target of the observations array for the pool
    struct ObservationState {
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityNext;
    }

    //*********************************************************************//
    // --------------------- immutable properties  ----------------------- //
    //*********************************************************************//

    /// @notice The Juicebox tokens contract for project token lookup
    IJBTokens public immutable TOKENS;

    /// @notice The Juicebox directory for terminal lookup
    IJBDirectory public immutable DIRECTORY;

    /// @notice The Juicebox controller for ruleset information
    IJBController public immutable CONTROLLER;

    /// @notice The Juicebox prices contract for currency conversion
    IJBPrices public immutable PRICES;

    /// @notice The Juicebox terminal store for getting reclaimable surplus
    IJBTerminalStore public immutable TERMINAL_STORE;

    /// @notice The Uniswap v3 factory for v3 pool lookups
    IUniswapV3Factory public immutable V3_FACTORY;

    /// @notice Native ETH address representation
    address public constant UNISWAP_NATIVE_ETH = address(0);

    /// @notice Juicebox native token address
    address public constant JB_NATIVE_TOKEN = address(0x000000000000000000000000000000000000EEEe);

    /// @notice Wrapped native ETH address for the current chain. Treated as native ETH for pricing.
    address public immutable WETH;

    /// @notice TWAP period in seconds (30 minutes by default)
    uint32 public constant TWAP_PERIOD = 1800;

    /// @notice Standard TWAP window in seconds (1 hour by default)
    uint256 public constant STANDARD_TWAP_WINDOW = 1 hours;

    /// @notice Uniswap v3 sqrt price bounds used when routing via v3 pools
    uint160 internal constant V3_MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant V3_MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    /// @notice The denominator used when calculating TWAP slippage percent values.
    uint256 public constant TWAP_SLIPPAGE_DENOMINATOR = 10_000;

    /// @notice The uncertain slippage tolerance allowed.
    uint256 public constant UNCERTAIN_TWAP_SLIPPAGE_TOLERANCE = 1050;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The list of observations for a given pool ID
    mapping(PoolId => Oracle.Observation[65535]) public observations;

    /// @notice The current observation array state for the given pool ID
    mapping(PoolId => ObservationState) public states;

    //*********************************************************************//
    // ---------------------------- events ------------------------------- //
    //*********************************************************************//

    /// @notice Emitted when a routing decision is made
    event RouteSelected(PoolId indexed poolId, bool useJuicebox, uint256 expectedTokens);

    /// @notice Emitted when the best route is selected among v3, v4, and Juicebox
    event BestRouteSelected(
        PoolId indexed poolId,
        string routeType, // "v3", "v4", or "juicebox"
        uint256 expectedTokens
    );

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param poolManager The Uniswap v4 pool manager
    /// @param tokens The Juicebox tokens contract
    /// @param directory The Juicebox directory
    /// @param controller The Juicebox controller
    /// @param prices The Juicebox prices contract for currency conversion
    /// @param terminalStore The Juicebox terminal store for getting reclaimable surplus
    /// @param v3Factory The Uniswap v3 factory for v3 pool lookups
    /// @param wrappedNativeEth The wrapped native ETH address for the current chain (e.g., WETH9 on mainnet, WETH on Base)
    constructor(
        IPoolManager poolManager,
        IJBTokens tokens,
        IJBDirectory directory,
        IJBController controller,
        IJBPrices prices,
        IJBTerminalStore terminalStore,
        IUniswapV3Factory v3Factory,
        address wrappedNativeEth
    ) BaseHook(poolManager) {
        TOKENS = tokens;
        DIRECTORY = directory;
        CONTROLLER = controller;
        PRICES = prices;
        TERMINAL_STORE = terminalStore;
        V3_FACTORY = v3Factory;
        WETH = wrappedNativeEth;
    }

    /// @notice Receive function to accept ETH
    receive() external payable {}

    //*********************************************************************//
    // ------------------------- public views ---------------------------- //
    //*********************************************************************//

    /// @notice Get the hook permissions for Uniswap v4
    /// @return permissions The hook permissions struct
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true, // Initialize oracle observations
            beforeAddLiquidity: false,
            afterAddLiquidity: true, // Record oracle observations
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true, // Record oracle observations
            beforeSwap: true,
            afterSwap: true, // Record oracle observations
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // Enable to override swap behavior
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Calculate expected tokens for a given payment amount in any currency
    /// @param projectId The Juicebox project ID
    /// @param paymentToken The token being used for payment
    /// @param paymentAmount The amount being paid (in the token's native decimals)
    /// @return expectedTokens The expected number of tokens to be received
    function calculateExpectedTokensWithCurrency(uint256 projectId, address paymentToken, uint256 paymentAmount)
        public
        view
        returns (uint256 expectedTokens)
    {
        // Get the project's weight (tokens per ETH) and reserved rate
        uint256 tokensPerBaseCurrency;
        // Get the currency Id for the `weight`.
        uint256 baseCurrency;
        uint16 reservedPercent;
        try CONTROLLER.currentRulesetOf(
            projectId
        ) returns (JBRuleset memory ruleset, JBRulesetMetadata memory metadata) {
            tokensPerBaseCurrency = ruleset.weight;
            baseCurrency = metadata.baseCurrency;
            // Get reserved percent from ruleset metadata
            reservedPercent = JBRulesetMetadataResolver.reservedPercent(ruleset);
        } catch {
            return 0;
        }

        // Normalize payment token to Juicebox's native token representation
        paymentToken = _normalizeToken(paymentToken);

        // Get the currency ID and decimals for the payment token
        uint32 paymentCurrencyId = uint32(uint160(paymentToken));
        uint8 paymentTokenDecimals = _getTokenDecimals(paymentToken);

        // Get the price: how much baseCurrency per 1 unit of payment token
        // pricePerUnitOf returns the pricingCurrency cost for one unit of unitCurrency
        // So: pricePerUnitOf(projectId, baseCurrency, paymentCurrencyId, 18) returns baseCurrency cost for 1 unit of paymentCurrencyId
        // The result is scaled by 10^decimals (18 in this case)
        uint256 baseCurrencyPerPaymentToken;
        // If payment currency is the same as base currency, use 1:1 conversion
        // Special case: JB_NATIVE_TOKEN (0xEEEe) represents ETH, same as baseCurrency = 1
        // Since paymentToken is already converted to JB_NATIVE_TOKEN if it was address(0),
        // we need to check if both represent ETH (paymentToken == JB_NATIVE_TOKEN && baseCurrency == 1)
        // OR if the currency IDs match (paymentCurrencyId == baseCurrency)
        if (paymentCurrencyId == baseCurrency) {
            // Same currency IDs - direct match
            baseCurrencyPerPaymentToken = 1e18;
        } else if (paymentToken == JB_NATIVE_TOKEN && baseCurrency == 1) {
            // Both represent ETH but have different IDs (0xeeee vs 1)
            baseCurrencyPerPaymentToken = 1e18;
        } else {
            // Different currencies - need price conversion
            try PRICES.pricePerUnitOf(projectId, baseCurrency, paymentCurrencyId, 18) returns (uint256 price) {
                baseCurrencyPerPaymentToken = price;
            } catch {
                return 0;
            }
        }

        // Calculate tokens based on the payment amount and weight.
        // Implementation details:
        // 1. paymentAmount is first normalized to 18 decimals.
        // 2. We compute: baseTokens = (tokensPerBaseCurrency * paymentAmount18) / 1e18.
        // 3. If baseCurrencyPerPaymentToken != 1e18, we then scale baseTokens by that rate (again / 1e18).
        // See _calculateTokensWithCurrency() for the exact math.
        uint256 estimatedTokens = _calculateTokensWithCurrency(
            tokensPerBaseCurrency, paymentAmount, paymentTokenDecimals, baseCurrencyPerPaymentToken
        );

        // Apply reserved rate: beneficiary only receives (1 - reservedPercent) of tokens
        // Reserved tokens go to team/contributors, not to the payer
        // Formula: actualTokens = estimatedTokens * (MAX_RESERVED_PERCENT - reservedPercent) / MAX_RESERVED_PERCENT
        if (reservedPercent > 0) {
            expectedTokens = FullMath.mulDiv(
                estimatedTokens,
                uint256(JBConstants.MAX_RESERVED_PERCENT - reservedPercent),
                uint256(JBConstants.MAX_RESERVED_PERCENT)
            );
        } else {
            expectedTokens = estimatedTokens;
        }
    }

    /// @notice Calculate expected output from selling JB tokens
    /// @param projectId The Juicebox project ID
    /// @param tokenAmountIn The amount of JB tokens being sold
    /// @param outputToken The token to receive (e.g., ETH, USDC)
    /// @return expectedOutput The expected amount of output tokens received
    function calculateExpectedOutputFromSelling(uint256 projectId, uint256 tokenAmountIn, address outputToken)
        public
        view
        returns (uint256 expectedOutput)
    {
        // Normalize output token to Juicebox's native token representation
        outputToken = _normalizeToken(outputToken);

        // Get the current reclaimable surplus for the project
        // This represents how much value can be reclaimed for the given token amount
        return TERMINAL_STORE.currentReclaimableSurplusOf(
            projectId,
            tokenAmountIn,
            uint32(uint160(outputToken)), // the currency id of the output token
            _getTokenDecimals(outputToken)
        );
    }

    /// @notice Estimate expected output tokens from a Uniswap swap using TWAP
    /// @dev Uses time-weighted average price to prevent manipulation
    /// @param poolId The pool ID
    /// @param key The pool key
    /// @param amountIn The input amount
    /// @param zeroForOne Whether swapping token0 for token1
    /// @return estimatedOut The estimated output amount
    function estimateUniswapOutput(PoolId poolId, PoolKey memory key, uint256 amountIn, bool zeroForOne)
        public
        view
        returns (uint256 estimatedOut)
    {
        // Get TWAP price instead of spot price to prevent manipulation
        uint160 sqrtPriceX96TWAP = _getTWAPSqrtPrice(poolId);

        // If TWAP is not available (not enough observations), fallback to spot price
        if (sqrtPriceX96TWAP == 0) {
            (sqrtPriceX96TWAP,,,) = poolManager.getSlot0(poolId);
        }

        // Calculate Q192 = 2^192
        uint256 Q192 = uint256(FixedPoint96.Q96) * FixedPoint96.Q96;
        uint256 priceSquared = uint256(sqrtPriceX96TWAP) * sqrtPriceX96TWAP;

        if (zeroForOne) {
            // Selling token0 for token1
            // price = token1/token0 = priceSquared / Q192
            // estimatedOut = amountIn * price
            estimatedOut = FullMath.mulDiv(amountIn, priceSquared, Q192);
        } else {
            // Selling token1 for token0
            // price = token0/token1 = Q192 / priceSquared
            // estimatedOut = amountIn * price
            estimatedOut = FullMath.mulDiv(amountIn, Q192, priceSquared);
        }

        // Apply fee from pool key
        // fee is in hundredths of a bip, so 3000 = 0.3%
        if (key.fee > 0) {
            estimatedOut = estimatedOut - FullMath.mulDiv(estimatedOut, key.fee, 1000000);
        }

        return estimatedOut;
    }

    /// @notice Observe TWAP tick
    /// @param poolId The pool ID
    /// @param secondsAgo Seconds in the past to calculate TWAP from
    /// @param tick Current tick
    /// @param index Current observation index
    /// @param liquidity Current liquidity
    /// @param cardinality Current cardinality
    /// @return arithmeticMeanTick The time-weighted average tick
    function observeTWAP(
        PoolId poolId,
        uint32 secondsAgo,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    ) external view returns (int24 arithmeticMeanTick) {
        if (secondsAgo == 0) {
            revert JBUniswapV4Hook_SecondsAgoCannotBeZero();
        }

        uint32 currentTime = uint32(block.timestamp);

        // Get tick cumulative for current time
        (int48 tickCumulativeCurrent,) =
            observations[poolId].observeSingle(currentTime, 0, tick, index, liquidity, cardinality);

        // Get tick cumulative for secondsAgo
        (int48 tickCumulativePast,) =
            observations[poolId].observeSingle(currentTime, secondsAgo, tick, index, liquidity, cardinality);

        // Calculate arithmetic mean tick
        arithmeticMeanTick = int24(
            (tickCumulativeCurrent - tickCumulativePast) / int48(uint48(secondsAgo))
        );
    }

    /// @notice Estimate expected output tokens from a Uniswap v3 swap using TWAP
    /// @dev Uses sophisticated TWAP calculation with slippage protection
    /// @param token0 First token in the pair
    /// @param token1 Second token in the pair
    /// @param amountIn The input amount
    /// @param zeroForOne Whether swapping token0 for token1
    /// @return estimatedOut The estimated output amount
    function estimateUniswapV3Output(address token0, address token1, uint256 amountIn, bool zeroForOne)
        external
        view
        returns (uint256 estimatedOut)
    {
        // Use _getQuote which handles the factory call internally
        // For _getQuote: (projectToken, amountIn, terminalToken) -> amountOut
        // When zeroForOne=true: swapping token0->token1, so token0 is input, token1 is output
        //   We want: how many token1 do we get for token0? So projectToken=token1, terminalToken=token0
        // When zeroForOne=false: swapping token1->token0, so token1 is input, token0 is output
        //   We want: how many token0 do we get for token1? So projectToken=token0, terminalToken=token1
        address inputToken = zeroForOne ? token0 : token1;
        address outputToken = zeroForOne ? token1 : token0;
        estimatedOut = _getQuote(outputToken, amountIn, inputToken);
        return estimatedOut;
    }

    /// @notice Get a quote based on the TWAP, using the standard TWAP window and slippage tolerance.
    /// @param projectToken The token being received (quote token).
    /// @param amountIn The number of terminal tokens being used to swap.
    /// @param terminalToken The token being paid in (base token).
    /// @return amountOut The minimum number of tokens to receive based on the TWAP and its params.
    function _getQuote(address projectToken, uint256 amountIn, address terminalToken)
        internal
        view
        returns (uint256 amountOut)
    {
        // Get a reference to the pool that'll be used to make the swap.
        address v3Pool;
        try V3_FACTORY.getPool(projectToken, terminalToken, 10000) returns (address poolAddr) {
            v3Pool = poolAddr;
        } catch {
            return 0;
        }

        // Make sure the pool exists, if not, return an empty quote.
        if (v3Pool == address(0)) return 0;

        IUniswapV3Pool pool = IUniswapV3Pool(v3Pool);

        // If there is a contract at the address, try to get the pool's slot 0.
        try pool.slot0() returns (uint160, int24, uint16, uint16, uint16, uint8, bool unlocked) {
            // If the pool hasn't been initialized, return an empty quote.
            if (!unlocked) return 0;
        } catch {
            // If the address is invalid, return an empty quote.
            return 0;
        }

        // Use the standard TWAP window
        uint256 twapWindow = STANDARD_TWAP_WINDOW;

        // If the oldest observation is younger than the TWAP window, use the oldest observation.
        uint32 oldestObservation;
        try this._getOldestObservationSecondsAgo(pool) returns (uint32 oo) {
            oldestObservation = oo;
        } catch {
            oldestObservation = 0;
        }
        if (oldestObservation < twapWindow && oldestObservation > 0) twapWindow = oldestObservation;

        // Keep a reference to the TWAP tick.
        int24 arithmeticMeanTick;

        // Keep a reference to the liquidity.
        uint128 liquidity;

        // Resolve mean tick and liquidity source
        if (oldestObservation == 0) {
            // fallback: use spot tick and current in-range liquidity
            try pool.slot0() returns (uint160, int24 tick, uint16, uint16, uint16, uint8, bool) {
                arithmeticMeanTick = tick;
                liquidity = pool.liquidity();
            } catch {
                return 0;
            }
        } else {
            try this._consult(pool, uint32(twapWindow)) returns (int24 tick, uint128 liq) {
                arithmeticMeanTick = tick;
                liquidity = liq;
            } catch {
                return 0;
            }
        }

        // If there's no liquidity, return an empty quote.
        if (liquidity == 0) return 0;

        // Calculate the slippage tolerance.
        uint256 slippageTolerance = _getSlippageTolerance({
            amountIn: amountIn,
            liquidity: liquidity,
            projectToken: projectToken,
            terminalToken: terminalToken,
            arithmeticMeanTick: arithmeticMeanTick
        });

        // If the slippage tolerance is at or above the maximum, return an empty quote.
        if (slippageTolerance >= TWAP_SLIPPAGE_DENOMINATOR) return 0;

        // Get a quote based on this TWAP tick.
        amountOut = _getQuoteAtTick({
            tick: arithmeticMeanTick, baseAmount: uint128(amountIn), baseToken: terminalToken, quoteToken: projectToken
        });

        // return the lowest acceptable return based on the TWAP and its parameters.
        // Ensure slippageTolerance doesn't exceed denominator to prevent underflow
        uint256 slippageAmount = (amountOut * slippageTolerance) / TWAP_SLIPPAGE_DENOMINATOR;
        // Safety check: ensure we don't subtract more than amountOut
        if (slippageAmount > amountOut) {
            return 0;
        }
        amountOut -= slippageAmount;
    }

    /// @notice Get the slippage tolerance for a given amount in and liquidity.
    /// @param amountIn The amount in to get the slippage tolerance for.
    /// @param liquidity The liquidity to get the slippage tolerance for.
    /// @param projectToken The project token to get the slippage tolerance for.
    /// @param terminalToken The terminal token to get the slippage tolerance for.
    /// @param arithmeticMeanTick The arithmetic mean tick to get the slippage tolerance for.
    /// @return slippageTolerance The slippage tolerance for the given amount in and liquidity.
    function _getSlippageTolerance(
        uint256 amountIn,
        uint128 liquidity,
        address projectToken,
        address terminalToken,
        int24 arithmeticMeanTick
    ) internal pure returns (uint256) {
        // Direction: is terminalToken token0?
        (address token0,) = projectToken < terminalToken ? (projectToken, terminalToken) : (terminalToken, projectToken);
        bool zeroForOne = terminalToken == token0;

        // sqrtP in Q96 from the TWAP tick
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(arithmeticMeanTick);

        // If the sqrtP is 0, there's no valid price so we'll return the maximum slippage tolerance.
        if (sqrtP == 0) return TWAP_SLIPPAGE_DENOMINATOR;

        // Approximate % of range liquidity consumed by the swap (in bps)
        // Multiply by 10 to to amplify the results and prevent results on the low end from rounding to zero.
        uint256 base = FullMath.mulDiv(amountIn, 10 * TWAP_SLIPPAGE_DENOMINATOR, uint256(liquidity));

        // Stage 1 — raw estimate (bps), normalized by √P
        uint256 rawSlippageBps = zeroForOne
            ? FullMath.mulDiv(base, uint256(sqrtP), uint256(1) << 96)
            : FullMath.mulDiv(base, uint256(1) << 96, uint256(sqrtP));

        // Stage 2 — policy adjustment: map raw → adjusted using log scaling and caps
        // Higher rawSlippageBps (lower liquidity) = MORE protection. Lower rawSlippageBps = LESS protection.
        if (rawSlippageBps == 0) return UNCERTAIN_TWAP_SLIPPAGE_TOLERANCE;

        // Cap very large values at reasonable maximum
        // Ensure maxAllowed never exceeds TWAP_SLIPPAGE_DENOMINATOR (100%)
        uint256 maxAllowed = rawSlippageBps > 15 * TWAP_SLIPPAGE_DENOMINATOR
            ? TWAP_SLIPPAGE_DENOMINATOR * 88 / 100
            : (rawSlippageBps > 10 * TWAP_SLIPPAGE_DENOMINATOR
                    ? TWAP_SLIPPAGE_DENOMINATOR * 67 / 100
                    : rawSlippageBps / 5); // Default max: 20% of input

        // Cap maxAllowed at 100% (safety check)
        //@note maybe this should be capped at 99%? Or even 95%?
        if (maxAllowed > TWAP_SLIPPAGE_DENOMINATOR) {
            maxAllowed = TWAP_SLIPPAGE_DENOMINATOR;
        }

        // Logarithmic scaling: Use log2 to create smooth growth with diminishing returns
        // Formula: adjusted grows logarithmically with rawSlippageBps
        // Scale rawSlippageBps to UD60x18 format (multiply by 1e18 to satisfy log2 requirement of x >= UNIT)
        uint256 scaledValue = rawSlippageBps * 1e18;
        if (scaledValue < 1e18) scaledValue = 1e18; // Ensure >= UNIT for log2

        UD60x18 logValue = log2(UD60x18.wrap(scaledValue));

        // Unwrap logValue - it's in UD60x18 format where 1 = 1e18
        // Divide by 1e18 to get the actual log2 value
        uint256 logApprox = UD60x18.unwrap(logValue) / 1e18;

        // Base value: minimum slippage protection (for very small raw/high liquidity)
        uint256 baseValue = UNCERTAIN_TWAP_SLIPPAGE_TOLERANCE;

        // Scale factor: how much the log value contributes to the result
        // Higher scaleFactor = steeper curve (more sensitive to liquidity changes)
        uint256 scaleFactor = 800; // Adjusts the steepness of the logarithmic curve

        // Calculate adjusted: base + logarithmic growth
        // Higher raw (low liquidity) → larger logApprox → larger adjusted (more protection)
        // Lower raw (high liquidity) → smaller logApprox → smaller adjusted (less protection)
        uint256 adjustedSlippageBps = baseValue + (scaleFactor * logApprox) / 2;

        // Cap at reasonable maximum to prevent excessive slippage protection (maxAllowed already capped at 100%)
        if (adjustedSlippageBps > maxAllowed) adjustedSlippageBps = maxAllowed;

        // For very small raw (high liquidity), ensure minimum sensible protection
        if (rawSlippageBps < 500 && adjustedSlippageBps < baseValue + 100) {
            adjustedSlippageBps = baseValue + (rawSlippageBps / 5);
        }

        return adjustedSlippageBps;
    }

    /// @notice Calculates time-weighted means of tick and liquidity for a given Uniswap V3 pool
    /// @param pool The pool that we want to observe
    /// @param secondsAgo Number of seconds in the past from which to calculate the time-weighted means
    /// @return arithmeticMeanTick The arithmetic mean tick from (block.timestamp - secondsAgo) to block.timestamp
    /// @return harmonicMeanLiquidity The harmonic mean liquidity from (block.timestamp - secondsAgo) to block.timestamp
    function _consult(IUniswapV3Pool pool, uint32 secondsAgo)
        external
        view
        returns (int24 arithmeticMeanTick, uint128 harmonicMeanLiquidity)
    {
        if (secondsAgo == 0) revert JBUniswapV4Hook_SecondsAgoCannotBeZero();

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = secondsAgo;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            pool.observe(secondsAgos);

        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        uint160 secondsPerLiquidityCumulativesDelta =
            secondsPerLiquidityCumulativeX128s[1] - secondsPerLiquidityCumulativeX128s[0];

        arithmeticMeanTick = int24(tickCumulativesDelta / int56(uint56(secondsAgo)));
        // Always round to negative infinity
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(uint56(secondsAgo)) != 0)) arithmeticMeanTick--;

        // We are multiplying here instead of shifting to ensure that harmonicMeanLiquidity doesn't overflow uint128
        uint192 secondsAgoX160 = uint192(secondsAgo) * type(uint160).max;
        harmonicMeanLiquidity = uint128(secondsAgoX160 / (uint192(secondsPerLiquidityCumulativesDelta) << 32));
    }

    /// @notice Given a pool, it returns the number of seconds ago of the oldest stored observation
    /// @param pool Address of Uniswap V3 pool that we want to observe
    /// @return secondsAgo The number of seconds ago of the oldest observation stored for the pool
    function _getOldestObservationSecondsAgo(IUniswapV3Pool pool) external view returns (uint32 secondsAgo) {
        (,, uint16 observationIndex, uint16 observationCardinality,,,) = pool.slot0();
        if (observationCardinality == 0) revert JBUniswapV4Hook_ObservationCardinalityZero();

        (uint32 observationTimestamp,,, bool initialized) =
            pool.observations((observationIndex + 1) % observationCardinality);

        // The next index might not be initialized if the cardinality is in the process of increasing
        // In this case the oldest observation is always in index 0
        if (!initialized) {
            (observationTimestamp,,,) = pool.observations(0);
        }

        secondsAgo = uint32(block.timestamp) - observationTimestamp;
    }

    /// @notice Given a tick and a token amount, calculates the amount of token received in exchange
    /// @param tick Tick value used to calculate the quote
    /// @param baseAmount Amount of token to be converted
    /// @param baseToken Address of an ERC20 token contract used as the baseAmount denomination
    /// @param quoteToken Address of an ERC20 token contract used as the quoteAmount denomination
    /// @return quoteAmount Amount of quoteToken received for baseAmount of baseToken
    function _getQuoteAtTick(int24 tick, uint128 baseAmount, address baseToken, address quoteToken)
        internal
        pure
        returns (uint256 quoteAmount)
    {
        uint160 sqrtRatioX96 = TickMath.getSqrtPriceAtTick(tick);

        // Calculate quoteAmount with better precision if it doesn't overflow when multiplied by itself
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }

    //*********************************************************************//
    // ---------------------- internal functions ---------------------- //
    //*********************************************************************//

    /// @notice Get the TWAP sqrt price for a pool
    /// @param poolId The pool ID
    /// @return sqrtPriceX96 The TWAP sqrt price, or 0 if not enough observations
    function _getTWAPSqrtPrice(PoolId poolId) internal view returns (uint160) {
        ObservationState memory state = states[poolId];

        // Need at least 2 observations for TWAP
        if (state.cardinality < 2) {
            return 0;
        }

        // Get current pool state for observation
        // getSlot0 returns: sqrtPriceX96, tick, protocolFee, lpFee (no liquidity)
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        // Get current liquidity from the dedicated accessor
        uint128 liquidity = poolManager.getLiquidity(poolId);

        uint32 currentTime = uint32(block.timestamp);

        // Calculate the target time (TWAP_PERIOD seconds ago)
        uint32 oldestAllowedTime = currentTime > TWAP_PERIOD ? currentTime - TWAP_PERIOD : 0;

        // Get oldest observation timestamp
        Oracle.Observation memory oldestObs = observations[poolId][(state.index + 1) % state.cardinality];
        if (!oldestObs.initialized) {
            oldestObs = observations[poolId][0];
        }

        // If we don't have observations old enough, return 0
        if (oldestObs.blockTimestamp > oldestAllowedTime) {
            return 0;
        }

        // Observe the TWAP
        int24 arithmeticMeanTick =
            this.observeTWAP(poolId, TWAP_PERIOD, tick, state.index, liquidity, state.cardinality);

        // Convert tick to sqrtPriceX96
        return TickMath.getSqrtPriceAtTick(arithmeticMeanTick);
    }

    /// @notice Creates a BeforeSwapDelta from input and output amounts
    /// @param amountIn The input amount
    /// @param amountOut The output amount
    /// @return delta The BeforeSwapDelta representing the swap
    function _createSwapDelta(uint256 amountIn, uint256 amountOut) internal pure returns (BeforeSwapDelta) {
        // The hook takes the input amount and settles the output amount
        // For both buying and selling: take inputCurrency, settle outputCurrency
        return toBeforeSwapDelta(int128(uint128(amountIn)), -int128(uint128(amountOut)));
    }

    /// @notice Settles output tokens back to PoolManager
    /// @param outputCurrency The output currency to settle
    /// @param amount The amount to settle
    /// @dev Uses OpenZeppelin's CurrencySettler library to ensure correct settlement order
    /// @dev This handles sync -> transfer -> settle in the correct order for flash-accounting safety
    function _settleOutput(Currency outputCurrency, uint256 amount) internal {
        // Use CurrencySettler library to ensure correct settlement order and flash-accounting safety
        // payer = address(this) since we're settling tokens we received
        // burn = false since we're transferring ERC-20 tokens, not burning ERC-6909 tokens
        CurrencySettler.settle(outputCurrency, poolManager, address(this), amount, false);
    }

    /// @notice Normalizes a token address to Juicebox's native token representation for pricing
    /// @dev For price quoting, only native ETH is normalized to JB_NATIVE_TOKEN. WETH is treated
    ///      as a distinct currency and must have its own Juicebox configuration if used.
    /// @param token The token address to normalize
    /// @return normalizedToken The normalized token address (JB_NATIVE_TOKEN only for native ETH)
    function _normalizeToken(address token) internal view returns (address) {
        return token == UNISWAP_NATIVE_ETH ? JB_NATIVE_TOKEN : token;
    }


    /// @notice Normalizes a token address for terminal interactions
    /// @dev Only normalizes native ETH to JB_NATIVE_TOKEN. WETH is only used when routing through v3,
    ///      not when routing through Juicebox, so we don't need to handle WETH normalization here.
    /// @param token The token address to normalize
    /// @return normalizedToken The normalized token address (JB_NATIVE_TOKEN only for native ETH)
    function _normalizeTokenForTerminal(address token) internal view returns (address) {
        return token == UNISWAP_NATIVE_ETH ? JB_NATIVE_TOKEN : token;
    }

    /// @notice Converts native ETH address to WETH for Uniswap v3 operations
    /// @dev v3 pools use WETH, not address(0), so we need to map native ETH to WETH
    /// @param token The token address (may be address(0) for native ETH)
    /// @return v3Token The token address to use for v3 operations (WETH if input was address(0))
    function _convertToV3Token(address token) internal view returns (address) {
        return token == UNISWAP_NATIVE_ETH ? WETH : token;
    }

    /// @notice Gets token decimals, defaulting to 18 if unavailable
    /// @param token The token address
    /// @return decimals The token decimals (defaults to 18)
    function _getTokenDecimals(address token) internal view returns (uint8) {
        if (token == JB_NATIVE_TOKEN) {
            return 18; // Native ETH has 18 decimals
        }
        try IERC20Metadata(token).decimals() returns (uint8 decimals) {
            return decimals;
        } catch {
            return 18; // Default to 18 if unavailable
        }
    }

    /// @notice Calculates expected tokens with currency conversion
    /// @dev Normalizes payment amount to 18 decimals, then calculates tokens based on weight and price conversion
    /// @param tokensPerBaseCurrency The project's weight (tokens per base currency unit)
    /// @param paymentAmount The payment amount in the token's native decimals
    /// @param paymentTokenDecimals The decimals of the payment token
    /// @param baseCurrencyPerPaymentToken The price conversion rate (base currency per payment token, scaled by 1e18)
    /// @return expectedTokens The expected number of tokens to be received
    function _calculateTokensWithCurrency(
        uint256 tokensPerBaseCurrency,
        uint256 paymentAmount,
        uint8 paymentTokenDecimals,
        uint256 baseCurrencyPerPaymentToken
    ) internal pure returns (uint256 expectedTokens) {
        // Normalize payment amount to 18 decimals
        uint256 paymentAmount18 =
            paymentTokenDecimals == 18 ? paymentAmount : (paymentAmount * 1e18) / (10 ** paymentTokenDecimals);

        // Calculate tokens: if price conversion is 1:1, simplify; otherwise apply price conversion
        if (baseCurrencyPerPaymentToken == 1e18) {
            // Direct calculation: (weight * paymentAmount18) / 1e18
            expectedTokens = FullMath.mulDiv(tokensPerBaseCurrency, paymentAmount18, 1e18);
        } else {
            // Two-step calculation: first multiply by weight, then apply price conversion
            uint256 intermediate = FullMath.mulDiv(tokensPerBaseCurrency, paymentAmount18, 1e18);
            expectedTokens = FullMath.mulDiv(intermediate, baseCurrencyPerPaymentToken, 1e18);
        }
    }

    /// @notice Gets the primary terminal for a project and token
    /// @param projectId The project ID
    /// @param token The token address
    /// @return terminal The primary terminal, or address(0) if not found
    function _getPrimaryTerminal(uint256 projectId, address token) internal view returns (IJBTerminal) {
        // Only normalize native ETH to JB_NATIVE_TOKEN for terminal lookup
        // WETH is only used when routing through v3, not when routing through Juicebox
        address normalized = _normalizeTokenForTerminal(token);
        try DIRECTORY.primaryTerminalOf(projectId, normalized) returns (IJBTerminal t) {
            return t;
        } catch {
            return IJBTerminal(address(0));
        }
    }

    /// @notice Calculates token ordering for Uniswap v3 (token0 < token1)
    /// @param tokenA First token
    /// @param tokenB Second token
    /// @return token0 The smaller token address
    /// @return token1 The larger token address
    /// @return zeroForOne Whether swapping token0 for token1
    function _getTokenOrdering(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1, bool zeroForOne)
    {
        if (tokenA < tokenB) {
            return (tokenA, tokenB, true);
        } else {
            return (tokenB, tokenA, false);
        }
    }

    /// @notice Hook called after pool initialization to set up oracle
    /// @param key The pool key
    /// @param tick The initial tick
    /// @return selector The function selector
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        PoolId poolId = key.toId();

        // Initialize oracle with first observation
        (uint16 cardinality, uint16 cardinalityNext) = observations[poolId].initialize(uint32(block.timestamp), tick);

        states[poolId] = ObservationState({index: 0, cardinality: cardinality, cardinalityNext: cardinalityNext});

        return BaseHook.afterInitialize.selector;
    }

    /// @notice Records an oracle observation and grows cardinality if needed
    /// @param poolId The pool ID
    function _recordObservation(PoolId poolId) internal {
        // Get current pool state
        // getSlot0 returns: sqrtPriceX96, tick, protocolFee, lpFee (no liquidity)
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        // Get current liquidity from the dedicated accessor
        uint128 liquidity = poolManager.getLiquidity(poolId);

        ObservationState memory state = states[poolId];

        // Auto-grow cardinality when at capacity to enable TWAP functionality
        // Grow when we're about to wrap around (index == cardinality - 1) and cardinality == cardinalityNext
        uint16 newCardinalityNext = state.cardinalityNext;
        if (state.cardinality == state.cardinalityNext && state.index == state.cardinality - 1) {
            // Double the cardinality, capped at a reasonable maximum (e.g., 256 for 30-minute TWAP with 1-hour window)
            // This allows storing ~256 observations = ~128 hours of data at 1 observation per 30 minutes
            uint16 targetCardinality = state.cardinalityNext < 128
                ? state.cardinalityNext * 2
                : (state.cardinalityNext < 256 ? 256 : state.cardinalityNext);

            // Grow the oracle array
            newCardinalityNext = observations[poolId].grow(state.cardinalityNext, targetCardinality);
        }

        // Write new observation
        (uint16 indexUpdated, uint16 cardinalityUpdated) = observations[poolId]
        .write(state.index, uint32(block.timestamp), tick, liquidity, state.cardinality, newCardinalityNext);

        // Update state
        states[poolId] = ObservationState({
            index: indexUpdated, cardinality: cardinalityUpdated, cardinalityNext: newCardinalityNext
        });
    }

    /// @notice Hook called after swap to record price observations
    /// @param key The pool key
    /// @return selector The function selector
    /// @return delta The delta to return (zero in our case)
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        _recordObservation(key.toId());
        return (BaseHook.afterSwap.selector, 0);
    }

    /// @notice Hook called after liquidity is added to record price observations
    /// @param key The pool key
    /// @return selector The function selector
    /// @return delta The delta to return (zero in our case)
    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        _recordObservation(key.toId());
        return (BaseHook.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    /// @notice Hook called after liquidity is removed to record price observations
    /// @param key The pool key
    /// @return selector The function selector
    /// @return delta The delta to return (zero in our case)
    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        _recordObservation(key.toId());
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    /// @notice Hook called before a swap
    /// @dev Compares prices between Uniswap and Juicebox, routes to cheaper option
    /// @notice Main routing logic that compares prices across V4, V3, and Juicebox routes
    /// @dev This function is called by Uniswap V4 before every swap. It:
    ///      1. Validates exact-input swap (reverts on exact-output)
    ///      2. Detects if swap involves a Juicebox project token
    ///      3. Calculates expected outputs from all three routes (V4, V3, Juicebox)
    ///      4. Compares outputs and routes to the best option
    ///      5. Returns swap delta to override V4 swap if routing elsewhere
    /// 
    /// @param key The pool key identifying the V4 pool
    /// @param params The swap parameters (direction, amount, price limit)
    /// @return selector The function selector (BaseHook.beforeSwap.selector)
    /// @return delta The swap delta (zero for V4, custom for V3/Juicebox routing)
    /// @return protocolFee The protocol fee (always 0, handled by PoolManager)
    /// 
    /// @custom:security This function:
    ///      - Only supports exact-input swaps (prevents exact-output manipulation)
    ///      - Uses TWAP oracles for price estimates (prevents manipulation)
    ///      - Validates terminal existence before routing through Juicebox
    ///      - Validates V3 pool existence and unlock status before routing
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        // Only support exact-input swaps (amountSpecified < 0)
        // Exact-output swaps (amountSpecified > 0) are not supported as they require
        // different handling of specified/unspecified tokens and delta signs
        if (params.amountSpecified > 0) {
            revert JBUniswapV4Hook_ExactOutputSwapsNotSupported();
        }

        // Determine input and output currencies based on swap direction
        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;

        address tokenIn = Currency.unwrap(inputCurrency);
        address tokenOut = Currency.unwrap(outputCurrency);

        // Get input amount (amountSpecified is negative for exact input)
        uint256 amountIn = uint256(-params.amountSpecified);

        // Check if either token is a JB token by looking up projectId dynamically
        uint256 tokenInProjectId = TOKENS.projectIdOf(IJBToken(tokenIn));
        uint256 tokenOutProjectId = TOKENS.projectIdOf(IJBToken(tokenOut));

        // Determine if we're buying or selling JB tokens
        bool isSellingJBToken = tokenInProjectId != 0;
        bool isBuyingJBToken = tokenOutProjectId != 0;

        // Get the projectId (whichever token is the JB token)
        uint256 projectId = isSellingJBToken ? tokenInProjectId : (isBuyingJBToken ? tokenOutProjectId : 0);

        uint256 juiceboxExpectedOutput;

        if (isBuyingJBToken) {
            // Buying JB tokens: compare Juicebox vs Uniswap for getting JB tokens
            juiceboxExpectedOutput = calculateExpectedTokensWithCurrency(projectId, tokenIn, amountIn);
        } else if (isSellingJBToken) {
            // Selling JB tokens: compare Juicebox vs Uniswap for getting output tokens
            juiceboxExpectedOutput = calculateExpectedOutputFromSelling(projectId, amountIn, tokenOut);
        } else {
            // No JB token involved, proceed with normal Uniswap swap
            emit RouteSelected(poolId, false, 0);
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Calculate how many tokens we'd get from Uniswap v4
        uint256 uniswapV4ExpectedTokens = estimateUniswapOutput(poolId, key, amountIn, params.zeroForOne);

        // Calculate how many tokens we'd get from Uniswap v3 (10000 fee tier only)
        // v3 pools use WETH, not address(0), so convert native ETH to WETH for v3 operations
        address v3TokenIn = _convertToV3Token(tokenIn);
        address v3TokenOut = _convertToV3Token(tokenOut);
        // Determine v3 swap direction based on token ordering (v3 uses token0 < token1)
        (address v3Token0, address v3Token1, bool v3ZeroForOne) = _getTokenOrdering(v3TokenIn, v3TokenOut);
        uint256 uniswapV3ExpectedTokens;
        try this.estimateUniswapV3Output(v3Token0, v3Token1, amountIn, v3ZeroForOne) returns (uint256 tokens) {
            uniswapV3ExpectedTokens = tokens;
        } catch {
            uniswapV3ExpectedTokens = 0;
        }

        // Compare v3 vs v4 prices
        bool v3BetterThanV4 = uniswapV3ExpectedTokens > uniswapV4ExpectedTokens;

        // Determine the best option among v3, v4, and Juicebox
        uint256 bestExpectedTokens = uniswapV4ExpectedTokens;
        string memory bestRoute = "v4";

        // Check if v3 is better than v4
        if (v3BetterThanV4 && uniswapV3ExpectedTokens > 0) {
            bestExpectedTokens = uniswapV3ExpectedTokens;
            bestRoute = "v3";
        }

        // Check if Juicebox is better than the best Uniswap option
        // Only consider Juicebox if a valid terminal exists for the appropriate token
        // For buying: terminal must support the payment token (tokenIn)
        // For selling: terminal must have the output token (tokenOut) that we're cashing out to
        address terminalToken = isBuyingJBToken ? tokenIn : tokenOut;
        IJBTerminal jbTerminal = _getPrimaryTerminal(projectId, terminalToken);
        bool jbTerminalAvailable = address(jbTerminal) != address(0) && address(jbTerminal).code.length > 0;
        bool juiceboxBetterThanUniswap = jbTerminalAvailable && juiceboxExpectedOutput > bestExpectedTokens;
        
        if (juiceboxBetterThanUniswap && juiceboxExpectedOutput > 0) {
            bestExpectedTokens = juiceboxExpectedOutput;
            bestRoute = "juicebox";
        }

        emit BestRouteSelected(poolId, bestRoute, bestExpectedTokens);

        // If Juicebox gives better output, route through Juicebox
        if (juiceboxBetterThanUniswap && juiceboxExpectedOutput > 0) {
            // Log the expected amount for the chosen route
            emit RouteSelected(poolId, true, juiceboxExpectedOutput);

            // Execute Juicebox routing (works for both buying and selling)
            uint256 outputReceived =
                _routeThroughJuicebox(projectId, inputCurrency, outputCurrency, amountIn, isBuyingJBToken, jbTerminal);

            return (BaseHook.beforeSwap.selector, _createSwapDelta(amountIn, outputReceived), 0);
        }

        if (v3BetterThanV4 && uniswapV3ExpectedTokens > 0) {
            // Log the expected amount for the chosen route
            emit RouteSelected(poolId, false, uniswapV3ExpectedTokens);

            // Execute v3 swap (pass pre-calculated token ordering with WETH mapping)
            // Note: v3Token0 and v3Token1 already have address(0) converted to WETH
            uint256 outputReceived =
                _routeThroughV3(v3Token0, v3Token1, amountIn, v3ZeroForOne, tokenIn, tokenOut);

            // Return delta that reflects what hook did
            return (BaseHook.beforeSwap.selector, _createSwapDelta(amountIn, outputReceived), 0);
        }

        // Proceed with normal v4 swap (RouteSelected already logs expected V4 amount)
        emit RouteSelected(poolId, false, uniswapV4ExpectedTokens);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Routes a swap through Juicebox terminal instead of Uniswap
    /// @dev This function handles both buying and selling Juicebox project tokens:
    ///      - Buying: Calls terminal.pay() to mint tokens
    ///      - Selling: Calls terminal.cashOutTokensOf() to redeem tokens
    /// 
    ///      The function:
    ///      1. Takes input tokens from PoolManager
    ///      2. Normalizes tokens (native ETH → JB_NATIVE_TOKEN)
    ///      3. Approves terminal if needed (ERC20 tokens)
    ///      4. Executes Juicebox operation (pay or cashOutTokensOf)
    ///      5. Settles output back to PoolManager
    /// 
    /// @param projectId The Juicebox project ID
    /// @param inputCurrency The input currency (native ETH or ERC20)
    /// @param outputCurrency The output currency (native ETH or ERC20)
    /// @param amountIn The input amount
    /// @param isBuying Whether we're buying (true) or selling (false) JB tokens
    /// @param terminal The Juicebox terminal to use (must be valid and have code)
    /// @return outputReceived The amount of output tokens received
    /// 
    /// @custom:security This function:
    ///      - Validates terminal exists and has code before calling
    ///      - Uses SafeERC20 for token transfers
    ///      - Handles native ETH properly (wrapping/unwrapping not needed for JB)
    ///      - Settles output back to PoolManager (prevents token loss)
    /// @notice Routes a swap through Juicebox instead of Uniswap
    /// @dev Handles both buying and selling JB tokens through Juicebox
    /// @param projectId The Juicebox project ID
    /// @param inputCurrency The input currency (what the swapper is paying)
    /// @param outputCurrency The output currency (what the swapper receives)
    /// @param amountIn The amount of input tokens
    /// @param isBuying Whether we're buying JB tokens (true) or selling them (false)
    /// @param terminal The Juicebox terminal to use (already validated by caller)
    /// @return outputReceived The amount of output tokens received
    function _routeThroughJuicebox(
        uint256 projectId,
        Currency inputCurrency,
        Currency outputCurrency,
        uint256 amountIn,
        bool isBuying,
        IJBTerminal terminal
    ) internal returns (uint256 outputReceived) {
        address tokenIn = Currency.unwrap(inputCurrency);
        address tokenOut = Currency.unwrap(outputCurrency);

        // Terminal is already validated by caller
        // Take input from PoolManager (pre-deposited by JuiceboxSwapRouter)
        poolManager.take(inputCurrency, address(this), amountIn);

        // Normalize token for Juicebox terminal interaction
        // Only normalize native ETH to JB_NATIVE_TOKEN (WETH only appears when routing through v3)
        address normalizedTokenIn = _normalizeTokenForTerminal(tokenIn);

        // Approve the terminal to spend the tokens if needed
        if (!inputCurrency.isAddressZero()) {
            IERC20(tokenIn).safeIncreaseAllowance(address(terminal), amountIn);
        }

        if (isBuying) {
            // Buying JB tokens: Pay to Juicebox and receive JB tokens
            // Only native ETH is normalized to JB_NATIVE_TOKEN (WETH only appears when routing through v3)
            uint256 payValue = inputCurrency.isAddressZero() ? amountIn : 0;
            outputReceived = terminal.pay{
                value: payValue
            }(
                projectId,
                normalizedTokenIn, // Native ETH → JB_NATIVE_TOKEN
                amountIn,
                address(this), // Tokens come to hook
                0, // No minimum tokens required
                "", // Empty memo
                bytes("") // Empty metadata
            );
        } else {
            // Selling JB tokens: Cash out JB tokens and receive output currency
            // Only normalize native ETH to JB_NATIVE_TOKEN (WETH only appears when routing through v3)
            address normalizedTokenOut = _normalizeTokenForTerminal(tokenOut);
            // Call the terminal's cash out function to get the output tokens
            outputReceived = IJBMultiTerminal(address(terminal))
                .cashOutTokensOf(
                    address(this), // holder (hook owns the JB tokens)
                    projectId,
                    amountIn, // cashOutCount: Amount of JB tokens to cash out
                    normalizedTokenOut, // Native ETH → JB_NATIVE_TOKEN
                    0, // minTokensReclaimed: No minimum tokens required
                    payable(address(this)), // beneficiary (hook)
                    bytes("") // Empty metadata
                );
        }

        // Settle output back to PoolManager
        _settleOutput(outputCurrency, outputReceived);

        return outputReceived;
    }

    /// @notice Routes a swap through Uniswap v3 instead of v4
    /// @dev Takes input tokens from PoolManager, executes v3 swap, settles output tokens back
    /// @dev Handles wrapping/unwrapping ETH↔WETH since v3 uses WETH but v4 can use native ETH
    /// @param token0 The v3 token0 address (token0 < token1, already converted to WETH if needed)
    /// @param token1 The v3 token1 address (token0 < token1, already converted to WETH if needed)
    /// @param amountIn The amount of input tokens
    /// @param zeroForOne Whether swapping token0 for token1
    /// @param originalTokenIn The original tokenIn from v4 (may be address(0) for native ETH)
    /// @param originalTokenOut The original tokenOut from v4 (may be address(0) for native ETH)
    /// @notice Routes a swap through Uniswap V3 pool when it offers better prices than V4
    /// @dev This function:
    ///      1. Looks up V3 pool via factory (10000 fee tier only)
    ///      2. Validates pool exists and is unlocked
    ///      3. Wraps native ETH to WETH if input is native ETH
    ///      4. Executes V3 swap (calls uniswapV3SwapCallback during execution)
    ///      5. Unwraps WETH to native ETH if output is native ETH
    ///      6. Settles output back to PoolManager
    /// 
    /// @param token0 First token in pair (must be < token1, already converted to WETH if native ETH)
    /// @param token1 Second token in pair (already converted to WETH if native ETH)
    /// @param amountIn The input amount
    /// @param zeroForOne Swap direction (true = token0 → token1)
    /// @param originalTokenIn Original input token (may be native ETH)
    /// @param originalTokenOut Original output token (may be native ETH)
    /// @return outputReceived The amount of output tokens received
    /// 
    /// @custom:security This function:
    ///      - Validates V3 pool exists (reverts if not found)
    ///      - Validates pool is unlocked (reverts if locked)
    ///      - Uses WETH for V3 operations (V3 doesn't support native ETH)
    ///      - Validates callback via uniswapV3SwapCallback()
    ///      - Settles output back to PoolManager (prevents token loss)
    function _routeThroughV3(
        address token0,
        address token1,
        uint256 amountIn,
        bool zeroForOne,
        address originalTokenIn,
        address originalTokenOut
    ) internal returns (uint256 outputReceived) {
        // Get the v3 pool (10000 fee tier)
        address v3Pool = V3_FACTORY.getPool(token0, token1, 10000);
        if (v3Pool == address(0)) revert JBUniswapV4Hook_V3PoolNotFound();

        // Check pool is unlocked
        (,,,,,, bool unlocked) = IUniswapV3Pool(v3Pool).slot0();
        if (!unlocked) revert JBUniswapV4Hook_V3PoolLocked();

        // Determine input/output tokens based on swap direction
        address v3TokenIn = zeroForOne ? token0 : token1;
        address v3TokenOut = zeroForOne ? token1 : token0;

        // Take input from PoolManager (may be native ETH)
        Currency inputCurrency = Currency.wrap(originalTokenIn);
        poolManager.take(inputCurrency, address(this), amountIn);

        // If input is native ETH, wrap it to WETH for v3 swap
        // WETH will be minted to this contract's balance
        if (originalTokenIn == UNISWAP_NATIVE_ETH) {
            IWETH9(payable(WETH)).deposit{value: amountIn}();
        }
        // Note: No approval needed - callback uses safeTransfer from contract balance

        // Execute v3 swap
        // v3 swap parameters: recipient, zeroForOne, amountSpecified, sqrtPriceLimitX96, data
        // The swap will call uniswapV3SwapCallback during execution
        (int256 amount0Delta, int256 amount1Delta) = IUniswapV3Pool(v3Pool)
            .swap(
                address(this), // recipient
                zeroForOne,
                int256(amountIn), // amountSpecified (positive for exact input)
                zeroForOne ? V3_MIN_SQRT_RATIO + 1 : V3_MAX_SQRT_RATIO - 1,
                abi.encode(token0, token1, uint24(10000)) // data for callback validation
            );

        // Calculate output received (one of the deltas will be negative, the other positive)
        if (zeroForOne) {
            // Swapping token0 for token1: amount0Delta is positive (input), amount1Delta is negative (output)
            outputReceived = uint256(-amount1Delta);
        } else {
            // Swapping token1 for token0: amount1Delta is positive (input), amount0Delta is negative (output)
            outputReceived = uint256(-amount0Delta);
        }

        // If output should be native ETH, unwrap WETH to ETH
        Currency outputCurrency;
        if (originalTokenOut == UNISWAP_NATIVE_ETH) {
            // Unwrap WETH to ETH
            IWETH9(payable(WETH)).withdraw(outputReceived);
            outputCurrency = Currency.wrap(UNISWAP_NATIVE_ETH);
        } else {
            outputCurrency = Currency.wrap(originalTokenOut);
        }

        // Settle output back to PoolManager
        _settleOutput(outputCurrency, outputReceived);
        return outputReceived;
    }

    /// @notice Callback for Uniswap v3 swaps
    /// @dev Called by the v3 pool during swap execution to request payment. This function:
    ///      1. Validates at least one delta is positive (actual swap occurred)
    ///      2. Decodes pool info from data (token0, token1, fee)
    ///      3. Validates caller is a legitimate V3 pool from factory
    ///      4. Determines which token to pay (the one with positive delta)
    ///      5. Transfers required amount to the pool
    /// 
    /// @param amount0Delta The amount of token0 that must be paid (positive) or received (negative)
    /// @param amount1Delta The amount of token1 that must be paid (positive) or received (negative)
    /// @param data Additional data containing pool info (token0, token1, fee) for validation
    /// 
    /// @custom:security This function is critical for security:
    ///      - Validates swap occurred (at least one delta > 0)
    ///      - Validates caller is legitimate V3 pool (via factory lookup)
    ///      - Validates pool exists (not address(0))
    ///      - Uses SafeERC20 for token transfers
    ///      - Tokens should already be in contract from take() call in _routeThroughV3()
    /// 
    /// @custom:invariant msg.sender must be a valid V3 pool from V3_FACTORY
    /// @custom:invariant At least one delta must be positive (swap must have occurred)
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        if (amount0Delta <= 0 && amount1Delta <= 0) revert JBUniswapV4Hook_NoSwap();

        // Decode pool info from data
        (address token0, address token1, uint24 fee) = abi.decode(data, (address, address, uint24));

        // Validate callback - ensure msg.sender is a valid v3 pool from the factory
        // Check via factory's getPool method (works for both real and mock factories)
        address expectedPool = V3_FACTORY.getPool(token0, token1, fee);
        if (msg.sender != expectedPool || expectedPool == address(0)) revert JBUniswapV4Hook_InvalidCallback();

        // Determine which token to pay (one delta will be positive)
        uint256 amountToPay;
        address tokenToPay;

        if (amount0Delta > 0) {
            amountToPay = uint256(amount0Delta);
            tokenToPay = token0;
        } else {
            amountToPay = uint256(amount1Delta);
            tokenToPay = token1;
        }

        // Transfer the required amount to the pool
        // The tokens should already be in this contract from the take() call
        // If native ETH was input, tokenToPay will be WETH (already wrapped in _routeThroughV3)
        IERC20(tokenToPay).safeTransfer(msg.sender, amountToPay);
    }
}
