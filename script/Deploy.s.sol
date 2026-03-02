// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@bananapus/core-v5/script/helpers/CoreDeploymentLib.sol";

import {Sphinx} from "@sphinx-labs/contracts/SphinxPlugin.sol";
import {Script} from "forge-std/Script.sol";

import {UniV3DeploymentSplitHook} from "src/UniV3DeploymentSplitHook.sol";
import {IJBPermissions} from "@bananapus/core-v5/src/interfaces/IJBPermissions.sol";

contract DeployScript is Script, Sphinx {
    /// @notice tracks the deployment of the core contracts for the chain we are deploying to.
    CoreDeployment core;

    /// @notice the salts that are used to deploy the contracts.
    bytes32 SPLIT_HOOK = "UniV3DeploymentSplitHook";

    /// @notice tracks the addresses that are required for the chain we are deploying to.
    address weth;
    address factory;
    address nfpm;
    address trustedForwarder;

    /// @notice The project ID that receives LP fees.
    uint256 feeProjectId;

    /// @notice The percentage of LP fees routed to the fee project (basis points, e.g. 3800 = 38%).
    uint256 feePercent;

    /// @notice The REVDeployer address for revnet operator validation.
    address revDeployer;

    function configureSphinx() public override {
        sphinxConfig.projectName = "nana-lp-split-hook-v5";
        sphinxConfig.mainnets = ["ethereum", "optimism", "base", "arbitrum", "celo"];
        sphinxConfig.testnets = ["ethereum_sepolia", "optimism_sepolia", "base_sepolia", "arbitrum_sepolia", "celo_sepolia"];
    }

    function run() public {
        // Get the deployment addresses for the nana CORE for this chain.
        // We want to do this outside of the `sphinx` modifier.
        core = CoreDeploymentLib.getDeployment(
            vm.envOr("NANA_CORE_DEPLOYMENT_PATH", string("node_modules/@bananapus/core-v5/deployments/"))
        );

        // Trusted forwarder for ERC2771 meta-transactions.
        trustedForwarder = vm.envOr("TRUSTED_FORWARDER", address(0));

        // Fee configuration.
        feeProjectId = vm.envOr("FEE_PROJECT_ID", uint256(0));
        feePercent = vm.envOr("FEE_PERCENT", uint256(3800));
        revDeployer = vm.envOr("REV_DEPLOYER", address(0));

        // Ethereum Mainnet
        if (block.chainid == 1) {
            weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
            factory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
            nfpm = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
        // Ethereum Sepolia
        } else if (block.chainid == 11_155_111) {
            weth = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
            factory = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
            nfpm = 0x1238536071E1c677A632429e3655c799b22cDA52;
        // Optimism Mainnet
        } else if (block.chainid == 10) {
            weth = 0x4200000000000000000000000000000000000006;
            factory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
            nfpm = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
        // Base Mainnet
        } else if (block.chainid == 8453) {
            weth = 0x4200000000000000000000000000000000000006;
            factory = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
            nfpm = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
        // Optimism Sepolia
        } else if (block.chainid == 11_155_420) {
            weth = 0x4200000000000000000000000000000000000006;
            factory = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
            nfpm = 0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2;
        // Base Sepolia
        } else if (block.chainid == 84_532) {
            weth = 0x4200000000000000000000000000000000000006;
            factory = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
            nfpm = 0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2;
        // Arbitrum Mainnet
        } else if (block.chainid == 42_161) {
            weth = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
            factory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
            nfpm = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
        // Arbitrum Sepolia
        } else if (block.chainid == 421_614) {
            weth = 0x980B62Da83eFf3D4576C647993b0c1D7faf17c73;
            factory = 0x248AB79Bbb9bC29bB72f7Cd42F17e054Fc40188e;
            nfpm = 0x6b2937Bde17889EDCf8fbD8dE31C3C2a70Bc4d65;
        } else {
            revert("Invalid RPC / no juice contracts deployed on this network");
        }

        deploy();
    }

    function deploy() public sphinx {
        new UniV3DeploymentSplitHook{salt: SPLIT_HOOK}({
            initialOwner: safeAddress(),
            directory: address(core.directory),
            permissions: IJBPermissions(address(core.permissions)),
            tokens: address(core.tokens),
            uniswapV3Factory: factory,
            uniswapV3NonfungiblePositionManager: nfpm,
            feeProjectId: feeProjectId,
            feePercent: feePercent,
            revDeployer: revDeployer,
            trustedForwarder: trustedForwarder
        });
    }

    function _isDeployed(
        bytes32 salt,
        bytes memory creationCode,
        bytes memory arguments
    ) internal view returns (bool) {
        address _deployedTo = vm.computeCreate2Address({
            salt: salt,
            initCodeHash: keccak256(abi.encodePacked(creationCode, arguments)),
            deployer: address(0x4e59b44847b379578588920cA78FbF26c0B4956C)
        });
        return address(_deployedTo).code.length != 0;
    }
}
