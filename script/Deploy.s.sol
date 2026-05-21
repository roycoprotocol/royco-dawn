// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AccessManager } from "../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { ERC1967Proxy } from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { RoycoAccountant } from "../src/accountant/RoycoAccountant.sol";
import {
    ADMIN_ACCOUNTANT_ROLE,
    ADMIN_BALANCER_POOL_MANAGER_ROLE,
    ADMIN_FACTORY_ROLE,
    ADMIN_KERNEL_ROLE,
    ADMIN_ORACLE_QUOTER_ROLE,
    ADMIN_PAUSER_ROLE,
    ADMIN_PROTOCOL_FEE_SETTER_ROLE,
    ADMIN_ROLE,
    ADMIN_UNPAUSER_ROLE,
    ADMIN_UPGRADER_ROLE,
    DEPLOYER_ROLE,
    GUARDIAN_ROLE,
    JT_LP_ROLE,
    LP_ROLE_ADMIN_ROLE,
    ST_LP_ROLE,
    SYNC_ROLE,
    TRANSFER_AGENT_ROLE
} from "../src/factory/RolesConfiguration.sol";
import { RoycoFactory } from "../src/factory/RoycoFactory.sol";
import { BaseDeploymentTemplate } from "../src/factory/templates/BaseDeploymentTemplate.sol";
import {
    COMPONENT_ID_ACCOUNTANT_IMPL,
    COMPONENT_ID_JUNIOR_TRANCHE_IMPL,
    COMPONENT_ID_KERNEL_APYUSD,
    COMPONENT_ID_KERNEL_IDENTICAL_ERC20_CHAINLINK,
    COMPONENT_ID_KERNEL_IDENTICAL_ERC20_CHAINLINK_SBT,
    COMPONENT_ID_KERNEL_IDENTICAL_ERC4626_ADMIN_ORACLE,
    COMPONENT_ID_KERNEL_IDENTICAL_ERC4626_CHAINLINK_ORACLE,
    COMPONENT_ID_KERNEL_IDENTICAL_MAKINA,
    COMPONENT_ID_KERNEL_IDLECDOAA,
    COMPONENT_ID_KERNEL_LOCKED_IUSD,
    COMPONENT_ID_KERNEL_MAPLE_V2,
    COMPONENT_ID_KERNEL_REUSD,
    COMPONENT_ID_KERNEL_SUSDAI,
    COMPONENT_ID_KERNEL_SUSDAT,
    COMPONENT_ID_SENIOR_TRANCHE_IMPL,
    COMPONENT_ID_YDM_ADAPTIVE_CURVE_V2
} from "../src/factory/templates/Components.sol";
import { IdenticalERC20ChainlinkDeploymentTemplate } from "../src/factory/templates/dawn/IdenticalERC20ChainlinkDeploymentTemplate.sol";
import { IdenticalERC20ChainlinkSBTDeploymentTemplate } from "../src/factory/templates/dawn/IdenticalERC20ChainlinkSBTDeploymentTemplate.sol";
import { IdenticalERC4626AdminOracleDeploymentTemplate } from "../src/factory/templates/dawn/IdenticalERC4626AdminOracleDeploymentTemplate.sol";
import { IdenticalERC4626ChainlinkOracleDeploymentTemplate } from "../src/factory/templates/dawn/IdenticalERC4626ChainlinkOracleDeploymentTemplate.sol";
import { IdenticalMakinaDeploymentTemplate } from "../src/factory/templates/dawn/IdenticalMakinaDeploymentTemplate.sol";
import { IdleCdoAADeploymentTemplate } from "../src/factory/templates/dawn/IdleCdoAADeploymentTemplate.sol";
import { LockediUSDDeploymentTemplate } from "../src/factory/templates/dawn/LockediUSDDeploymentTemplate.sol";
import { MapleV2DeploymentTemplate } from "../src/factory/templates/dawn/MapleV2DeploymentTemplate.sol";
import { ReUSDDeploymentTemplate } from "../src/factory/templates/dawn/ReUSDDeploymentTemplate.sol";
import { apyUSDDeploymentTemplate } from "../src/factory/templates/dawn/apyUSDDeploymentTemplate.sol";
import { DawnDeploymentTemplate } from "../src/factory/templates/dawn/base/DawnDeploymentTemplate.sol";
import { sUSDaiDeploymentTemplate } from "../src/factory/templates/dawn/sUSDaiDeploymentTemplate.sol";
import { sUSDatDeploymentTemplate } from "../src/factory/templates/dawn/sUSDatDeploymentTemplate.sol";
import { IRoycoAccountant } from "../src/interfaces/IRoycoAccountant.sol";
import { IRoycoDawnKernel } from "../src/interfaces/IRoycoDawnKernel.sol";
import { IRoycoEntryPoint } from "../src/interfaces/IRoycoEntryPoint.sol";
import { IRoycoVaultTranche } from "../src/interfaces/IRoycoVaultTranche.sol";
import { IYDM } from "../src/interfaces/IYDM.sol";
import { IRoycoProtocolTemplate } from "../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_Kernel } from "../src/kernels/dawn/Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_Kernel.sol";
import { Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel } from "../src/kernels/dawn/Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel.sol";
import {
    Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel
} from "../src/kernels/dawn/Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel.sol";
import { Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel } from "../src/kernels/dawn/Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel.sol";
import { Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel } from "../src/kernels/dawn/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";
import { Identical_Makina_ST_JT_MachineToAdminOracle_Kernel } from "../src/kernels/dawn/Identical_Makina_ST_JT_MachineToAdminOracle_Kernel.sol";
import { Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle } from "../src/kernels/dawn/Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle.sol";
import { MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel } from "../src/kernels/dawn/MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel.sol";
import { ReUSD_ST_JT_ICLOracle_Kernel } from "../src/kernels/dawn/ReUSD_ST_JT_ICLOracle_Kernel.sol";
import { apyUSD_ST_JT_SharePriceToChainlinkOracle_Kernel } from "../src/kernels/dawn/apyUSD_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";
import { sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel } from "../src/kernels/dawn/sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel.sol";
import { sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel } from "../src/kernels/dawn/sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";
import { toNAVUnits } from "../src/libraries/Units.sol";
import { RoycoJuniorTranche } from "../src/tranches/RoycoJuniorTranche.sol";
import { RoycoSeniorTranche } from "../src/tranches/RoycoSeniorTranche.sol";
import { AdaptiveCurveYDM_V2 } from "../src/ydm/AdaptiveCurveYDM_V2.sol";
import { MarketDeploymentConfig } from "./config/MarketDeploymentConfig.sol";
import { Script } from "lib/forge-std/src/Script.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

/**
 * @title DeployScript
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Deployment script for Royco markets.
 */
contract DeployScript is Script, MarketDeploymentConfig {
    error UnsupportedComponent(bytes32 component);

    bool internal ENABLE_LOGGING = false;

    /// @notice Aggregated addresses for the per-role wallet assignments wired on the fresh AM.
    struct RoleAssignmentAddresses {
        address pauserAddress;
        address unpauserAddress;
        address upgraderAddress;
        address syncRoleAddress;
        address adminKernelAddress;
        address adminAccountantAddress;
        address adminProtocolFeeSetterAddress;
        address adminOracleQuoterAddress;
        address adminBalancerPoolManagerAddress;
        address lpRoleAdminAddress;
        address guardianAddress;
        address deployerAddress;
        address transferAgentAddress;
    }

    /// @notice Complete deployment result returned to callers (tests / scripts).
    struct DeploymentResult {
        AccessManager accessManager;
        RoycoFactory factory;
        IYDM ydm;
        IRoycoVaultTranche seniorTranche;
        IRoycoVaultTranche juniorTranche;
        IRoycoAccountant accountant;
        IRoycoDawnKernel kernel;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ENTRY POINTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice CLI entry: reads `MARKET_NAME` + `DEPLOYER_PRIVATE_KEY` from env and deploys.
    function run() external virtual {
        ENABLE_LOGGING = true;

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        string memory marketName = vm.envString("MARKET_NAME");

        console2.log("Deploying market from config:", marketName);
        deployFromConfig(marketName, deployerPrivateKey);
    }

    /// @notice Resolves a market+chain config, builds default `RoleAssignmentAddresses` from the
    ///         chain config, and forwards to `deploy(...)`.
    function deployFromConfig(string memory _marketName, uint256 _deployerPrivateKey) public returns (DeploymentResult memory) {
        ChainConfig memory chainConfig = getChainConfig(block.chainid);
        MarketConfig memory marketConfig = getMarketConfig(_marketName);

        RoleAssignmentAddresses memory roles = RoleAssignmentAddresses({
            pauserAddress: chainConfig.pauserAddress,
            unpauserAddress: chainConfig.unpauserAddress,
            upgraderAddress: chainConfig.upgraderAddress,
            syncRoleAddress: chainConfig.syncRoleAddress,
            adminKernelAddress: chainConfig.adminKernelAddress,
            adminAccountantAddress: chainConfig.adminAccountantAddress,
            adminProtocolFeeSetterAddress: chainConfig.adminProtocolFeeSetterAddress,
            adminOracleQuoterAddress: chainConfig.adminOracleQuoterAddress,
            adminBalancerPoolManagerAddress: chainConfig.adminAccountantAddress, // default — chain config can be widened later
            lpRoleAdminAddress: chainConfig.lpRoleAdminAddress,
            guardianAddress: chainConfig.guardianAddress,
            deployerAddress: chainConfig.deployerAddress,
            transferAgentAddress: marketConfig.transferAgentAddress
        });

        return deploy(marketConfig, chainConfig.factoryAdmin, chainConfig.protocolFeeRecipient, roles, _deployerPrivateKey);
    }

    /// @notice Stands up a fresh AM + factory, registers the right concrete template, and runs
    ///         the market deployment for `_config`.
    /// @param _config Market params (from `getMarketConfig(name)`).
    /// @param _factoryAdmin AM ADMIN_ROLE holder. Owns the AM going forward.
    /// @param _protocolFeeRecipient Initial protocol-fee recipient for the kernel.
    /// @param _roles Address assignments for the standard role surface.
    /// @param _deployerPrivateKey Key whose address gets DEPLOYER_ROLE + actually broadcasts.
    function deploy(
        MarketConfig memory _config,
        address _factoryAdmin,
        address _protocolFeeRecipient,
        RoleAssignmentAddresses memory _roles,
        uint256 _deployerPrivateKey
    )
        public
        returns (DeploymentResult memory result)
    {
        // 1. Stand up the AM + factory + all role grants in one call (shared with tests).
        (result.accessManager, result.factory) = bootstrapFactory(_factoryAdmin, _roles, _deployerPrivateKey);

        // 2. Register the right concrete template for this market's `component`.
        address template = _instantiateAndRegisterTemplate(result.factory, _factoryAdmin, _config.component);

        // 3. Execute the market deployment via the factory.
        IRoycoProtocolTemplate.DeploymentResult memory r;
        vm.prank(vm.addr(_deployerPrivateKey));
        r = result.factory.executeMarketDeployment(template, _encodeDawnParams(_config, _protocolFeeRecipient));

        result.seniorTranche = IRoycoVaultTranche(r.seniorTranche);
        result.juniorTranche = IRoycoVaultTranche(r.juniorTranche);
        result.kernel = IRoycoDawnKernel(r.kernel);
        result.accountant = IRoycoAccountant(r.accountant);
        result.ydm = IYDM(r.ydm);

        if (ENABLE_LOGGING) _logSummary(result, _config.marketName);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FACTORY BOOTSTRAP — sole source of truth for AM + factory + role wiring.
    // Tests and production market deploys both go through this so the AM role surface is
    // identical (matters most for `executionDelay`s — schedule()-based tests rely on the same
    // 2-day delays that main runs in production).
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Per-role `executionDelay`s, mirroring main's `RolesConfiguration.getRoleConfig`.
    ///         Anything not listed defaults to 0.
    /// @dev `ADMIN_UNPAUSER_ROLE` lives in legacy `ExtraRoles` on main; pre-existing tests
    ///      assume a 1-day delay for it (matches the `ApplySecurityMigration` post-init grant).
    uint32 internal constant DELAY_ADMIN_UPGRADER = 2 days;
    uint32 internal constant DELAY_ADMIN_KERNEL = 2 days;
    uint32 internal constant DELAY_ADMIN_ACCOUNTANT = 2 days;
    uint32 internal constant DELAY_ADMIN_PROTOCOL_FEE_SETTER = 2 days;
    uint32 internal constant DELAY_ADMIN_UNPAUSER = 1 days;

    /// @notice Deploys a fresh `AccessManager` + `RoycoFactory` proxy, grants every standard
    ///         role to the provided addresses with the production-correct `executionDelay`s,
    ///         and wires `ST_LP_ROLE`/`JT_LP_ROLE` admin to `LP_ROLE_ADMIN_ROLE`.
    /// @param _factoryAdmin AM ADMIN_ROLE holder. Pranked as the role granter throughout.
    /// @param _roles Address assignments for every standard role (see `RoleAssignmentAddresses`).
    /// @param _deployerPrivateKey EOA that performs the CREATE for the factory impl + proxy.
    ///        Its address gets `DEPLOYER_ROLE` (delay 0) so it can drive `executeMarketDeployment`.
    /// @return am Deployed `AccessManager`.
    /// @return factory Deployed `RoycoFactory` (ERC1967 proxy already `initialize`d).
    function bootstrapFactory(
        address _factoryAdmin,
        RoleAssignmentAddresses memory _roles,
        uint256 _deployerPrivateKey
    )
        public
        returns (AccessManager am, RoycoFactory factory)
    {
        address deployer = vm.addr(_deployerPrivateKey);
        am = new AccessManager(_factoryAdmin);
        factory = _deployFactoryProxy(am, _factoryAdmin, deployer);
        _wireRoleAssignments(am, _factoryAdmin, deployer, _roles);
    }

    function _deployFactoryProxy(AccessManager _am, address _factoryAdmin, address _deployer) internal returns (RoycoFactory factory) {
        RoycoFactory factoryImpl;
        vm.prank(_deployer);
        factoryImpl = new RoycoFactory();

        address predictedProxy = vm.computeCreateAddress(_deployer, vm.getNonce(_deployer));
        vm.prank(_factoryAdmin);
        _am.grantRole(ADMIN_ROLE, predictedProxy, 0);

        vm.prank(_deployer);
        factory = RoycoFactory(address(new ERC1967Proxy(address(factoryImpl), abi.encodeCall(RoycoFactory.initialize, (address(_am))))));
        require(address(factory) == predictedProxy, "factory predicted-vs-actual mismatch");
    }

    function _wireRoleAssignments(AccessManager _am, address _factoryAdmin, address _deployer, RoleAssignmentAddresses memory _roles) internal {
        vm.startPrank(_factoryAdmin);
        _am.grantRole(ADMIN_FACTORY_ROLE, _factoryAdmin, 0);
        _am.grantRole(DEPLOYER_ROLE, _deployer, 0);
        _am.grantRole(ADMIN_PAUSER_ROLE, _roles.pauserAddress, 0);
        _am.grantRole(ADMIN_UNPAUSER_ROLE, _roles.unpauserAddress, DELAY_ADMIN_UNPAUSER);
        _am.grantRole(ADMIN_UPGRADER_ROLE, _roles.upgraderAddress, DELAY_ADMIN_UPGRADER);
        _am.grantRole(SYNC_ROLE, _roles.syncRoleAddress, 0);
        _am.grantRole(ADMIN_KERNEL_ROLE, _roles.adminKernelAddress, DELAY_ADMIN_KERNEL);
        _am.grantRole(ADMIN_ACCOUNTANT_ROLE, _roles.adminAccountantAddress, DELAY_ADMIN_ACCOUNTANT);
        _am.grantRole(ADMIN_PROTOCOL_FEE_SETTER_ROLE, _roles.adminProtocolFeeSetterAddress, DELAY_ADMIN_PROTOCOL_FEE_SETTER);
        _am.grantRole(ADMIN_ORACLE_QUOTER_ROLE, _roles.adminOracleQuoterAddress, 0);
        _am.grantRole(ADMIN_BALANCER_POOL_MANAGER_ROLE, _roles.adminBalancerPoolManagerAddress, 0);
        _am.grantRole(LP_ROLE_ADMIN_ROLE, _roles.lpRoleAdminAddress, 0);
        _am.grantRole(GUARDIAN_ROLE, _roles.guardianAddress, 0);
        _am.grantRole(TRANSFER_AGENT_ROLE, _roles.transferAgentAddress, 0);

        // LP roles are admined by LP_ROLE_ADMIN_ROLE.
        _am.setRoleAdmin(ST_LP_ROLE, LP_ROLE_ADMIN_ROLE);
        _am.setRoleAdmin(JT_LP_ROLE, LP_ROLE_ADMIN_ROLE);

        // GUARDIAN_ROLE is the guardian for every admin/operator role on the AM (mirrors main's
        // `RolesConfiguration.getRoleConfig`). The guardian can cancel any scheduled operation
        // for these roles. Roles intentionally NOT guarded by GUARDIAN_ROLE (TRANSFER_AGENT,
        // BURNER) keep AM's default — admin manages them.
        _am.setRoleGuardian(ADMIN_PAUSER_ROLE, GUARDIAN_ROLE);
        _am.setRoleGuardian(ADMIN_UNPAUSER_ROLE, GUARDIAN_ROLE);
        _am.setRoleGuardian(ADMIN_UPGRADER_ROLE, GUARDIAN_ROLE);
        _am.setRoleGuardian(SYNC_ROLE, GUARDIAN_ROLE);
        _am.setRoleGuardian(ADMIN_KERNEL_ROLE, GUARDIAN_ROLE);
        _am.setRoleGuardian(ADMIN_ACCOUNTANT_ROLE, GUARDIAN_ROLE);
        _am.setRoleGuardian(ADMIN_PROTOCOL_FEE_SETTER_ROLE, GUARDIAN_ROLE);
        _am.setRoleGuardian(ADMIN_ORACLE_QUOTER_ROLE, GUARDIAN_ROLE);
        _am.setRoleGuardian(ADMIN_BALANCER_POOL_MANAGER_ROLE, GUARDIAN_ROLE);
        _am.setRoleGuardian(LP_ROLE_ADMIN_ROLE, GUARDIAN_ROLE);
        _am.setRoleGuardian(ST_LP_ROLE, GUARDIAN_ROLE);
        _am.setRoleGuardian(JT_LP_ROLE, GUARDIAN_ROLE);
        _am.setRoleGuardian(DEPLOYER_ROLE, GUARDIAN_ROLE);

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEMPLATE INSTANTIATION (component → concrete template + kernel creation code)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Picks the right concrete Dawn template for `_component`, deploys it, and registers
    ///      it with the 5 standard components (ST/JT/accountant/YDM + the chosen kernel impl).
    function _instantiateAndRegisterTemplate(RoycoFactory _factory, address _factoryAdmin, bytes32 _component) internal returns (address template) {
        bytes memory kernelCreationCode;

        if (_component == COMPONENT_ID_KERNEL_REUSD) {
            template = address(new ReUSDDeploymentTemplate(_factory));
            kernelCreationCode = type(ReUSD_ST_JT_ICLOracle_Kernel).creationCode;
        } else if (_component == COMPONENT_ID_KERNEL_IDENTICAL_ERC20_CHAINLINK) {
            template = address(new IdenticalERC20ChainlinkDeploymentTemplate(_factory));
            kernelCreationCode = type(Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel).creationCode;
        } else if (_component == COMPONENT_ID_KERNEL_IDENTICAL_ERC20_CHAINLINK_SBT) {
            template = address(new IdenticalERC20ChainlinkSBTDeploymentTemplate(_factory));
            kernelCreationCode = type(Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel).creationCode;
        } else if (_component == COMPONENT_ID_KERNEL_IDENTICAL_ERC4626_ADMIN_ORACLE) {
            template = address(new IdenticalERC4626AdminOracleDeploymentTemplate(_factory));
            kernelCreationCode = type(Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel).creationCode;
        } else if (_component == COMPONENT_ID_KERNEL_IDENTICAL_ERC4626_CHAINLINK_ORACLE) {
            template = address(new IdenticalERC4626ChainlinkOracleDeploymentTemplate(_factory));
            kernelCreationCode = type(Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel).creationCode;
        } else if (_component == COMPONENT_ID_KERNEL_IDLECDOAA) {
            template = address(new IdleCdoAADeploymentTemplate(_factory));
            kernelCreationCode = type(Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_Kernel).creationCode;
        } else if (_component == COMPONENT_ID_KERNEL_IDENTICAL_MAKINA) {
            template = address(new IdenticalMakinaDeploymentTemplate(_factory));
            kernelCreationCode = type(Identical_Makina_ST_JT_MachineToAdminOracle_Kernel).creationCode;
        } else if (_component == COMPONENT_ID_KERNEL_SUSDAI) {
            template = address(new sUSDaiDeploymentTemplate(_factory));
            kernelCreationCode = type(sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel).creationCode;
        } else if (_component == COMPONENT_ID_KERNEL_MAPLE_V2) {
            template = address(new MapleV2DeploymentTemplate(_factory));
            kernelCreationCode = type(MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel).creationCode;
        } else if (_component == COMPONENT_ID_KERNEL_APYUSD) {
            template = address(new apyUSDDeploymentTemplate(_factory));
            kernelCreationCode = type(apyUSD_ST_JT_SharePriceToChainlinkOracle_Kernel).creationCode;
        } else if (_component == COMPONENT_ID_KERNEL_LOCKED_IUSD) {
            template = address(new LockediUSDDeploymentTemplate(_factory));
            kernelCreationCode = type(Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle).creationCode;
        } else if (_component == COMPONENT_ID_KERNEL_SUSDAT) {
            template = address(new sUSDatDeploymentTemplate(_factory));
            kernelCreationCode = type(sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel).creationCode;
        } else {
            revert UnsupportedComponent(_component);
        }

        bytes32[] memory ids = new bytes32[](5);
        bytes[] memory codes = new bytes[](5);
        ids[0] = COMPONENT_ID_SENIOR_TRANCHE_IMPL;
        codes[0] = type(RoycoSeniorTranche).creationCode;
        ids[1] = COMPONENT_ID_JUNIOR_TRANCHE_IMPL;
        codes[1] = type(RoycoJuniorTranche).creationCode;
        ids[2] = COMPONENT_ID_ACCOUNTANT_IMPL;
        codes[2] = type(RoycoAccountant).creationCode;
        ids[3] = COMPONENT_ID_YDM_ADAPTIVE_CURVE_V2;
        codes[3] = type(AdaptiveCurveYDM_V2).creationCode;
        ids[4] = _component;
        codes[4] = kernelCreationCode;

        vm.prank(_factoryAdmin);
        _factory.registerTemplate(template, ids, codes);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PARAM BUILDING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Translates a `MarketConfig` into the ABI-encoded `DawnParams` blob the factory
    ///      forwards to the chosen template.
    function _encodeDawnParams(MarketConfig memory _c, address _protocolFeeRecipient) internal pure returns (bytes memory) {
        DawnDeploymentTemplate.DawnParams memory p = DawnDeploymentTemplate.DawnParams({
            marketId: keccak256(abi.encodePacked("ROYCO_MARKET_", _c.marketName)),
            st: BaseDeploymentTemplate.SeniorTrancheParams({ name: _c.seniorTrancheName, symbol: _c.seniorTrancheSymbol, asset: _c.seniorAsset }),
            jt: BaseDeploymentTemplate.JuniorTrancheParams({ name: _c.juniorTrancheName, symbol: _c.juniorTrancheSymbol, asset: _c.juniorAsset }),
            accountant: BaseDeploymentTemplate.AccountantParams({
                stProtocolFeeWAD: _c.stProtocolFeeWAD,
                jtProtocolFeeWAD: _c.jtProtocolFeeWAD,
                yieldShareProtocolFeeWAD: _c.jtYieldShareProtocolFeeWAD,
                coverageWAD: _c.coverageWAD,
                betaWAD: _c.betaWAD,
                liquidationUtilizationWAD: _c.liquidationUtilizationWAD,
                fixedTermDurationSeconds: _c.fixedTermDurationSeconds,
                stNAVDustTolerance: toNAVUnits(_c.stDustTolerance),
                jtNAVDustTolerance: toNAVUnits(_c.jtDustTolerance),
                ydmInitializationData: _buildYDMInitData(_c.ydmType, _c.ydmSpecificParams)
            }),
            ydm: BaseDeploymentTemplate.YDMParams({ componentTag: COMPONENT_ID_YDM_ADAPTIVE_CURVE_V2, version: bytes32("V1") }),
            kernelSpecificParams: _c.kernelSpecificParams,
            enforceVaultSharesTransferWhitelist: _c.enforceVaultSharesTransferWhitelist,
            protocolFeeRecipient: _protocolFeeRecipient,
            stSelfLiquidationBonusWAD: _c.stSelfLiquidationBonusWAD,
            entryPoint: address(0),
            stEntryPointConfig: IRoycoEntryPoint.TrancheConfig({
                enabled: false, yieldRecipient: IRoycoEntryPoint.AccruedYieldRecipient.PROTOCOL, depositDelaySeconds: 0, redemptionDelaySeconds: 0
            }),
            jtEntryPointConfig: IRoycoEntryPoint.TrancheConfig({
                enabled: false, yieldRecipient: IRoycoEntryPoint.AccruedYieldRecipient.PROTOCOL, depositDelaySeconds: 0, redemptionDelaySeconds: 0
            })
        });
        return abi.encode(p);
    }

    /// @dev Reshapes the legacy `YDMParams` blob into the new accountant init calldata. The
    ///      accountant does a low-level `.call(ydmInitializationData)` against the YDM, so this
    ///      must be the complete `(selector, args)` calldata for the variant's `initialize`.
    function _buildYDMInitData(YDMType _ydmType, bytes memory _ydmSpecificParams) internal pure returns (bytes memory) {
        if (_ydmType == YDMType.AdaptiveCurve_V2) {
            AdaptiveCurveYDM_V2_Params memory p = abi.decode(_ydmSpecificParams, (AdaptiveCurveYDM_V2_Params));
            return abi.encodeCall(
                AdaptiveCurveYDM_V2.initializeYDMForMarket,
                (p.jtYieldShareAtZeroUtilWAD, p.jtYieldShareAtTargetUtilWAD, p.jtYieldShareAtFullUtilWAD, p.maxAdaptationSpeedWAD)
            );
        }
        // StaticCurve / AdaptiveCurve_V1 not currently supported by the new factory's templates
        // (Dawn templates register `AdaptiveCurveYDM_V2` as their YDM slot). Add additional
        // branches here if and when older YDMs need template support.
        revert UnsupportedComponent(bytes32(uint256(uint8(_ydmType))));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LOGGING
    // ═══════════════════════════════════════════════════════════════════════════

    function _logSummary(DeploymentResult memory _r, string memory _marketName) internal view {
        console2.log("=== Deployment Summary ===");
        console2.log("Market:           ", _marketName);
        console2.log("Access Manager:   ", address(_r.accessManager));
        console2.log("Factory:          ", address(_r.factory));
        console2.log("YDM:              ", address(_r.ydm));
        console2.log("Senior Tranche:   ", address(_r.seniorTranche));
        console2.log("Junior Tranche:   ", address(_r.juniorTranche));
        console2.log("Accountant:       ", address(_r.accountant));
        console2.log("Kernel:           ", address(_r.kernel));
        console2.log("==========================");
    }
}
