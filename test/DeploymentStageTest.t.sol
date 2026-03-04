// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {LPSplitHookTestBase} from "./TestBase.sol";
import {UniV3DeploymentSplitHook} from "../src/UniV3DeploymentSplitHook.sol";
import {IUniV3DeploymentSplitHook} from "../src/interfaces/IUniV3DeploymentSplitHook.sol";
import {JBPermissioned} from "@bananapus/core/abstract/JBPermissioned.sol";
import {JBSplitHookContext} from "@bananapus/core/structs/JBSplitHookContext.sol";

/// @notice Tests for UniV3DeploymentSplitHook deployment stage behavior.
/// @dev Covers deployPool access control, processSplitWith accumulation/burning, leftovers, and revert conditions.
contract DeploymentStageTest is LPSplitHookTestBase {

    function setUp() public override {
        super.setUp();
    }

    // ─────────────────────────────────────────────────────────────────────
    // 1. deployPool — creates pool and sets poolOf
    // ─────────────────────────────────────────────────────────────────────

    /// @notice After accumulating tokens, the project owner calls deployPool which should create
    ///         the pool and set poolOf to a nonzero address.
    function test_DeployPool_CreatesPool() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0, 0);

        address pool = hook.poolOf(PROJECT_ID, address(terminalToken));
        assertTrue(pool != address(0), "poolOf should be nonzero after deployPool");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. deployPool — cashes out optimal fraction of accumulated tokens
    // ─────────────────────────────────────────────────────────────────────

    /// @notice deployPool should cash out an optimal fraction of accumulated project tokens.
    ///         The amount is computed based on LP position geometry (typically < 50%).
    function test_DeployPool_CashesOutOptimalFraction() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0, 0);

        assertEq(terminal.cashOutCallCount(), 1, "cashOutTokensOf should be called once");
        // Optimal fraction is less than or equal to 50% of accumulated
        assertLe(terminal.lastCashOutAmount(), 50e18, "cashOut amount should be <= 50% of accumulated");
        // Should cash out some nonzero amount (we have a positive cash-out rate)
        assertGt(terminal.lastCashOutAmount(), 0, "cashOut amount should be > 0 with positive cash-out rate");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. deployPool — mints LP position via NFPM
    // ─────────────────────────────────────────────────────────────────────

    /// @notice deployPool should call NFPM.mint exactly once to create the LP position.
    function test_DeployPool_MintsLPPosition() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0, 0);

        assertEq(nfpm.mintCallCount(), 1, "NFPM mint should be called once");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. deployPool — sets tokenIdForPool
    // ─────────────────────────────────────────────────────────────────────

    /// @notice After deployment, tokenIdForPool for the created pool should be nonzero.
    function test_DeployPool_SetsTokenId() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0, 0);

        address pool = hook.poolOf(PROJECT_ID, address(terminalToken));
        uint256 tokenId = hook.tokenIdForPool(pool);
        assertTrue(tokenId != 0, "tokenIdForPool should be nonzero after deployPool");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 5. deployPool — clears accumulatedProjectTokens
    // ─────────────────────────────────────────────────────────────────────

    /// @notice After deployment, accumulatedProjectTokens should be reset to 0.
    function test_DeployPool_ClearsAccumulated() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0, 0);

        assertEq(
            hook.accumulatedProjectTokens(PROJECT_ID),
            0,
            "accumulatedProjectTokens should be 0 after deployment"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // 6. deployPool — emits ProjectDeployed event
    // ─────────────────────────────────────────────────────────────────────

    /// @notice deployPool should emit ProjectDeployed with the correct projectId and terminalToken.
    function test_DeployPool_EmitsEvent() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        // Check indexed params: projectId (topic1) and terminalToken (topic2)
        // The pool address (topic3) is unknown ahead of time, so we only check the first two indexed params.
        vm.expectEmit(true, true, false, false);
        emit IUniV3DeploymentSplitHook.ProjectDeployed(PROJECT_ID, address(terminalToken), address(0));

        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0, 0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 7. deployPool — reverts if no tokens accumulated
    // ─────────────────────────────────────────────────────────────────────

    /// @notice deployPool reverts with NoTokensAccumulated when no tokens have been accumulated.
    function test_DeployPool_RevertsIf_NoTokens() public {
        vm.expectRevert(UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_NoTokensAccumulated.selector);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0, 0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 8. deployPool — reverts if pool already deployed (PoolAlreadyDeployed)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice deployPool reverts with PoolAlreadyDeployed when called a second time for the
    ///         same project and terminal token.
    function test_DeployPool_RevertsIf_PoolAlreadyDeployed() public {
        // First deploy succeeds
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        // Accumulate more tokens so NoTokensAccumulated wouldn't fire
        _accumulateTokens(PROJECT_ID, 50e18);

        vm.expectRevert(UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_PoolAlreadyDeployed.selector);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0, 0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 9. deployPool — reverts if terminal token is invalid
    // ─────────────────────────────────────────────────────────────────────

    /// @notice deployPool reverts with InvalidTerminalToken when using a token that has
    ///         no primary terminal configured in the directory.
    function test_DeployPool_RevertsIf_InvalidTerminal() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        // Use an address with no terminal configured
        address invalidToken = makeAddr("invalidToken");

        vm.expectRevert(UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_InvalidTerminalToken.selector);
        vm.prank(owner);
        hook.deployPool(PROJECT_ID, invalidToken, 0, 0, 0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 10. processSplitWith — accumulates tokens when pool not yet deployed
    // ─────────────────────────────────────────────────────────────────────

    /// @notice When processSplitWith is called before the pool has been deployed,
    ///         it should accumulate the tokens (no auto-deploy).
    function test_ProcessSplit_AccumulatesWhenNoPoolDeployed() public {
        uint256 amount = 100e18;
        projectToken.mint(address(hook), amount);

        JBSplitHookContext memory context = _buildReservedContext(PROJECT_ID, amount);

        vm.prank(address(controller));
        hook.processSplitWith(context);

        // Tokens should be accumulated
        assertEq(
            hook.accumulatedProjectTokens(PROJECT_ID),
            amount,
            "accumulatedProjectTokens should equal the sent amount"
        );

        // Pool should NOT exist (no auto-deploy)
        address pool = hook.poolOf(PROJECT_ID, address(terminalToken));
        assertEq(pool, address(0), "poolOf should remain address(0) -- no auto-deploy");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 11. processSplitWith — burns new tokens after pool deployed
    // ─────────────────────────────────────────────────────────────────────

    /// @notice After the pool has been deployed by the owner, processSplitWith should
    ///         burn the newly received project tokens via the controller.
    function test_ProcessSplit_BurnsNewTokens() public {
        // Deploy pool first (as owner)
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        // Reset burn tracking after deploy (deploy may have burned leftovers)
        uint256 burnCountAfterDeploy = controller.burnCallCount();

        // Send new tokens to hook
        uint256 newAmount = 50e18;
        projectToken.mint(address(hook), newAmount);

        JBSplitHookContext memory context = _buildReservedContext(PROJECT_ID, newAmount);

        vm.prank(address(controller));
        hook.processSplitWith(context);

        // Verify burn was called for the newly received tokens
        assertTrue(
            controller.burnCallCount() > burnCountAfterDeploy,
            "controller.burnTokensOf should be called after receiving tokens when pool is deployed"
        );
        assertEq(controller.lastBurnProjectId(), PROJECT_ID, "burn should be for the correct project");
        assertEq(controller.lastBurnHolder(), address(hook), "burn should be from the hook address");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 12. processSplitWith — burns tokens even with 0 accumulated (after deploy)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice After pool is deployed, processSplitWith burns tokens even when there were
    ///         0 accumulated tokens at the time of deployment.
    function test_ProcessSplit_BurnsAfterDeploy_EvenWithZeroAccumulated() public {
        // Deploy pool with some tokens
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        // Confirm accumulated is cleared
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), 0, "accumulated should be 0 after deploy");

        // Reset burn tracking
        uint256 burnCountAfterDeploy = controller.burnCallCount();

        // Send new tokens and process — should burn, not accumulate
        uint256 newAmount = 10e18;
        projectToken.mint(address(hook), newAmount);

        JBSplitHookContext memory context = _buildReservedContext(PROJECT_ID, newAmount);

        vm.prank(address(controller));
        hook.processSplitWith(context);

        // Should have burned, not accumulated
        assertTrue(
            controller.burnCallCount() > burnCountAfterDeploy,
            "burn should be called for newly received tokens after pool deployed"
        );
        assertEq(
            hook.accumulatedProjectTokens(PROJECT_ID),
            0,
            "accumulatedProjectTokens should remain 0 after burning"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // 13. deployPool — handles leftover tokens when NFPM uses less than 100%
    // ─────────────────────────────────────────────────────────────────────

    /// @notice When NFPM uses less than 100% of desired amounts (e.g., 80%), leftover project
    ///         tokens should be burned via the controller.
    function test_DeployPool_HandlesBurnOfLeftovers() public {
        // Set NFPM to only use 80% of desired amounts
        nfpm.setUsagePercent(8000);

        _accumulateTokens(PROJECT_ID, 100e18);

        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0, 0);

        // The hook should have called burnTokensOf for leftover project tokens
        assertTrue(controller.burnCallCount() > 0, "controller.burnTokensOf should be called for leftover tokens");
        assertEq(controller.lastBurnProjectId(), PROJECT_ID, "leftover burn should target the correct project");
        assertEq(controller.lastBurnHolder(), address(hook), "leftover burn should be from the hook");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 14. After pool deployed, processSplitWith only burns — no second pool
    // ─────────────────────────────────────────────────────────────────────

    /// @notice After the pool has been deployed, calling processSplitWith again should NOT
    ///         create a second pool. It should only burn the newly received tokens.
    function test_DeployPool_PoolAlreadyExists_OnlyBurns() public {
        // Deploy pool as owner
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        // Record pool address and NFPM mint count after first deploy
        address firstPool = hook.poolOf(PROJECT_ID, address(terminalToken));
        uint256 mintCountAfterDeploy = nfpm.mintCallCount();
        uint256 burnCountAfterDeploy = controller.burnCallCount();

        // Send new tokens and call processSplitWith
        uint256 newAmount = 25e18;
        projectToken.mint(address(hook), newAmount);

        JBSplitHookContext memory context = _buildReservedContext(PROJECT_ID, newAmount);

        vm.prank(address(controller));
        hook.processSplitWith(context);

        // Pool address should remain the same (no second pool created)
        address poolAfter = hook.poolOf(PROJECT_ID, address(terminalToken));
        assertEq(poolAfter, firstPool, "pool address should not change after second processSplitWith");

        // NFPM.mint should NOT have been called again
        assertEq(nfpm.mintCallCount(), mintCountAfterDeploy, "NFPM mint should not be called again");

        // But burn should have been called for the new tokens
        assertTrue(
            controller.burnCallCount() > burnCountAfterDeploy,
            "burn should be called for newly received tokens when pool already exists"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // 15. deployPool — reverts if caller is unauthorized
    // ─────────────────────────────────────────────────────────────────────

    /// @notice deployPool reverts with JBPermissioned_Unauthorized when called by a random
    ///         user who is not the project owner and has no SET_BUYBACK_POOL permission.
    function test_DeployPool_RevertsIf_Unauthorized() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        address randomUser = makeAddr("randomUser");

        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                owner,          // account (the project owner whose permission is required)
                randomUser,     // sender (the unauthorized caller)
                PROJECT_ID,     // projectId
                25              // permissionId (SET_BUYBACK_POOL_PERMISSION)
            )
        );
        vm.prank(randomUser);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0, 0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 16. deployPool — succeeds for permitted operator
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A user with SET_BUYBACK_POOL permission (permissionId 25) granted by the
    ///         project owner can successfully call deployPool.
    function test_DeployPool_SucceedsFor_PermittedOperator() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        address operator = makeAddr("operator");

        // Grant SET_BUYBACK_POOL permission (25) to operator from owner for PROJECT_ID
        permissions.setPermission(operator, owner, PROJECT_ID, 25, true);

        vm.prank(operator);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0, 0);

        address pool = hook.poolOf(PROJECT_ID, address(terminalToken));
        assertTrue(pool != address(0), "poolOf should be nonzero after deployPool by permitted operator");
    }
}
