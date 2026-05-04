// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "../lib/openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import { RoycoAccountant } from "../src/accountant/RoycoAccountant.sol";
import { RolesConfiguration, RoycoFactory } from "../src/factory/RoycoFactory.sol";
import { IRoycoAccountant } from "../src/interfaces/IRoycoAccountant.sol";
import { IRoycoAuth } from "../src/interfaces/IRoycoAuth.sol";
import { IRoycoFactory } from "../src/interfaces/IRoycoFactory.sol";
import { IRoycoKernel } from "../src/interfaces/IRoycoKernel.sol";
import { IRoycoVaultTranche } from "../src/interfaces/IRoycoVaultTranche.sol";
import { IYDM } from "../src/interfaces/IYDM.sol";
import { Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_Kernel } from "../src/kernels/Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_Kernel.sol";
import { Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel } from "../src/kernels/Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel.sol";
import {
    Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel
} from "../src/kernels/Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel.sol";
import { Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel } from "../src/kernels/Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel.sol";
import { Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel } from "../src/kernels/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";
import { Identical_Makina_ST_JT_MachineToAdminOracle_Kernel } from "../src/kernels/Identical_Makina_ST_JT_MachineToAdminOracle_Kernel.sol";
import { Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle } from "../src/kernels/Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle.sol";
import { MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel } from "../src/kernels/MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel.sol";
import { ReUSD_ST_JT_ICLOracle_Kernel } from "../src/kernels/ReUSD_ST_JT_ICLOracle_Kernel.sol";
import { apyUSD_ST_JT_SharePriceToChainlinkOracle_Kernel } from "../src/kernels/apyUSD_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";
import { IdenticalAssetsChainlinkOracleQuoter } from "../src/kernels/base/quoter/base/IdenticalAssetsChainlinkOracleQuoter.sol";
import { IdenticalAssetsOracleQuoter } from "../src/kernels/base/quoter/base/IdenticalAssetsOracleQuoter.sol";
import { sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel } from "../src/kernels/sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel.sol";
import { sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel } from "../src/kernels/sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";
import { toNAVUnits } from "../src/libraries/Units.sol";
import { RoycoJuniorTranche } from "../src/tranches/RoycoJuniorTranche.sol";
import { RoycoSeniorTranche } from "../src/tranches/RoycoSeniorTranche.sol";
import { AdaptiveCurveYDM_V1 } from "../src/ydm/AdaptiveCurveYDM_V1.sol";
import { AdaptiveCurveYDM_V2 } from "../src/ydm/AdaptiveCurveYDM_V2.sol";
import { StaticCurveYDM } from "../src/ydm/StaticCurveYDM.sol";
import { MarketDeploymentConfig } from "./config/MarketDeploymentConfig.sol";
import { Create2DeployUtils } from "./utils/Create2DeployUtils.sol";
import { Script } from "lib/forge-std/src/Script.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

/// @title DeployScript
/// @notice Deployment script for Royco markets. Handles deterministic (CREATE2) deployment of all
///         market components: factory, kernel, accountant, tranches, and YDM.
/// @dev Inherits from:
///   - Script (Foundry scripting)
///   - Create2DeployUtils (deterministic deployments via CREATE2)
///   - RolesConfiguration (role constants and config)
///   - MarketDeploymentConfig (per-chain and per-market configuration)
contract DeployScript is Script, Create2DeployUtils, RolesConfiguration, MarketDeploymentConfig {
    // Custom errors
    error UnsupportedKernelType(KernelType kernelType);
    error UnsupportedYDMType(YDMType ydmType);

    // Deployment salts for CREATE2
    bytes32 constant ACCOUNTANT_IMPL_SALT = keccak256("ROYCO_ACCOUNTANT_IMPLEMENTATION_V2");
    bytes32 constant KERNEL_IMPL_SALT = keccak256("ROYCO_KERNEL_IMPLEMENTATION_V2");
    bytes32 constant ST_TRANCHE_IMPL_SALT = keccak256("ROYCO_ST_TRANCHE_IMPLEMENTATION_V2");
    bytes32 constant JT_TRANCHE_IMPL_SALT = keccak256("ROYCO_JT_TRANCHE_IMPLEMENTATION_V2");
    bytes32 constant YDM_SALT = keccak256("ROYCO_YDM_IMPLEMENTATION_V2");
    bytes32 constant FACTORY_SALT_BASE = keccak256("ROYCO_FACTORY_IMPLEMENTATION_V2");
    bytes32 constant MARKET_DEPLOYMENT_SALT = keccak256("ROYCO_MARKET_DEPLOYMENT_V2");

    // Whether to print deployment parameters
    bool ENABLE_LOGGING = false;

    /// @notice Enum for kernel types
    enum KernelType {
        ReUSD_ST_ReUSD_JT,
        Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel,
        Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel,
        Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel,
        Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel,
        IdleCdoAA_ST_IdleCdoAA_JT,
        Identical_Makina_ST_JT_MachineToAdminOracle_Kernel,
        sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel,
        MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel,
        apyUSD_ST_JT_SharePriceToChainlinkOracle_Kernel,
        Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle_Kernel,
        sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel
    }

    /// @notice Enum for YDM types
    enum YDMType {
        StaticCurve,
        AdaptiveCurve_V1,
        AdaptiveCurve_V2
    }

    /// @notice Deployment parameters for Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_Kernel
    struct IdleAACdoSTCdoJTKernelParams {
        address idleCDO;
    }

    /// @notice Deployment parameters for ReUSD_ST_JT_ICLOracle_Kernel
    struct ReUSDSTReUSDJTKernelParams {
        address reusd;
        address reusdUsdQuoteToken;
        address insuranceCapitalLayer;
    }

    /// @notice Deployment parameters for Identical_Makina_ST_JT_MachineToAdminOracle_Kernel
    struct IdenticalMakinaSTMakinaJTKernelParams {
        address makinaMachine;
        uint256 initialConversionRateWAD;
    }

    /// @notice Deployment parameters for Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel
    struct IdenticalAssetsChainlinkToAdminOracleQuoterKernelParams {
        uint256 initialConversionRateWAD;
        address trancheAssetToReferenceAssetOracle;
        uint48 stalenessThresholdSeconds;
    }

    /// @notice Deployment parameters for Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel
    struct IdenticalERC4626SharesToAdminOracleQuoterKernelParams {
        uint256 initialConversionRateWAD;
    }

    /// @notice Deployment parameters for Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel
    struct IdenticalERC4626SharesToChainlinkOracleQuoterKernelParams {
        uint256 initialConversionRateWAD;
        address baseAssetToNavAssetOracle;
        uint48 stalenessThresholdSeconds;
    }

    /// @notice Deployment parameters for kernels that employ the IdenticalAssetsAdminOracleQuoter
    struct IdenticalAssetsAdminOracleQuoterKernelParams {
        uint256 initialConversionRateWAD;
    }

    /// @notice Deployment parameters for Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle_Kernel
    struct LockedIUSDKernelParams {
        address infiniFiGateway;
        uint32 unwindingEpochs;
        uint256 initialConversionRateWAD;
        address iUSDToNavAssetOracle;
        uint48 stalenessThresholdSeconds;
    }

    /// @notice Deployment parameters for StaticCurveYDM
    struct StaticCurveYDMParams {
        uint64 jtYieldShareAtZeroUtilWAD;
        uint64 jtYieldShareAtTargetUtilWAD;
        uint64 jtYieldShareAtFullUtilWAD;
    }

    /// @notice Deployment parameters for AdaptiveCurveYDM_V1
    struct AdaptiveCurveYDM_V1_Params {
        uint64 jtYieldShareAtTargetUtilWAD;
        uint64 jtYieldShareAtFullUtilWAD;
    }

    /// @notice Deployment parameters for AdaptiveCurveYDM_V2
    struct AdaptiveCurveYDM_V2_Params {
        uint64 jtYieldShareAtZeroUtilWAD;
        uint64 jtYieldShareAtTargetUtilWAD;
        uint64 jtYieldShareAtFullUtilWAD;
        uint64 maxAdaptationSpeedWAD;
    }

    /// @notice Complete deployment result containing all deployed contracts
    struct DeploymentResult {
        RoycoFactory factory;
        RoycoAccountant accountantImplementation;
        RoycoSeniorTranche stTrancheImplementation;
        RoycoJuniorTranche jtTrancheImplementation;
        address kernelImplementation;
        IYDM ydm;
        IRoycoVaultTranche seniorTranche;
        IRoycoVaultTranche juniorTranche;
        IRoycoAccountant accountant;
        IRoycoKernel kernel;
    }

    /// @notice Addresses for role assignments
    struct RoleAssignmentAddresses {
        address pauserAddress;
        address upgraderAddress;
        address syncRoleAddress;
        address adminKernelAddress;
        address adminAccountantAddress;
        address adminProtocolFeeSetterAddress;
        address adminOracleQuoterAddress;
        address lpRoleAdminAddress;
        address guardianAddress;
        address deployerAddress;
        address deployerAdminAddress;
        address protocolFeeRecipientAddress;
        address transferAgentAddress;
    }

    /// @notice Entry point for `forge script`. Reads DEPLOYER_PRIVATE_KEY and MARKET_NAME from env.
    function run() external virtual {
        ENABLE_LOGGING = true;

        // Read deployer private key
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Read market name from config
        string memory marketName = vm.envString("MARKET_NAME");

        console2.log("Deploying market from config:", marketName);
        deployFromConfig(marketName, deployerPrivateKey);
    }

    /// @notice Deploy a market using Solidity configuration
    /// @param marketName The name of the market to deploy (must match a config in MarketDeploymentConfig)
    /// @param deployerPrivateKey The private key of the deployer
    /// @return result The deployment result containing all deployed contract addresses
    function deployFromConfig(string memory marketName, uint256 deployerPrivateKey) public returns (DeploymentResult memory) {
        ChainConfig memory chainConfig = getChainConfig(block.chainid);
        MarketConfig memory marketConfig = getMarketConfig(marketName);

        // Build role assignments from chain config
        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = generateRolesAssignments(
            RoleAssignmentAddresses({
                pauserAddress: chainConfig.pauserAddress,
                upgraderAddress: chainConfig.upgraderAddress,
                syncRoleAddress: chainConfig.syncRoleAddress,
                adminKernelAddress: chainConfig.adminKernelAddress,
                adminAccountantAddress: chainConfig.adminAccountantAddress,
                adminProtocolFeeSetterAddress: chainConfig.adminProtocolFeeSetterAddress,
                adminOracleQuoterAddress: chainConfig.adminOracleQuoterAddress,
                lpRoleAdminAddress: chainConfig.lpRoleAdminAddress,
                guardianAddress: chainConfig.guardianAddress,
                deployerAddress: chainConfig.deployerAddress,
                deployerAdminAddress: chainConfig.deployerAdminAddress,
                protocolFeeRecipientAddress: chainConfig.protocolFeeRecipient,
                transferAgentAddress: marketConfig.transferAgentAddress
            })
        );

        // Print all deployment parameters before deployment
        if (ENABLE_LOGGING) {
            _printDeploymentParams(marketConfig, chainConfig.factoryAdmin, chainConfig.protocolFeeRecipient);
        }

        return deploy(
            marketConfig,
            chainConfig.factoryAdmin,
            chainConfig.protocolFeeRecipient,
            chainConfig.scheduledOperationsExpirySeconds,
            roleAssignments,
            deployerPrivateKey
        );
    }

    /// @notice Prints all deployment parameters for verification before deployment
    function _printDeploymentParams(MarketConfig memory _config, address _factoryAdmin, address _protocolFeeRecipient) internal view {
        console2.log("=== DEPLOYMENT PARAMETERS ===");
        console2.log("");

        // Chain & Market Info
        console2.log("--- Chain & Market Info ---");
        console2.log("Chain ID:", block.chainid);
        console2.log("Market Name:", _config.marketName);
        console2.log("");

        // Factory Config
        console2.log("--- Factory Config ---");
        console2.log("Factory Admin:", _factoryAdmin);
        console2.log("Protocol Fee Recipient:", _protocolFeeRecipient);
        console2.log("");

        // Tranche Metadata
        console2.log("--- Tranche Metadata ---");
        console2.log("Senior Tranche Name:", _config.seniorTrancheName);
        console2.log("Senior Tranche Symbol:", _config.seniorTrancheSymbol);
        console2.log("Junior Tranche Name:", _config.juniorTrancheName);
        console2.log("Junior Tranche Symbol:", _config.juniorTrancheSymbol);
        console2.log("");

        // Assets
        console2.log("--- Assets ---");
        console2.log("Senior Asset:", _config.seniorAsset);
        console2.log("Junior Asset:", _config.juniorAsset);
        console2.log("ST Dust Tolerance:", _config.stDustTolerance);
        console2.log("JT Dust Tolerance:", _config.jtDustTolerance);
        console2.log("");

        // Kernel Config
        console2.log("--- Kernel Config ---");
        console2.log("Kernel Type:", uint256(_config.kernelType));
        console2.log("");

        // Accountant Config
        console2.log("--- Accountant Config ---");
        console2.log("ST Protocol Fee (WAD):", uint256(_config.stProtocolFeeWAD));
        console2.log("JT Protocol Fee (WAD):", uint256(_config.jtProtocolFeeWAD));
        console2.log("Coverage (WAD):", uint256(_config.coverageWAD));
        console2.log("Beta (WAD):", uint256(_config.betaWAD));
        console2.log("Liquidation Utilization (WAD):", uint256(_config.liquidationUtilizationWAD));
        console2.log("Fixed Term Duration (seconds):", uint256(_config.fixedTermDurationSeconds));
        console2.log("");

        // YDM Config
        console2.log("--- YDM Config ---");
        console2.log("YDM Type:", uint256(_config.ydmType));
        console2.log("");

        console2.log("=============================");
        console2.log("");
    }

    /// @notice Deploys a complete Royco market: factory, implementations, and proxied market contracts.
    /// @param _config The market deployment configuration (assets, kernel type, accountant params, YDM params)
    /// @param _factoryAdmin The address that will admin the factory's AccessManager
    /// @param _protocolFeeRecipient The address that receives protocol fees
    /// @param _scheduledOperationsExpirySeconds The expiry time for scheduled operations in seconds
    /// @param _roleAssignments Role-to-address assignments configured on the factory
    /// @param _deployerPrivateKey The private key used to broadcast deployment transactions
    /// @return The deployment result containing all deployed contract addresses
    function deploy(
        MarketConfig memory _config,
        address _factoryAdmin,
        address _protocolFeeRecipient,
        uint32 _scheduledOperationsExpirySeconds,
        IRoycoFactory.RoleAssignmentConfiguration[] memory _roleAssignments,
        uint256 _deployerPrivateKey
    )
        public
        returns (DeploymentResult memory)
    {
        vm.startBroadcast(_deployerPrivateKey);
        address deployer = vm.addr(_deployerPrivateKey);

        // Deploy implementations using CREATE2
        IYDM ydm = _deployYDM(_config.ydmType);

        // Deploy factory with factory admin as admin and deployer as deployer
        RoycoFactory factory = _deployFactory(_factoryAdmin, deployer, _scheduledOperationsExpirySeconds, _roleAssignments);

        // Deploy all implementations. Then deploy the market using the factory
        (
            IRoycoFactory.RoycoMarket memory market,
            RoycoSeniorTranche stTrancheImpl,
            RoycoJuniorTranche jtTrancheImpl,
            address kernelImpl,
            RoycoAccountant accountantImpl
        ) = _deployMarket(factory, address(ydm), _config, _protocolFeeRecipient);

        // Build deployment result
        DeploymentResult memory result = DeploymentResult({
            factory: factory,
            accountantImplementation: accountantImpl,
            stTrancheImplementation: stTrancheImpl,
            jtTrancheImplementation: jtTrancheImpl,
            kernelImplementation: kernelImpl,
            ydm: ydm,
            seniorTranche: market.seniorTranche,
            juniorTranche: market.juniorTranche,
            accountant: market.accountant,
            kernel: market.kernel
        });

        if (ENABLE_LOGGING) {
            // Log all deployed contracts
            console2.log("=== Deployment Summary ===");
            console2.log("Factory:", address(result.factory));
            console2.log("Factory Admin:", _factoryAdmin);
            console2.log("YDM:", address(result.ydm));
            console2.log("Accountant Implementation:", address(result.accountantImplementation));
            console2.log("ST Tranche Implementation:", address(result.stTrancheImplementation));
            console2.log("JT Tranche Implementation:", address(result.jtTrancheImplementation));
            console2.log("Kernel Implementation:", result.kernelImplementation);
            console2.log("Senior Tranche (Proxy):", address(result.seniorTranche));
            console2.log("Junior Tranche (Proxy):", address(result.juniorTranche));
            console2.log("Accountant (Proxy):", address(result.accountant));
            console2.log("Kernel (Proxy):", address(result.kernel));
            console2.log("========================");
        }

        vm.stopBroadcast();

        return result;
    }

    /// @notice Builds the roles configuration for a market
    /// @param _seniorTranche The senior tranche address
    /// @param _juniorTranche The junior tranche address
    /// @param _kernel The kernel address
    /// @param _accountant The accountant address
    /// @return roles The roles configuration array
    function buildRolesTargetConfiguration(
        address _seniorTranche,
        address _juniorTranche,
        address _kernel,
        address _accountant
    )
        public
        pure
        returns (IRoycoFactory.RolesTargetConfiguration[] memory roles)
    {
        roles = new IRoycoFactory.RolesTargetConfiguration[](4);
        roles[0] = _buildTrancheRolesConfig(_seniorTranche, ST_LP_ROLE);
        roles[1] = _buildTrancheRolesConfig(_juniorTranche, JT_LP_ROLE);
        roles[2] = _buildKernelRolesConfig(_kernel);
        roles[3] = _buildAccountantRolesConfig(_accountant);
    }

    /// @notice Builds selector-to-role mappings for a tranche contract.
    /// @dev Maps deposit/redeem to the LP role, pause/unpause to ADMIN_PAUSER_ROLE,
    ///      upgradeToAndCall to ADMIN_UPGRADER_ROLE, and seize functions to TRANSFER_AGENT_ROLE.
    /// @param _tranche The address of the tranche contract
    /// @param _lpRole The role value for the LP role
    /// @return The roles configuration for the tranche contract
    function _buildTrancheRolesConfig(address _tranche, uint64 _lpRole) private pure returns (IRoycoFactory.RolesTargetConfiguration memory) {
        bytes4[] memory selectors = new bytes4[](9);
        uint64[] memory roleValues = new uint64[](9);

        selectors[0] = IRoycoVaultTranche.deposit.selector;
        roleValues[0] = _lpRole;
        selectors[1] = IRoycoVaultTranche.redeem.selector;
        roleValues[1] = _lpRole;
        selectors[2] = IRoycoAuth.pause.selector;
        roleValues[2] = ADMIN_PAUSER_ROLE;
        selectors[3] = IRoycoAuth.unpause.selector;
        roleValues[3] = ADMIN_PAUSER_ROLE;
        selectors[4] = UUPSUpgradeable.upgradeToAndCall.selector;
        roleValues[4] = ADMIN_UPGRADER_ROLE;
        selectors[5] = IRoycoVaultTranche.seizeShares.selector;
        roleValues[5] = TRANSFER_AGENT_ROLE;
        selectors[6] = IRoycoVaultTranche.seizeAndRedeemShares.selector;
        roleValues[6] = TRANSFER_AGENT_ROLE;
        selectors[7] = IRoycoVaultTranche.burn.selector;
        roleValues[7] = BURNER_ROLE;
        selectors[8] = IRoycoVaultTranche.burnFrom.selector;
        roleValues[8] = BURNER_ROLE;

        return IRoycoFactory.RolesTargetConfiguration({ target: _tranche, selectors: selectors, roles: roleValues });
    }

    /// @notice Builds selector-to-role mappings for the kernel contract.
    /// @dev Maps admin functions to ADMIN_KERNEL_ROLE, oracle quoter functions to ADMIN_ORACLE_QUOTER_ROLE,
    ///      sync to SYNC_ROLE, pause/unpause to ADMIN_PAUSER_ROLE, upgrade to ADMIN_UPGRADER_ROLE,
    ///      and blacklist functions to TRANSFER_AGENT_ROLE.
    /// @param _kernel The address of the kernel contract
    /// @return The roles configuration for the kernel contract
    function _buildKernelRolesConfig(address _kernel) private pure returns (IRoycoFactory.RolesTargetConfiguration memory) {
        bytes4[] memory selectors = new bytes4[](11);
        uint64[] memory roleValues = new uint64[](11);

        selectors[0] = IRoycoKernel.setProtocolFeeRecipient.selector;
        roleValues[0] = ADMIN_KERNEL_ROLE;
        selectors[1] = IRoycoAuth.pause.selector;
        roleValues[1] = ADMIN_PAUSER_ROLE;
        selectors[2] = IRoycoAuth.unpause.selector;
        roleValues[2] = ADMIN_PAUSER_ROLE;
        selectors[3] = IdenticalAssetsOracleQuoter.setConversionRate.selector;
        roleValues[3] = ADMIN_ORACLE_QUOTER_ROLE;
        selectors[4] = IdenticalAssetsChainlinkOracleQuoter.setChainlinkOracle.selector;
        roleValues[4] = ADMIN_ORACLE_QUOTER_ROLE;
        selectors[5] = UUPSUpgradeable.upgradeToAndCall.selector;
        roleValues[5] = ADMIN_UPGRADER_ROLE;
        selectors[6] = IRoycoKernel.syncTrancheAccounting.selector;
        roleValues[6] = SYNC_ROLE;
        selectors[7] = IRoycoKernel.setSeniorTrancheSelfLiquidationBonus.selector;
        roleValues[7] = ADMIN_KERNEL_ROLE;
        selectors[8] = IRoycoKernel.blacklistAccounts.selector;
        roleValues[8] = TRANSFER_AGENT_ROLE;
        selectors[9] = IRoycoKernel.unblacklistAccounts.selector;
        roleValues[9] = TRANSFER_AGENT_ROLE;
        selectors[10] = IRoycoKernel.setBlacklistStatus.selector;
        roleValues[10] = TRANSFER_AGENT_ROLE;

        return IRoycoFactory.RolesTargetConfiguration({ target: _kernel, selectors: selectors, roles: roleValues });
    }

    /// @notice Builds selector-to-role mappings for the accountant contract.
    /// @dev Maps setYDM/setCoverage/setBeta/setLiquidationUtilization/setFixedTermDuration/dust tolerances/coverage config
    ///      to ADMIN_ACCOUNTANT_ROLE, fee setters to ADMIN_PROTOCOL_FEE_SETTER_ROLE, and shared
    ///      pause/unpause/upgrade to their respective roles.
    /// @param _accountant The address of the accountant contract
    /// @return The roles configuration for the accountant contract
    function _buildAccountantRolesConfig(address _accountant) private pure returns (IRoycoFactory.RolesTargetConfiguration memory) {
        bytes4[] memory selectors = new bytes4[](14);
        uint64[] memory roleValues = new uint64[](14);

        selectors[0] = IRoycoAccountant.setYDM.selector;
        roleValues[0] = ADMIN_ACCOUNTANT_ROLE;
        selectors[1] = IRoycoAccountant.setSeniorTrancheProtocolFee.selector;
        roleValues[1] = ADMIN_PROTOCOL_FEE_SETTER_ROLE;
        selectors[2] = IRoycoAccountant.setJuniorTrancheProtocolFee.selector;
        roleValues[2] = ADMIN_PROTOCOL_FEE_SETTER_ROLE;
        selectors[3] = IRoycoAccountant.setCoverage.selector;
        roleValues[3] = ADMIN_ACCOUNTANT_ROLE;
        selectors[4] = IRoycoAccountant.setBeta.selector;
        roleValues[4] = ADMIN_ACCOUNTANT_ROLE;
        selectors[5] = IRoycoAccountant.setLiquidationUtilization.selector;
        roleValues[5] = ADMIN_ACCOUNTANT_ROLE;
        selectors[6] = IRoycoAccountant.setFixedTermDuration.selector;
        roleValues[6] = ADMIN_ACCOUNTANT_ROLE;
        selectors[7] = IRoycoAuth.pause.selector;
        roleValues[7] = ADMIN_PAUSER_ROLE;
        selectors[8] = IRoycoAuth.unpause.selector;
        roleValues[8] = ADMIN_PAUSER_ROLE;
        selectors[9] = UUPSUpgradeable.upgradeToAndCall.selector;
        roleValues[9] = ADMIN_UPGRADER_ROLE;
        selectors[10] = IRoycoAccountant.setSeniorTrancheDustTolerance.selector;
        roleValues[10] = ADMIN_ACCOUNTANT_ROLE;
        selectors[11] = IRoycoAccountant.setYieldShareProtocolFee.selector;
        roleValues[11] = ADMIN_PROTOCOL_FEE_SETTER_ROLE;
        selectors[12] = IRoycoAccountant.setCoverageConfiguration.selector;
        roleValues[12] = ADMIN_ACCOUNTANT_ROLE;
        selectors[13] = IRoycoAccountant.setJuniorTrancheDustTolerance.selector;
        roleValues[13] = ADMIN_ACCOUNTANT_ROLE;

        return IRoycoFactory.RolesTargetConfiguration({ target: _accountant, selectors: selectors, roles: roleValues });
    }

    /// @notice Generates role assignments from addresses
    /// @dev ST_LP_ROLE and JT_LP_ROLE are included with assignee=address(0) so their admin roles get configured
    /// @param _addresses The addresses for role assignments
    /// @return roleAssignments The role assignments for the factory
    function generateRolesAssignments(RoleAssignmentAddresses memory _addresses)
        public
        pure
        returns (IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments)
    {
        roleAssignments = new IRoycoFactory.RoleAssignmentConfiguration[](14);

        // Get role configs from RolesConfiguration
        RoleConfig memory pauserConfig = getRoleConfig(ADMIN_PAUSER_ROLE);
        RoleConfig memory upgraderConfig = getRoleConfig(ADMIN_UPGRADER_ROLE);
        RoleConfig memory syncConfig = getRoleConfig(SYNC_ROLE);
        RoleConfig memory kernelConfig = getRoleConfig(ADMIN_KERNEL_ROLE);
        RoleConfig memory accountantConfig = getRoleConfig(ADMIN_ACCOUNTANT_ROLE);
        RoleConfig memory feeSetterConfig = getRoleConfig(ADMIN_PROTOCOL_FEE_SETTER_ROLE);
        RoleConfig memory oracleQuoterConfig = getRoleConfig(ADMIN_ORACLE_QUOTER_ROLE);
        RoleConfig memory lpRoleAdminConfig = getRoleConfig(LP_ROLE_ADMIN_ROLE);
        RoleConfig memory stLpRoleConfig = getRoleConfig(ST_LP_ROLE);
        RoleConfig memory jtLpRoleConfig = getRoleConfig(JT_LP_ROLE);
        RoleConfig memory roleGuardianConfig = getRoleConfig(GUARDIAN_ROLE);
        RoleConfig memory deployerConfig = getRoleConfig(DEPLOYER_ROLE);
        RoleConfig memory deployerAdminConfig = getRoleConfig(DEPLOYER_ROLE_ADMIN_ROLE);
        RoleConfig memory transferAgentConfig = getRoleConfig(TRANSFER_AGENT_ROLE);

        roleAssignments[0] = IRoycoFactory.RoleAssignmentConfiguration({
            role: ADMIN_PAUSER_ROLE, roleAdminRole: pauserConfig.adminRole, assignee: _addresses.pauserAddress, executionDelay: pauserConfig.executionDelay
        });

        roleAssignments[1] = IRoycoFactory.RoleAssignmentConfiguration({
            role: ADMIN_UPGRADER_ROLE,
            roleAdminRole: upgraderConfig.adminRole,
            assignee: _addresses.upgraderAddress,
            executionDelay: upgraderConfig.executionDelay
        });

        roleAssignments[2] = IRoycoFactory.RoleAssignmentConfiguration({
            role: SYNC_ROLE, roleAdminRole: syncConfig.adminRole, assignee: _addresses.syncRoleAddress, executionDelay: syncConfig.executionDelay
        });

        roleAssignments[3] = IRoycoFactory.RoleAssignmentConfiguration({
            role: ADMIN_KERNEL_ROLE, roleAdminRole: kernelConfig.adminRole, assignee: _addresses.adminKernelAddress, executionDelay: kernelConfig.executionDelay
        });

        roleAssignments[4] = IRoycoFactory.RoleAssignmentConfiguration({
            role: ADMIN_ACCOUNTANT_ROLE,
            roleAdminRole: accountantConfig.adminRole,
            assignee: _addresses.adminAccountantAddress,
            executionDelay: accountantConfig.executionDelay
        });

        roleAssignments[5] = IRoycoFactory.RoleAssignmentConfiguration({
            role: ADMIN_PROTOCOL_FEE_SETTER_ROLE,
            roleAdminRole: feeSetterConfig.adminRole,
            assignee: _addresses.adminProtocolFeeSetterAddress,
            executionDelay: feeSetterConfig.executionDelay
        });

        roleAssignments[6] = IRoycoFactory.RoleAssignmentConfiguration({
            role: ADMIN_ORACLE_QUOTER_ROLE,
            roleAdminRole: oracleQuoterConfig.adminRole,
            assignee: _addresses.adminOracleQuoterAddress,
            executionDelay: oracleQuoterConfig.executionDelay
        });

        roleAssignments[7] = IRoycoFactory.RoleAssignmentConfiguration({
            role: LP_ROLE_ADMIN_ROLE,
            roleAdminRole: lpRoleAdminConfig.adminRole,
            assignee: _addresses.lpRoleAdminAddress,
            executionDelay: lpRoleAdminConfig.executionDelay
        });

        // Grant the protocol fee recipient the ST_LP_ROLE
        roleAssignments[8] = IRoycoFactory.RoleAssignmentConfiguration({
            role: ST_LP_ROLE,
            roleAdminRole: stLpRoleConfig.adminRole,
            assignee: _addresses.protocolFeeRecipientAddress,
            executionDelay: stLpRoleConfig.executionDelay
        });

        // Grant the protocol fee recipient the JT_LP_ROLE
        roleAssignments[9] = IRoycoFactory.RoleAssignmentConfiguration({
            role: JT_LP_ROLE,
            roleAdminRole: jtLpRoleConfig.adminRole,
            assignee: _addresses.protocolFeeRecipientAddress,
            executionDelay: jtLpRoleConfig.executionDelay
        });

        roleAssignments[10] = IRoycoFactory.RoleAssignmentConfiguration({
            role: GUARDIAN_ROLE,
            roleAdminRole: roleGuardianConfig.adminRole,
            assignee: _addresses.guardianAddress,
            executionDelay: roleGuardianConfig.executionDelay
        });

        roleAssignments[11] = IRoycoFactory.RoleAssignmentConfiguration({
            role: DEPLOYER_ROLE, roleAdminRole: deployerConfig.adminRole, assignee: _addresses.deployerAddress, executionDelay: deployerConfig.executionDelay
        });

        roleAssignments[12] = IRoycoFactory.RoleAssignmentConfiguration({
            role: DEPLOYER_ROLE_ADMIN_ROLE,
            roleAdminRole: deployerAdminConfig.adminRole,
            assignee: _addresses.deployerAdminAddress,
            executionDelay: deployerAdminConfig.executionDelay
        });

        roleAssignments[13] = IRoycoFactory.RoleAssignmentConfiguration({
            role: TRANSFER_AGENT_ROLE,
            roleAdminRole: transferAgentConfig.adminRole,
            assignee: _addresses.transferAgentAddress,
            executionDelay: transferAgentConfig.executionDelay
        });
    }

    /// @notice Deploys all implementation contracts and calls `factory.deployMarket()` to create proxied market.
    /// @dev Precomputes deterministic proxy addresses via CREATE3 salts so implementations can reference
    ///      each other at construction time (e.g. tranches reference the kernel, accountant references the kernel).
    /// @param factory The deployed factory (acts as deployer and AccessManager)
    /// @param ydmAddress The address of the deployed YDM singleton
    /// @param _config The market deployment configuration
    /// @param _protocolFeeRecipient The protocol fee recipient address
    /// @return deployedContracts The deployed market proxy contracts (ST, JT, kernel, accountant)
    /// @return stImpl The deployed senior tranche implementation address
    /// @return jtImpl The deployed junior tranche implementation address
    /// @return kernelImpl The deployed kernel implementation address
    /// @return accountantImpl The deployed accountant implementation address
    function _deployMarket(
        RoycoFactory factory,
        address ydmAddress,
        MarketConfig memory _config,
        address _protocolFeeRecipient
    )
        internal
        returns (
            IRoycoFactory.RoycoMarket memory deployedContracts,
            RoycoSeniorTranche stImpl,
            RoycoJuniorTranche jtImpl,
            address kernelImpl,
            RoycoAccountant accountantImpl
        )
    {
        // Precompute expected proxy addresses using salt derived from market ID
        bytes32 salt = keccak256(abi.encodePacked(MARKET_DEPLOYMENT_SALT, _config.seniorTrancheName, _config.juniorTrancheName, block.timestamp));

        // Predict the deterministic addresses of the contracts
        // The salt is unique for each contract type to prevent CREATE3 collisions
        bytes32 seniorTrancheSalt = keccak256(abi.encodePacked(salt, "-ST"));
        bytes32 juniorTrancheSalt = keccak256(abi.encodePacked(salt, "-JT"));
        bytes32 accountantSalt = keccak256(abi.encodePacked(salt, "-ACCOUNTANT"));
        bytes32 kernelSalt = keccak256(abi.encodePacked(salt, "-KERNEL"));
        address expectedSeniorTrancheAddress = factory.predictDeterministicAddress(seniorTrancheSalt);
        address expectedJuniorTrancheAddress = factory.predictDeterministicAddress(juniorTrancheSalt);
        address expectedAccountantAddress = factory.predictDeterministicAddress(accountantSalt);
        address expectedKernelAddress = factory.predictDeterministicAddress(kernelSalt);

        // Deploy the senior tranche implementation
        stImpl = _deploySTTrancheImpl(_config.seniorAsset, expectedKernelAddress);

        // Deploy the junior tranche implementation
        jtImpl = _deployJTTrancheImpl(_config.juniorAsset, expectedKernelAddress);

        // Deploy the accountant implementation
        accountantImpl = _deployAccountantImpl(expectedKernelAddress);

        // Deploy the kernel implementation based on kernel type
        kernelImpl = _deployKernelImpl(
            _config.kernelType,
            _config.kernelSpecificParams,
            expectedSeniorTrancheAddress,
            expectedJuniorTrancheAddress,
            _config.seniorAsset,
            _config.juniorAsset,
            _config.enforceVaultSharesTransferWhitelist,
            expectedAccountantAddress
        );

        if (ENABLE_LOGGING) {
            console2.log("Expected Senior Tranche Address:", expectedSeniorTrancheAddress);
            console2.log("Expected Junior Tranche Address:", expectedJuniorTrancheAddress);
            console2.log("Expected Kernel Address:", expectedKernelAddress);
            console2.log("Expected Accountant Address:", expectedAccountantAddress);
        }

        // Build initialization data
        address factoryAddress = address(factory);
        bytes memory kernelInitializationData = _buildKernelInitializationData(
            _config.kernelType, _config.kernelSpecificParams, factoryAddress, _protocolFeeRecipient, _config.stSelfLiquidationBonusWAD
        );
        bytes memory accountantInitializationData = _buildAccountantInitializationData(ydmAddress, factoryAddress, _config);
        bytes memory seniorTrancheInitializationData = _buildSeniorTrancheInitializationData(factoryAddress, _config);
        bytes memory juniorTrancheInitializationData = _buildJuniorTrancheInitializationData(factoryAddress, _config);

        // Build roles configuration
        IRoycoFactory.RolesTargetConfiguration[] memory roles =
            buildRolesTargetConfiguration(expectedSeniorTrancheAddress, expectedJuniorTrancheAddress, expectedKernelAddress, expectedAccountantAddress);

        // Build market deployment params
        IRoycoFactory.MarketDeploymentParams memory marketParams = IRoycoFactory.MarketDeploymentParams({
            seniorTrancheName: _config.seniorTrancheName,
            seniorTrancheSymbol: _config.seniorTrancheSymbol,
            juniorTrancheName: _config.juniorTrancheName,
            juniorTrancheSymbol: _config.juniorTrancheSymbol,
            seniorTrancheImplementation: IRoycoVaultTranche(address(stImpl)),
            juniorTrancheImplementation: IRoycoVaultTranche(address(jtImpl)),
            kernelImplementation: IRoycoKernel(address(kernelImpl)),
            accountantImplementation: IRoycoAccountant(address(accountantImpl)),
            seniorTrancheInitializationData: seniorTrancheInitializationData,
            juniorTrancheInitializationData: juniorTrancheInitializationData,
            kernelInitializationData: kernelInitializationData,
            accountantInitializationData: accountantInitializationData,
            seniorTrancheProxyDeploymentSalt: seniorTrancheSalt,
            juniorTrancheProxyDeploymentSalt: juniorTrancheSalt,
            kernelProxyDeploymentSalt: kernelSalt,
            accountantProxyDeploymentSalt: accountantSalt,
            roles: roles
        });

        // Deploy market
        if (ENABLE_LOGGING) {
            console2.log("Deploying market...");
        }
        deployedContracts = factory.deployMarket(marketParams);

        if (ENABLE_LOGGING) {
            console2.log("Market deployed successfully!");
            console2.log("Senior Tranche:", address(deployedContracts.seniorTranche));
            console2.log("Junior Tranche:", address(deployedContracts.juniorTranche));
            console2.log("Kernel:", address(deployedContracts.kernel));
            console2.log("Accountant:", address(deployedContracts.accountant));
        }
    }

    /// @notice Deploys the accountant implementation via CREATE2.
    /// @param _kernel The (precomputed) kernel proxy address baked into the implementation as an immutable
    /// @return The deployed accountant implementation
    function _deployAccountantImpl(address _kernel) internal returns (RoycoAccountant) {
        bytes memory creationCode = abi.encodePacked(type(RoycoAccountant).creationCode, abi.encode(_kernel));

        (address addr, bool alreadyDeployed) = deployWithSanityChecks(ACCOUNTANT_IMPL_SALT, creationCode, false);
        if (ENABLE_LOGGING) {
            if (alreadyDeployed) {
                console2.log("Accountant implementation already deployed at:", addr);
            } else {
                console2.log("Accountant implementation deployed at:", addr);
            }
        }
        return RoycoAccountant(addr);
    }

    /// @notice Deploys the senior tranche implementation via CREATE2.
    /// @param _asset The senior tranche's underlying asset (ERC20)
    /// @param _kernel The (precomputed) kernel proxy address baked into the implementation as an immutable
    /// @return The deployed senior tranche implementation
    function _deploySTTrancheImpl(address _asset, address _kernel) internal returns (RoycoSeniorTranche) {
        bytes memory creationCode = abi.encodePacked(type(RoycoSeniorTranche).creationCode, abi.encode(_asset, _kernel));

        (address addr, bool alreadyDeployed) = deployWithSanityChecks(ST_TRANCHE_IMPL_SALT, creationCode, false);
        if (ENABLE_LOGGING) {
            if (alreadyDeployed) {
                console2.log("ST tranche implementation already deployed at:", addr);
            } else {
                console2.log("ST tranche implementation deployed at:", addr);
            }
        }
        return RoycoSeniorTranche(addr);
    }

    /// @notice Deploys the junior tranche implementation via CREATE2.
    /// @param _asset The junior tranche's underlying asset (ERC20)
    /// @param _kernel The (precomputed) kernel proxy address baked into the implementation as an immutable
    /// @return The deployed junior tranche implementation
    function _deployJTTrancheImpl(address _asset, address _kernel) internal returns (RoycoJuniorTranche) {
        bytes memory creationCode = abi.encodePacked(type(RoycoJuniorTranche).creationCode, abi.encode(_asset, _kernel));

        (address addr, bool alreadyDeployed) = deployWithSanityChecks(JT_TRANCHE_IMPL_SALT, creationCode, false);
        if (ENABLE_LOGGING) {
            if (alreadyDeployed) {
                console2.log("JT tranche implementation already deployed at:", addr);
            } else {
                console2.log("JT tranche implementation deployed at:", addr);
            }
        }
        return RoycoJuniorTranche(addr);
    }

    /// @notice Deploys YDM implementation based on YDM type
    /// @param _ydmType The YDM type to deploy
    /// @return ydm The deployed YDM contract
    function _deployYDM(YDMType _ydmType) internal returns (IYDM) {
        bytes memory creationCode;
        bytes32 salt;

        if (_ydmType == YDMType.StaticCurve) {
            creationCode = type(StaticCurveYDM).creationCode;
            salt = keccak256(abi.encodePacked(YDM_SALT, "STATIC_CURVE"));
        } else if (_ydmType == YDMType.AdaptiveCurve_V1) {
            creationCode = type(AdaptiveCurveYDM_V1).creationCode;
            salt = keccak256(abi.encodePacked(YDM_SALT, "ADAPTIVE_CURVE_V1"));
        } else if (_ydmType == YDMType.AdaptiveCurve_V2) {
            creationCode = type(AdaptiveCurveYDM_V2).creationCode;
            salt = keccak256(abi.encodePacked(YDM_SALT, "ADAPTIVE_CURVE_V2"));
        } else {
            revert UnsupportedYDMType(_ydmType);
        }

        (address addr, bool alreadyDeployed) = deployWithSanityChecks(salt, creationCode, false);
        if (ENABLE_LOGGING) {
            if (alreadyDeployed) {
                console2.log("YDM already deployed at:", addr);
            } else {
                console2.log("YDM deployed at:", addr);
            }
        }
        return IYDM(addr);
    }

    /// @notice Deploys the factory implementation and its UUPS proxy via CREATE2.
    /// @param _factoryAdmin The address that receives the admin role on the factory's AccessManager
    /// @param _deployer The address that receives the DEPLOYER_ROLE for market deployments
    /// @param _scheduledOperationsExpirySeconds The expiry time for scheduled operations in seconds
    /// @param _roleAssignments Initial role assignments configured during factory initialization
    function _deployFactory(
        address _factoryAdmin,
        address _deployer,
        uint32 _scheduledOperationsExpirySeconds,
        IRoycoFactory.RoleAssignmentConfiguration[] memory _roleAssignments
    )
        internal
        returns (RoycoFactory)
    {
        // Deploy the factory implementation
        (address factoryImplAddr, bool alreadyDeployed) = deployWithSanityChecks(FACTORY_SALT_BASE, type(RoycoFactory).creationCode, false);
        if (ENABLE_LOGGING) {
            if (alreadyDeployed) {
                console2.log("Factory Implementation already deployed at:", factoryImplAddr);
            } else {
                console2.log("Factory Implementation deployed at:", factoryImplAddr);
            }
        }

        // Deploy the factory proxy
        address factoryProxyAddress;
        (factoryProxyAddress, alreadyDeployed) = deployWithSanityChecks(
            FACTORY_SALT_BASE,
            getERC1967ProxyCreationCode(
                factoryImplAddr, abi.encodeCall(RoycoFactory.initialize, (_factoryAdmin, _deployer, _scheduledOperationsExpirySeconds, _roleAssignments))
            ),
            false
        );
        if (ENABLE_LOGGING) {
            if (alreadyDeployed) {
                console2.log("Factory proxy already deployed at:", factoryProxyAddress);
            } else {
                console2.log("Factory proxy deployed at:", factoryProxyAddress);
            }
        }

        return RoycoFactory(factoryProxyAddress);
    }

    /// @notice Deploys the kernel implementation via CREATE2. Generates creation code based on kernel type,
    ///         then deploys using the shared KERNEL_IMPL_SALT.
    /// @param _kernelType The kernel type to deploy
    /// @param _kernelSpecificParams ABI-encoded kernel-specific constructor parameters
    /// @param _expectedSeniorTrancheAddress Precomputed senior tranche proxy address
    /// @param _expectedJuniorTrancheAddress Precomputed junior tranche proxy address
    /// @param _seniorAsset The senior tranche's underlying asset
    /// @param _juniorAsset The junior tranche's underlying asset
    /// @param _expectedAccountantAddress Precomputed accountant proxy address
    /// @param _enforceVaultSharesTransferWhitelist Whether to enforce the vault shares transfer whitelist
    /// @return The deployed kernel implementation address
    /// @dev Precomputes deterministic proxy addresses via CREATE3 salts so implementations can reference
    ///      each other at construction time (e.g. tranches reference the kernel, accountant references the kernel).
    function _deployKernelImpl(
        KernelType _kernelType,
        bytes memory _kernelSpecificParams,
        address _expectedSeniorTrancheAddress,
        address _expectedJuniorTrancheAddress,
        address _seniorAsset,
        address _juniorAsset,
        bool _enforceVaultSharesTransferWhitelist,
        address _expectedAccountantAddress
    )
        internal
        returns (address)
    {
        IRoycoKernel.RoycoKernelConstructionParams memory cp = IRoycoKernel.RoycoKernelConstructionParams({
            seniorTranche: _expectedSeniorTrancheAddress,
            stAsset: _seniorAsset,
            juniorTranche: _expectedJuniorTrancheAddress,
            jtAsset: _juniorAsset,
            accountant: _expectedAccountantAddress,
            enforceVaultSharesTransferWhitelist: _enforceVaultSharesTransferWhitelist
        });

        bytes memory creationCode = _buildKernelCreationCode(_kernelType, _kernelSpecificParams, cp);

        (address addr, bool alreadyDeployed) = deployWithSanityChecks(KERNEL_IMPL_SALT, creationCode, false);
        if (ENABLE_LOGGING) {
            if (alreadyDeployed) {
                console2.log("Kernel implementation already deployed at:", addr);
            } else {
                console2.log("Kernel implementation deployed at:", addr);
            }
        }
        return addr;
    }

    /// @notice Builds the full creation code (bytecode + constructor args) for the given kernel type.
    /// @param _kernelType The kernel type to build creation code for
    /// @param _kernelSpecificParams ABI-encoded kernel-specific constructor parameters
    /// @param _cp The construction parameters for the kernel
    /// @return The creation code for the kernel implementation
    function _buildKernelCreationCode(
        KernelType _kernelType,
        bytes memory _kernelSpecificParams,
        IRoycoKernel.RoycoKernelConstructionParams memory _cp
    )
        private
        pure
        returns (bytes memory)
    {
        if (_kernelType == KernelType.ReUSD_ST_ReUSD_JT) {
            ReUSDSTReUSDJTKernelParams memory kp = abi.decode(_kernelSpecificParams, (ReUSDSTReUSDJTKernelParams));
            return abi.encodePacked(type(ReUSD_ST_JT_ICLOracle_Kernel).creationCode, abi.encode(_cp, kp.reusd, kp.reusdUsdQuoteToken, kp.insuranceCapitalLayer));
        } else if (_kernelType == KernelType.Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel) {
            return abi.encodePacked(type(Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel).creationCode, abi.encode(_cp));
        } else if (_kernelType == KernelType.Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel) {
            return abi.encodePacked(type(Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel).creationCode, abi.encode(_cp));
        } else if (_kernelType == KernelType.Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel) {
            return abi.encodePacked(type(Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel).creationCode, abi.encode(_cp));
        } else if (_kernelType == KernelType.IdleCdoAA_ST_IdleCdoAA_JT) {
            IdleAACdoSTCdoJTKernelParams memory kp = abi.decode(_kernelSpecificParams, (IdleAACdoSTCdoJTKernelParams));
            return abi.encodePacked(type(Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_Kernel).creationCode, abi.encode(_cp, kp.idleCDO));
        } else if (_kernelType == KernelType.Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel) {
            return abi.encodePacked(type(Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel).creationCode, abi.encode(_cp));
        } else if (_kernelType == KernelType.Identical_Makina_ST_JT_MachineToAdminOracle_Kernel) {
            IdenticalMakinaSTMakinaJTKernelParams memory kp = abi.decode(_kernelSpecificParams, (IdenticalMakinaSTMakinaJTKernelParams));
            return abi.encodePacked(type(Identical_Makina_ST_JT_MachineToAdminOracle_Kernel).creationCode, abi.encode(_cp, kp.makinaMachine));
        } else if (_kernelType == KernelType.sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel) {
            return abi.encodePacked(type(sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel).creationCode, abi.encode(_cp));
        } else if (_kernelType == KernelType.MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel) {
            return abi.encodePacked(type(MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel).creationCode, abi.encode(_cp));
        } else if (_kernelType == KernelType.apyUSD_ST_JT_SharePriceToChainlinkOracle_Kernel) {
            return abi.encodePacked(type(apyUSD_ST_JT_SharePriceToChainlinkOracle_Kernel).creationCode, abi.encode(_cp));
        } else if (_kernelType == KernelType.Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle_Kernel) {
            LockedIUSDKernelParams memory kp = abi.decode(_kernelSpecificParams, (LockedIUSDKernelParams));
            return abi.encodePacked(type(Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle).creationCode, abi.encode(_cp, kp.infiniFiGateway, kp.unwindingEpochs));
        } else if (_kernelType == KernelType.sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel) {
            return abi.encodePacked(type(sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel).creationCode, abi.encode(_cp));
        } else {
            revert UnsupportedKernelType(_kernelType);
        }
    }

    /// @notice Builds ABI-encoded initialization calldata for the kernel proxy.
    /// @dev Each kernel type has its own `initialize()` signature. This function routes to the correct one
    ///      and encodes the calldata that the factory will use when initializing the kernel proxy.
    /// @param _kernelType The kernel type to build initialization data for
    /// @param _kernelSpecificParams ABI-encoded kernel-specific constructor parameters
    /// @param _factoryAddress The address of the factory
    /// @param _protocolFeeRecipient The address that receives protocol fees
    /// @param _stSelfLiquidationBonusWAD The self-liquidation bonus for the senior tranche
    /// @return The initialization data for the kernel proxy
    function _buildKernelInitializationData(
        KernelType _kernelType,
        bytes memory _kernelSpecificParams,
        address _factoryAddress,
        address _protocolFeeRecipient,
        uint64 _stSelfLiquidationBonusWAD
    )
        internal
        pure
        returns (bytes memory)
    {
        IRoycoKernel.RoycoKernelInitParams memory kernelParams = IRoycoKernel.RoycoKernelInitParams({
            initialAuthority: _factoryAddress, protocolFeeRecipient: _protocolFeeRecipient, stSelfLiquidationBonusWAD: _stSelfLiquidationBonusWAD
        });

        if (_kernelType == KernelType.ReUSD_ST_ReUSD_JT) {
            return abi.encodeCall(ReUSD_ST_JT_ICLOracle_Kernel.initialize, (kernelParams));
        } else if (_kernelType == KernelType.Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel) {
            IdenticalAssetsChainlinkToAdminOracleQuoterKernelParams memory kernelParams2 =
                abi.decode(_kernelSpecificParams, (IdenticalAssetsChainlinkToAdminOracleQuoterKernelParams));
            return abi.encodeCall(
                Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel.initialize,
                (
                    kernelParams,
                    kernelParams2.initialConversionRateWAD,
                    kernelParams2.trancheAssetToReferenceAssetOracle,
                    kernelParams2.stalenessThresholdSeconds
                )
            );
        } else if (_kernelType == KernelType.Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel) {
            IdenticalERC4626SharesToAdminOracleQuoterKernelParams memory kernelParams2 =
                abi.decode(_kernelSpecificParams, (IdenticalERC4626SharesToAdminOracleQuoterKernelParams));
            return abi.encodeCall(Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel.initialize, (kernelParams, kernelParams2.initialConversionRateWAD));
        } else if (_kernelType == KernelType.Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel) {
            IdenticalERC4626SharesToChainlinkOracleQuoterKernelParams memory kernelParams2 =
                abi.decode(_kernelSpecificParams, (IdenticalERC4626SharesToChainlinkOracleQuoterKernelParams));
            return abi.encodeCall(
                Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.initialize,
                (kernelParams, kernelParams2.initialConversionRateWAD, kernelParams2.baseAssetToNavAssetOracle, kernelParams2.stalenessThresholdSeconds)
            );
        } else if (_kernelType == KernelType.IdleCdoAA_ST_IdleCdoAA_JT) {
            return abi.encodeCall(Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_Kernel.initialize, (kernelParams));
        } else if (_kernelType == KernelType.Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel) {
            IdenticalAssetsChainlinkToAdminOracleQuoterKernelParams memory kernelParams2 =
                abi.decode(_kernelSpecificParams, (IdenticalAssetsChainlinkToAdminOracleQuoterKernelParams));
            return abi.encodeCall(
                Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel.initialize,
                (
                    kernelParams,
                    kernelParams2.initialConversionRateWAD,
                    kernelParams2.trancheAssetToReferenceAssetOracle,
                    kernelParams2.stalenessThresholdSeconds
                )
            );
        } else if (_kernelType == KernelType.Identical_Makina_ST_JT_MachineToAdminOracle_Kernel) {
            IdenticalMakinaSTMakinaJTKernelParams memory kernelParams2 = abi.decode(_kernelSpecificParams, (IdenticalMakinaSTMakinaJTKernelParams));
            return abi.encodeCall(Identical_Makina_ST_JT_MachineToAdminOracle_Kernel.initialize, (kernelParams, kernelParams2.initialConversionRateWAD));
        } else if (_kernelType == KernelType.sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel) {
            IdenticalAssetsAdminOracleQuoterKernelParams memory kernelParams2 =
                abi.decode(_kernelSpecificParams, (IdenticalAssetsAdminOracleQuoterKernelParams));
            return abi.encodeCall(sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel.initialize, (kernelParams, kernelParams2.initialConversionRateWAD));
        } else if (_kernelType == KernelType.MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel) {
            IdenticalERC4626SharesToChainlinkOracleQuoterKernelParams memory kernelParams2 =
                abi.decode(_kernelSpecificParams, (IdenticalERC4626SharesToChainlinkOracleQuoterKernelParams));
            return abi.encodeCall(
                Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.initialize,
                (kernelParams, kernelParams2.initialConversionRateWAD, kernelParams2.baseAssetToNavAssetOracle, kernelParams2.stalenessThresholdSeconds)
            );
        } else if (_kernelType == KernelType.apyUSD_ST_JT_SharePriceToChainlinkOracle_Kernel) {
            IdenticalERC4626SharesToChainlinkOracleQuoterKernelParams memory kernelParams2 =
                abi.decode(_kernelSpecificParams, (IdenticalERC4626SharesToChainlinkOracleQuoterKernelParams));
            // apyUSD kernel inherits initialize from Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel
            return abi.encodeCall(
                Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.initialize,
                (kernelParams, kernelParams2.initialConversionRateWAD, kernelParams2.baseAssetToNavAssetOracle, kernelParams2.stalenessThresholdSeconds)
            );
        } else if (_kernelType == KernelType.Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle_Kernel) {
            LockedIUSDKernelParams memory kernelParams2 = abi.decode(_kernelSpecificParams, (LockedIUSDKernelParams));
            return abi.encodeCall(
                Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle.initialize,
                (kernelParams, kernelParams2.initialConversionRateWAD, kernelParams2.iUSDToNavAssetOracle, kernelParams2.stalenessThresholdSeconds)
            );
        } else if (_kernelType == KernelType.sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel) {
            IdenticalERC4626SharesToChainlinkOracleQuoterKernelParams memory kernelParams2 =
                abi.decode(_kernelSpecificParams, (IdenticalERC4626SharesToChainlinkOracleQuoterKernelParams));
            return abi.encodeCall(
                Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.initialize,
                (kernelParams, kernelParams2.initialConversionRateWAD, kernelParams2.baseAssetToNavAssetOracle, kernelParams2.stalenessThresholdSeconds)
            );
        } else {
            revert UnsupportedKernelType(_kernelType);
        }
    }

    /// @notice Builds YDM initialization data based on YDM type
    /// @param _ydmType The YDM type
    /// @param _ydmSpecificParams Encoded YDM-specific parameters
    /// @return ydmInitializationData The encoded YDM initialization data
    /// @dev Routes to the correct YDM implementation initializer based on YDM type
    function _buildYDMInitializationData(YDMType _ydmType, bytes memory _ydmSpecificParams) internal pure returns (bytes memory ydmInitializationData) {
        if (_ydmType == YDMType.StaticCurve) {
            StaticCurveYDMParams memory ydmParams = abi.decode(_ydmSpecificParams, (StaticCurveYDMParams));
            ydmInitializationData = abi.encodeCall(
                StaticCurveYDM.initializeYDMForMarket,
                (ydmParams.jtYieldShareAtZeroUtilWAD, ydmParams.jtYieldShareAtTargetUtilWAD, ydmParams.jtYieldShareAtFullUtilWAD)
            );
        } else if (_ydmType == YDMType.AdaptiveCurve_V1) {
            AdaptiveCurveYDM_V1_Params memory ydmParams = abi.decode(_ydmSpecificParams, (AdaptiveCurveYDM_V1_Params));
            ydmInitializationData =
                abi.encodeCall(AdaptiveCurveYDM_V1.initializeYDMForMarket, (ydmParams.jtYieldShareAtTargetUtilWAD, ydmParams.jtYieldShareAtFullUtilWAD));
        } else if (_ydmType == YDMType.AdaptiveCurve_V2) {
            AdaptiveCurveYDM_V2_Params memory ydmParams = abi.decode(_ydmSpecificParams, (AdaptiveCurveYDM_V2_Params));
            ydmInitializationData = abi.encodeCall(
                AdaptiveCurveYDM_V2.initializeYDMForMarket,
                (
                    ydmParams.jtYieldShareAtZeroUtilWAD,
                    ydmParams.jtYieldShareAtTargetUtilWAD,
                    ydmParams.jtYieldShareAtFullUtilWAD,
                    ydmParams.maxAdaptationSpeedWAD
                )
            );
        } else {
            revert UnsupportedYDMType(_ydmType);
        }
    }

    /// @notice Builds ABI-encoded initialization calldata for the accountant proxy.
    /// @dev Constructs `RoycoAccountantInitParams` from the market config and encodes `RoycoAccountant.initialize()`.
    /// @param _ydmAddress The address of the deployed YDM singleton
    /// @param _factoryAddress The address of the factory
    /// @param _config The market deployment configuration
    /// @return The initialization data for the accountant proxy
    function _buildAccountantInitializationData(address _ydmAddress, address _factoryAddress, MarketConfig memory _config)
        internal
        pure
        returns (bytes memory)
    {
        IRoycoAccountant.RoycoAccountantInitParams memory accountantParams = IRoycoAccountant.RoycoAccountantInitParams({
            stProtocolFeeWAD: _config.stProtocolFeeWAD,
            jtProtocolFeeWAD: _config.jtProtocolFeeWAD,
            yieldShareProtocolFeeWAD: _config.jtYieldShareProtocolFeeWAD,
            coverageWAD: _config.coverageWAD,
            betaWAD: _config.betaWAD,
            ydm: _ydmAddress,
            ydmInitializationData: _buildYDMInitializationData(_config.ydmType, _config.ydmSpecificParams),
            fixedTermDurationSeconds: _config.fixedTermDurationSeconds,
            liquidationUtilizationWAD: _config.liquidationUtilizationWAD,
            stNAVDustTolerance: toNAVUnits(_config.stDustTolerance),
            jtNAVDustTolerance: toNAVUnits(_config.jtDustTolerance)
        });

        return abi.encodeCall(RoycoAccountant.initialize, (accountantParams, _factoryAddress));
    }

    /// @notice Builds ABI-encoded initialization calldata for the senior tranche proxy.
    /// @param _factoryAddress The address of the factory
    /// @param _config The market deployment configuration
    /// @return The initialization data for the senior tranche proxy
    function _buildSeniorTrancheInitializationData(address _factoryAddress, MarketConfig memory _config) internal pure returns (bytes memory) {
        IRoycoVaultTranche.RoycoTrancheInitParams memory trancheParams = IRoycoVaultTranche.RoycoTrancheInitParams({
            name: _config.seniorTrancheName, symbol: _config.seniorTrancheSymbol, initialAuthority: _factoryAddress
        });

        return abi.encodeCall(RoycoSeniorTranche.initialize, (trancheParams));
    }

    /// @notice Builds ABI-encoded initialization calldata for the junior tranche proxy.
    /// @param _factoryAddress The address of the factory
    /// @param _config The market deployment configuration
    /// @return The initialization data for the junior tranche proxy
    function _buildJuniorTrancheInitializationData(address _factoryAddress, MarketConfig memory _config) internal pure returns (bytes memory) {
        IRoycoVaultTranche.RoycoTrancheInitParams memory trancheParams = IRoycoVaultTranche.RoycoTrancheInitParams({
            name: _config.juniorTrancheName, symbol: _config.juniorTrancheSymbol, initialAuthority: _factoryAddress
        });

        return abi.encodeCall(RoycoJuniorTranche.initialize, (trancheParams));
    }
}
