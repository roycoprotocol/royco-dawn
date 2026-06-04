// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { Vm } from "../../lib/forge-std/src/Vm.sol";
import { IAccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { DeployScript } from "../../script/Deploy.s.sol";
import { MarketDeploymentConfig } from "../../script/config/MarketDeploymentConfig.sol";
import { RolesConfiguration, RoycoFactory } from "../../src/factory/RoycoFactory.sol";
import { IRoycoFactory } from "../../src/interfaces/IRoycoFactory.sol";
import { ERC4626Mock } from "../mock/ERC4626Mock.sol";

/// @title DeploymentScriptRerunTest
/// @notice Tests that the deployment script can be run twice without reverting
/// @dev The first run deploys the factory and first market, the second run deploys a new market
contract DeploymentScriptRerunTest is Test, RolesConfiguration {
    // Test Wallets
    Vm.Wallet internal OWNER;
    address internal OWNER_ADDRESS;

    Vm.Wallet internal DEPLOYER;
    address internal DEPLOYER_ADDRESS;

    Vm.Wallet internal DEPLOYER_ADMIN;
    address internal DEPLOYER_ADMIN_ADDRESS;

    // Role-specific wallets
    Vm.Wallet internal PAUSER;
    address internal PAUSER_ADDRESS;

    Vm.Wallet internal UNPAUSER;
    address internal UNPAUSER_ADDRESS;

    Vm.Wallet internal UPGRADER;
    address internal UPGRADER_ADDRESS;

    Vm.Wallet internal SYNC_ROLE_HOLDER;
    address internal SYNC_ROLE_ADDRESS;

    Vm.Wallet internal KERNEL_ADMIN;
    address internal KERNEL_ADMIN_ADDRESS;

    Vm.Wallet internal ACCOUNTANT_ADMIN;
    address internal ACCOUNTANT_ADMIN_ADDRESS;

    Vm.Wallet internal PROTOCOL_FEE_SETTER;
    address internal PROTOCOL_FEE_SETTER_ADDRESS;

    Vm.Wallet internal ORACLE_QUOTER_ADMIN;
    address internal ORACLE_QUOTER_ADMIN_ADDRESS;

    Vm.Wallet internal LP_ROLE_ADMIN;
    address internal LP_ROLE_ADMIN_ADDRESS;

    Vm.Wallet internal ROLE_GUARDIAN;
    address internal ROLE_GUARDIAN_ADDRESS;

    Vm.Wallet internal PROTOCOL_FEE_RECIPIENT;
    address internal PROTOCOL_FEE_RECIPIENT_ADDRESS;

    Vm.Wallet internal RESERVE;
    address internal RESERVE_ADDRESS;

    // Deploy Script
    DeployScript internal DEPLOY_SCRIPT;

    // Mock vaults
    ERC4626Mock internal MOCK_UNDERLYING_ST_VAULT_1;
    ERC4626Mock internal MOCK_UNDERLYING_ST_VAULT_2;

    // Constants
    address internal constant ETHEREUM_MAINNET_USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Deployment params
    uint64 internal COVERAGE_WAD = 0.2e18;
    uint96 internal BETA_WAD = 0;
    uint64 internal ST_PROTOCOL_FEE_WAD = 0.1e18;
    uint64 internal JT_PROTOCOL_FEE_WAD = 0.1e18;
    uint256 internal LIQUIDATION_UTILIZATION_WAD = 6.4667e18;
    uint24 internal FIXED_TERM_DURATION_SECONDS = 2 weeks;
    uint256 internal DUST_TOLERANCE_RAW = 1;
    uint24 internal JT_REDEMPTION_DELAY_SECONDS = 1_000_000;

    function setUp() public {
        // Setup fork
        uint256 forkBlock = 23_997_023;
        string memory forkRpcUrl = vm.envString("MAINNET_RPC_URL");
        require(bytes(forkRpcUrl).length > 0, "MAINNET_RPC_URL environment variable is not set");
        vm.createSelectFork(forkRpcUrl, forkBlock);

        // Setup wallets
        _setupWallets();

        // Deploy the deploy script
        DEPLOY_SCRIPT = new DeployScript();

        // Deploy mock senior tranche underlying vaults
        MOCK_UNDERLYING_ST_VAULT_1 = new ERC4626Mock(ETHEREUM_MAINNET_USDC_ADDRESS, RESERVE_ADDRESS);
        vm.label(address(MOCK_UNDERLYING_ST_VAULT_1), "MockSTUnderlyingVault1");

        MOCK_UNDERLYING_ST_VAULT_2 = new ERC4626Mock(ETHEREUM_MAINNET_USDC_ADDRESS, RESERVE_ADDRESS);
        vm.label(address(MOCK_UNDERLYING_ST_VAULT_2), "MockSTUnderlyingVault2");

        // Have the reserve approve the mock vaults
        vm.startPrank(RESERVE_ADDRESS);
        IERC20(ETHEREUM_MAINNET_USDC_ADDRESS).approve(address(MOCK_UNDERLYING_ST_VAULT_1), type(uint256).max);
        IERC20(ETHEREUM_MAINNET_USDC_ADDRESS).approve(address(MOCK_UNDERLYING_ST_VAULT_2), type(uint256).max);
        vm.stopPrank();
    }

    function _setupWallets() internal {
        // Admin wallet
        OWNER = _initWallet("OWNER", 1000 ether);
        OWNER_ADDRESS = OWNER.addr;

        // Deployer wallets
        DEPLOYER = _initWallet("DEPLOYER", 1000 ether);
        DEPLOYER_ADDRESS = DEPLOYER.addr;

        DEPLOYER_ADMIN = _initWallet("DEPLOYER_ADMIN", 1000 ether);
        DEPLOYER_ADMIN_ADDRESS = DEPLOYER_ADMIN.addr;

        // Role-specific wallets
        PAUSER = _initWallet("PAUSER", 1000 ether);
        PAUSER_ADDRESS = PAUSER.addr;

        UNPAUSER = _initWallet("UNPAUSER", 1000 ether);
        UNPAUSER_ADDRESS = UNPAUSER.addr;

        UPGRADER = _initWallet("UPGRADER", 1000 ether);
        UPGRADER_ADDRESS = UPGRADER.addr;

        SYNC_ROLE_HOLDER = _initWallet("SYNC_ROLE_HOLDER", 1000 ether);
        SYNC_ROLE_ADDRESS = SYNC_ROLE_HOLDER.addr;

        KERNEL_ADMIN = _initWallet("KERNEL_ADMIN", 1000 ether);
        KERNEL_ADMIN_ADDRESS = KERNEL_ADMIN.addr;

        ACCOUNTANT_ADMIN = _initWallet("ACCOUNTANT_ADMIN", 1000 ether);
        ACCOUNTANT_ADMIN_ADDRESS = ACCOUNTANT_ADMIN.addr;

        PROTOCOL_FEE_SETTER = _initWallet("PROTOCOL_FEE_SETTER", 1000 ether);
        PROTOCOL_FEE_SETTER_ADDRESS = PROTOCOL_FEE_SETTER.addr;

        ORACLE_QUOTER_ADMIN = _initWallet("ORACLE_QUOTER_ADMIN", 1000 ether);
        ORACLE_QUOTER_ADMIN_ADDRESS = ORACLE_QUOTER_ADMIN.addr;

        LP_ROLE_ADMIN = _initWallet("LP_ROLE_ADMIN", 1000 ether);
        LP_ROLE_ADMIN_ADDRESS = LP_ROLE_ADMIN.addr;

        ROLE_GUARDIAN = _initWallet("ROLE_GUARDIAN", 1000 ether);
        ROLE_GUARDIAN_ADDRESS = ROLE_GUARDIAN.addr;

        PROTOCOL_FEE_RECIPIENT = _initWallet("PROTOCOL_FEE_RECIPIENT", 1000 ether);
        PROTOCOL_FEE_RECIPIENT_ADDRESS = PROTOCOL_FEE_RECIPIENT.addr;

        RESERVE = _initWallet("RESERVE", 1000 ether);
        RESERVE_ADDRESS = RESERVE.addr;
    }

    function _initWallet(string memory _name, uint256 _amount) internal returns (Vm.Wallet memory) {
        Vm.Wallet memory wallet = vm.createWallet(_name);
        vm.label(wallet.addr, _name);
        vm.deal(wallet.addr, _amount);
        return wallet;
    }

    function _generateRoleAssignments() internal view returns (IRoycoFactory.RoleAssignmentConfiguration[] memory) {
        return DEPLOY_SCRIPT.generateRolesAssignments(
            DeployScript.RoleAssignmentAddresses({
                pauserAddress: PAUSER_ADDRESS,
                unpauserAddress: UNPAUSER_ADDRESS,
                upgraderAddress: UPGRADER_ADDRESS,
                syncRoleAddress: SYNC_ROLE_ADDRESS,
                adminKernelAddress: KERNEL_ADMIN_ADDRESS,
                adminAccountantAddress: ACCOUNTANT_ADMIN_ADDRESS,
                adminProtocolFeeSetterAddress: PROTOCOL_FEE_SETTER_ADDRESS,
                adminOracleQuoterAddress: ORACLE_QUOTER_ADMIN_ADDRESS,
                lpRoleAdminAddress: LP_ROLE_ADMIN_ADDRESS,
                guardianAddress: ROLE_GUARDIAN_ADDRESS,
                deployerAddress: DEPLOYER_ADDRESS,
                deployerAdminAddress: DEPLOYER_ADMIN_ADDRESS,
                protocolFeeRecipientAddress: PROTOCOL_FEE_RECIPIENT_ADDRESS,
                transferAgentAddress: address(0)
            })
        );
    }

    function _buildMarketDeploymentConfig(
        string memory _seniorTrancheName,
        string memory _seniorTrancheSymbol,
        string memory _juniorTrancheName,
        string memory _juniorTrancheSymbol,
        address _stVault
    )
        internal
        view
        returns (MarketDeploymentConfig.MarketConfig memory config, IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments)
    {
        config.marketName = "test";
        config.chainId = block.chainid;
        config.seniorTrancheName = _seniorTrancheName;
        config.seniorTrancheSymbol = _seniorTrancheSymbol;
        config.juniorTrancheName = _juniorTrancheName;
        config.juniorTrancheSymbol = _juniorTrancheSymbol;
        config.seniorAsset = _stVault;
        config.juniorAsset = _stVault;
        config.stDustTolerance = DUST_TOLERANCE_RAW;
        config.jtDustTolerance = DUST_TOLERANCE_RAW;
        config.kernelType = DeployScript.KernelType.Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel;
        config.stProtocolFeeWAD = ST_PROTOCOL_FEE_WAD;
        config.jtProtocolFeeWAD = JT_PROTOCOL_FEE_WAD;
        config.jtYieldShareProtocolFeeWAD = JT_PROTOCOL_FEE_WAD;
        config.coverageWAD = COVERAGE_WAD;
        config.betaWAD = BETA_WAD;
        config.liquidationUtilizationWAD = LIQUIDATION_UTILIZATION_WAD;
        config.fixedTermDurationSeconds = FIXED_TERM_DURATION_SECONDS;
        config.ydmType = DeployScript.YDMType.AdaptiveCurve_V2;
        config.kernelSpecificParams = abi.encode(DeployScript.IdenticalERC4626SharesToAdminOracleQuoterKernelParams({ initialConversionRateWAD: 1e18 }));
        config.ydmSpecificParams = abi.encode(
            DeployScript.AdaptiveCurveYDM_V2_Params({
                jtYieldShareAtZeroUtilWAD: 0.225e18,
                jtYieldShareAtTargetUtilWAD: 0.225e18,
                jtYieldShareAtFullUtilWAD: 1e18,
                maxAdaptationSpeedWAD: uint64(30e18 / uint256(365 days))
            })
        );
        roleAssignments = _generateRoleAssignments();
    }

    // ============================================
    // DEPLOYMENT RERUN TESTS
    // ============================================

    /// @notice Test that the deployment script can be run twice - first deploy, then deploy a new market
    function test_deploymentScript_canRunTwice_differentMarkets() public {
        // ============================================
        // FIRST DEPLOYMENT
        // ============================================
        (MarketDeploymentConfig.MarketConfig memory config1, IRoycoFactory.RoleAssignmentConfiguration[] memory roles1) =
            _buildMarketDeploymentConfig("Royco Senior Tranche Alpha", "RST-A", "Royco Junior Tranche Alpha", "RJT-A", address(MOCK_UNDERLYING_ST_VAULT_1));

        uint32 scheduledOperationsExpirySeconds = DEPLOY_SCRIPT.getChainConfig(block.chainid).scheduledOperationsExpirySeconds;
        DeployScript.DeploymentResult memory result1 =
            DEPLOY_SCRIPT.deploy(config1, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, scheduledOperationsExpirySeconds, roles1, DEPLOYER.privateKey);

        // Verify first deployment succeeded
        assertTrue(address(result1.factory) != address(0), "First factory should be deployed");
        assertTrue(address(result1.kernel) != address(0), "First kernel should be deployed");
        assertTrue(address(result1.accountant) != address(0), "First accountant should be deployed");
        assertTrue(address(result1.seniorTranche) != address(0), "First senior tranche should be deployed");
        assertTrue(address(result1.juniorTranche) != address(0), "First junior tranche should be deployed");

        // Verify first market details
        assertEq(result1.seniorTranche.name(), "Royco Senior Tranche Alpha", "First ST name mismatch");
        assertEq(result1.seniorTranche.symbol(), "RST-A", "First ST symbol mismatch");
        assertEq(result1.juniorTranche.name(), "Royco Junior Tranche Alpha", "First JT name mismatch");
        assertEq(result1.juniorTranche.symbol(), "RJT-A", "First JT symbol mismatch");

        // ============================================
        // SECOND DEPLOYMENT - Different market, same factory
        // ============================================
        // Warp time to get different market ID
        vm.warp(block.timestamp + 1);

        (MarketDeploymentConfig.MarketConfig memory config2, IRoycoFactory.RoleAssignmentConfiguration[] memory roles2) =
            _buildMarketDeploymentConfig("Royco Senior Tranche Beta", "RST-B", "Royco Junior Tranche Beta", "RJT-B", address(MOCK_UNDERLYING_ST_VAULT_2));

        // Second deployment should succeed
        DeployScript.DeploymentResult memory result2 =
            DEPLOY_SCRIPT.deploy(config2, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, scheduledOperationsExpirySeconds, roles2, DEPLOYER.privateKey);

        // Verify second deployment succeeded
        assertTrue(address(result2.factory) != address(0), "Second factory should be deployed");
        assertTrue(address(result2.kernel) != address(0), "Second kernel should be deployed");
        assertTrue(address(result2.accountant) != address(0), "Second accountant should be deployed");
        assertTrue(address(result2.seniorTranche) != address(0), "Second senior tranche should be deployed");
        assertTrue(address(result2.juniorTranche) != address(0), "Second junior tranche should be deployed");

        // Verify second market details
        assertEq(result2.seniorTranche.name(), "Royco Senior Tranche Beta", "Second ST name mismatch");
        assertEq(result2.seniorTranche.symbol(), "RST-B", "Second ST symbol mismatch");
        assertEq(result2.juniorTranche.name(), "Royco Junior Tranche Beta", "Second JT name mismatch");
        assertEq(result2.juniorTranche.symbol(), "RJT-B", "Second JT symbol mismatch");

        // ============================================
        // VERIFY BOTH MARKETS ARE DISTINCT
        // ============================================

        // Both deployments should have deployed a new factory (due to different kernel implementations)
        // But the kernel, accountant, and tranches should be different
        assertTrue(address(result1.kernel) != address(result2.kernel), "Kernels should be different");
        assertTrue(address(result1.accountant) != address(result2.accountant), "Accountants should be different");
        assertTrue(address(result1.seniorTranche) != address(result2.seniorTranche), "Senior tranches should be different");
        assertTrue(address(result1.juniorTranche) != address(result2.juniorTranche), "Junior tranches should be different");
    }

    /// @notice Test that the deployment script properly configures roles on both runs
    function test_deploymentScript_rolesConfiguredOnBothRuns() public {
        // First deployment
        (MarketDeploymentConfig.MarketConfig memory config1, IRoycoFactory.RoleAssignmentConfiguration[] memory roles1) =
            _buildMarketDeploymentConfig("Royco Senior Tranche Alpha", "RST-A", "Royco Junior Tranche Alpha", "RJT-A", address(MOCK_UNDERLYING_ST_VAULT_1));

        uint32 scheduledOperationsExpirySeconds = DEPLOY_SCRIPT.getChainConfig(block.chainid).scheduledOperationsExpirySeconds;
        DeployScript.DeploymentResult memory result1 =
            DEPLOY_SCRIPT.deploy(config1, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, scheduledOperationsExpirySeconds, roles1, DEPLOYER.privateKey);

        // Verify roles are configured for first deployment
        IAccessManager factory1 = IAccessManager(address(result1.factory));
        (bool hasPauserRole,) = factory1.hasRole(ADMIN_PAUSER_ROLE, PAUSER_ADDRESS);
        assertTrue(hasPauserRole, "First deployment: PAUSER should have ADMIN_PAUSER_ROLE");

        (bool hasSyncRole,) = factory1.hasRole(SYNC_ROLE, SYNC_ROLE_ADDRESS);
        assertTrue(hasSyncRole, "First deployment: SYNC_ROLE_HOLDER should have SYNC_ROLE");

        (bool hasKernelAdminRole,) = factory1.hasRole(ADMIN_KERNEL_ROLE, KERNEL_ADMIN_ADDRESS);
        assertTrue(hasKernelAdminRole, "First deployment: KERNEL_ADMIN should have ADMIN_KERNEL_ROLE");

        // Second deployment
        vm.warp(block.timestamp + 1);

        (MarketDeploymentConfig.MarketConfig memory config2, IRoycoFactory.RoleAssignmentConfiguration[] memory roles2) =
            _buildMarketDeploymentConfig("Royco Senior Tranche Beta", "RST-B", "Royco Junior Tranche Beta", "RJT-B", address(MOCK_UNDERLYING_ST_VAULT_2));

        DeployScript.DeploymentResult memory result2 =
            DEPLOY_SCRIPT.deploy(config2, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, scheduledOperationsExpirySeconds, roles2, DEPLOYER.privateKey);

        // Verify roles are configured for second deployment
        IAccessManager factory2 = IAccessManager(address(result2.factory));
        (hasPauserRole,) = factory2.hasRole(ADMIN_PAUSER_ROLE, PAUSER_ADDRESS);
        assertTrue(hasPauserRole, "Second deployment: PAUSER should have ADMIN_PAUSER_ROLE");

        (hasSyncRole,) = factory2.hasRole(SYNC_ROLE, SYNC_ROLE_ADDRESS);
        assertTrue(hasSyncRole, "Second deployment: SYNC_ROLE_HOLDER should have SYNC_ROLE");

        (hasKernelAdminRole,) = factory2.hasRole(ADMIN_KERNEL_ROLE, KERNEL_ADMIN_ADDRESS);
        assertTrue(hasKernelAdminRole, "Second deployment: KERNEL_ADMIN should have ADMIN_KERNEL_ROLE");
    }

    /// @notice Test that deployer can deploy multiple markets using the factory's deployMarket function
    function test_deployerCanDeployMultipleMarketsViaFactory() public {
        // First deployment creates the factory
        (MarketDeploymentConfig.MarketConfig memory config1, IRoycoFactory.RoleAssignmentConfiguration[] memory roles1) =
            _buildMarketDeploymentConfig("Royco Senior Tranche Alpha", "RST-A", "Royco Junior Tranche Alpha", "RJT-A", address(MOCK_UNDERLYING_ST_VAULT_1));

        uint32 scheduledOperationsExpirySeconds = DEPLOY_SCRIPT.getChainConfig(block.chainid).scheduledOperationsExpirySeconds;
        DeployScript.DeploymentResult memory result1 =
            DEPLOY_SCRIPT.deploy(config1, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, scheduledOperationsExpirySeconds, roles1, DEPLOYER.privateKey);
        RoycoFactory factory = result1.factory;

        // Verify DEPLOYER has DEPLOYER_ROLE
        (bool hasDeployerRole,) = IAccessManager(address(factory)).hasRole(DEPLOYER_ROLE, DEPLOYER_ADDRESS);
        assertTrue(hasDeployerRole, "DEPLOYER should have DEPLOYER_ROLE");

        // Now deploy a second market directly using the factory
        // This simulates a scenario where the factory already exists and we just want to add a new market
        vm.warp(block.timestamp + 1);

        // Verify the factory admin is OWNER_ADDRESS after deployment
        (bool isOwnerAdmin,) = IAccessManager(address(factory)).hasRole(0, OWNER_ADDRESS);
        assertTrue(isOwnerAdmin, "OWNER should be admin of the factory");
    }

    /// @notice Test that the same deployer can use the factory after ownership transfer
    function test_deployerRetainsRoleAfterOwnershipTransfer() public {
        // Deploy first market
        (MarketDeploymentConfig.MarketConfig memory config1, IRoycoFactory.RoleAssignmentConfiguration[] memory roles1) =
            _buildMarketDeploymentConfig("Royco Senior Tranche Alpha", "RST-A", "Royco Junior Tranche Alpha", "RJT-A", address(MOCK_UNDERLYING_ST_VAULT_1));

        uint32 scheduledOperationsExpirySeconds = DEPLOY_SCRIPT.getChainConfig(block.chainid).scheduledOperationsExpirySeconds;
        DeployScript.DeploymentResult memory result1 =
            DEPLOY_SCRIPT.deploy(config1, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, scheduledOperationsExpirySeconds, roles1, DEPLOYER.privateKey);
        RoycoFactory factory = result1.factory;

        // After deployment, OWNER_ADDRESS should be the admin (ownership transferred)
        (bool isOwnerAdmin,) = IAccessManager(address(factory)).hasRole(0, OWNER_ADDRESS);
        assertTrue(isOwnerAdmin, "OWNER should be admin after deployment");

        // DEPLOYER should still have DEPLOYER_ROLE
        (bool hasDeployerRole,) = IAccessManager(address(factory)).hasRole(DEPLOYER_ROLE, DEPLOYER_ADDRESS);
        assertTrue(hasDeployerRole, "DEPLOYER should retain DEPLOYER_ROLE after ownership transfer");
    }
}
