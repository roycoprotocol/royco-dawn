// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IAccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { CREATE3 } from "../../lib/solady/src/utils/CREATE3.sol";
import { RolesConfiguration } from "../../src/factory/RolesConfiguration.sol";
import { IRoycoAuth } from "../../src/interfaces/IRoycoAuth.sol";
import { IRoycoEntryPoint } from "../../src/interfaces/IRoycoEntryPoint.sol";
import { RoycoEntryPoint } from "../../src/periphery/RoycoEntryPoint.sol";
import { EntryPointDeploymentConfig } from "../config/EntryPointDeploymentConfig.sol";
import { ExtraRoles } from "../config/ExtraRoles.sol";
import { AccessManagerConfigUtils } from "../utils/AccessManagerConfigUtils.sol";
import { Create2DeployUtils } from "../utils/Create2DeployUtils.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

/**
 * @title DeployEntryPointScript
 * @notice Deployment script for the RoycoEntryPoint contract
 * @dev Deploys both the implementation and ERC1967 proxy using deterministic CREATE2 deployment,
 *      then initializes the proxy with the per-chain tranche configuration. Factory role
 *      configuration is generated separately via `buildFactoryConfigTransactions` and applied
 *      through a Safe transaction batch.
 */
contract DeployEntryPointScript is EntryPointDeploymentConfig, AccessManagerConfigUtils, Create2DeployUtils, RolesConfiguration, ExtraRoles {
    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Deployment salt for the RoycoEntryPoint
    bytes32 internal constant ENTRY_POINT_SALT_BASE = keccak256("ROYCO_ENTRY_POINT_PRODUCTION");

    /// @dev Suffix for the Safe transaction JSON file name
    string internal constant SAFE_TX_OUTPUT_FILE_NAME_SUFFIX = "_entry_point_role_config";

    /// @dev OZ AccessManager's PUBLIC_ROLE — auto-membership for every address.
    ///      Used to leave the entry point's LP selectors open at the AM layer; the underlying
    ///      tranches still gate `deposit`/`redeem` on `ST_LP_ROLE`/`JT_LP_ROLE`.
    uint64 internal constant PUBLIC_ROLE = type(uint64).max;

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT FLAGS
    // ═══════════════════════════════════════════════════════════════════════════

    bool internal ENABLE_LOGGING = false;

    // ═══════════════════════════════════════════════════════════════════════════
    // ENTRY POINTS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Production deployment entry point
     * @dev Deploys the entry point only. Factory role configuration must be done
     *      separately via Safe transaction batches.
     *
     * Environment variables:
     *   DEPLOYER_PRIVATE_KEY - Key for the deployer account (CREATE2 deployment)
     */
    function run() external {
        ENABLE_LOGGING = true;

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        EntryPointConfig memory config = getEntryPointConfig();
        require(config.roycoFactory != address(0), "Chain not supported");

        address entryPoint = deployEntryPoint(config, deployerPrivateKey);

        // Write the Safe JSON containing the factory role-config batch
        writeFactoryConfigSafeJson(config.roycoFactory, entryPoint);

        // Simulate applying the batch + verify FNDN and WCE access. Cheatcodes are local-only
        // (no on-chain effect), so this is safe to run alongside the deploy broadcast.
        simulateFactoryConfig(config.roycoFactory, entryPoint);

        if (ENABLE_LOGGING) {
            console2.log("");
            console2.log("========================================");
            console2.log("Entry Point deployed at:", entryPoint);
            console2.log("Factory:", config.roycoFactory);
            console2.log("Chain:", config.chainId);
            console2.log("Tranches configured:", config.tranches.length);
            console2.log("========================================");
            console2.log("");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deploys a RoycoEntryPoint implementation and proxy via CREATE2
     * @param _config The entry point deployment configuration
     * @param _deployerPrivateKey The private key for executing the deployment
     * @return entryPoint The address of the deployed entry point proxy
     */
    function deployEntryPoint(EntryPointConfig memory _config, uint256 _deployerPrivateKey) public returns (address entryPoint) {
        (address[] memory tranches, IRoycoEntryPoint.TrancheConfig[] memory trancheConfigs) = _unpackTrancheConfigs(_config);

        vm.startBroadcast(_deployerPrivateKey);

        // Deploy the implementation
        (address implAddr, bool alreadyDeployed) = deployWithSanityChecks(ENTRY_POINT_SALT_BASE, type(RoycoEntryPoint).creationCode, true);
        if (ENABLE_LOGGING) {
            if (alreadyDeployed) console2.log("EntryPoint Implementation already deployed at:", implAddr);
            else console2.log("EntryPoint Implementation deployed at:", implAddr);
        }

        bytes memory initData = abi.encodeCall(RoycoEntryPoint.initialize, (_config.roycoFactory, tranches, trancheConfigs));
        bytes memory proxyCreationCode = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(implAddr, initData));
        entryPoint = CREATE3.deployDeterministic(proxyCreationCode, ENTRY_POINT_SALT_BASE);
        if (ENABLE_LOGGING) console2.log("EntryPoint Proxy deployed at:", entryPoint);

        vm.stopBroadcast();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SAFE TRANSACTION BUILDERS (for future production use)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Builds the Safe transactions needed to configure factory roles for the entry point
     * @dev Returns the transactions without writing them. Can be used by future Safe batch generation.
     * @param _factory The Royco factory (AccessManager) address
     * @param _entryPoint The deployed entry point proxy address
     * @return transactions Array of Safe transactions to execute
     */
    function buildFactoryConfigTransactions(address _factory, address _entryPoint) public view returns (SafeTransaction[] memory transactions) {
        bytes4[] memory lpSelectors = _buildLPSelectors();

        bytes4[] memory adminSelectors = new bytes4[](1);
        adminSelectors[0] = IRoycoEntryPoint.modifyTrancheConfigs.selector;

        bytes4[] memory entryPointClaimFeeSelectors = new bytes4[](1);
        entryPointClaimFeeSelectors[0] = IRoycoEntryPoint.collectProtocolFees.selector;

        bytes4[] memory pauseSelectors = new bytes4[](1);
        pauseSelectors[0] = IRoycoAuth.pause.selector;

        bytes4[] memory unpauseSelectors = new bytes4[](1);
        unpauseSelectors[0] = IRoycoAuth.unpause.selector;

        bytes4[] memory upgraderSelectors = new bytes4[](1);
        upgraderSelectors[0] = UUPSUpgradeable.upgradeToAndCall.selector;

        // 6 setTargetFunctionRole + 6 grantRole = 12 total
        //   - LP -> PUBLIC_ROLE
        //   - modifyTrancheConfigs   -> ADMIN_ENTRY_POINT_ROLE (Standard 24h)
        //   - collectProtocolFees    -> ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE (Immediate)
        //   - pause / unpause / upgrade -> respective roles
        //   - grant ADMIN_ENTRY_POINT_ROLE to ROOT_MULTISIG (Standard) and WCE_MULTISIG (Immediate)
        //   - grant ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE to ROOT_MULTISIG (Immediate)
        //   - grant ST_LP_ROLE / JT_LP_ROLE / BURNER_ROLE to the entry point itself
        RoleConfig memory entryPointAdminConfig = getRoleConfig(ADMIN_ENTRY_POINT_ROLE);
        RoleConfig memory entryPointClaimFeeConfig = getRoleConfig(ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE);
        transactions = new SafeTransaction[](12);
        transactions[0] = buildSetTargetFunctionRole(_factory, _entryPoint, lpSelectors, PUBLIC_ROLE);
        transactions[1] = buildSetTargetFunctionRole(_factory, _entryPoint, adminSelectors, ADMIN_ENTRY_POINT_ROLE);
        transactions[2] = buildSetTargetFunctionRole(_factory, _entryPoint, entryPointClaimFeeSelectors, ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE);
        transactions[3] = buildSetTargetFunctionRole(_factory, _entryPoint, pauseSelectors, ADMIN_PAUSER_ROLE);
        transactions[4] = buildSetTargetFunctionRole(_factory, _entryPoint, unpauseSelectors, ADMIN_UNPAUSER_ROLE);
        transactions[5] = buildSetTargetFunctionRole(_factory, _entryPoint, upgraderSelectors, ADMIN_UPGRADER_ROLE);
        // Grant ADMIN_ENTRY_POINT_ROLE to ROOT_MULTISIG with the configured Standard delay
        transactions[6] = buildGrantRole(_factory, ADMIN_ENTRY_POINT_ROLE, ROOT_MULTISIG, entryPointAdminConfig.executionDelay);
        // Grant ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE to ROOT_MULTISIG (Immediate)
        transactions[7] = buildGrantRole(_factory, ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE, ROOT_MULTISIG, entryPointClaimFeeConfig.executionDelay);
        // Grant ADMIN_ENTRY_POINT_ROLE to WCE_MULTISIG with immediate delay
        transactions[8] = buildGrantRole(_factory, ADMIN_ENTRY_POINT_ROLE, WCE_MULTISIG, 0);
        // The entry point itself needs LP roles to call tranche.deposit/redeem and BURNER_ROLE for yield forfeiture
        transactions[9] = buildGrantRole(_factory, ST_LP_ROLE, _entryPoint, 0);
        transactions[10] = buildGrantRole(_factory, JT_LP_ROLE, _entryPoint, 0);
        transactions[11] = buildGrantRole(_factory, BURNER_ROLE, _entryPoint, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SAFE JSON COMPOSITION + SIMULATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Composes the factory role-config Safe batch and writes it to disk.
     * @param _factory The Royco factory (AccessManager) address
     * @param _entryPoint The deployed entry point proxy address
     */
    function writeFactoryConfigSafeJson(address _factory, address _entryPoint) public {
        SafeTransaction[] memory txs = buildFactoryConfigTransactions(_factory, _entryPoint);
        string memory fileName = string.concat(vm.toString(block.chainid), SAFE_TX_OUTPUT_FILE_NAME_SUFFIX);
        writeSafeTransactionJson(
            txs, fileName, "Royco Entry Point Factory Configuration", "Sets up the role configuration for the Royco Entry Point on the Royco Factory"
        );
        if (ENABLE_LOGGING) console2.log("Wrote factory config Safe JSON:", fileName);
    }

    /**
     * @notice Simulates applying the factory role-config batch on a fork and asserts that
     *         FNDN (`ROOT_MULTISIG`) and WCE (`WCE_MULTISIG`) can call the entry point's
     *         admin functions per the security model:
     *
     *           - WCE  -> `modifyTrancheConfigs` directly (Immediate, delay 0)
     *           - WCE  -> `collectProtocolFees`         REVERT (no claim-fee role)
     *           - FNDN -> `modifyTrancheConfigs` directly REVERT (Standard delay required)
     *           - FNDN -> `modifyTrancheConfigs` via schedule + 24h + execute -> SUCCESS
     *           - FNDN -> `collectProtocolFees`        directly -> SUCCESS (Immediate)
     *
     *         Uses cheatcodes (vm.prank, vm.warp) — these are local-only and do not affect
     *         the broadcast.
     * @param _factory The Royco factory (AccessManager) address
     * @param _entryPoint The deployed entry point proxy address
     */
    function simulateFactoryConfig(address _factory, address _entryPoint) public {
        SafeTransaction[] memory txs = buildFactoryConfigTransactions(_factory, _entryPoint);

        // Apply each batch tx as ROOT_MULTISIG (admin role 0). On a fresh factory ROOT_MULTISIG
        // has 0 delay on role 0, so direct calls work; on the live mainnet/avalanche/arbitrum
        // factories the security migration applies a 2d delay first — that batch is a separate
        // schedule+execute and is out of scope here.
        for (uint256 i = 0; i < txs.length; i++) {
            vm.prank(ROOT_MULTISIG);
            (bool ok, bytes memory ret) = txs[i].to.call{ value: txs[i].value }(txs[i].data);
            require(ok, _decodeRevert(ret, i));
        }

        // OZ AccessManager schedules a grace period for delay reductions; warp past it.
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);

        // Build empty-config calldata for both admin functions (zero-tranche updates / zero-fee
        // collections; just exercising authorization, not state mutation).
        address[] memory emptyTranches = new address[](0);
        IRoycoEntryPoint.TrancheConfig[] memory emptyConfigs = new IRoycoEntryPoint.TrancheConfig[](0);
        bytes memory modifyData = abi.encodeCall(IRoycoEntryPoint.modifyTrancheConfigs, (emptyTranches, emptyConfigs));

        uint256[] memory emptyShares = new uint256[](0);
        bytes memory claimFeeData = abi.encodeCall(IRoycoEntryPoint.collectProtocolFees, (emptyTranches, emptyShares, ROOT_MULTISIG));

        // ── 1. WCE -> modifyTrancheConfigs directly (Immediate)
        vm.prank(WCE_MULTISIG);
        (bool wceOk,) = _entryPoint.call(modifyData);
        require(wceOk, "WCE should call modifyTrancheConfigs immediately");

        // ── 2. WCE -> collectProtocolFees should revert (no claim-fee role)
        vm.prank(WCE_MULTISIG);
        (bool wceFeeOk,) = _entryPoint.call(claimFeeData);
        require(!wceFeeOk, "WCE must NOT have claim-fee role");

        // ── 3. FNDN -> modifyTrancheConfigs directly should revert (delay required)
        vm.prank(ROOT_MULTISIG);
        (bool fndnDirect,) = _entryPoint.call(modifyData);
        require(!fndnDirect, "FNDN direct modifyTrancheConfigs must revert (Standard delay)");

        // ── 4. FNDN -> schedule + 1d + execute modifyTrancheConfigs (Standard)
        vm.prank(ROOT_MULTISIG);
        IAccessManager(_factory).schedule(_entryPoint, modifyData, 0);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.prank(ROOT_MULTISIG);
        IAccessManager(_factory).execute(_entryPoint, modifyData);

        // ── 5. FNDN -> collectProtocolFees directly (Immediate via claim-fee role)
        vm.prank(ROOT_MULTISIG);
        (bool fndnFeeOk,) = _entryPoint.call(claimFeeData);
        require(fndnFeeOk, "FNDN should call collectProtocolFees immediately");

        if (ENABLE_LOGGING) {
            console2.log("");
            console2.log("[OK] Factory config simulated and access verified:");
            console2.log("     WCE  modifyTrancheConfigs (immediate)        : passed");
            console2.log("     WCE  collectProtocolFees   (must revert)     : passed");
            console2.log("     FNDN modifyTrancheConfigs direct (must revert): passed");
            console2.log("     FNDN modifyTrancheConfigs via schedule+exec  : passed");
            console2.log("     FNDN collectProtocolFees   (immediate)        : passed");
        }
    }

    function _decodeRevert(bytes memory _ret, uint256 _i) internal pure returns (string memory) {
        if (_ret.length >= 4) {
            return string.concat("Factory config tx ", vm.toString(_i), " reverted; selector=0x", _bytes4ToHex(bytes4(_ret)));
        }
        return string.concat("Factory config tx ", vm.toString(_i), " reverted");
    }

    function _bytes4ToHex(bytes4 _b) internal pure returns (string memory) {
        bytes memory hexAlphabet = "0123456789abcdef";
        bytes memory out = new bytes(8);
        for (uint256 i = 0; i < 4; i++) {
            uint8 b = uint8(_b[i]);
            out[2 * i] = hexAlphabet[b >> 4];
            out[2 * i + 1] = hexAlphabet[b & 0x0f];
        }
        return string(out);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _buildLPSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](10);
        selectors[0] = IRoycoEntryPoint.requestDeposit.selector;
        selectors[1] = IRoycoEntryPoint.executeDeposit.selector;
        selectors[2] = IRoycoEntryPoint.executeDeposits.selector;
        selectors[3] = IRoycoEntryPoint.cancelDepositRequest.selector;
        selectors[4] = IRoycoEntryPoint.cancelDepositRequests.selector;
        selectors[5] = IRoycoEntryPoint.requestRedemption.selector;
        selectors[6] = IRoycoEntryPoint.executeRedemption.selector;
        selectors[7] = IRoycoEntryPoint.executeRedemptions.selector;
        selectors[8] = IRoycoEntryPoint.cancelRedemptionRequest.selector;
        selectors[9] = IRoycoEntryPoint.cancelRedemptionRequests.selector;
    }

    /**
     * @dev Unpacks TrancheInitConfig[] into separate arrays for the initialize call
     */
    function _unpackTrancheConfigs(EntryPointConfig memory _config)
        internal
        pure
        returns (address[] memory tranches, IRoycoEntryPoint.TrancheConfig[] memory configs)
    {
        uint256 len = _config.tranches.length;
        tranches = new address[](len);
        configs = new IRoycoEntryPoint.TrancheConfig[](len);
        for (uint256 i = 0; i < len; i++) {
            tranches[i] = _config.tranches[i].tranche;
            configs[i] = _config.tranches[i].config;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIG INITIALIZATION (override to set deployment parameters)
    // ═══════════════════════════════════════════════════════════════════════════

    function _initializeEntryPointConfigs() internal virtual override {
        // ── Mainnet ──────────────────────────────────────────────────────────
        EntryPointConfig storage mainnet = _entryPointConfigs[MAINNET];
        mainnet.chainId = MAINNET;
        mainnet.roycoFactory = ROYCO_FACTORY;
        // sNUSD
        _addTrancheWithDefaultDelays(mainnet, 0x2070Af1C865f5d764F673Baf5654822947e71243); // ST
        _addTrancheWithDefaultDelays(mainnet, 0x3821eBea3BBbE23F3dea74f24082BD0f0b67f6c5); // JT
        // autoUSD
        _addTrancheWithDefaultDelays(mainnet, 0x73C641fe41EB0270C7f473f3c3E4A40eb97fd8dE);
        _addTrancheWithDefaultDelays(mainnet, 0x6f0D6567099621deE3850C673d73c532071A888d);
        // Smokehouse USDC Morpho
        _addTrancheWithDefaultDelays(mainnet, 0xa225F24654b8995036606D5Cd0634133a4BE169c);
        _addTrancheWithDefaultDelays(mainnet, 0xC8fab124292cB792d15041292C2399910bD086d1);
        // Maple SyrupUSDC
        _addTrancheWithDefaultDelays(mainnet, 0x66182442522D3049A941035190C315379c959250);
        _addTrancheWithDefaultDelays(mainnet, 0x5f340B400F892bBFDed2e5c316369Dcbf05C282A);
        // stcUSD
        _addTrancheWithDefaultDelays(mainnet, 0xa7Da92685ea436276B2e87aE12E5eE6DABaD5bB5);
        _addTrancheWithDefaultDelays(mainnet, 0xe4060E83ad26618c7Ed56A02ce099beBA4f73b29);
        // Pareto FalconX
        _addTrancheWithDefaultDelays(mainnet, 0x694ADB3077BBecE31882B6d6A74fc4A4fA6a754b);
        _addTrancheWithDefaultDelays(mainnet, 0x8E0ec43E51B88AA2324102e1A3D667822be51A6d);
        // ApyUSD
        _addTrancheWithDefaultDelays(mainnet, 0xBd373c9D3D8976a4FECC504a93c768BBE8C3227C);
        _addTrancheWithDefaultDelays(mainnet, 0xAB2ab53E1e2E2c5D7202918EC8c873712bcc4a2D);

        // ── Avalanche ────────────────────────────────────────────────────────
        EntryPointConfig storage avalanche = _entryPointConfigs[AVALANCHE];
        avalanche.chainId = AVALANCHE;
        avalanche.roycoFactory = ROYCO_FACTORY;
        // savUSD
        _addTrancheWithDefaultDelays(avalanche, 0xDA7bf1788aecb94fE6D5D3f739358De94f43E5C9);
        _addTrancheWithDefaultDelays(avalanche, 0x2dfde7811567562aaB39D0A292e43aa7195f6Cf6);

        // ── Arbitrum ─────────────────────────────────────────────────────────
        EntryPointConfig storage arbitrum = _entryPointConfigs[ARBITRUM];
        arbitrum.chainId = ARBITRUM;
        arbitrum.roycoFactory = ROYCO_FACTORY;
        // sUSDai
        _addTrancheWithDefaultDelays(arbitrum, 0x90465aad4e426948A4ea342AC49A1A38200B7017);
        _addTrancheWithDefaultDelays(arbitrum, 0xeB60a64039289a4c07879147073A1Ec5AEA91553);
    }
}
