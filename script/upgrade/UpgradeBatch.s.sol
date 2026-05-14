// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TrancheType } from "../../src/libraries/Types.sol";

import { UpgradeBase } from "./base/UpgradeBase.sol";
import { UpgradeAccountantModule } from "./modules/UpgradeAccountantModule.sol";
import { UpgradeFactoryModule } from "./modules/UpgradeFactoryModule.sol";
import { UpgradeModuleBase } from "./modules/UpgradeModuleBase.sol";
import { UpgradeTrancheModule } from "./modules/UpgradeTrancheModule.sol";
import { UpgradeIdenticalErc4626KernelModule } from "./modules/kernels/UpgradeIdenticalErc4626KernelModule.sol";
import { UpgradeMaplePoolV2KernelModule } from "./modules/kernels/UpgradeMaplePoolV2KernelModule.sol";
import { UpgradeSUSDaiKernelModule } from "./modules/kernels/UpgradeSUSDaiKernelModule.sol";

/**
 * @title UpgradeBatch
 * @notice Single orchestrator that drives a heterogeneous list of UUPS upgrades — any mix of
 *         tranches, kernels, accountants, factory — and emits one `schedule.json` + one
 *         `execute.json` + one `cancel.json` per chain.
 *
 * @dev Workflow:
 *      1. Edit `_initializeConfigs()` below to list the upgrades you want to ship.
 *      2. Dry-run:  `forge script script/upgrade/UpgradeBatch.s.sol`
 *         Real run: `forge script script/upgrade/UpgradeBatch.s.sol --broadcast --private-key 0x<DEPLOYER_KEY>`
 *         (Requires `MAINNET_RPC_URL`, `ARBITRUM_RPC_URL`, etc. in env for the chains you target.)
 *      3. Import the generated JSONs from `output/upgrade/` into the Safe Transaction Builder.
 *
 *      Per-chain output:
 *        output/upgrade/{chainId}_schedule.json
 *        output/upgrade/{chainId}_execute.json
 *        output/upgrade/{chainId}_cancel.json
 *
 *      Each `UpgradeConfig` entry carries:
 *        - `chainId`     — which chain
 *        - `kind`        — which contract type (TRANCHE, KERNEL, ACCOUNTANT, FACTORY)
 *        - `saltVersion` — version suffix folded into the CREATE2 salt (e.g. "V3"); bump per upgrade
 *        - `payload`     — ABI-encoded module-specific data (see each module's natspec)
 */
contract UpgradeBatch is UpgradeBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev One enum per kernel type so the orchestrator dispatches without a registry. Add a new
    ///      `KERNEL_*` value when introducing a new kernel module.
    enum UpgradeKind {
        TRANCHE,
        KERNEL_IDENTICAL_ERC4626_CHAINLINK,
        KERNEL_MAPLE_POOL_V2_CHAINLINK,
        KERNEL_SUSDAI_ADMIN_ORACLE,
        ACCOUNTANT,
        FACTORY
    }

    struct UpgradeConfigEntry {
        uint256 chainId;
        UpgradeKind kind;
        string saltVersion;
        bytes payload;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    UpgradeConfigEntry[] internal _configs;

    // Modules — one instance per kind.
    UpgradeTrancheModule internal _trancheModule;
    UpgradeAccountantModule internal _accountantModule;
    UpgradeFactoryModule internal _factoryModule;
    UpgradeIdenticalErc4626KernelModule internal _kernelIdenticalErc4626Module;
    UpgradeMaplePoolV2KernelModule internal _kernelMapleModule;
    UpgradeSUSDaiKernelModule internal _kernelSUSDaiModule;

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error UpgradeBatch__NoConfigs();
    error UpgradeBatch__ModuleNotImplemented(UpgradeKind kind);

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor() {
        _trancheModule = new UpgradeTrancheModule();
        _accountantModule = new UpgradeAccountantModule();
        _factoryModule = new UpgradeFactoryModule();
        _kernelIdenticalErc4626Module = new UpgradeIdenticalErc4626KernelModule();
        _kernelMapleModule = new UpgradeMaplePoolV2KernelModule();
        _kernelSUSDaiModule = new UpgradeSUSDaiKernelModule();
        // Modules must persist across `vm.createSelectFork` calls in `run()` — their bytecode is
        // deployed at setup time (before any fork is selected).
        vm.makePersistent(address(_trancheModule));
        vm.makePersistent(address(_accountantModule));
        vm.makePersistent(address(_factoryModule));
        vm.makePersistent(address(_kernelIdenticalErc4626Module));
        vm.makePersistent(address(_kernelMapleModule));
        vm.makePersistent(address(_kernelSUSDaiModule));
        _initializeConfigs();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIG — EDIT THIS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Populate the upgrade list here. Empty by default.
     */
    function _initializeConfigs() internal {
        string memory v = "V1.2.1";

        // ── Mainnet ──────────────────────────────────────────────────────────
        _pushAccountantUpgrade(MAINNET, SNUSD, v);
        _pushAccountantUpgrade(MAINNET, AUTOUSD, v);
        _pushAccountantUpgrade(MAINNET, SMOKEHOUSE_USDC, v);
        _pushAccountantUpgrade(MAINNET, SYRUP_USDC, v);
        _pushAccountantUpgrade(MAINNET, STCUSD, v);
        _pushAccountantUpgrade(MAINNET, PARETO_FALCONX, v);
        _pushAccountantUpgrade(MAINNET, APYUSD, v);

        // ── Avalanche ────────────────────────────────────────────────────────
        _pushAccountantUpgrade(AVALANCHE, SAVUSD, v);

        // ── Arbitrum ─────────────────────────────────────────────────────────
        _pushAccountantUpgrade(ARBITRUM, SUSDAI, v);
    }

    /// @dev Push ST + JT + Kernel + Accountant entries for a market. The caller picks the right
    ///      kernel kind based on the market's deployed kernel type (cross-checked against
    ///      `script/config/MarketDeploymentConfig.sol`). Order is: tranches → kernel → accountant.
    function _pushMarketUpgrades(uint256 chainId, string memory marketName, UpgradeKind kernelKind, string memory saltVersion) internal {
        _configs.push(
            UpgradeConfigEntry({ chainId: chainId, kind: UpgradeKind.TRANCHE, saltVersion: saltVersion, payload: abi.encode(marketName, TrancheType.SENIOR) })
        );
        _configs.push(
            UpgradeConfigEntry({ chainId: chainId, kind: UpgradeKind.TRANCHE, saltVersion: saltVersion, payload: abi.encode(marketName, TrancheType.JUNIOR) })
        );
        _configs.push(UpgradeConfigEntry({ chainId: chainId, kind: kernelKind, saltVersion: saltVersion, payload: abi.encode(marketName) }));
        _configs.push(UpgradeConfigEntry({ chainId: chainId, kind: UpgradeKind.ACCOUNTANT, saltVersion: saltVersion, payload: abi.encode(marketName) }));
    }

    /// @dev Push a single accountant upgrade for a market. Use when only the accountant impl
    ///      changes (vs. `_pushMarketUpgrades` which pushes the full ST + JT + kernel + accountant
    ///      set for a market).
    function _pushAccountantUpgrade(uint256 chainId, string memory marketName, string memory saltVersion) internal {
        _configs.push(UpgradeConfigEntry({ chainId: chainId, kind: UpgradeKind.ACCOUNTANT, saltVersion: saltVersion, payload: abi.encode(marketName) }));
    }

    /// @dev Push a factory upgrade for the chain. Factory is a per-chain singleton, so one entry
    ///      per chain — placed after all market entries so it lands last in the Safe batch.
    function _pushFactoryUpgrade(uint256 chainId, string memory saltVersion) internal {
        _configs.push(UpgradeConfigEntry({ chainId: chainId, kind: UpgradeKind.FACTORY, saltVersion: saltVersion, payload: "" }));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ENTRY POINT
    // ═══════════════════════════════════════════════════════════════════════════

    function run() external {
        require(_configs.length > 0, UpgradeBatch__NoConfigs());

        uint256[] memory chainIds = _uniqueChainIds();
        for (uint256 c = 0; c < chainIds.length; c++) {
            _processOneChain(chainIds[c]);
        }
    }

    function _processOneChain(uint256 _chainId) internal {
        // Fork the target chain — module.prepare() reads the proxy's ERC1967 slot off the fork
        vm.createSelectFork(_getRpcUrl(_chainId));

        uint256 n = _countForChain(_chainId);
        PreparedUpgrade[] memory prepped = new PreparedUpgrade[](n);
        address[] memory modules = new address[](n);

        uint256 idx = 0;
        for (uint256 i = 0; i < _configs.length; i++) {
            if (_configs[i].chainId != _chainId) continue;
            (prepped[idx], modules[idx]) = _prepareOne(_chainId, _configs[i]);
            idx++;
        }

        _processChainUpgrades(_chainId, prepped, modules);
    }

    function _prepareOne(uint256 _chainId, UpgradeConfigEntry storage _cfg) internal returns (PreparedUpgrade memory prepared, address moduleAddr) {
        UpgradeModuleBase mod = _moduleFor(_cfg.kind);
        prepared = mod.prepare(_chainId, _cfg.saltVersion, _cfg.payload);
        moduleAddr = address(mod);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DISPATCH
    // ═══════════════════════════════════════════════════════════════════════════

    function _moduleFor(UpgradeKind kind) internal view returns (UpgradeModuleBase) {
        if (kind == UpgradeKind.TRANCHE) return _trancheModule;
        if (kind == UpgradeKind.ACCOUNTANT) return _accountantModule;
        if (kind == UpgradeKind.FACTORY) return _factoryModule;
        if (kind == UpgradeKind.KERNEL_IDENTICAL_ERC4626_CHAINLINK) return _kernelIdenticalErc4626Module;
        if (kind == UpgradeKind.KERNEL_MAPLE_POOL_V2_CHAINLINK) return _kernelMapleModule;
        if (kind == UpgradeKind.KERNEL_SUSDAI_ADMIN_ORACLE) return _kernelSUSDaiModule;
        revert UpgradeBatch__ModuleNotImplemented(kind);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _countForChain(uint256 chainId) internal view returns (uint256 count) {
        for (uint256 i = 0; i < _configs.length; i++) {
            if (_configs[i].chainId == chainId) count++;
        }
    }

    function _uniqueChainIds() internal view returns (uint256[] memory) {
        uint256[] memory temp = new uint256[](_configs.length);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < _configs.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (temp[j] == _configs[i].chainId) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                temp[uniqueCount] = _configs[i].chainId;
                uniqueCount++;
            }
        }

        uint256[] memory result = new uint256[](uniqueCount);
        for (uint256 i = 0; i < uniqueCount; i++) {
            result[i] = temp[i];
        }
        return result;
    }
}
