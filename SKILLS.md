# nana-lp-split-hook-v5

## Purpose

Juicebox reserved-token split hook that accumulates project tokens, deploys a Uniswap V3 liquidity position bounded by the project's issuance and cash-out rates, and routes LP fees back to the project.

## Contracts

| Contract | Role |
|----------|------|
| `UniV3DeploymentSplitHook` | Core split hook. Implements `IJBSplitHook.processSplitWith` to accumulate or burn tokens. Manages V3 pool creation, LP position minting, fee collection, and liquidity rebalancing. Inherits `JBPermissioned` (permission checks), `ERC2771Context` (meta-transactions), `Ownable` (admin). |
| `IUniV3DeploymentSplitHook` | Public interface: `isPoolDeployed`, `deployPool`, `collectAndRouteLPFees`, `claimFeeTokensFor`. |
| `IREVDeployer` | Minimal interface with `isSplitOperatorOf(uint256 projectId, address operator)` for revnet operator validation. |

## Key Functions

| Function | Contract | What it does |
|----------|----------|--------------|
| `processSplitWith` | `UniV3DeploymentSplitHook` | Called by the project controller when distributing reserved tokens. If no pool deployed yet, accumulates tokens. If pool exists, burns received tokens. Only accepts `groupId == 1` (reserved tokens); reverts on payout splits. |
| `deployPool` | `UniV3DeploymentSplitHook` | Owner/operator-gated (SET_BUYBACK_POOL permission). Creates and initializes V3 pool at geometric mean of [cashOutRate, issuanceRate] ticks. Computes optimal cash-out fraction for LP geometry, cashes out project tokens for terminal tokens, mints concentrated LP position, handles leftovers. |
| `collectAndRouteLPFees` | `UniV3DeploymentSplitHook` | Permissionless. Collects fees from V3 position. Routes terminal-token fees: `FEE_PERCENT` to fee project via `pay()`, remainder to original project via `addToBalanceOf()`. Burns collected project-token fees. Tracks fee-project tokens for later claiming. |
| `rebalanceLiquidity` | `UniV3DeploymentSplitHook` | Permissionless. Removes existing position, burns NFT, recalculates tick bounds from current issuance/cashOut rates, mints new position. Handles fee collection and leftover routing. |
| `claimFeeTokensFor` | `UniV3DeploymentSplitHook` | Validates beneficiary is the revnet split operator via `IREVDeployer.isSplitOperatorOf`. Transfers accumulated fee-project tokens. |
| `isPoolDeployed` | `UniV3DeploymentSplitHook` | View: returns whether a V3 pool exists for a project/terminal-token pair. |
| `_getProjectTokensOutForTerminalTokensIn` | `UniV3DeploymentSplitHook` | Internal view: converts terminal tokens to project tokens using current ruleset weight and price feeds. |
| `_getTerminalTokensOutForProjectTokensIn` | `UniV3DeploymentSplitHook` | Internal view: converts project tokens to terminal tokens (inverse of above). |
| `_getSqrtPriceX96ForCurrentJuiceboxPrice` | `UniV3DeploymentSplitHook` | Internal view: converts Juicebox pricing to V3 sqrtPriceX96 format. |
| `_getIssuanceRate` | `UniV3DeploymentSplitHook` | Internal view: project tokens per terminal token (ceiling), accounting for reserved rate. |
| `_getCashOutRate` | `UniV3DeploymentSplitHook` | Internal view: terminal tokens per project token (floor), via `currentReclaimableSurplusOf`. |
| `_computeInitialSqrtPrice` | `UniV3DeploymentSplitHook` | Internal view: geometric mean of cashOut and issuance ticks, used as pool initialization price. Falls back to issuance rate if cashOut is zero. |
| `_computeOptimalCashOutAmount` | `UniV3DeploymentSplitHook` | Internal view: for V3 concentrated liquidity in range [Pa, Pb] at price P, computes the fraction of project tokens to cash out so the terminal/project token ratio matches LP geometry. Typically 15-30% instead of a naive 50%. |
| `_calculateTickBounds` | `UniV3DeploymentSplitHook` | Internal view: returns (tickLower, tickUpper) aligned to TICK_SPACING, derived from cashOutRate (floor) and issuanceRate (ceiling) sqrtPrices. Falls back to +/- one tick spacing around current price if rates are inverted. |

## Integration Points

| Dependency | Import | Used For |
|------------|--------|----------|
| `@bananapus/core-v6` | `IJBController`, `IJBDirectory`, `IJBMultiTerminal`, `IJBPermissions`, `IJBSplitHook`, `IJBTerminal`, `IJBTerminalStore`, `IJBTokens`, `JBPermissioned`, `JBSplitHookContext`, `JBRuleset`, `JBRulesetMetadata`, `JBRulesetMetadataResolver`, `JBAccountingContext`, `JBConstants` | Full Juicebox protocol interaction: controller queries, terminal pay/cashOut/addToBalance, permission checks, ruleset weight and pricing |
| `@bananapus/permission-ids-v6` | `JBPermissionIds` | `SET_BUYBACK_POOL` permission ID for `deployPool` access control |
| `@openzeppelin/contracts` | `IERC20`, `IERC20Metadata`, `SafeERC20`, `Ownable`, `ERC2771Context`, `Context` | Token operations, ownership, meta-transactions |
| `@prb/math` | `mulDiv`, `sqrt` | Overflow-safe multiplication and square root for sqrtPriceX96 calculations |
| `@uniswap/v3-periphery-flattened` | `INonfungiblePositionManager` | V3 position management: `createAndInitializePoolIfNecessary`, `mint`, `collect`, `decreaseLiquidity`, `burn`, `unwrapWETH9` |
| `@uniswap/v3-core` | `IUniswapV3Factory`, `IUniswapV3Pool` | V3 pool creation and queries |
| `@uniswap/v3-core-patched` | `TickMath` | Tick-to-sqrtPrice and sqrtPrice-to-tick conversions |

## Key Types

| Struct/Enum | Key Fields | Used In |
|-------------|------------|---------|
| `JBSplitHookContext` | `uint256 projectId`, `uint256 groupId`, `address token`, `uint256 amount`, `JBSplit split` | `processSplitWith` -- provides the split execution context from the controller |

## Storage

| Mapping | Type | Purpose |
|---------|------|---------|
| `poolOf` | `projectId => terminalToken => address` | V3 pool address per project/token pair |
| `tokenIdForPool` | `pool => uint256` | V3 NFT position ID for each pool |
| `accumulatedProjectTokens` | `projectId => uint256` | Pre-deployment token accumulation |
| `projectDeployed` | `projectId => bool` | Whether any pool has been deployed (switches accumulate to burn) |
| `claimableFeeTokens` | `projectId => uint256` | Fee-project tokens claimable by revnet operator |

## Gotchas

- **Requires `via_ir = true` in foundry.toml.** The contract hits stack-too-deep without the IR pipeline, particularly in `INonfungiblePositionManager.positions()` return value destructuring and the `_addUniswapLiquidity` function.
- **Only accepts reserved-token splits (`groupId == 1`).** Reverts with `UniV3DeploymentSplitHook_TerminalTokensNotAllowed` if called from a payout split. This is intentional -- it only manages project tokens, not terminal tokens from payouts.
- **`deployPool` requires `SET_BUYBACK_POOL` permission.** The caller must be the project owner or have been granted this permission via `JBPermissions`.
- **`collectAndRouteLPFees` and `rebalanceLiquidity` are permissionless.** Anyone can call them. This is safe because they only operate on existing positions and route funds to verified project terminals.
- **`claimFeeTokensFor` validates the beneficiary is the revnet split operator** via `IREVDeployer.isSplitOperatorOf`. It does not check `msg.sender` -- it checks the `beneficiary` parameter.
- **Native ETH handling is non-trivial.** Juicebox uses `JBConstants.NATIVE_TOKEN` (0x...EEEe), Uniswap uses WETH. The contract converts between them via `_toUniswapToken` (reads WETH from NonfungiblePositionManager) and `unwrapWETH9` for fee routing.
- **Cash-out fraction is geometrically optimized, not 50/50.** `_computeOptimalCashOutAmount` uses V3 concentrated liquidity math to compute the exact ratio needed, typically 15-30%. Safety-capped at 50%.
- **Pool initialization price is the geometric mean of [cashOutRate, issuanceRate] in tick space.** This centers the initial price in the LP range, creating a balanced position. Falls back to issuance rate if cash-out rate is 0 or ticks are equal.
- **One LP position per pool.** The contract manages a single NFT position per V3 pool. Rebalancing burns the old NFT and mints a new one.
- **Pragma is `0.8.23`** (not ^0.8.24 like the V4 hook repo), matching nana-core-v6.

## Example Integration

```solidity
import {UniV3DeploymentSplitHook} from "nana-lp-split-hook-v6/src/UniV3DeploymentSplitHook.sol";

// Deploy the split hook
UniV3DeploymentSplitHook hook = new UniV3DeploymentSplitHook(
    owner,
    address(jbDirectory),
    jbPermissions,
    address(jbTokens),
    address(uniswapV3Factory),
    address(nonfungiblePositionManager),
    feeProjectId,        // e.g. project 1
    3800,                // 38% of LP fees to fee project
    address(revDeployer),
    trustedForwarder
);

// Configure as a reserved-token split in a Juicebox ruleset:
// JBSplit({ ... hook: hook, ... })

// After enough tokens accumulate, deploy the pool:
hook.deployPool(
    projectId,
    terminalToken,       // e.g. JBConstants.NATIVE_TOKEN for ETH
    0,                   // amount0Min (slippage)
    0,                   // amount1Min (slippage)
    0                    // minCashOutReturn (0 = auto 1% tolerance)
);

// Periodically collect LP fees:
hook.collectAndRouteLPFees(projectId, terminalToken);

// Rebalance when rates change significantly:
hook.rebalanceLiquidity(projectId, terminalToken, 0, 0, 0, 0);
```
