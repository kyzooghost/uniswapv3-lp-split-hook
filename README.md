# nana-lp-split-hook-v5

Juicebox split hook that accumulates reserved project tokens, then deploys a Uniswap V3 liquidity position bounded by the project's issuance rate (ceiling) and cash-out rate (floor), with ongoing fee collection and liquidity rebalancing.

## Architecture

| Contract | Description |
|----------|-------------|
| `UniV3DeploymentSplitHook` | `IJBSplitHook` implementation with a two-stage lifecycle. **Before deployment:** accumulates project tokens received via reserved-token splits. **After deployment:** burns newly received project tokens, manages the V3 LP position (fee collection, rebalancing), and routes LP fees back to the project with a configurable fee split to a fee project. Inherits `JBPermissioned`, `ERC2771Context`, `Ownable`. |
| `IUniV3DeploymentSplitHook` | Interface declaring `isPoolDeployed`, `deployPool`, `collectAndRouteLPFees`, `claimFeeTokensFor`, plus events. |
| `IREVDeployer` | Minimal interface for `isSplitOperatorOf(projectId, operator)` used to authorize fee-token claims. |

## Lifecycle

```
1. Configure as a reserved-token split hook for a Juicebox project
   |
2. Controller calls processSplitWith() on each reserved-token distribution
   --> Tokens accumulate in accumulatedProjectTokens[projectId]
   |
3. Project owner calls deployPool(projectId, terminalToken, ...)
   --> Creates V3 pool at geometric mean of [cashOutRate, issuanceRate]
   --> Computes optimal cash-out fraction for LP geometry
   --> Cashes out a portion of project tokens for terminal tokens
   --> Mints V3 LP position bounded by [cashOutRate tick, issuanceRate tick]
   --> Burns leftover project tokens, adds leftover terminal tokens to project
   --> Sets projectDeployed[projectId] = true
   |
4. Future processSplitWith() calls burn received project tokens
   |
5. Anyone calls collectAndRouteLPFees(projectId, terminalToken)
   --> Collects fees from V3 position
   --> Routes terminal token fees: FEE_PERCENT to fee project, rest to original project
   --> Burns collected project token fees
   |
6. Anyone calls rebalanceLiquidity(projectId, terminalToken, ...)
   --> Removes old position, burns NFT
   --> Recalculates tick bounds from current rates
   --> Mints new position with updated bounds
   |
7. Revnet operator calls claimFeeTokensFor(projectId, beneficiary)
   --> Transfers accumulated fee-project tokens to beneficiary
```

## Install

```bash
npm install
forge install
```

## Develop

| Command | Description |
|---------|-------------|
| `forge build` | Compile (requires `via_ir = true` due to stack depth) |
| `forge test` | Run tests |
| `forge test -vvv` | Run tests with full trace |

## Key Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `BPS` | 10000 | Basis points denominator |
| `UNISWAP_V3_POOL_FEE` | 10000 (1%) | V3 pool fee tier |
| `TICK_SPACING` | 200 | Tick spacing for 1% fee tier |

## Constructor

```solidity
constructor(
    address initialOwner,                              // Contract owner
    address directory,                                 // JBDirectory
    IJBPermissions permissions,                        // JBPermissions
    address tokens,                                    // JBTokens
    address uniswapV3Factory,                          // V3 Factory
    address uniswapV3NonfungiblePositionManager,       // V3 NonfungiblePositionManager
    uint256 feeProjectId,                              // Project ID to receive LP fee split
    uint256 feePercent,                                // Fee split in basis points (e.g. 3800 = 38%)
    address revDeployer,                               // REVDeployer for operator validation
    address trustedForwarder                           // ERC-2771 trusted forwarder
)
```

## License

MIT
