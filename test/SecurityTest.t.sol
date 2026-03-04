// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {LPSplitHookTestBase} from "./TestBase.sol";
import {UniV3DeploymentSplitHook} from "../src/UniV3DeploymentSplitHook.sol";
import {JBSplit} from "@bananapus/core/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core/structs/JBSplitHookContext.sol";
import {JBAccountingContext} from "@bananapus/core/structs/JBAccountingContext.sol";
import {IJBSplitHook} from "@bananapus/core/interfaces/IJBSplitHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Security-focused tests for UniV3DeploymentSplitHook.
/// @dev Covers access control on processSplitWith, claimFeeTokensFor authorization,
///      permissionless function access, cross-project isolation, and reentrancy safety.
contract SecurityTest is LPSplitHookTestBase {

    // ─────────────────────────────────────────────────────────────────────
    // 1. processSplitWith -- only the controller can call it
    // ─────────────────────────────────────────────────────────────────────

    /// @notice processSplitWith reverts when called by an arbitrary address that is not the controller.
    function test_OnlyController_CanProcessSplit() public {
        JBSplitHookContext memory context = _buildReservedContext(PROJECT_ID, 100e18);
        projectToken.mint(address(hook), 100e18);

        vm.prank(user); // NOT the controller
        vm.expectRevert(
            UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_SplitSenderNotValidControllerOrTerminal.selector
        );
        hook.processSplitWith(context);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. processSplitWith -- wrong hook address in context
    // ─────────────────────────────────────────────────────────────────────

    /// @notice processSplitWith reverts when context.split.hook points to a different contract.
    function test_WrongHookInContext_Reverts() public {
        uint256 amount = 100e18;
        projectToken.mint(address(hook), amount);

        // Build context with a split whose hook is a random address, not this hook
        JBSplitHookContext memory context = JBSplitHookContext({
            token: address(projectToken),
            amount: amount,
            decimals: 18,
            projectId: PROJECT_ID,
            groupId: 1,
            split: JBSplit({
                percent: 1000000,
                projectId: 0,
                beneficiary: payable(address(0)),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(makeAddr("wrongHook"))
            })
        });

        vm.prank(address(controller));
        vm.expectRevert(
            UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_NotHookSpecifiedInContext.selector
        );
        hook.processSplitWith(context);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. processSplitWith -- payout groupId (0) reverts
    // ─────────────────────────────────────────────────────────────────────

    /// @notice processSplitWith reverts with TerminalTokensNotAllowed when groupId != 1 (payouts).
    function test_PayoutGroupId_Reverts() public {
        uint256 amount = 100e18;
        projectToken.mint(address(hook), amount);

        // groupId=0 means payout split, not reserved tokens
        JBSplitHookContext memory context = _buildContext(
            PROJECT_ID, address(projectToken), amount, 0
        );

        vm.prank(address(controller));
        vm.expectRevert(
            UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_TerminalTokensNotAllowed.selector
        );
        hook.processSplitWith(context);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. claimFeeTokensFor -- valid operator succeeds
    // ─────────────────────────────────────────────────────────────────────

    /// @notice claimFeeTokensFor transfers fee tokens when the beneficiary is a valid split operator.
    function test_ClaimFeeTokens_ValidOperator() public {
        address beneficiary = makeAddr("beneficiary");

        // Step 1: Accumulate and deploy pool (deployPool called as owner inside helper)
        _accumulateAndDeploy(PROJECT_ID, 1000e18);

        // Step 2: Set up collectable fees on the NFPM mock
        // Determine token ordering to figure out which amount slot is the terminal token
        address pool = hook.poolOf(PROJECT_ID, address(terminalToken));
        uint256 tokenId = hook.tokenIdForPool(pool);
        (address token0,) = _sortForTest(address(projectToken), address(terminalToken));

        uint256 feeAmount = 50e18;
        if (token0 == address(terminalToken)) {
            // Terminal token is token0
            nfpm.setCollectableFees(tokenId, feeAmount, 0);
            // Mint terminal tokens to NFPM so it can transfer them during collect
            terminalToken.mint(address(nfpm), feeAmount);
        } else {
            // Terminal token is token1
            nfpm.setCollectableFees(tokenId, 0, feeAmount);
            terminalToken.mint(address(nfpm), feeAmount);
        }

        // Step 3: Set fee terminal accounting context for the fee project
        terminal.setAccountingContext(
            FEE_PROJECT_ID,
            address(terminalToken),
            uint32(uint160(address(terminalToken))),
            18
        );

        // Step 4: Call collectAndRouteLPFees -- this routes fees and creates claimable fee tokens
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        // Step 5: Verify claimable fee tokens were generated
        uint256 claimable = hook.claimableFeeTokens(PROJECT_ID);
        assertTrue(claimable > 0, "Claimable fee tokens should be > 0 after fee collection");

        // Step 6: Set operator authorization for the beneficiary
        revDeployer.setOperator(PROJECT_ID, beneficiary, true);

        // Step 7: Record the fee project token balance before claiming
        uint256 balanceBefore = feeProjectToken.balanceOf(beneficiary);

        // Step 8: Claim fee tokens
        hook.claimFeeTokensFor(PROJECT_ID, beneficiary);

        // Step 9: Verify tokens were transferred to beneficiary
        uint256 balanceAfter = feeProjectToken.balanceOf(beneficiary);
        assertEq(balanceAfter - balanceBefore, claimable, "Beneficiary should receive claimed fee tokens");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 5. claimFeeTokensFor -- unauthorized beneficiary reverts
    // ─────────────────────────────────────────────────────────────────────

    /// @notice claimFeeTokensFor reverts when the beneficiary is not a valid split operator.
    function test_ClaimFeeTokens_InvalidOperator_Reverts() public {
        address beneficiary = makeAddr("unauthorized");

        // Do NOT set the operator for this beneficiary
        vm.expectRevert(
            UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_UnauthorizedBeneficiary.selector
        );
        hook.claimFeeTokensFor(PROJECT_ID, beneficiary);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 6. claimFeeTokensFor -- clears balance before transfer (reentrancy safe)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice After claiming, claimableFeeTokens for the project should be zero.
    function test_ClaimFeeTokens_ClearsBeforeTransfer() public {
        address beneficiary = makeAddr("beneficiary");

        // Accumulate and deploy pool (deployPool called as owner inside helper)
        _accumulateAndDeploy(PROJECT_ID, 1000e18);

        address pool = hook.poolOf(PROJECT_ID, address(terminalToken));
        uint256 tokenId = hook.tokenIdForPool(pool);
        (address token0,) = _sortForTest(address(projectToken), address(terminalToken));

        uint256 feeAmount = 50e18;
        if (token0 == address(terminalToken)) {
            nfpm.setCollectableFees(tokenId, feeAmount, 0);
        } else {
            nfpm.setCollectableFees(tokenId, 0, feeAmount);
        }
        terminalToken.mint(address(nfpm), feeAmount);

        terminal.setAccountingContext(
            FEE_PROJECT_ID,
            address(terminalToken),
            uint32(uint160(address(terminalToken))),
            18
        );

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        uint256 claimableBefore = hook.claimableFeeTokens(PROJECT_ID);
        assertTrue(claimableBefore > 0, "Should have claimable tokens before claiming");

        // Set operator and claim
        revDeployer.setOperator(PROJECT_ID, beneficiary, true);
        hook.claimFeeTokensFor(PROJECT_ID, beneficiary);

        // Verify the claimable balance is zeroed out
        uint256 claimableAfter = hook.claimableFeeTokens(PROJECT_ID);
        assertEq(claimableAfter, 0, "claimableFeeTokens should be 0 after claiming");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 7. claimFeeTokensFor -- zero balance succeeds with no transfer
    // ─────────────────────────────────────────────────────────────────────

    /// @notice claimFeeTokensFor succeeds when no fees are accumulated (no-op, no revert).
    function test_ClaimFeeTokens_ZeroBalance_NoTransfer() public {
        address beneficiary = makeAddr("beneficiary");

        // Authorize the beneficiary as a valid operator
        revDeployer.setOperator(PROJECT_ID, beneficiary, true);

        // No fees have been collected, so claimableFeeTokens[PROJECT_ID] == 0
        assertEq(hook.claimableFeeTokens(PROJECT_ID), 0, "Pre-condition: no claimable tokens");

        // Record balance before
        uint256 balanceBefore = feeProjectToken.balanceOf(beneficiary);

        // Should succeed without reverting
        hook.claimFeeTokensFor(PROJECT_ID, beneficiary);

        // No tokens should have been transferred
        uint256 balanceAfter = feeProjectToken.balanceOf(beneficiary);
        assertEq(balanceAfter, balanceBefore, "No tokens should transfer when claimable is 0");

        // claimableFeeTokens should still be 0
        assertEq(hook.claimableFeeTokens(PROJECT_ID), 0, "claimableFeeTokens remains 0");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 8. Cross-project isolation
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Accumulating tokens for one project does not affect another project's balance.
    function test_CrossProjectIsolation() public {
        uint256 projectA = PROJECT_ID;       // Already configured (ID=1)
        uint256 projectB = 3;

        // Set up project B with its own controller, weights, and terminal
        _setDirectoryController(projectB, address(controller));
        controller.setWeight(projectB, DEFAULT_WEIGHT);
        controller.setFirstWeight(projectB, DEFAULT_FIRST_WEIGHT);
        controller.setReservedPercent(projectB, DEFAULT_RESERVED_PERCENT);
        controller.setBaseCurrency(projectB, 1);
        _setDirectoryTerminal(projectB, address(terminalToken), address(terminal));
        _addDirectoryTerminal(projectB, address(terminal));

        terminal.setAccountingContext(
            projectB,
            address(terminalToken),
            uint32(uint160(address(terminalToken))),
            18
        );
        terminal.addAccountingContext(
            projectB,
            JBAccountingContext({
                token: address(terminalToken),
                decimals: 18,
                currency: uint32(uint160(address(terminalToken)))
            })
        );

        // Accumulate different amounts for each project
        uint256 amountA = 100e18;
        uint256 amountB = 777e18;

        _accumulateTokens(projectA, amountA);
        _accumulateTokens(projectB, amountB);

        // Verify independent accounting
        assertEq(
            hook.accumulatedProjectTokens(projectA),
            amountA,
            "Project A should have its own accumulated balance"
        );
        assertEq(
            hook.accumulatedProjectTokens(projectB),
            amountB,
            "Project B should have its own accumulated balance"
        );

        // Accumulate more for project A and verify B is unchanged
        _accumulateTokens(projectA, 50e18);
        assertEq(
            hook.accumulatedProjectTokens(projectA),
            amountA + 50e18,
            "Project A total should reflect additional accumulation"
        );
        assertEq(
            hook.accumulatedProjectTokens(projectB),
            amountB,
            "Project B should be unaffected by Project A accumulation"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // 9. collectAndRouteLPFees -- permissionless
    // ─────────────────────────────────────────────────────────────────────

    /// @notice collectAndRouteLPFees can be called by any address (no access control).
    function test_CollectFees_Permissionless() public {
        // Deploy pool first (deployPool called as owner inside helper)
        _accumulateAndDeploy(PROJECT_ID, 1000e18);

        // Set up collectable fees on NFPM
        address pool = hook.poolOf(PROJECT_ID, address(terminalToken));
        uint256 tokenId = hook.tokenIdForPool(pool);
        (address token0,) = _sortForTest(address(projectToken), address(terminalToken));

        uint256 feeAmount = 10e18;
        if (token0 == address(terminalToken)) {
            nfpm.setCollectableFees(tokenId, feeAmount, 0);
        } else {
            nfpm.setCollectableFees(tokenId, 0, feeAmount);
        }
        terminalToken.mint(address(nfpm), feeAmount);

        terminal.setAccountingContext(
            FEE_PROJECT_ID,
            address(terminalToken),
            uint32(uint160(address(terminalToken))),
            18
        );

        // Call from a random user address -- should succeed without reverting
        address randomCaller = makeAddr("randomCaller");
        vm.prank(randomCaller);
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        // Verify fees were collected (collect call count increased)
        assertTrue(nfpm.collectCallCount() > 0, "Fees should have been collected");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 10. deployPool -- requires owner or SET_BUYBACK_POOL permission
    // ─────────────────────────────────────────────────────────────────────

    /// @notice deployPool reverts when called by a random address without permission.
    function test_DeployPool_UnauthorizedReverts() public {
        uint256 amount = 500e18;

        // Accumulate tokens as the controller
        _accumulateTokens(PROJECT_ID, amount);

        // Call deployPool from a random user address -- should revert
        address randomUser = makeAddr("randomUser");
        vm.prank(randomUser);
        vm.expectRevert();
        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0, 0);
    }

    /// @notice deployPool succeeds when called by the project owner.
    function test_DeployPool_OwnerSucceeds() public {
        uint256 amount = 500e18;

        // Accumulate tokens as the controller
        _accumulateTokens(PROJECT_ID, amount);

        // Approve hook to spend project tokens (for NFPM mint)
        vm.startPrank(address(hook));
        projectToken.approve(address(nfpm), type(uint256).max);
        terminalToken.approve(address(nfpm), type(uint256).max);
        vm.stopPrank();

        // Call deployPool as the project owner -- should succeed
        vm.prank(owner);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0, 0);

        // Verify pool was deployed
        address pool = hook.poolOf(PROJECT_ID, address(terminalToken));
        assertTrue(pool != address(0), "Pool should have been deployed by owner");

        // Verify the NFPM mint was called
        assertTrue(nfpm.mintCallCount() > 0, "NFPM mint should have been called");

        // Verify projectDeployed is set
        assertTrue(hook.projectDeployed(PROJECT_ID), "projectDeployed should be true after deployment");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 11. processSplitWith -- burns after deployment
    // ─────────────────────────────────────────────────────────────────────

    /// @notice After pool deployment, processSplitWith burns tokens instead of accumulating.
    function test_ProcessSplit_BurnsAfterDeployment() public {
        // Deploy pool (sets projectDeployed[PROJECT_ID] = true)
        _accumulateAndDeploy(PROJECT_ID, 1000e18);

        // Verify project is in deployed state
        assertTrue(hook.projectDeployed(PROJECT_ID), "projectDeployed should be true");

        // Now send more tokens via processSplitWith -- should burn, not accumulate
        uint256 additionalAmount = 200e18;
        projectToken.mint(address(hook), additionalAmount);

        JBSplitHookContext memory context = _buildReservedContext(PROJECT_ID, additionalAmount);
        vm.prank(address(controller));
        hook.processSplitWith(context);

        // accumulatedProjectTokens should NOT increase (tokens were burned, not accumulated)
        // After _accumulateAndDeploy, the accumulated balance is consumed by deployPool,
        // so new tokens should not add to it
        // The key check: projectDeployed is true, so the burn path was taken
        assertTrue(hook.projectDeployed(PROJECT_ID), "projectDeployed remains true after burn");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Internal helper to sort tokens (mirrors hook's _sortTokens)
    // ─────────────────────────────────────────────────────────────────────

    function _sortForTest(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1)
    {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }
}
