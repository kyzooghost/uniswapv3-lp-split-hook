// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {LPSplitHookTestBase} from "./TestBase.sol";
import {UniV3DeploymentSplitHook} from "../src/UniV3DeploymentSplitHook.sol";
import {IJBPermissions} from "@bananapus/core/interfaces/IJBPermissions.sol";

/// @notice Tests for UniV3DeploymentSplitHook constructor behavior.
/// @dev Verifies all immutables are set correctly, zero-address checks revert,
///      fee percent validation works, and feeProjectId=0 skips the controllerOf check.
contract ConstructorTest is LPSplitHookTestBase {
    /// @notice Verify all immutables are correctly set after construction.
    function test_Constructor_SetsAllImmutables() public view {
        assertEq(hook.DIRECTORY(), address(directory), "DIRECTORY mismatch");
        assertEq(hook.TOKENS(), address(jbTokens), "TOKENS mismatch");
        assertEq(hook.UNISWAP_V3_FACTORY(), address(v3Factory), "UNISWAP_V3_FACTORY mismatch");
        assertEq(
            hook.UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER(),
            address(nfpm),
            "UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER mismatch"
        );
        assertEq(hook.FEE_PROJECT_ID(), FEE_PROJECT_ID, "FEE_PROJECT_ID mismatch");
        assertEq(hook.FEE_PERCENT(), FEE_PERCENT, "FEE_PERCENT mismatch");
        assertEq(hook.REV_DEPLOYER(), address(revDeployer), "REV_DEPLOYER mismatch");
        assertEq(hook.owner(), owner, "owner mismatch");
    }

    /// @notice Constructor reverts when directory is address(0).
    function test_Constructor_RevertsOn_ZeroDirectory() public {
        vm.expectRevert(UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_ZeroAddressNotAllowed.selector);
        new UniV3DeploymentSplitHook(
            owner,
            address(0), // directory = zero
            IJBPermissions(address(permissions)),
            address(jbTokens),
            address(v3Factory),
            address(nfpm),
            FEE_PROJECT_ID,
            FEE_PERCENT,
            address(revDeployer)
        );
    }

    /// @notice Constructor reverts when tokens is address(0).
    function test_Constructor_RevertsOn_ZeroTokens() public {
        vm.expectRevert(UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_ZeroAddressNotAllowed.selector);
        new UniV3DeploymentSplitHook(
            owner,
            address(directory),
            IJBPermissions(address(permissions)),
            address(0), // tokens = zero
            address(v3Factory),
            address(nfpm),
            FEE_PROJECT_ID,
            FEE_PERCENT,
            address(revDeployer)
        );
    }

    /// @notice Constructor reverts when uniswapV3Factory is address(0).
    function test_Constructor_RevertsOn_ZeroFactory() public {
        vm.expectRevert(UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_ZeroAddressNotAllowed.selector);
        new UniV3DeploymentSplitHook(
            owner,
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            address(0), // uniswapV3Factory = zero
            address(nfpm),
            FEE_PROJECT_ID,
            FEE_PERCENT,
            address(revDeployer)
        );
    }

    /// @notice Constructor reverts when uniswapV3NonfungiblePositionManager is address(0).
    function test_Constructor_RevertsOn_ZeroNFPM() public {
        vm.expectRevert(UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_ZeroAddressNotAllowed.selector);
        new UniV3DeploymentSplitHook(
            owner,
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            address(v3Factory),
            address(0), // nfpm = zero
            FEE_PROJECT_ID,
            FEE_PERCENT,
            address(revDeployer)
        );
    }

    /// @notice Constructor reverts when revDeployer is address(0).
    function test_Constructor_RevertsOn_ZeroRevDeployer() public {
        vm.expectRevert(UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_ZeroAddressNotAllowed.selector);
        new UniV3DeploymentSplitHook(
            owner,
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            address(v3Factory),
            address(nfpm),
            FEE_PROJECT_ID,
            FEE_PERCENT,
            address(0) // revDeployer = zero
        );
    }

    /// @notice Constructor reverts when feePercent exceeds 10000 (100%).
    function test_Constructor_RevertsOn_FeePercentOver100() public {
        vm.expectRevert(UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_InvalidFeePercent.selector);
        new UniV3DeploymentSplitHook(
            owner,
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            address(v3Factory),
            address(nfpm),
            FEE_PROJECT_ID,
            10001, // feePercent > BPS (10000)
            address(revDeployer)
        );
    }

    /// @notice When feeProjectId is 0, the constructor skips the controllerOf validation
    ///         and completes successfully without requiring a valid fee project.
    function test_Constructor_FeeProjectIdZero_NoValidation() public {
        UniV3DeploymentSplitHook noFeeHook = new UniV3DeploymentSplitHook(
            owner,
            address(directory),
            IJBPermissions(address(permissions)),
            address(jbTokens),
            address(v3Factory),
            address(nfpm),
            0, // feeProjectId = 0 => skip controllerOf check
            FEE_PERCENT,
            address(revDeployer)
        );

        assertEq(noFeeHook.FEE_PROJECT_ID(), 0, "FEE_PROJECT_ID should be 0");
        // All other immutables should still be set correctly.
        assertEq(noFeeHook.DIRECTORY(), address(directory), "DIRECTORY mismatch");
        assertEq(noFeeHook.TOKENS(), address(jbTokens), "TOKENS mismatch");
        assertEq(noFeeHook.UNISWAP_V3_FACTORY(), address(v3Factory), "UNISWAP_V3_FACTORY mismatch");
        assertEq(
            noFeeHook.UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER(),
            address(nfpm),
            "UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER mismatch"
        );
        assertEq(noFeeHook.FEE_PERCENT(), FEE_PERCENT, "FEE_PERCENT mismatch");
        assertEq(noFeeHook.REV_DEPLOYER(), address(revDeployer), "REV_DEPLOYER mismatch");
        assertEq(noFeeHook.owner(), owner, "owner mismatch");
    }
}
