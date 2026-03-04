// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {LPSplitHookTestBase} from "./TestBase.sol";
import {UniV3DeploymentSplitHook} from "../src/UniV3DeploymentSplitHook.sol";
import {IJBPermissions} from "@bananapus/core/interfaces/IJBPermissions.sol";
import {JBConstants} from "@bananapus/core/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core/structs/JBAccountingContext.sol";

/// @notice Wrapper contract that exposes internal native-ETH helper functions for testing.
contract TestableHookForETH is UniV3DeploymentSplitHook {
    constructor(
        address _owner,
        address _directory,
        IJBPermissions _permissions,
        address _tokens,
        address _factory,
        address _nfpm,
        uint256 _feeProjectId,
        uint256 _feePercent,
        address _revDeployer
    )
        UniV3DeploymentSplitHook(
            _owner, _directory, _permissions, _tokens, _factory, _nfpm, _feeProjectId, _feePercent, _revDeployer
        )
    {}

    function exposed_isNativeToken(address token) external pure returns (bool) {
        return _isNativeToken(token);
    }

    function exposed_toUniswapToken(address token) external view returns (address) {
        return _toUniswapToken(token);
    }

    function exposed_getWETH() external view returns (address) {
        return _getWETH();
    }
}

/// @notice Tests for native ETH handling in UniV3DeploymentSplitHook.
/// @dev Covers _isNativeToken, _toUniswapToken, receive(), WETH plumbing,
///      and native-ETH deployment setup through the accounting pipeline.
contract NativeETHTest is LPSplitHookTestBase {
    TestableHookForETH public testableHook;
    address constant NATIVE_TOKEN = address(0x000000000000000000000000000000000000EEEe);

    function setUp() public override {
        super.setUp();

        testableHook = new TestableHookForETH(
            owner,
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            address(v3Factory),
            address(nfpm),
            FEE_PROJECT_ID,
            FEE_PERCENT,
            address(revDeployer)
        );
    }

    // -----------------------------------------------------------------------
    // 1. _isNativeToken returns true for JBConstants.NATIVE_TOKEN
    // -----------------------------------------------------------------------

    /// @notice NATIVE_TOKEN sentinel value must be recognized as native.
    function test_IsNativeToken_Correct() public view {
        assertTrue(
            testableHook.exposed_isNativeToken(NATIVE_TOKEN),
            "NATIVE_TOKEN should be identified as native"
        );
    }

    // -----------------------------------------------------------------------
    // 2. _isNativeToken returns false for other addresses
    // -----------------------------------------------------------------------

    /// @notice Non-native addresses (including address(0), address(1), and real ERC20s) must return false.
    function test_IsNativeToken_OtherAddress() public view {
        assertFalse(
            testableHook.exposed_isNativeToken(address(terminalToken)),
            "ERC20 address should not be native"
        );
        assertFalse(
            testableHook.exposed_isNativeToken(address(0)),
            "address(0) should not be native"
        );
        assertFalse(
            testableHook.exposed_isNativeToken(address(1)),
            "address(1) should not be native"
        );
        assertFalse(
            testableHook.exposed_isNativeToken(address(weth)),
            "WETH address should not be native"
        );
    }

    // -----------------------------------------------------------------------
    // 3. _toUniswapToken converts NATIVE_TOKEN to WETH
    // -----------------------------------------------------------------------

    /// @notice When the terminal token is NATIVE_TOKEN, Uniswap operations
    ///         must use WETH instead (obtained from NFPM.WETH9()).
    function test_ToUniswapToken_NativeETH_ReturnsWETH() public view {
        address result = testableHook.exposed_toUniswapToken(NATIVE_TOKEN);
        assertEq(result, address(weth), "NATIVE_TOKEN should convert to WETH for Uniswap");
    }

    // -----------------------------------------------------------------------
    // 4. _toUniswapToken passes through ERC20 addresses unchanged
    // -----------------------------------------------------------------------

    /// @notice For ordinary ERC20 terminal tokens the address must be returned as-is.
    function test_ToUniswapToken_ERC20_Unchanged() public view {
        address result = testableHook.exposed_toUniswapToken(address(terminalToken));
        assertEq(
            result,
            address(terminalToken),
            "ERC20 address should pass through unchanged"
        );
    }

    // -----------------------------------------------------------------------
    // 5. JBConstants.NATIVE_TOKEN has the expected sentinel value
    // -----------------------------------------------------------------------

    /// @notice Guard against accidental changes to the sentinel constant.
    function test_NativeToken_ConstantValue() public pure {
        assertEq(
            JBConstants.NATIVE_TOKEN,
            address(0x000000000000000000000000000000000000EEEe),
            "JBConstants.NATIVE_TOKEN must be 0x...EEEe"
        );
    }

    // -----------------------------------------------------------------------
    // 6. Hook contract accepts direct ETH transfers (receive function)
    // -----------------------------------------------------------------------

    /// @notice The hook must have a payable receive() so that WETH unwraps
    ///         and terminal cashOuts can send ETH to the contract.
    function test_HookAcceptsETH() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool success,) = address(hook).call{value: 1 ether}("");
        assertTrue(success, "Hook should accept ETH via receive()");
        assertEq(address(hook).balance, 1 ether, "Hook balance should reflect received ETH");
    }

    // -----------------------------------------------------------------------
    // 7. Full native-ETH deployment setup (accounting + accumulation)
    // -----------------------------------------------------------------------

    /// @notice Validate that a project configured with NATIVE_TOKEN as the
    ///         terminal token can wire up directory, accounting contexts,
    ///         accumulate tokens, and verify it is still pre-deployment.
    function test_DeployPool_WithNativeETH_Setup() public {
        // --- Wire the directory for NATIVE_TOKEN ---
        _setDirectoryTerminal(PROJECT_ID, NATIVE_TOKEN, address(terminal));

        // --- Add an accounting context for NATIVE_TOKEN (18 decimals, currency = sentinel) ---
        terminal.setAccountingContext(
            PROJECT_ID,
            NATIVE_TOKEN,
            uint32(uint160(NATIVE_TOKEN)),
            18
        );
        terminal.addAccountingContext(
            PROJECT_ID,
            JBAccountingContext({
                token: NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(NATIVE_TOKEN))
            })
        );

        // --- Accumulate project tokens (simulates reserved-token split) ---
        uint256 accAmount = 100e18;
        projectToken.mint(address(hook), accAmount);

        // Build a split-hook context for reserved tokens (groupId = 1)
        // with the project token as the token field.
        vm.prank(address(controller));
        hook.processSplitWith(
            _buildReservedContext(PROJECT_ID, accAmount)
        );

        // Verify accumulation was recorded
        assertEq(
            hook.accumulatedProjectTokens(PROJECT_ID),
            accAmount,
            "Accumulated tokens should match minted amount"
        );

        // Verify the project has not been deployed yet (no pool exists)
        assertFalse(
            hook.projectDeployed(PROJECT_ID),
            "Project should not be deployed yet (no deployPool called)"
        );
        assertFalse(
            hook.isPoolDeployed(PROJECT_ID, NATIVE_TOKEN),
            "No pool should exist for NATIVE_TOKEN yet"
        );
    }

    // -----------------------------------------------------------------------
    // 8. Full native-ETH deployPool end-to-end
    // -----------------------------------------------------------------------

    /// @notice Full e2e: accumulate project tokens, then deployPool with NATIVE_TOKEN
    ///         as the terminal token. Verifies the pool is created using WETH (not
    ///         the native sentinel), NFPM.mint is called, and the pool/tokenId are set.
    function test_DeployPool_NativeETH_EndToEnd() public {
        // Wire directory for NATIVE_TOKEN
        _setDirectoryTerminal(PROJECT_ID, NATIVE_TOKEN, address(terminal));
        _addDirectoryTerminal(PROJECT_ID, address(terminal));

        // Add accounting context for NATIVE_TOKEN
        terminal.setAccountingContext(
            PROJECT_ID,
            NATIVE_TOKEN,
            uint32(uint160(NATIVE_TOKEN)),
            18
        );
        terminal.addAccountingContext(
            PROJECT_ID,
            JBAccountingContext({
                token: NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(NATIVE_TOKEN))
            })
        );

        // Set NATIVE_TOKEN as the terminal token for cash-outs
        // The mock terminal needs to know how to handle native ETH cash-outs
        terminal.setProjectToken(PROJECT_ID, address(projectToken));

        // Accumulate project tokens
        uint256 accAmount = 100e18;
        projectToken.mint(address(hook), accAmount);

        vm.prank(address(controller));
        hook.processSplitWith(_buildReservedContext(PROJECT_ID, accAmount));

        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), accAmount);

        // Fund the mock terminal with ETH so cash-out can send native ETH
        vm.deal(address(terminal), 100 ether);

        // Deploy pool with NATIVE_TOKEN (owner required)
        // The hook should convert NATIVE_TOKEN -> WETH for Uniswap operations
        vm.prank(owner);
        hook.deployPool(PROJECT_ID, NATIVE_TOKEN, 0, 0, 0);

        // Verify pool was created
        address pool = hook.poolOf(PROJECT_ID, NATIVE_TOKEN);
        assertTrue(pool != address(0), "Pool should be created for NATIVE_TOKEN");

        // Verify NFPM was called
        assertEq(nfpm.mintCallCount(), 1, "NFPM.mint should be called once");

        // Verify tokenId was set
        uint256 tokenId = hook.tokenIdForPool(pool);
        assertTrue(tokenId != 0, "tokenIdForPool should be nonzero");

        // Verify accumulated tokens were cleared
        assertEq(hook.accumulatedProjectTokens(PROJECT_ID), 0, "Accumulated should be 0 after deploy");

        // Verify project is marked deployed
        assertTrue(hook.projectDeployed(PROJECT_ID), "projectDeployed should be true after deploy");
    }

    // -----------------------------------------------------------------------
    // 9. WETH address sourced correctly from NFPM
    // -----------------------------------------------------------------------

    /// @notice The internal _getWETH() must return the WETH9 address
    ///         configured on the NonfungiblePositionManager mock.
    function test_WETH_AddressFromNFPM() public view {
        // Verify the mock NFPM returns the correct WETH address
        assertEq(
            nfpm.WETH9(),
            address(weth),
            "NFPM WETH9() must equal the MockWETH address"
        );

        // Verify the exposed helper agrees
        assertEq(
            testableHook.exposed_getWETH(),
            address(weth),
            "_getWETH() must return the same WETH address as NFPM"
        );
    }
}
