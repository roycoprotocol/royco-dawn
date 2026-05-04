// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IAccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { RolesConfiguration } from "../../src/factory/RolesConfiguration.sol";
import { IRoycoAuth } from "../../src/interfaces/IRoycoAuth.sol";
import { IRoycoEntryPoint } from "../../src/interfaces/IRoycoEntryPoint.sol";
import { IRoycoVaultTranche } from "../../src/interfaces/IRoycoVaultTranche.sol";
import { TRANCHE_UNIT, toTrancheUnits } from "../../src/libraries/Units.sol";
import { RoycoEntryPoint } from "../../src/periphery/RoycoEntryPoint.sol";

import { EntryPointDeploymentConfig } from "../config/EntryPointDeploymentConfig.sol";
import { AccessManagerConfigUtils } from "../utils/AccessManagerConfigUtils.sol";
import { Create2DeployUtils } from "../utils/Create2DeployUtils.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

/**
 * @title DeployEntryPointScript
 * @notice Deployment script for the RoycoEntryPoint contract
 * @dev Deploys both the implementation and ERC1967 proxy using deterministic CREATE2 deployment.
 *      Supports two modes:
 *      - Production: deploys only, role configuration done separately via Safe (future)
 *      - Test: deploys AND configures roles using separate deployer and admin keys
 */
contract DeployEntryPointScript is EntryPointDeploymentConfig, AccessManagerConfigUtils, Create2DeployUtils, RolesConfiguration {
    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Deployment salt for the RoycoEntryPoint
    bytes32 internal constant ENTRY_POINT_SALT_BASE = keccak256("ROYCO_ENTRY_POINT");

    /// @dev Suffix for the Safe transaction JSON file name
    string internal constant SAFE_TX_OUTPUT_FILE_NAME_SUFFIX = "_entry_point_role_config";

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

        address entryPoint = deployEntryPoint(config, deployerPrivateKey);

        if (ENABLE_LOGGING) {
            console2.log("");
            console2.log("========================================");
            console2.log("Entry Point deployed at:", entryPoint);
            console2.log("Factory:", config.roycoFactory);
            console2.log("Chain:", config.chainId);
            console2.log("Tranches configured:", config.tranches.length);
            console2.log("========================================");
            console2.log("");
            console2.log("NOTE: Factory role configuration must be done separately.");
            console2.log("Use runTest() for test environments.");
        }
    }

    /**
     * @notice Test deployment entry point - deploys AND configures roles
     * @dev Uses two separate keys:
     *      - DEPLOYER_PRIVATE_KEY for CREATE2 deployment
     *      - ADMIN_PRIVATE_KEY for configuring roles on the factory (must have admin role)
     *
     * Environment variables:
     *   DEPLOYER_PRIVATE_KEY - Key for the deployer account (CREATE2 deployment)
     *   ADMIN_PRIVATE_KEY    - Key with admin access to the factory (role configuration)
     */
    function runTest() external {
        ENABLE_LOGGING = true;

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 adminPrivateKey = vm.envUint("ADMIN_PRIVATE_KEY");
        EntryPointConfig memory config = getEntryPointConfig();

        // Step 1: Deploy using the deployer key
        address entryPoint = deployEntryPoint(config, deployerPrivateKey);

        // Step 2: Configure factory roles using the admin key
        vm.startBroadcast(adminPrivateKey);
        configureFactoryRoles(config.roycoFactory, entryPoint);

        // Step 3: Grant LP role to the admin so they can call the entry point
        address adminAddr = vm.addr(adminPrivateKey);
        IAccessManager(config.roycoFactory).grantRole(ST_LP_ROLE, adminAddr, 0);
        vm.stopBroadcast();

        // Step 4: Smoke test - request a deposit through the entry point
        // _smokeTestDeposit(entryPoint, config, adminPrivateKey);

        if (ENABLE_LOGGING) {
            console2.log("");
            console2.log("========================================");
            console2.log("Entry Point Deployed & Configured (Test Mode)");
            console2.log("  Entry Point:", entryPoint);
            console2.log("  Factory:", config.roycoFactory);
            console2.log("  Chain:", config.chainId);
            console2.log("  Tranches:", config.tranches.length);
            console2.log("  Roles: configured directly");
            console2.log("  Smoke test: passed");
            console2.log("========================================");
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
        (address implAddr, bool alreadyDeployed) = deployWithSanityChecks(ENTRY_POINT_SALT_BASE, type(RoycoEntryPoint).creationCode, false);
        if (ENABLE_LOGGING) {
            if (alreadyDeployed) console2.log("EntryPoint Implementation already deployed at:", implAddr);
            else console2.log("EntryPoint Implementation deployed at:", implAddr);
        }

        // Deploy the proxy
        bytes memory initData = abi.encodeCall(RoycoEntryPoint.initialize, (_config.roycoFactory, tranches, trancheConfigs));
        (entryPoint, alreadyDeployed) = deployWithSanityChecks(ENTRY_POINT_SALT_BASE, getERC1967ProxyCreationCode(implAddr, initData), false);
        if (ENABLE_LOGGING) {
            if (alreadyDeployed) console2.log("EntryPoint Proxy already deployed at:", entryPoint);
            else console2.log("EntryPoint Proxy deployed at:", entryPoint);
        }

        vm.stopBroadcast();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FACTORY ROLE CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Configures factory roles for the entry point directly on-chain
     * @dev Must be called within a broadcast from an account with admin access to the factory.
     *      Sets up function-to-role mappings and grants LP roles to the entry point.
     *
     * Role mappings:
     *   - LP functions (request/execute/cancel deposits & redemptions) -> ST_LP_ROLE
     *   - Admin functions (modifyTrancheConfigs, collectProtocolFees)  -> ADMIN_KERNEL_ROLE
     *   - Pause/unpause                                                -> ADMIN_PAUSER_ROLE
     *   - upgradeToAndCall                                             -> ADMIN_UPGRADER_ROLE
     *
     * The entry point itself is granted ST_LP_ROLE and JT_LP_ROLE so it can
     * call tranche deposit/redeem functions when executing user requests.
     *
     * @param _factory The Royco factory (AccessManager) address
     * @param _entryPoint The deployed entry point proxy address
     */
    function configureFactoryRoles(address _factory, address _entryPoint) public {
        if (ENABLE_LOGGING) console2.log("Configuring factory roles for entry point...");

        // ── LP function selectors ────────────────────────────────────────────
        bytes4[] memory lpSelectors = _buildLPSelectors();
        IAccessManager(_factory).setTargetFunctionRole(_entryPoint, lpSelectors, ST_LP_ROLE);
        if (ENABLE_LOGGING) console2.log("  [OK] LP functions -> ST_LP_ROLE");

        // ── Admin function selectors ─────────────────────────────────────────
        bytes4[] memory adminSelectors = new bytes4[](2);
        adminSelectors[0] = IRoycoEntryPoint.modifyTrancheConfigs.selector;
        adminSelectors[1] = IRoycoEntryPoint.collectProtocolFees.selector;
        IAccessManager(_factory).setTargetFunctionRole(_entryPoint, adminSelectors, ADMIN_KERNEL_ROLE);
        if (ENABLE_LOGGING) console2.log("  [OK] Admin functions -> ADMIN_KERNEL_ROLE");

        // ── Pauser selectors ─────────────────────────────────────────────────
        bytes4[] memory pauserSelectors = new bytes4[](2);
        pauserSelectors[0] = IRoycoAuth.pause.selector;
        pauserSelectors[1] = IRoycoAuth.unpause.selector;
        IAccessManager(_factory).setTargetFunctionRole(_entryPoint, pauserSelectors, ADMIN_PAUSER_ROLE);
        if (ENABLE_LOGGING) console2.log("  [OK] Pause/unpause -> ADMIN_PAUSER_ROLE");

        // ── Upgrader selectors ───────────────────────────────────────────────
        bytes4[] memory upgraderSelectors = new bytes4[](1);
        upgraderSelectors[0] = UUPSUpgradeable.upgradeToAndCall.selector;
        IAccessManager(_factory).setTargetFunctionRole(_entryPoint, upgraderSelectors, ADMIN_UPGRADER_ROLE);
        if (ENABLE_LOGGING) console2.log("  [OK] upgradeToAndCall -> ADMIN_UPGRADER_ROLE");

        // ── Grant LP roles to the entry point itself ─────────────────────────
        IAccessManager(_factory).grantRole(ST_LP_ROLE, _entryPoint, 0);
        IAccessManager(_factory).grantRole(JT_LP_ROLE, _entryPoint, 0);
        IAccessManager(_factory).grantRole(BURNER_ROLE, _entryPoint, 0);
        if (ENABLE_LOGGING) console2.log("  [OK] Granted ST_LP_ROLE + JT_LP_ROLE + BURNER_ROLE to entry point");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SMOKE TEST
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Smoke tests the entry point by requesting and executing a deposit on the first tranche
     * @dev Uses a trace amount (1 wei of the tranche asset) to verify the full flow works
     * @param _entryPoint The deployed entry point proxy address
     * @param _config The entry point deployment configuration
     * @param _adminPrivateKey The admin private key (must hold some of the tranche asset)
     */
    function _smokeTestDeposit(address _entryPoint, EntryPointConfig memory _config, uint256 _adminPrivateKey) internal {
        require(_config.tranches.length > 0, "No tranches to test");

        // Use the last tranche (JT) since ST deposits require JT capital for coverage
        address tranche = _config.tranches[_config.tranches.length - 1].tranche;
        address asset = IRoycoVaultTranche(tranche).asset();
        address adminAddr = vm.addr(_adminPrivateKey);
        TRANCHE_UNIT depositAmount = toTrancheUnits(1000); // 1000 wei - trace amount

        if (ENABLE_LOGGING) console2.log("Smoke testing deposit...");
        if (ENABLE_LOGGING) console2.log("  Tranche:", tranche);
        if (ENABLE_LOGGING) console2.log("  Asset:", asset);

        // Use prank (not broadcast) for the smoke test since we need vm.warp between request and execute
        vm.startPrank(adminAddr);

        // Approve the entry point to spend the asset
        IERC20(asset).approve(_entryPoint, type(uint256).max);

        // Request a deposit (with executor execution disabled)
        (uint256 nonce, uint32 executableAt) =
            IRoycoEntryPoint(_entryPoint)
                .requestDeposit(
                    tranche,
                    depositAmount,
                    adminAddr,
                    type(uint64).max // opt out of third-party execution
                );

        if (ENABLE_LOGGING) console2.log("  [OK] Deposit requested, nonce:", nonce);
        if (ENABLE_LOGGING) console2.log("  [OK] Executable at:", uint256(executableAt));

        vm.stopPrank();

        // Warp past the deposit delay and execute
        vm.warp(executableAt + 1);

        vm.prank(adminAddr);
        uint256 sharesMinted = IRoycoEntryPoint(_entryPoint).executeDeposit(adminAddr, nonce, depositAmount);

        if (ENABLE_LOGGING) console2.log("  [OK] Deposit executed, shares minted:", sharesMinted);
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
    function buildFactoryConfigTransactions(address _factory, address _entryPoint) public pure returns (SafeTransaction[] memory transactions) {
        bytes4[] memory lpSelectors = _buildLPSelectors();

        bytes4[] memory adminSelectors = new bytes4[](2);
        adminSelectors[0] = IRoycoEntryPoint.modifyTrancheConfigs.selector;
        adminSelectors[1] = IRoycoEntryPoint.collectProtocolFees.selector;

        bytes4[] memory pauserSelectors = new bytes4[](2);
        pauserSelectors[0] = IRoycoAuth.pause.selector;
        pauserSelectors[1] = IRoycoAuth.unpause.selector;

        bytes4[] memory upgraderSelectors = new bytes4[](1);
        upgraderSelectors[0] = UUPSUpgradeable.upgradeToAndCall.selector;

        // 4 setTargetFunctionRole + 3 grantRole = 7 total
        transactions = new SafeTransaction[](7);
        transactions[0] = buildSetTargetFunctionRole(_factory, _entryPoint, lpSelectors, ST_LP_ROLE);
        transactions[1] = buildSetTargetFunctionRole(_factory, _entryPoint, adminSelectors, ADMIN_KERNEL_ROLE);
        transactions[2] = buildSetTargetFunctionRole(_factory, _entryPoint, pauserSelectors, ADMIN_PAUSER_ROLE);
        transactions[3] = buildSetTargetFunctionRole(_factory, _entryPoint, upgraderSelectors, ADMIN_UPGRADER_ROLE);
        transactions[4] = buildGrantRole(_factory, ST_LP_ROLE, _entryPoint, 0);
        transactions[5] = buildGrantRole(_factory, JT_LP_ROLE, _entryPoint, 0);
        transactions[6] = buildGrantRole(_factory, BURNER_ROLE, _entryPoint, 0);
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

    function _initializeEntryPointConfig() internal virtual override {
        // ── sUSDai on Arbitrum ────────────────────────────────────────────────
        _entryPointConfig.chainId = ARBITRUM;
        _entryPointConfig.roycoFactory = 0xD5dF65cfA3fAb54470cecC22b776cD54Ac718A1c;

        _entryPointConfig.tranches
            .push(
                TrancheInitConfig({
                    tranche: 0x8C20837244C59cd2204D5318e334af16A3C4Ab28, // ST
                    config: IRoycoEntryPoint.TrancheConfig({
                        enabled: true,
                        yieldRecipient: IRoycoEntryPoint.AccruedYieldRecipient.REMAINING_LPS,
                        depositDelaySeconds: 5 minutes,
                        redemptionDelaySeconds: 5 minutes
                    })
                })
            );
        _entryPointConfig.tranches
            .push(
                TrancheInitConfig({
                    tranche: 0xd645abcB2836CbB84246E3634454372637E65Fb1, // JT
                    config: IRoycoEntryPoint.TrancheConfig({
                        enabled: true,
                        yieldRecipient: IRoycoEntryPoint.AccruedYieldRecipient.REMAINING_LPS,
                        depositDelaySeconds: 5 minutes,
                        redemptionDelaySeconds: 5 minutes
                    })
                })
            );
    }
}
