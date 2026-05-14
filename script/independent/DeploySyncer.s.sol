// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { RolesConfiguration } from "../../src/factory/RolesConfiguration.sol";
import { IRoycoAuth } from "../../src/interfaces/IRoycoAuth.sol";
import { RoycoMarketSyncer } from "../../src/periphery/RoycoMarketSyncer.sol";
import { ExtraRoles } from "../config/ExtraRoles.sol";
import { SyncerDeploymentConfig } from "../config/SyncerDeploymentConfig.sol";
import { AccessManagerConfigUtils } from "../utils/AccessManagerConfigUtils.sol";
import { Create2DeployUtils } from "../utils/Create2DeployUtils.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

/**
 * @title DeploySyncerScript
 * @notice Deployment script for the RoycoMarketSyncer contract
 * @dev Deploys both the implementation and ERC1967 proxy using deterministic CREATE2 deployment.
 *      Also generates a Safe-compatible JSON file containing the factory configuration transactions
 *      needed to make the syncer operational.
 */
contract DeploySyncerScript is SyncerDeploymentConfig, AccessManagerConfigUtils, Create2DeployUtils, RolesConfiguration, ExtraRoles {
    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Deployment salt for Royco syncers
    bytes32 constant SYNCER_SALT_BASE = keccak256("ROYCO_SYNCER");

    /// @dev Suffix for the Safe transaction JSON file name (prepended with chain ID)
    string constant SAFE_TX_OUTPUT_FILE_NAME_SUFFIX = "_syncer_role_config";

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT FLAGS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Whether to print deployment parameters
    bool ENABLE_LOGGING = false;

    /// @dev Whether to generate Safe transaction JSON for factory configuration
    bool GENERATE_SAFE_TX_JSON = true;

    // ═══════════════════════════════════════════════════════════════════════════
    // ENTRY POINT
    // ═══════════════════════════════════════════════════════════════════════════

    function run() external {
        ENABLE_LOGGING = true;

        // Read config from environment variables
        string memory syncerName = block.chainid == MAINNET ? MAINNET_SYNCER : block.chainid == AVALANCHE ? AVALANCHE_SYNCER : ARBITRUM_SYNCER;
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        SyncerConfig memory config = getSyncerConfig(syncerName);

        // Deploy the syncer
        address syncer = deploySyncer(config.roycoFactory, config.marketKernels, deployerPrivateKey);

        // Generate Safe transaction JSON for factory configuration
        if (GENERATE_SAFE_TX_JSON) {
            generateFactoryConfigSafeJson(config.roycoFactory, syncer, config.configSpecificSyncOperators);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deploys a RoycoMarketSyncer implementation and proxy
     * @dev Uses CREATE2 for deterministic deployment addresses
     * @param _roycoFactory The Royco factory to use as the access manager for the syncer
     * @param _marketKernels The initial market kernels to register with the syncer
     * @param deployerPrivateKey The private key to use for executing the deployment
     * @return syncer The address of the deployed syncer proxy
     */
    function deploySyncer(address _roycoFactory, address[] memory _marketKernels, uint256 deployerPrivateKey) public returns (address syncer) {
        vm.startBroadcast(deployerPrivateKey);
        // Deploy the syncer implementation
        (address syncerImplAddr, bool alreadyDeployed) = deployWithSanityChecks(SYNCER_SALT_BASE, type(RoycoMarketSyncer).creationCode, false);
        if (ENABLE_LOGGING) {
            if (alreadyDeployed) {
                console2.log("Syncer Implementation already deployed at:", syncerImplAddr);
            } else {
                console2.log("Syncer Implementation deployed at:", syncerImplAddr);
            }
        }

        // Deploy the syncer proxy
        (syncer, alreadyDeployed) = deployWithSanityChecks(
            SYNCER_SALT_BASE, getERC1967ProxyCreationCode(syncerImplAddr, abi.encodeCall(RoycoMarketSyncer.initialize, (_roycoFactory, _marketKernels))), false
        );
        if (ENABLE_LOGGING) {
            if (alreadyDeployed) {
                console2.log("Syncer proxy already deployed at:", syncer);
            } else {
                console2.log("Syncer proxy deployed at:", syncer);
            }
        }
        vm.stopBroadcast();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SAFE TRANSACTION GENERATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Generates a Safe-compatible JSON file containing the factory configuration transactions
     * @dev The transactions configure the syncer's function-to-role mappings on the factory.
     *      This function is public to allow testing against production roles and deployment config.
     * @param _factory The Royco factory (access manager) address
     * @param _syncer The deployed syncer proxy address
     * @param _syncOperators Addresses to grant SYNC_ROLE (keeper bots, operators)
     */
    function generateFactoryConfigSafeJson(address _factory, address _syncer, address[] memory _syncOperators) public {
        // Build the list of transactions needed to configure the syncer
        SafeTransaction[] memory transactions = buildSyncerConfigTransactions(_factory, _syncer, _syncOperators);

        string memory outputFileName = string(abi.encodePacked(vm.toString(block.chainid), SAFE_TX_OUTPUT_FILE_NAME_SUFFIX));
        // Write the Safe-compatible JSON using inherited utility
        writeSafeTransactionJson(
            transactions,
            outputFileName,
            "Royco Market Syncer Factory Configuration",
            "Sets up the roles configuration for the Royco Market Syncer on the Royco Factory"
        );

        if (ENABLE_LOGGING) {
            console2.log("");
            console2.log("========================================");
            console2.log("Safe Transaction JSON Generated:");
            console2.log("  File Name:", outputFileName);
            console2.log("  Transactions:", transactions.length);
            console2.log("========================================");
            console2.log("");
            console2.log("Import this JSON into Safe Transaction Builder to configure the syncer.");
        }
    }

    /**
     * @notice Builds the transactions needed to configure the syncer on the factory, including role grants
     * @dev Configures function-to-role mappings and grants SYNC_ROLE to specified operators.
     *      This function is public to allow testing against production roles and deployment config.
     * @param _factory The Royco factory (access manager) address
     * @param _syncer The deployed syncer proxy address
     * @param _syncOperators Addresses to grant SYNC_ROLE (e.g., keeper bots, operators)
     * @return transactions Array of transactions to execute via Safe
     */
    function buildSyncerConfigTransactions(
        address _factory,
        address _syncer,
        address[] memory _syncOperators
    )
        public
        pure
        returns (SafeTransaction[] memory transactions)
    {
        // Base transactions: 4 for setTargetFunctionRole (SYNC, pause, unpause, upgrade)
        //                  + 1 for granting syncer SYNC_ROLE
        // Plus 1 grantRole per sync operator
        uint256 numTransactions = 5 + _syncOperators.length;
        transactions = new SafeTransaction[](numTransactions);

        // Transaction 1: SYNC_ROLE functions
        bytes4[] memory syncSelectors = new bytes4[](4);
        syncSelectors[0] = RoycoMarketSyncer.executeBatchAccountingSync.selector;
        syncSelectors[1] = RoycoMarketSyncer.executeBatchAccountingSyncFor.selector;
        syncSelectors[2] = RoycoMarketSyncer.addMarketKernels.selector;
        syncSelectors[3] = RoycoMarketSyncer.removeMarketKernels.selector;
        transactions[0] = buildSetTargetFunctionRole(_factory, _syncer, syncSelectors, SYNC_ROLE);

        // Transaction 2: pause -> ADMIN_PAUSER_ROLE
        bytes4[] memory pauseSelectors = new bytes4[](1);
        pauseSelectors[0] = IRoycoAuth.pause.selector;
        transactions[1] = buildSetTargetFunctionRole(_factory, _syncer, pauseSelectors, ADMIN_PAUSER_ROLE);

        // Transaction 3: unpause -> ADMIN_UNPAUSER_ROLE
        bytes4[] memory unpauseSelectors = new bytes4[](1);
        unpauseSelectors[0] = IRoycoAuth.unpause.selector;
        transactions[2] = buildSetTargetFunctionRole(_factory, _syncer, unpauseSelectors, ADMIN_UNPAUSER_ROLE);

        // Transaction 4: ADMIN_UPGRADER_ROLE functions
        bytes4[] memory upgraderSelectors = new bytes4[](1);
        upgraderSelectors[0] = UUPSUpgradeable.upgradeToAndCall.selector;
        transactions[3] = buildSetTargetFunctionRole(_factory, _syncer, upgraderSelectors, ADMIN_UPGRADER_ROLE);

        // Transaction 5: Grant SYNC_ROLE to the syncer (required to call syncTrancheAccounting on kernels)
        transactions[4] = buildGrantRole(_factory, SYNC_ROLE, _syncer, 0);

        // Transactions 6+: Grant SYNC_ROLE to each operator
        for (uint256 i = 0; i < _syncOperators.length; i++) {
            transactions[5 + i] = buildGrantRole(_factory, SYNC_ROLE, _syncOperators[i], 0);
        }
    }
}
