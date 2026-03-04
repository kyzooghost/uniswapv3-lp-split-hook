// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IJBPermissions} from "@bananapus/core/interfaces/IJBPermissions.sol";
import {JBSplit} from "@bananapus/core/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core/structs/JBSplitHookContext.sol";
import {JBAccountingContext} from "@bananapus/core/structs/JBAccountingContext.sol";
import {IJBSplitHook} from "@bananapus/core/interfaces/IJBSplitHook.sol";
import {JBConstants} from "@bananapus/core/libraries/JBConstants.sol";

import {UniV3DeploymentSplitHook} from "../src/UniV3DeploymentSplitHook.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {MockWETH} from "./mock/MockWETH.sol";
import {MockNFPM} from "./mock/MockNFPM.sol";
import {
    MockJBDirectory,
    MockJBController,
    MockJBMultiTerminal,
    MockJBTokens,
    MockJBPrices,
    MockJBTerminalStore,
    MockREVDeployer,
    MockUniswapV3Factory,
    MockJBProjects,
    MockJBPermissions
} from "./mock/MockJBContracts.sol";

/// @notice Shared test harness for UniV3DeploymentSplitHook tests
/// @dev Deploys all mocks, creates default project, and provides helpers
contract LPSplitHookTestBase is Test {
    // ─── Contracts Under Test ───────────────────────────────────────────
    UniV3DeploymentSplitHook public hook;

    // ─── Mock Infrastructure ────────────────────────────────────────────
    MockJBDirectory public directory;
    MockJBController public controller;
    MockJBMultiTerminal public terminal;
    MockJBTokens public jbTokens;
    MockJBPrices public prices;
    MockJBTerminalStore public store;
    MockREVDeployer public revDeployer;
    MockUniswapV3Factory public v3Factory;
    MockNFPM public nfpm;
    MockWETH public weth;
    MockJBProjects public jbProjects;
    MockJBPermissions public permissions;

    // ─── Test Tokens ────────────────────────────────────────────────────
    MockERC20 public projectToken;
    MockERC20 public terminalToken;
    MockERC20 public feeProjectToken;

    // ─── Test Constants ─────────────────────────────────────────────────
    uint256 public constant PROJECT_ID = 1;
    uint256 public constant FEE_PROJECT_ID = 2;
    uint256 public constant FEE_PERCENT = 3800; // 38%
    uint256 public constant DEFAULT_WEIGHT = 1000e18;
    uint256 public constant DEFAULT_FIRST_WEIGHT = 1000e18;
    uint16 public constant DEFAULT_RESERVED_PERCENT = 1000; // 10%

    address public owner;
    address public user;

    // Accept ETH
    receive() external payable {}

    function setUp() public virtual {
        owner = makeAddr("owner");
        user = makeAddr("user");

        // Deploy mock tokens
        projectToken = new MockERC20("Project Token", "PROJ", 18);
        terminalToken = new MockERC20("Terminal Token", "TERM", 18);
        feeProjectToken = new MockERC20("Fee Project Token", "FEE", 18);
        weth = new MockWETH();

        // Deploy mock JB contracts
        directory = new MockJBDirectory();
        controller = new MockJBController();
        terminal = new MockJBMultiTerminal();
        jbTokens = new MockJBTokens();
        prices = new MockJBPrices();
        store = new MockJBTerminalStore();
        revDeployer = new MockREVDeployer();
        jbProjects = new MockJBProjects();
        permissions = new MockJBPermissions();

        // Deploy mock Uniswap contracts
        v3Factory = new MockUniswapV3Factory();
        nfpm = new MockNFPM(address(weth), address(v3Factory));

        // Wire JB contracts
        controller.setPrices(address(prices));
        controller.setWeight(PROJECT_ID, DEFAULT_WEIGHT);
        controller.setFirstWeight(PROJECT_ID, DEFAULT_FIRST_WEIGHT);
        controller.setReservedPercent(PROJECT_ID, DEFAULT_RESERVED_PERCENT);
        controller.setBaseCurrency(PROJECT_ID, 1); // ETH

        // Set up fee project
        controller.setWeight(FEE_PROJECT_ID, 100e18);
        controller.setFirstWeight(FEE_PROJECT_ID, 100e18);

        // Wire directory
        directory.setProjects(address(jbProjects));
        _setDirectoryController(PROJECT_ID, address(controller));
        _setDirectoryController(FEE_PROJECT_ID, address(controller));
        _setDirectoryTerminal(PROJECT_ID, address(terminalToken), address(terminal));
        _setDirectoryTerminal(FEE_PROJECT_ID, address(terminalToken), address(terminal));

        // Wire project ownership
        jbProjects.setOwner(PROJECT_ID, owner);
        jbProjects.setOwner(FEE_PROJECT_ID, owner);

        // Wire terminal
        terminal.setStore(address(store));
        terminal.setProjectToken(PROJECT_ID, address(projectToken));
        terminal.setProjectToken(FEE_PROJECT_ID, address(feeProjectToken));

        // Set accounting context
        terminal.setAccountingContext(
            PROJECT_ID,
            address(terminalToken),
            uint32(uint160(address(terminalToken))),
            18
        );
        terminal.addAccountingContext(
            PROJECT_ID,
            JBAccountingContext({
                token: address(terminalToken),
                decimals: 18,
                currency: uint32(uint160(address(terminalToken)))
            })
        );

        // Wire JB tokens
        jbTokens.setToken(PROJECT_ID, address(projectToken));
        jbTokens.setToken(FEE_PROJECT_ID, address(feeProjectToken));

        // Set surplus for cash out rate
        store.setSurplus(PROJECT_ID, 0.5e18); // 0.5 terminal tokens per project token

        // Add terminal to directory's terminal list
        _addDirectoryTerminal(PROJECT_ID, address(terminal));

        // Deploy the hook
        hook = new UniV3DeploymentSplitHook(
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

    // ─── Directory Helpers (write to fallback-based mock) ───────────────

    function _setDirectoryController(uint256 projectId, address ctrl) internal {
        directory._controllers(projectId); // Ensure storage slot exists
        // Use vm.store to set the mapping — slot 1 now (_projects at slot 0, _controllers at slot 1)
        bytes32 slot = keccak256(abi.encode(projectId, uint256(1)));
        vm.store(address(directory), slot, bytes32(uint256(uint160(ctrl))));
    }

    function _setDirectoryTerminal(uint256 projectId, address token, address term) internal {
        // _terminals is at slot 2 (after _projects at slot 0, _controllers at slot 1)
        bytes32 innerSlot = keccak256(abi.encode(projectId, uint256(2)));
        bytes32 slot = keccak256(abi.encode(token, innerSlot));
        vm.store(address(directory), slot, bytes32(uint256(uint160(term))));
    }

    function _addDirectoryTerminal(uint256 projectId, address term) internal {
        // _terminalsList is at slot 3
        bytes32 arraySlot = keccak256(abi.encode(projectId, uint256(3)));
        // Read current length
        uint256 currentLen = uint256(vm.load(address(directory), arraySlot));
        // Set new length
        vm.store(address(directory), arraySlot, bytes32(currentLen + 1));
        // Set element at index currentLen
        bytes32 elementSlot = bytes32(uint256(keccak256(abi.encode(arraySlot))) + currentLen);
        vm.store(address(directory), elementSlot, bytes32(uint256(uint160(term))));
    }

    // ─── Context Builder ────────────────────────────────────────────────

    function _buildContext(
        uint256 projectId,
        address token,
        uint256 amount,
        uint256 groupId
    ) internal view returns (JBSplitHookContext memory) {
        return JBSplitHookContext({
            token: token,
            amount: amount,
            decimals: 18,
            projectId: projectId,
            groupId: groupId,
            split: JBSplit({
                percent: 1000000, // 100%
                projectId: 0,
                beneficiary: payable(address(0)),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(hook))
            })
        });
    }

    /// @notice Build context with reserved tokens groupId (1)
    function _buildReservedContext(uint256 projectId, uint256 amount)
        internal
        view
        returns (JBSplitHookContext memory)
    {
        return _buildContext(projectId, address(projectToken), amount, 1);
    }

    // ─── Accumulation & Deployment Helpers ───────────────────────────────

    /// @notice Accumulate tokens by calling processSplitWith from controller
    function _accumulateTokens(uint256 projectId, uint256 amount) internal {
        // Mint project tokens to the hook (simulates controller sending tokens)
        projectToken.mint(address(hook), amount);

        // Build context
        JBSplitHookContext memory context = _buildReservedContext(projectId, amount);

        // Call processSplitWith as the controller
        vm.prank(address(controller));
        hook.processSplitWith(context);
    }

    /// @notice Accumulate and deploy pool for a project (called as owner)
    function _accumulateAndDeploy(uint256 projectId, uint256 amount) internal {
        // Accumulate tokens
        _accumulateTokens(projectId, amount);

        // Approve hook to spend project tokens (for NFPM mint)
        vm.startPrank(address(hook));
        projectToken.approve(address(nfpm), type(uint256).max);
        terminalToken.approve(address(nfpm), type(uint256).max);
        vm.stopPrank();

        // Deploy pool as owner
        vm.prank(owner);
        hook.deployPool(projectId, address(terminalToken), 0, 0, 0);
    }
}
