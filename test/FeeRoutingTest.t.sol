// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {LPSplitHookTestBase} from "./TestBase.sol";
import {UniV3DeploymentSplitHook} from "../src/UniV3DeploymentSplitHook.sol";
import {IUniV3DeploymentSplitHook} from "../src/interfaces/IUniV3DeploymentSplitHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Tests for UniV3DeploymentSplitHook fee routing logic.
/// @dev Covers collectAndRouteLPFees, _routeFeesToProject, _routeCollectedFees, and claimFeeTokensFor.
contract FeeRoutingTest is LPSplitHookTestBase {
    // --- Test State --------------------------------------------------------

    uint256 public poolTokenId;
    address public pool;

    // Token ordering helpers (set in setUp)
    bool public terminalTokenIsToken0;

    function setUp() public override {
        super.setUp();

        // Accumulate and deploy a pool for PROJECT_ID
        _accumulateAndDeploy(PROJECT_ID, 100e18);
        pool = hook.poolOf(PROJECT_ID, address(terminalToken));
        poolTokenId = hook.tokenIdForPool(pool);

        // Determine token ordering for this pool
        terminalTokenIsToken0 = address(terminalToken) < address(projectToken);
    }

    // --- Helpers -----------------------------------------------------------

    /// @notice Set collectable fees on the terminal token side of the pool and fund the NFPM.
    function _setTerminalTokenFees(uint256 amount) internal {
        if (terminalTokenIsToken0) {
            nfpm.setCollectableFees(poolTokenId, amount, 0);
        } else {
            nfpm.setCollectableFees(poolTokenId, 0, amount);
        }
        // Mint terminal tokens to NFPM so it can transfer them during collect
        terminalToken.mint(address(nfpm), amount);
    }

    /// @notice Set collectable fees on the project token side of the pool and fund the NFPM.
    function _setProjectTokenFees(uint256 amount) internal {
        if (terminalTokenIsToken0) {
            // Project token is token1
            nfpm.setCollectableFees(poolTokenId, 0, amount);
        } else {
            // Project token is token0
            nfpm.setCollectableFees(poolTokenId, amount, 0);
        }
        // Mint project tokens to NFPM so it can transfer them during collect
        projectToken.mint(address(nfpm), amount);
    }

    /// @notice Set collectable fees on both sides of the pool and fund the NFPM.
    function _setBothFees(uint256 terminalAmount, uint256 projectAmount) internal {
        if (terminalTokenIsToken0) {
            nfpm.setCollectableFees(poolTokenId, terminalAmount, projectAmount);
        } else {
            nfpm.setCollectableFees(poolTokenId, projectAmount, terminalAmount);
        }
        terminalToken.mint(address(nfpm), terminalAmount);
        projectToken.mint(address(nfpm), projectAmount);
    }

    // -----------------------------------------------------------------------
    // 1. collectAndRouteLPFees collects from NFPM
    // -----------------------------------------------------------------------

    /// @notice Verifies that collectAndRouteLPFees calls NFPM.collect.
    function test_CollectFees_CollectsFromNFPM() public {
        uint256 feeAmount = 1000e18;
        _setTerminalTokenFees(feeAmount);

        uint256 collectCountBefore = nfpm.collectCallCount();
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));
        uint256 collectCountAfter = nfpm.collectCallCount();

        assertGt(collectCountAfter, collectCountBefore, "NFPM collect should have been called");
    }

    // -----------------------------------------------------------------------
    // 2. Terminal token fees are routed via pay and addToBalance
    // -----------------------------------------------------------------------

    /// @notice When terminal token fees are collected, they should be routed:
    /// fee portion via terminal.pay (to fee project) and remainder via terminal.addToBalanceOf (to project).
    function test_CollectFees_RoutesTerminalTokenFees() public {
        uint256 feeAmount = 1000e18;
        _setTerminalTokenFees(feeAmount);

        uint256 payCountBefore = terminal.payCallCount();
        uint256 addBalanceCountBefore = terminal.addToBalanceCallCount();

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        assertGt(terminal.payCallCount(), payCountBefore, "terminal.pay should have been called for fee routing");
        assertGt(
            terminal.addToBalanceCallCount(),
            addBalanceCountBefore,
            "terminal.addToBalanceOf should have been called for remainder routing"
        );
    }

    // -----------------------------------------------------------------------
    // 3. Project token fees are burned
    // -----------------------------------------------------------------------

    /// @notice When project token fees are collected, they should be burned via the controller.
    function test_CollectFees_BurnsProjectTokenFees() public {
        uint256 projFeeAmount = 500e18;
        _setProjectTokenFees(projFeeAmount);

        uint256 burnCountBefore = controller.burnCallCount();

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        assertGt(controller.burnCallCount(), burnCountBefore, "controller.burnTokensOf should have been called");
        assertEq(controller.lastBurnProjectId(), PROJECT_ID, "Burn should target PROJECT_ID");
        assertEq(controller.lastBurnHolder(), address(hook), "Burn holder should be the hook");
    }

    // -----------------------------------------------------------------------
    // 4. collectAndRouteLPFees reverts when no pool deployed
    // -----------------------------------------------------------------------

    /// @notice collectAndRouteLPFees should revert if no pool has been deployed for the project.
    function test_CollectFees_RevertsIfNoPoolDeployed() public {
        // Use a fresh project that has no pool deployed
        uint256 freshProjectId = 3;
        controller.setWeight(freshProjectId, DEFAULT_WEIGHT);
        controller.setFirstWeight(freshProjectId, DEFAULT_FIRST_WEIGHT);
        _setDirectoryController(freshProjectId, address(controller));

        vm.expectRevert(UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_InvalidStageForAction.selector);
        hook.collectAndRouteLPFees(freshProjectId, address(terminalToken));
    }

    // -----------------------------------------------------------------------
    // 5. collectAndRouteLPFees reverts if no pool exists for token pair
    // -----------------------------------------------------------------------

    /// @notice collectAndRouteLPFees should revert for a deployed project but without a pool for the given token.
    function test_CollectFees_RevertsIfNoPool() public {
        // Create a project without a deployed pool for a specific token
        uint256 noPoolProjectId = 4;
        controller.setWeight(noPoolProjectId, 1);
        controller.setFirstWeight(noPoolProjectId, DEFAULT_FIRST_WEIGHT);
        _setDirectoryController(noPoolProjectId, address(controller));

        vm.expectRevert(UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_InvalidStageForAction.selector);
        hook.collectAndRouteLPFees(noPoolProjectId, address(terminalToken));
    }

    // -----------------------------------------------------------------------
    // 6. collectAndRouteLPFees reverts if pool exists but tokenId is 0
    // -----------------------------------------------------------------------

    /// @notice collectAndRouteLPFees should revert when pool is set but tokenId mapping is cleared.
    function test_CollectFees_RevertsIfNoTokenId() public {
        // tokenIdForPool is the second mapping in contract storage.
        // Ownable uses slot 0 (_owner), so:
        //   slot 1 = poolOf (nested mapping)
        //   slot 2 = tokenIdForPool (mapping)
        // For mapping(address => uint256), the slot for key `pool` is keccak256(abi.encode(pool, 2))
        bytes32 slot = keccak256(abi.encode(pool, uint256(2)));
        vm.store(address(hook), slot, bytes32(0));

        vm.expectRevert(UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_InvalidStageForAction.selector);
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));
    }

    // -----------------------------------------------------------------------
    // 7. Fee split arithmetic: 38% to fee project, 62% to original project
    // -----------------------------------------------------------------------

    /// @notice Terminal token fees should be split: 38% paid to fee project, 62% added to project balance.
    function test_RouteFees_SplitsBetweenFeeAndOriginal() public {
        uint256 feeAmount = 1000e18;
        _setTerminalTokenFees(feeAmount);

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        // FEE_PERCENT = 3800 => feeAmount = 1000e18 * 3800 / 10000 = 380e18
        uint256 expectedFee = (feeAmount * FEE_PERCENT) / 10000;
        assertEq(expectedFee, 380e18, "Expected fee should be 380e18");

        // Verify terminal.pay was called with the fee amount
        assertEq(terminal.lastPayProjectId(), FEE_PROJECT_ID, "Pay should target FEE_PROJECT_ID");
        assertEq(terminal.lastPayAmount(), expectedFee, "Pay amount should be 38% of total fees");

        // Verify addToBalance was called (for the remaining 62%)
        assertGt(terminal.addToBalanceCallCount(), 0, "addToBalance should have been called for remainder");
    }

    // -----------------------------------------------------------------------
    // 8. Zero collectable fees result in no routing
    // -----------------------------------------------------------------------

    /// @notice When there are zero collectable fees, no pay or addToBalance calls should occur.
    function test_RouteFees_ZeroAmount_NoOp() public {
        // Don't set any collectable fees (defaults to 0)
        uint256 payCountBefore = terminal.payCallCount();
        uint256 addBalanceCountBefore = terminal.addToBalanceCallCount();

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        assertEq(terminal.payCallCount(), payCountBefore, "No pay calls expected for zero fees");
        assertEq(
            terminal.addToBalanceCallCount(),
            addBalanceCountBefore,
            "No addToBalance calls expected for zero fees"
        );
    }

    // -----------------------------------------------------------------------
    // 9. Fee routing tracks claimable fee tokens
    // -----------------------------------------------------------------------

    /// @notice After routing fees, claimableFeeTokens[PROJECT_ID] should be updated with minted fee tokens.
    function test_RouteFees_TracksFeeTokens() public {
        uint256 feeAmount = 1000e18;
        _setTerminalTokenFees(feeAmount);

        uint256 claimableBefore = hook.claimableFeeTokens(PROJECT_ID);

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        uint256 claimableAfter = hook.claimableFeeTokens(PROJECT_ID);
        assertGt(claimableAfter, claimableBefore, "claimableFeeTokens should increase after fee routing");

        // The mock terminal mints 1:1, so fee tokens minted = feeAmount paid
        uint256 expectedFeePayment = (feeAmount * FEE_PERCENT) / 10000; // 380e18
        assertEq(
            claimableAfter - claimableBefore,
            expectedFeePayment,
            "claimableFeeTokens should equal fee tokens minted by terminal.pay"
        );
    }

    // -----------------------------------------------------------------------
    // 10. claimFeeTokensFor -- valid operator receives tokens
    // -----------------------------------------------------------------------

    /// @notice A valid revnet operator can claim accumulated fee tokens.
    function test_ClaimFeeTokens_ValidOperator() public {
        // First generate claimable fee tokens
        uint256 feeAmount = 1000e18;
        _setTerminalTokenFees(feeAmount);
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        uint256 claimable = hook.claimableFeeTokens(PROJECT_ID);
        assertGt(claimable, 0, "Should have claimable fee tokens");

        // Set user as the operator for PROJECT_ID
        revDeployer.setOperator(PROJECT_ID, user, true);

        uint256 userBalanceBefore = feeProjectToken.balanceOf(user);

        hook.claimFeeTokensFor(PROJECT_ID, user);

        uint256 userBalanceAfter = feeProjectToken.balanceOf(user);
        assertEq(
            userBalanceAfter - userBalanceBefore,
            claimable,
            "User should receive all claimable fee tokens"
        );
    }

    // -----------------------------------------------------------------------
    // 11. claimFeeTokensFor -- reverts for non-operator
    // -----------------------------------------------------------------------

    /// @notice claimFeeTokensFor should revert when beneficiary is not a valid revnet operator.
    function test_ClaimFeeTokens_InvalidOperator_Reverts() public {
        // Generate claimable fee tokens first
        uint256 feeAmount = 1000e18;
        _setTerminalTokenFees(feeAmount);
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        // Do NOT set user as operator
        vm.expectRevert(UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_UnauthorizedBeneficiary.selector);
        hook.claimFeeTokensFor(PROJECT_ID, user);
    }

    // -----------------------------------------------------------------------
    // 12. claimFeeTokensFor -- clears balance after claim
    // -----------------------------------------------------------------------

    /// @notice After claiming, claimableFeeTokens for the project should be zero.
    function test_ClaimFeeTokens_ClearsBalance() public {
        // Generate claimable fee tokens
        uint256 feeAmount = 1000e18;
        _setTerminalTokenFees(feeAmount);
        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));

        assertGt(hook.claimableFeeTokens(PROJECT_ID), 0, "Should have claimable fee tokens before claim");

        // Set user as operator and claim
        revDeployer.setOperator(PROJECT_ID, user, true);
        hook.claimFeeTokensFor(PROJECT_ID, user);

        assertEq(hook.claimableFeeTokens(PROJECT_ID), 0, "claimableFeeTokens should be zero after claim");
    }

    // -----------------------------------------------------------------------
    // 13. collectAndRouteLPFees emits LPFeesRouted event
    // -----------------------------------------------------------------------

    /// @notice collectAndRouteLPFees should emit the LPFeesRouted event with correct parameters.
    function test_CollectFees_EmitsLPFeesRouted() public {
        uint256 feeAmount = 1000e18;
        _setTerminalTokenFees(feeAmount);

        // Expected values
        uint256 expectedFee = (feeAmount * FEE_PERCENT) / 10000; // 380e18
        uint256 expectedRemaining = feeAmount - expectedFee; // 620e18
        // Mock terminal mints 1:1, so feeTokensMinted = expectedFee
        uint256 expectedFeeTokensMinted = expectedFee;

        vm.expectEmit(true, true, false, true, address(hook));
        emit IUniV3DeploymentSplitHook.LPFeesRouted(
            PROJECT_ID,
            address(terminalToken),
            feeAmount,
            expectedFee,
            expectedRemaining,
            expectedFeeTokensMinted
        );

        hook.collectAndRouteLPFees(PROJECT_ID, address(terminalToken));
    }
}
