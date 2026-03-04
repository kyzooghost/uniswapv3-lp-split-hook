// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JBRuleset} from "@bananapus/core/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core/structs/JBRulesetMetadata.sol";
import {JBRulesetWithMetadata} from "@bananapus/core/structs/JBRulesetWithMetadata.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core/libraries/JBRulesetMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core/structs/JBAccountingContext.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminal} from "@bananapus/core/interfaces/IJBTerminal.sol";
import {MockERC20} from "./MockERC20.sol";

// ═══════════════════════════════════════════════════════════════════════
// MockJBProjects — minimal ERC721-like mock for ownerOf()
// ═══════════════════════════════════════════════════════════════════════

contract MockJBProjects {
    mapping(uint256 tokenId => address owner) public _owners;

    function setOwner(uint256 tokenId, address owner) external {
        _owners[tokenId] = owner;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _owners[tokenId];
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MockJBPermissions — minimal mock for hasPermission()
// ═══════════════════════════════════════════════════════════════════════

contract MockJBPermissions {
    // operator => account => projectId => permissionId => granted
    mapping(address => mapping(address => mapping(uint256 => mapping(uint256 => bool)))) public _permissions;

    function setPermission(
        address operator,
        address account,
        uint256 projectId,
        uint256 permissionId,
        bool granted
    ) external {
        _permissions[operator][account][projectId][permissionId] = granted;
    }

    function hasPermission(
        address operator,
        address account,
        uint256 projectId,
        uint256 permissionId,
        bool /* includeRoot */,
        bool /* includeWildcardProjectId */
    ) external view returns (bool) {
        return _permissions[operator][account][projectId][permissionId];
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MockJBDirectory
// ═══════════════════════════════════════════════════════════════════════

contract MockJBDirectory {
    address public _projects; // MockJBProjects address

    mapping(uint256 projectId => address controller) public _controllers;
    mapping(uint256 projectId => mapping(address token => address terminal)) public _terminals;
    mapping(uint256 projectId => address[]) public _terminalsList;

    function setProjects(address projects) external {
        _projects = projects;
    }

    function setController(uint256 projectId, address controller) external {
        _controllers[projectId] = controller;
    }

    function setTerminal(uint256 projectId, address token, address terminal) external {
        _terminals[projectId][token] = terminal;
    }

    function addTerminalToList(uint256 projectId, address terminal) external {
        _terminalsList[projectId].push(terminal);
    }

    // Fallback handles controllerOf, primaryTerminalOf, terminalsOf, PROJECTS
    // because IJBDirectory.controllerOf returns IERC165, not address,
    // so we must use fallback to avoid selector conflicts with mismatched return types.
    fallback() external payable {
        bytes4 sig = bytes4(msg.data);

        // controllerOf(uint256) => 0x5dd8f6aa
        if (sig == 0x5dd8f6aa) {
            uint256 projectId = abi.decode(msg.data[4:], (uint256));
            address controller = _controllers[projectId];
            assembly {
                mstore(0x00, controller)
                return(0x00, 0x20)
            }
        }

        // primaryTerminalOf(uint256,address) => 0x86202650
        if (sig == 0x86202650) {
            (uint256 projectId, address token) = abi.decode(msg.data[4:], (uint256, address));
            address terminal = _terminals[projectId][token];
            assembly {
                mstore(0x00, terminal)
                return(0x00, 0x20)
            }
        }

        // terminalsOf(uint256) => 0xd1754153
        if (sig == 0xd1754153) {
            uint256 projectId = abi.decode(msg.data[4:], (uint256));
            address[] storage terminals = _terminalsList[projectId];
            uint256 len = terminals.length;

            // Encode as dynamic array
            bytes memory result = abi.encode(terminals);
            assembly {
                return(add(result, 0x20), mload(result))
            }
        }

        // PROJECTS() => 0x293c4999
        if (sig == 0x293c4999) {
            address projects = _projects;
            assembly {
                mstore(0x00, projects)
                return(0x00, 0x20)
            }
        }
    }

    receive() external payable {}
}

// ═══════════════════════════════════════════════════════════════════════
// MockJBController
// ═══════════════════════════════════════════════════════════════════════

contract MockJBController {
    address public pricesContract;

    mapping(uint256 projectId => uint256 weight) public weights;
    mapping(uint256 projectId => uint16 reservedPercent) public reservedPercents;
    mapping(uint256 projectId => uint32 baseCurrency) public baseCurrencies;
    mapping(uint256 projectId => uint256 firstWeight) public firstWeights;

    // Track burn calls for verification
    uint256 public burnCallCount;
    uint256 public lastBurnProjectId;
    uint256 public lastBurnAmount;
    address public lastBurnHolder;

    function setPrices(address _prices) external {
        pricesContract = _prices;
    }

    function setWeight(uint256 projectId, uint256 weight) external {
        weights[projectId] = weight;
    }

    function setReservedPercent(uint256 projectId, uint16 reservedPercent) external {
        reservedPercents[projectId] = reservedPercent;
    }

    function setBaseCurrency(uint256 projectId, uint32 currency) external {
        baseCurrencies[projectId] = currency;
    }

    function setFirstWeight(uint256 projectId, uint256 weight) external {
        firstWeights[projectId] = weight;
    }

    function PRICES() external view returns (address) {
        return pricesContract;
    }

    function currentRulesetOf(uint256 projectId)
        external
        view
        returns (JBRuleset memory ruleset, JBRulesetMetadata memory metadata)
    {
        uint32 baseCurr = baseCurrencies[projectId];
        if (baseCurr == 0) baseCurr = 1; // Default ETH

        metadata = JBRulesetMetadata({
            reservedPercent: reservedPercents[projectId],
            cashOutTaxRate: 0,
            baseCurrency: baseCurr,
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 0,
            weight: uint112(weights[projectId]),
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadataResolver.packRulesetMetadata(metadata)
        });
    }

    function allRulesetsOf(uint256 projectId, uint256 /* startIndex */, uint256 /* limit */)
        external
        view
        returns (JBRulesetWithMetadata[] memory rulesets)
    {
        uint256 fw = firstWeights[projectId];
        if (fw == 0) fw = weights[projectId]; // Default to current weight

        rulesets = new JBRulesetWithMetadata[](1);

        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: reservedPercents[projectId],
            cashOutTaxRate: 0,
            baseCurrency: baseCurrencies[projectId] == 0 ? uint32(1) : baseCurrencies[projectId],
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        rulesets[0] = JBRulesetWithMetadata({
            ruleset: JBRuleset({
                cycleNumber: 1,
                id: 1,
                basedOnId: 0,
                start: uint48(block.timestamp),
                duration: 0,
                weight: uint112(fw),
                weightCutPercent: 0,
                approvalHook: IJBRulesetApprovalHook(address(0)),
                metadata: JBRulesetMetadataResolver.packRulesetMetadata(metadata)
            }),
            metadata: metadata
        });
    }

    function burnTokensOf(
        address holder,
        uint256 projectId,
        uint256 amount,
        string calldata /* memo */
    ) external {
        burnCallCount++;
        lastBurnProjectId = projectId;
        lastBurnAmount = amount;
        lastBurnHolder = holder;

        // Actually burn the tokens if possible (need to know the project token)
        // This is handled by the test setup - tokens are burned from the holder
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MockJBMultiTerminal
// ═══════════════════════════════════════════════════════════════════════

contract MockJBMultiTerminal {
    address public storeAddress;

    // Per-project accounting contexts
    mapping(uint256 projectId => mapping(address token => JBAccountingContext)) public _contexts;
    mapping(uint256 projectId => JBAccountingContext[]) public _contextsList;

    // Track calls
    uint256 public payCallCount;
    uint256 public cashOutCallCount;
    uint256 public addToBalanceCallCount;
    uint256 public lastPayProjectId;
    uint256 public lastPayAmount;
    uint256 public lastCashOutAmount;

    // Override return amounts
    uint256 public payReturnAmount;
    bool public usePayReturnOverride;
    uint256 public cashOutReturnAmount;
    bool public useCashOutReturnOverride;

    // Project token for minting on pay
    mapping(uint256 projectId => address token) public projectTokens;

    function setStore(address store) external {
        storeAddress = store;
    }

    function setAccountingContext(uint256 projectId, address token, uint32 currency, uint8 decimals) external {
        _contexts[projectId][token] = JBAccountingContext({
            token: token,
            decimals: decimals,
            currency: currency
        });
    }

    function addAccountingContext(uint256 projectId, JBAccountingContext memory ctx) external {
        _contextsList[projectId].push(ctx);
        _contexts[projectId][ctx.token] = ctx;
    }

    function setProjectToken(uint256 projectId, address token) external {
        projectTokens[projectId] = token;
    }

    function setPayReturn(uint256 amount) external {
        payReturnAmount = amount;
        usePayReturnOverride = true;
    }

    function setCashOutReturn(uint256 amount) external {
        cashOutReturnAmount = amount;
        useCashOutReturnOverride = true;
    }

    function STORE() external view returns (address) {
        return storeAddress;
    }

    function accountingContextForTokenOf(uint256 projectId, address token)
        external
        view
        returns (JBAccountingContext memory)
    {
        return _contexts[projectId][token];
    }

    function accountingContextsOf(uint256 projectId)
        external
        view
        returns (JBAccountingContext[] memory)
    {
        return _contextsList[projectId];
    }

    function pay(
        uint256 projectId,
        address /* token */,
        uint256 amount,
        address beneficiary,
        uint256 /* minReturnedTokens */,
        string calldata /* memo */,
        bytes calldata /* metadata */
    ) external payable returns (uint256 beneficiaryTokenCount) {
        payCallCount++;
        lastPayProjectId = projectId;
        lastPayAmount = amount;

        if (usePayReturnOverride) {
            beneficiaryTokenCount = payReturnAmount;
        } else {
            beneficiaryTokenCount = amount; // 1:1 default
        }

        // Mint project tokens to beneficiary
        address projectToken = projectTokens[projectId];
        if (projectToken != address(0) && beneficiaryTokenCount > 0) {
            MockERC20(projectToken).mint(beneficiary, beneficiaryTokenCount);
        }

        return beneficiaryTokenCount;
    }

    function cashOutTokensOf(
        address /* holder */,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256 /* minTokensReclaimed */,
        address payable beneficiary,
        bytes calldata /* metadata */
    ) external returns (uint256 reclaimAmount) {
        cashOutCallCount++;
        lastCashOutAmount = cashOutCount;

        if (useCashOutReturnOverride) {
            reclaimAmount = cashOutReturnAmount;
        } else {
            reclaimAmount = cashOutCount / 2; // Default: 50% reclaim
        }

        // Transfer terminal tokens to beneficiary
        if (reclaimAmount > 0) {
            if (tokenToReclaim == address(0x000000000000000000000000000000000000EEEe)) {
                // Native ETH
                (bool success,) = beneficiary.call{value: reclaimAmount}("");
                require(success, "ETH transfer failed");
            } else {
                MockERC20(tokenToReclaim).mint(beneficiary, reclaimAmount);
            }
        }

        return reclaimAmount;
    }

    function addToBalanceOf(
        uint256 /* projectId */,
        address /* token */,
        uint256 /* amount */,
        bool /* shouldReturnHeldTokens */,
        string calldata /* memo */,
        bytes calldata /* metadata */
    ) external payable {
        addToBalanceCallCount++;
    }

    receive() external payable {}
}

// ═══════════════════════════════════════════════════════════════════════
// MockJBTokens
// ═══════════════════════════════════════════════════════════════════════

contract MockJBTokens {
    mapping(uint256 projectId => address token) public _tokens;

    function setToken(uint256 projectId, address token) external {
        _tokens[projectId] = token;
    }

    function tokenOf(uint256 projectId) external view returns (address) {
        return _tokens[projectId];
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MockJBPrices
// ═══════════════════════════════════════════════════════════════════════

contract MockJBPrices {
    // projectId => pricingCurrency => unitCurrency => price
    mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))) public prices;

    function setPrice(uint256 projectId, uint32 pricingCurrency, uint32 unitCurrency, uint256 price) external {
        prices[projectId][pricingCurrency][unitCurrency] = price;
    }

    function pricePerUnitOf(
        uint256 projectId,
        uint256 pricingCurrency,
        uint256 unitCurrency,
        uint256 /* decimals */
    ) external view returns (uint256) {
        uint256 price = prices[projectId][pricingCurrency][unitCurrency];
        return price > 0 ? price : 1e18; // Default 1:1
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MockJBTerminalStore
// ═══════════════════════════════════════════════════════════════════════

contract MockJBTerminalStore {
    // projectId => surplus per project token
    mapping(uint256 => uint256) public surplusPerToken;

    function setSurplus(uint256 projectId, uint256 surplus) external {
        surplusPerToken[projectId] = surplus;
    }

    /// @dev Matches IJBTerminalStore.currentReclaimableSurplusOf(uint256,uint256,uint256,uint256)
    function currentReclaimableSurplusOf(
        uint256 projectId,
        uint256 cashOutCount,
        uint256 /* totalSupply */,
        uint256 /* surplus */
    ) external view returns (uint256) {
        uint256 surplus = surplusPerToken[projectId];
        if (surplus == 0) return 0;
        return (surplus * cashOutCount) / 1e18;
    }

    /// @dev Matches IJBTerminalStore.currentReclaimableSurplusOf(uint256,uint256,IJBTerminal[],JBAccountingContext[],uint256,uint256)
    function currentReclaimableSurplusOf(
        uint256 projectId,
        uint256 cashOutCount,
        IJBTerminal[] calldata /* terminals */,
        JBAccountingContext[] calldata /* accountingContexts */,
        uint256 /* decimals */,
        uint256 /* currency */
    ) external view returns (uint256) {
        uint256 surplus = surplusPerToken[projectId];
        if (surplus == 0) return 0;
        return (surplus * cashOutCount) / 1e18;
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MockREVDeployer
// ═══════════════════════════════════════════════════════════════════════

contract MockREVDeployer {
    mapping(uint256 projectId => mapping(address operator => bool)) public _operators;

    function setOperator(uint256 projectId, address operator, bool isOperator) external {
        _operators[projectId][operator] = isOperator;
    }

    function isSplitOperatorOf(uint256 projectId, address operator) external view returns (bool) {
        return _operators[projectId][operator];
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MockUniswapV3Factory
// ═══════════════════════════════════════════════════════════════════════

contract MockUniswapV3Factory {
    mapping(address => mapping(address => mapping(uint24 => address))) public pools;

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return pools[t0][t1][fee];
    }

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pools[t0][t1][fee] = pool;
    }
}
