// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {LPSplitHookTestBase} from "./TestBase.sol";
import {UniV3DeploymentSplitHook} from "../src/UniV3DeploymentSplitHook.sol";
import {IUniV3DeploymentSplitHook} from "../src/interfaces/IUniV3DeploymentSplitHook.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {JBAccountingContext} from "@bananapus/core/structs/JBAccountingContext.sol";
import {JBSplitHookContext} from "@bananapus/core/structs/JBSplitHookContext.sol";

/// @notice End-to-end lifecycle integration tests for UniV3DeploymentSplitHook.
/// @dev Exercises the full protocol flow: accumulate -> deploy -> collect fees -> rebalance -> claim.
contract IntegrationLifecycle is LPSplitHookTestBase {
    // --- Helpers -----------------------------------------------------------

    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    // -----------------------------------------------------------------------
    // 1. Full lifecycle: accumulate three times, then manually deploy
    // -----------------------------------------------------------------------

    /// @notice Accumulate project tokens across 3 separate splits, verify total tracked,
    ///         then manually deploy the pool and verify all state is updated.
    function test_FullLifecycle_AccumulateThenDeploy() public {
        // Accumulate 3 times
        _accumulateTokens(PROJECT_ID, 30e18);
        _accumulateTokens(PROJECT_ID, 30e18);
        _accumulateTokens(PROJECT_ID, 30e18);
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), 90e18, "accumulated should be 90e18 after 3 deposits");

        // Approve tokens for NFPM (needed for mint transferFrom)
        vm.startPrank(address(hook));
        projectToken.approve(address(nfpm), type(uint256).max);
        terminalToken.approve(address(nfpm), type(uint256).max);
        vm.stopPrank();

        // Deploy pool manually (owner required)
        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0, 0);

        // Verify pool was created
        address pool = hook.poolOf(PROJECT_ID, address(terminalToken));
        assertTrue(pool != address(0), "poolOf should be nonzero after deploy");

        // Verify accumulated tokens were cleared
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), 0, "accumulated should be 0 after deploy");

        // Verify tokenId was set for the pool
        uint256 tokenId = hook.tokenIdForPool(pool);
        assertTrue(tokenId != 0, "tokenIdForPool should be nonzero after deploy");

        // Verify projectDeployed is set
        assertTrue(hook.projectDeployed(PROJECT_ID), "projectDeployed should be true after deploy");

        // Verify isPoolDeployed returns true
        assertTrue(hook.isPoolDeployed(PROJECT_ID, address(terminalToken)), "isPoolDeployed should be true after deploy");
    }

    // -----------------------------------------------------------------------
    // 2. Full lifecycle: deploy pool then collect and route LP fees
    // -----------------------------------------------------------------------

    /// @notice Deploy a pool, configure collectable fees,
    ///         then collect and route them. Verify terminal token fees are routed via pay
    ///         and project token fees are burned.
    function test_FullLifecycle_DeployThenCollectFees() public {
        // Deploy pool
        _accumulateAndDeploy(PROJECT_ID, 100e18);
        address pool = hook.poolOf(PROJECT_ID, address(terminalToken));
        uint256 poolTokenId = hook.tokenIdForPool(pool);

        // Determine token ordering for this pool
        bool terminalTokenIsToken0 = address(terminalToken) < address(projectToken);

        // Set collectable terminal token fees on NFPM and fund it
        uint256 terminalFeeAmount = 10e18;
        uint256 projectFeeAmount = 5e18;
        if (terminalTokenIsToken0) {
            nfpm.setCollectableFees(poolTokenId, terminalFeeAmount, projectFeeAmount);
        } else {
            nfpm.setCollectableFees(poolTokenId, projectFeeAmount, terminalFeeAmount);
        }
        terminalToken.mint(address(nfpm), terminalFeeAmount);
        projectToken.mint(address(nfpm), projectFeeAmount);

        uint256 payCountBefore = terminal.payCallCount();
        uint256 burnCountBefore = controller.burnCallCount();

        // Collect and route fees
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        // Verify terminal token fees were routed (pay was called for fee project)
        assertGt(terminal.payCallCount(), payCountBefore, "terminal.pay should be called to route terminal token fees");

        // Verify project token fees were burned
        assertGt(controller.burnCallCount(), burnCountBefore, "controller.burnTokensOf should be called for project token fees");
    }

    // -----------------------------------------------------------------------
    // 3. Full lifecycle: deploy pool then rebalance liquidity
    // -----------------------------------------------------------------------

    /// @notice Deploy a pool, then rebalance liquidity.
    ///         Verify old position is burned and a new position is minted with a different tokenId.
    function test_FullLifecycle_DeployThenRebalance() public {
        // Deploy pool
        _accumulateAndDeploy(PROJECT_ID, 100e18);
        address pool = hook.poolOf(PROJECT_ID, address(terminalToken));
        uint256 originalTokenId = hook.tokenIdForPool(pool);
        assertTrue(originalTokenId != 0, "original tokenId should be nonzero");

        // Mint tokens to NFPM so decreaseLiquidity -> collect has tokens to give back
        projectToken.mint(address(nfpm), 50e18);
        terminalToken.mint(address(nfpm), 50e18);

        // Approve tokens from hook for new NFPM mint
        vm.startPrank(address(hook));
        projectToken.approve(address(nfpm), type(uint256).max);
        terminalToken.approve(address(nfpm), type(uint256).max);
        vm.stopPrank();

        uint256 mintCountBefore = nfpm.mintCallCount();
        uint256 burnCountBefore = nfpm.burnCallCount();

        // Rebalance
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0, 0, 0);

        // Verify old position was burned and new one minted
        assertEq(nfpm.burnCallCount(), burnCountBefore + 1, "NFPM burn should be called once for old position");
        assertEq(nfpm.mintCallCount(), mintCountBefore + 1, "NFPM mint should be called once for new position");

        // Verify new tokenId differs from original
        uint256 newTokenId = hook.tokenIdForPool(pool);
        assertTrue(newTokenId != 0, "new tokenId should be nonzero");
        assertTrue(newTokenId != originalTokenId, "tokenIdForPool should change after rebalance");
    }

    // -----------------------------------------------------------------------
    // 4. Full lifecycle: deploy, collect fees, then claim fee tokens
    // -----------------------------------------------------------------------

    /// @notice Deploy a pool, collect terminal token fees to generate claimable fee project tokens,
    ///         set operator, then claim fee tokens and verify beneficiary receives them.
    function test_FullLifecycle_DeployThenClaimFees() public {
        // Deploy pool
        _accumulateAndDeploy(PROJECT_ID, 100e18);
        address pool = hook.poolOf(PROJECT_ID, address(terminalToken));
        uint256 poolTokenId = hook.tokenIdForPool(pool);

        // Determine token ordering
        bool terminalTokenIsToken0 = address(terminalToken) < address(projectToken);

        // Set collectable terminal token fees on NFPM and fund it
        uint256 feeAmount = 100e18;
        if (terminalTokenIsToken0) {
            nfpm.setCollectableFees(poolTokenId, feeAmount, 0);
        } else {
            nfpm.setCollectableFees(poolTokenId, 0, feeAmount);
        }
        terminalToken.mint(address(nfpm), feeAmount);

        // Set up fee project terminal accounting context for the terminal token
        _setDirectoryTerminal(FEE_PROJECT_ID, address(terminalToken), address(terminal));
        terminal.setAccountingContext(
            FEE_PROJECT_ID,
            address(terminalToken),
            uint32(uint160(address(terminalToken))),
            18
        );

        // Collect and route fees -- this generates claimable fee tokens
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        // Verify claimable fee tokens were accrued
        uint256 claimable = hook.claimableFeeTokens(PROJECT_ID);
        assertGt(claimable, 0, "claimableFeeTokens should be > 0 after fee routing");

        // The mock terminal mints fee project tokens to the hook (beneficiary) during pay.
        // Verify fee project tokens were minted to the hook.
        uint256 hookFeeBalance = feeProjectToken.balanceOf(address(hook));
        assertEq(hookFeeBalance, claimable, "hook should hold fee project tokens equal to claimable amount");

        // Set user as operator for PROJECT_ID
        revDeployer.setOperator(PROJECT_ID, user, true);

        // Claim fee tokens
        uint256 userBalanceBefore = feeProjectToken.balanceOf(user);
        hook.claimFeeTokensFor(PROJECT_ID, user);
        uint256 userBalanceAfter = feeProjectToken.balanceOf(user);

        // Verify user received the fee project tokens
        assertEq(
            userBalanceAfter - userBalanceBefore,
            claimable,
            "user should receive all claimable fee project tokens"
        );

        // Verify claimable balance is cleared
        assertEq(hook.claimableFeeTokens(PROJECT_ID), 0, "claimableFeeTokens should be 0 after claim");
    }

    // -----------------------------------------------------------------------
    // 5. Full lifecycle: multiple independent projects
    // -----------------------------------------------------------------------

    /// @notice Set up two independent projects, accumulate and deploy pools for each,
    ///         verify they have independent pool addresses and token IDs.
    function test_FullLifecycle_MultipleProjects() public {
        // --- Set up project 3 ---
        uint256 PROJECT_3 = 3;
        MockERC20 projectToken3 = new MockERC20("Project3 Token", "P3", 18);

        // Configure controller for project 3
        controller.setWeight(PROJECT_3, 1000e18);
        controller.setFirstWeight(PROJECT_3, 1000e18);
        controller.setReservedPercent(PROJECT_3, 1000);
        controller.setBaseCurrency(PROJECT_3, 1);

        // Wire directory for project 3
        _setDirectoryController(PROJECT_3, address(controller));
        _setDirectoryTerminal(PROJECT_3, address(terminalToken), address(terminal));
        _addDirectoryTerminal(PROJECT_3, address(terminal));

        // Wire tokens for project 3
        jbTokens.setToken(PROJECT_3, address(projectToken3));
        terminal.setProjectToken(PROJECT_3, address(projectToken3));
        terminal.setAccountingContext(
            PROJECT_3,
            address(terminalToken),
            uint32(uint160(address(terminalToken))),
            18
        );
        terminal.addAccountingContext(
            PROJECT_3,
            JBAccountingContext({
                token: address(terminalToken),
                decimals: 18,
                currency: uint32(uint160(address(terminalToken)))
            })
        );
        store.setSurplus(PROJECT_3, 0.5e18);

        // Set project 3 ownership
        jbProjects.setOwner(PROJECT_3, owner);

        // --- Accumulate for both projects ---
        _accumulateTokens(PROJECT_ID, 50e18);

        // For project 3, manually accumulate (using its own project token)
        projectToken3.mint(address(hook), 50e18);
        JBSplitHookContext memory ctx3 = _buildContext(PROJECT_3, address(projectToken3), 50e18, 1);
        vm.prank(address(controller));
        hook.processSplitWith(ctx3);

        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), 50e18, "PROJECT_ID accumulated should be 50e18");
        assertEq(hook.accumulatedProjectTokens(PROJECT_3), 50e18, "PROJECT_3 accumulated should be 50e18");

        // --- Approve tokens for NFPM ---
        vm.startPrank(address(hook));
        projectToken.approve(address(nfpm), type(uint256).max);
        projectToken3.approve(address(nfpm), type(uint256).max);
        terminalToken.approve(address(nfpm), type(uint256).max);
        vm.stopPrank();

        // --- Deploy both pools (owner required) ---
        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0, 0);
        vm.prank(owner);
        hook.deployPool(PROJECT_3, address(terminalToken), 0, 0, 0);

        // --- Verify independent pools ---
        address pool1 = hook.poolOf(PROJECT_ID, address(terminalToken));
        address pool3 = hook.poolOf(PROJECT_3, address(terminalToken));

        assertTrue(pool1 != address(0), "PROJECT_ID pool should be nonzero");
        assertTrue(pool3 != address(0), "PROJECT_3 pool should be nonzero");
        assertTrue(pool1 != pool3, "pools should be different addresses (different project tokens)");

        // Verify independent token IDs
        uint256 tokenId1 = hook.tokenIdForPool(pool1);
        uint256 tokenId3 = hook.tokenIdForPool(pool3);
        assertTrue(tokenId1 != 0, "PROJECT_ID tokenId should be nonzero");
        assertTrue(tokenId3 != 0, "PROJECT_3 tokenId should be nonzero");
        assertTrue(tokenId1 != tokenId3, "tokenIds should differ between projects");

        // Verify accumulated tokens were cleared for both
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), 0, "PROJECT_ID accumulated should be 0 after deploy");
        assertEq(hook.accumulatedProjectTokens(PROJECT_3), 0, "PROJECT_3 accumulated should be 0 after deploy");

        // Verify both projects are marked as deployed
        assertTrue(hook.projectDeployed(PROJECT_ID), "PROJECT_ID should be deployed");
        assertTrue(hook.projectDeployed(PROJECT_3), "PROJECT_3 should be deployed");
    }

    // -----------------------------------------------------------------------
    // 6. Full lifecycle: tokens are burned after pool is deployed
    // -----------------------------------------------------------------------

    /// @notice After pool deployment, calling processSplitWith with new tokens should
    ///         burn them rather than accumulate. Accumulated balance stays 0.
    function test_FullLifecycle_BurnAfterDeploy() public {
        // Deploy pool (this sets projectDeployed[PROJECT_ID] = true)
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        // Record burn count after deploy (deploy may burn leftovers)
        uint256 burnCountAfterDeploy = controller.burnCallCount();

        // Send new tokens to hook and call processSplitWith
        // Since projectDeployed is true, tokens should be burned
        uint256 newAmount = 50e18;
        projectToken.mint(address(hook), newAmount);
        JBSplitHookContext memory context = _buildReservedContext(PROJECT_ID, newAmount);

        vm.prank(address(controller));
        hook.processSplitWith(context);

        // Verify tokens were burned (not accumulated)
        assertGt(
            controller.burnCallCount(),
            burnCountAfterDeploy,
            "controller.burnTokensOf should be called after pool deployment"
        );
        assertEq(controller.lastBurnProjectId(), PROJECT_ID, "burn should target PROJECT_ID");
        assertEq(controller.lastBurnHolder(), address(hook), "burn holder should be the hook");

        // Verify accumulated stays 0 (tokens were burned, not accumulated)
        assertEq(
            hook.accumulatedProjectTokens(PROJECT_ID),
            0,
            "accumulatedProjectTokens should remain 0 after burn"
        );
    }

    // -----------------------------------------------------------------------
    // 7. Fuzz lifecycle: various accumulation amounts deploy correctly
    // -----------------------------------------------------------------------

    /// @notice Fuzz the accumulation amount. For any amount in [1e18, 1000e18], the hook should
    ///         accumulate correctly and deploy a pool that clears the accumulated balance.
    function testFuzz_FullLifecycle_VariousAmounts(uint256 amount) public {
        amount = bound(amount, 1e18, 1000e18);

        // Accumulate
        _accumulateTokens(PROJECT_ID, amount);
        assertEq(
            hook.accumulatedProjectTokens(PROJECT_ID),
            amount,
            "accumulated should match deposited amount"
        );

        // Approve tokens for NFPM
        vm.startPrank(address(hook));
        projectToken.approve(address(nfpm), type(uint256).max);
        terminalToken.approve(address(nfpm), type(uint256).max);
        vm.stopPrank();

        // Deploy pool (owner required)
        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0, 0);

        // Verify pool was created
        address pool = hook.poolOf(PROJECT_ID, address(terminalToken));
        assertTrue(pool != address(0), "poolOf should be nonzero after deploy");

        // Verify accumulated tokens were cleared
        assertEq(
            hook.accumulatedProjectTokens(PROJECT_ID),
            0,
            "accumulated should be 0 after deploy"
        );

        // Verify tokenId was set
        uint256 tokenId = hook.tokenIdForPool(pool);
        assertTrue(tokenId != 0, "tokenIdForPool should be nonzero after deploy");

        // Verify project is marked deployed
        assertTrue(hook.projectDeployed(PROJECT_ID), "projectDeployed should be true");
    }
}
