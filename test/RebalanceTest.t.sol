// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {LPSplitHookTestBase} from "./TestBase.sol";
import {UniV3DeploymentSplitHook} from "../src/UniV3DeploymentSplitHook.sol";
import {MockERC20} from "./mock/MockERC20.sol";

/// @notice Tests for UniV3DeploymentSplitHook.rebalanceLiquidity function.
/// @dev Covers revert conditions, NFPM interactions (collect, decrease, burn, mint), and permissionlessness.
contract RebalanceTest is LPSplitHookTestBase {

    uint256 poolTokenId;
    address pool;

    function setUp() public override {
        super.setUp();

        // Deploy a pool so we have a position to rebalance
        _accumulateAndDeploy(PROJECT_ID, 100e18);
        pool = hook.poolOf(PROJECT_ID, address(terminalToken));
        poolTokenId = hook.tokenIdForPool(pool);

        // Ensure NFPM has tokens so that collect can transfer them to the hook
        // after decreaseLiquidity makes them collectable
        projectToken.mint(address(nfpm), 50e18);
        terminalToken.mint(address(nfpm), 50e18);
    }

    // -----------------------------------------------------------------------
    // 1. rebalanceLiquidity -- reverts when no pool exists
    // -----------------------------------------------------------------------

    /// @notice rebalanceLiquidity reverts with InvalidStageForAction when no pool
    ///         has been deployed for the project/token pair.
    function test_Rebalance_RevertsIfNoPoolDeployed() public {
        // Use a separate project that has no pool deployed
        uint256 newProjectId = 3;
        controller.setWeight(newProjectId, DEFAULT_WEIGHT);
        controller.setFirstWeight(newProjectId, DEFAULT_FIRST_WEIGHT);
        _setDirectoryController(newProjectId, address(controller));
        _setDirectoryTerminal(newProjectId, address(terminalToken), address(terminal));

        vm.expectRevert(UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_InvalidStageForAction.selector);
        hook.rebalanceLiquidity(newProjectId, address(terminalToken), 0, 0, 0, 0);
    }

    // -----------------------------------------------------------------------
    // 2. rebalanceLiquidity -- reverts if no pool exists for token pair
    // -----------------------------------------------------------------------

    /// @notice rebalanceLiquidity reverts with InvalidStageForAction when there is no pool
    ///         for the given projectId/terminalToken pair.
    function test_Rebalance_RevertsIfNoPool() public {
        // Use a different terminal token that has a primary terminal but no pool deployed
        MockERC20 otherToken = new MockERC20("Other", "OTH", 18);
        _setDirectoryTerminal(PROJECT_ID, address(otherToken), address(terminal));

        // Set accounting context for the other token
        terminal.setAccountingContext(
            PROJECT_ID,
            address(otherToken),
            uint32(uint160(address(otherToken))),
            18
        );

        vm.expectRevert(UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_InvalidStageForAction.selector);
        hook.rebalanceLiquidity(PROJECT_ID, address(otherToken), 0, 0, 0, 0);
    }

    // -----------------------------------------------------------------------
    // 3. rebalanceLiquidity -- reverts if terminal token is invalid
    // -----------------------------------------------------------------------

    /// @notice rebalanceLiquidity reverts with InvalidTerminalToken when the terminal token
    ///         has no primary terminal configured in the directory.
    function test_Rebalance_RevertsIfInvalidTerminal() public {
        address randomToken = makeAddr("randomToken");

        vm.expectRevert(UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_InvalidTerminalToken.selector);
        hook.rebalanceLiquidity(PROJECT_ID, randomToken, 0, 0, 0, 0);
    }

    // -----------------------------------------------------------------------
    // 4. rebalanceLiquidity -- collects fees first
    // -----------------------------------------------------------------------

    /// @notice rebalanceLiquidity calls NFPM.collect at least once (the first collect
    ///         before decreaseLiquidity to harvest accrued fees).
    function test_Rebalance_CollectsFeesFirst() public {
        // Pre-configure some collectable fees on the position
        nfpm.setCollectableFees(poolTokenId, 2e18, 3e18);

        uint256 collectCountBefore = nfpm.collectCallCount();

        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0, 0, 0);

        // Collect is called at least twice: once for fees, once after decreaseLiquidity
        assertTrue(
            nfpm.collectCallCount() >= collectCountBefore + 2,
            "NFPM collect should be called at least twice during rebalance"
        );
    }

    // -----------------------------------------------------------------------
    // 5. rebalanceLiquidity -- removes all liquidity
    // -----------------------------------------------------------------------

    /// @notice rebalanceLiquidity calls NFPM.decreaseLiquidity exactly once to remove
    ///         all liquidity from the existing position.
    function test_Rebalance_RemovesAllLiquidity() public {
        uint256 decreaseCountBefore = nfpm.decreaseLiquidityCallCount();

        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0, 0, 0);

        assertEq(
            nfpm.decreaseLiquidityCallCount(),
            decreaseCountBefore + 1,
            "NFPM decreaseLiquidity should be called exactly once"
        );
    }

    // -----------------------------------------------------------------------
    // 6. rebalanceLiquidity -- burns old NFT
    // -----------------------------------------------------------------------

    /// @notice rebalanceLiquidity calls NFPM.burn exactly once to remove the old position NFT
    ///         before minting a new one.
    function test_Rebalance_BurnsOldNFT() public {
        uint256 burnCountBefore = nfpm.burnCallCount();

        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0, 0, 0);

        assertEq(
            nfpm.burnCallCount(),
            burnCountBefore + 1,
            "NFPM burn should be called exactly once"
        );
    }

    // -----------------------------------------------------------------------
    // 7. rebalanceLiquidity -- mints new position
    // -----------------------------------------------------------------------

    /// @notice rebalanceLiquidity calls NFPM.mint to create a new LP position with
    ///         updated tick bounds. The mint count should increase by 1 from the deploy mint.
    function test_Rebalance_MintsNewPosition() public {
        uint256 mintCountBefore = nfpm.mintCallCount();
        // mintCountBefore should be 1 (from the initial _accumulateAndDeploy)

        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0, 0, 0);

        assertEq(
            nfpm.mintCallCount(),
            mintCountBefore + 1,
            "NFPM mint should be called once more for the new position"
        );
    }

    // -----------------------------------------------------------------------
    // 8. rebalanceLiquidity -- updates tokenIdForPool
    // -----------------------------------------------------------------------

    /// @notice After rebalance, the tokenIdForPool mapping should point to a new tokenId
    ///         (different from the original one created during deployPool).
    function test_Rebalance_UpdatesTokenId() public {
        uint256 originalTokenId = hook.tokenIdForPool(pool);
        assertTrue(originalTokenId != 0, "original tokenId should be nonzero");

        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0, 0, 0);

        uint256 newTokenId = hook.tokenIdForPool(pool);
        assertTrue(newTokenId != 0, "new tokenId should be nonzero");
        assertTrue(
            newTokenId != originalTokenId,
            "tokenIdForPool should change after rebalance"
        );
    }

    // -----------------------------------------------------------------------
    // 9. rebalanceLiquidity -- permissionless (anyone can call)
    // -----------------------------------------------------------------------

    /// @notice rebalanceLiquidity is permissionless: a random user address can call it
    ///         without any special permissions and it succeeds.
    function test_Rebalance_Permissionless() public {
        address randomUser = makeAddr("randomRebalancer");

        vm.prank(randomUser);
        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0, 0, 0);

        // Verify it succeeded by checking the tokenId was updated
        uint256 newTokenId = hook.tokenIdForPool(pool);
        assertTrue(newTokenId != 0, "rebalance should succeed from any caller");
        assertTrue(
            newTokenId != poolTokenId,
            "tokenId should change after permissionless rebalance"
        );
    }

    // -----------------------------------------------------------------------
    // 10. rebalanceLiquidity -- routes collected fees
    // -----------------------------------------------------------------------

    /// @notice When the position has accrued fees, rebalanceLiquidity collects them and
    ///         routes terminal token fees to the project (via pay for fee project or addToBalance).
    function test_Rebalance_HandlesFees() public {
        // Pre-configure collectable fees on the position
        // We need to figure out token ordering: the mock NFPM stores token0/token1 in the position
        // The fees need to include terminal token fees to trigger routing
        (address token0,) = _sortTokens(address(projectToken), address(terminalToken));

        uint256 feeAmount0;
        uint256 feeAmount1;
        if (token0 == address(terminalToken)) {
            feeAmount0 = 5e18;
            feeAmount1 = 0;
        } else {
            feeAmount0 = 0;
            feeAmount1 = 5e18;
        }

        nfpm.setCollectableFees(poolTokenId, feeAmount0, feeAmount1);

        // Ensure NFPM has enough terminal tokens for the fee transfer
        terminalToken.mint(address(nfpm), 5e18);

        // Set up fee project terminal
        terminal.setAccountingContext(
            FEE_PROJECT_ID,
            address(terminalToken),
            uint32(uint160(address(terminalToken))),
            18
        );

        uint256 payCountBefore = terminal.payCallCount();
        uint256 addToBalanceCountBefore = terminal.addToBalanceCallCount();

        hook.rebalanceLiquidity(PROJECT_ID, address(terminalToken), 0, 0, 0, 0);

        // Fees should have been routed: either pay (for fee project) or addToBalance (for original project)
        bool feesRouted = (terminal.payCallCount() > payCountBefore)
            || (terminal.addToBalanceCallCount() > addToBalanceCountBefore);
        assertTrue(feesRouted, "Collected fees should be routed via pay or addToBalance");
    }

    // --- Helper ------------------------------------------------------------

    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }
}
