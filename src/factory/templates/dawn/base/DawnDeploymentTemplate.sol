// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AccessManagedUpgradeable } from "../../../../../lib/openzeppelin-contracts-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";
import { UUPSUpgradeable } from "../../../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IRoycoAccountant } from "../../../../interfaces/IRoycoAccountant.sol";
import { IRoycoAuth } from "../../../../interfaces/IRoycoAuth.sol";
import { IRoycoDawnKernel } from "../../../../interfaces/IRoycoDawnKernel.sol";
import { IRoycoEntryPoint } from "../../../../interfaces/IRoycoEntryPoint.sol";
import { IRoycoVaultTranche } from "../../../../interfaces/IRoycoVaultTranche.sol";
import { IRoycoFactory } from "../../../../interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../../interfaces/factory/IRoycoProtocolTemplate.sol";
import { IdenticalAssetsChainlinkOracleQuoter } from "../../../../kernels/base/quoter/dawn/base/IdenticalAssetsChainlinkOracleQuoter.sol";
import { IdenticalAssetsOracleQuoter } from "../../../../kernels/base/quoter/dawn/base/IdenticalAssetsOracleQuoter.sol";
import { TrancheType } from "../../../../libraries/Types.sol";
import {
    ADMIN_ACCOUNTANT_ROLE,
    ADMIN_KERNEL_ROLE,
    ADMIN_ORACLE_QUOTER_ROLE,
    ADMIN_PAUSER_ROLE,
    ADMIN_PROTOCOL_FEE_SETTER_ROLE,
    ADMIN_UNPAUSER_ROLE,
    ADMIN_UPGRADER_ROLE,
    BURNER_ROLE,
    JT_LP_ROLE,
    ST_LP_ROLE,
    SYNC_ROLE,
    TRANSFER_AGENT_ROLE
} from "../../../RolesConfiguration.sol";
import { BaseDeploymentTemplate } from "../../BaseDeploymentTemplate.sol";

/**
 * @title DawnDeploymentTemplate
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Abstract base for every Dawn-family market deployment template.
 *
 * @dev One concrete subclass exists per Dawn kernel variant. The base class owns the standard
 *      Dawn deployment flow (predict addresses → deploy YDM → deploy 4 impls → deploy 4 proxies
 *      → apply role bindings → optional entry-point wiring) plus the cross-wiring verification.
 *      Subclasses only need to override three pure hooks to plug in their kernel:
 *
 *        - `_kernelComponentId()` — which SSTORE2 slot holds the kernel's creation code.
 *        - `_kernelCtorArgs(constructionParams, kernelSpecificParams)` — ABI-encoded kernel ctor
 *          args. The first half is shared (`RoycoDawnKernelConstructionParams`); subclasses
 *          append whatever extra constructor args their kernel takes.
 *        - `_kernelInitData(initParams, kernelSpecificParams)` — ABI-encoded `initialize(...)`
 *          calldata for the kernel proxy. Each concrete kernel has its own initialize
 *          signature; subclasses encode against their kernel type.
 *
 *      The `kernelSpecificParams` byte blob is opaque to this base — subclasses decode it
 *      against their own per-kernel param struct.
 */
abstract contract DawnDeploymentTemplate is BaseDeploymentTemplate {
    // ═══════════════════════════════════════════════════════════════════════════
    // PARAM STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Top-level params struct passed to `deployMarket(bytes)`.
    /// @dev Role bindings are NOT in this struct — they're hardcoded in `_buildRoleBindings`
    ///      (a virtual hook concrete kernel templates can override to add more bindings).
    /// @custom:field kernelSpecificParams - Opaque byte blob the concrete subclass decodes
    ///        against its own per-kernel param struct. Empty for kernels with no extras.
    /// @custom:field enforceVaultSharesTransferWhitelist - Forwarded into the kernel's
    ///        `RoycoDawnKernelConstructionParams`. True for permissioned markets (e.g. ACRED).
    /// @custom:field entryPoint - Optional. If non-zero, the template configures the entry
    ///        point's tranche configs for the ST and JT it just deployed. Skipped when zero.
    struct DawnParams {
        bytes32 marketId;
        SeniorTrancheParams st;
        JuniorTrancheParams jt;
        AccountantParams accountant;
        YDMParams ydm;
        bytes kernelSpecificParams;
        bool enforceVaultSharesTransferWhitelist;
        address protocolFeeRecipient;
        uint64 stSelfLiquidationBonusWAD;
        address entryPoint;
        IRoycoEntryPoint.TrancheConfig stEntryPointConfig;
        IRoycoEntryPoint.TrancheConfig jtEntryPointConfig;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error INVALID_ACCESS_MANAGER();
    error INVALID_ENTRY_POINT_TRANCHE_CONFIG();
    error INVALID_TRANCHE_TYPE_ON_SENIOR_TRANCHE();
    error INVALID_TRANCHE_TYPE_ON_JUNIOR_TRANCHE();
    error INVALID_KERNEL_ON_SENIOR_TRANCHE();
    error INVALID_KERNEL_ON_JUNIOR_TRANCHE();
    error INVALID_SENIOR_TRANCHE_ON_KERNEL();
    error INVALID_JUNIOR_TRANCHE_ON_KERNEL();
    error INVALID_ST_ASSET_ON_KERNEL();
    error INVALID_JT_ASSET_ON_KERNEL();
    error INVALID_ACCOUNTANT_ON_KERNEL();
    error INVALID_KERNEL_ON_ACCOUNTANT();

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTION
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(IRoycoFactory _factory) BaseDeploymentTemplate(_factory) { }

    // ═══════════════════════════════════════════════════════════════════════════
    // PER-KERNEL HOOKS (subclasses override)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Returns the SSTORE2 component ID that holds this kernel's creation code.
    function _kernelComponentId() internal pure virtual returns (bytes32);

    /// @dev Returns the ABI-encoded kernel constructor args. Subclasses ABI-encode their
    ///      concrete kernel's full ctor tuple (typically `(_cp, ...kernel-specific extras)`).
    function _kernelCtorArgs(
        IRoycoDawnKernel.RoycoDawnKernelConstructionParams memory _cp,
        bytes memory _kernelSpecificParams
    )
        internal
        pure
        virtual
        returns (bytes memory);

    /// @dev Returns the ABI-encoded kernel `initialize(...)` calldata. Subclasses use
    ///      `abi.encodeCall(ConcreteKernel.initialize, (kip, ...kernel-specific extras))`.
    function _kernelInitData(
        IRoycoDawnKernel.RoycoDawnKernelInitParams memory _kip,
        bytes memory _kernelSpecificParams
    )
        internal
        pure
        virtual
        returns (bytes memory);

    // ═══════════════════════════════════════════════════════════════════════════
    // VALIDATE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IRoycoProtocolTemplate
    function validateParams(bytes calldata _params) external pure override {
        DawnParams memory p = abi.decode(_params, (DawnParams));
        require(p.marketId != bytes32(0), INVALID_PARAMS());
        require(bytes(p.st.name).length > 0, INVALID_PARAMS());
        require(bytes(p.st.symbol).length > 0, INVALID_PARAMS());
        require(p.st.asset != address(0), INVALID_PARAMS());
        require(bytes(p.jt.name).length > 0, INVALID_PARAMS());
        require(bytes(p.jt.symbol).length > 0, INVALID_PARAMS());
        require(p.jt.asset != address(0), INVALID_PARAMS());
        require(p.protocolFeeRecipient != address(0), INVALID_PARAMS());
        require(p.ydm.componentTag != bytes32(0), INVALID_PARAMS());
        require(p.ydm.version != bytes32(0), INVALID_PARAMS());
        require(p.accountant.ydmInitializationData.length > 0, INVALID_PARAMS());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IRoycoProtocolTemplate
    function deployMarket(bytes calldata _params) external override onlyRoycoFactory returns (DeploymentResult memory result) {
        DawnParams memory p = abi.decode(_params, (DawnParams));

        // 1. Predict the 4 proxy addresses so they can be baked into each impl's immutables.
        bytes32 stProxySalt = _marketComponentSalt(p.marketId, "ST");
        bytes32 jtProxySalt = _marketComponentSalt(p.marketId, "JT");
        bytes32 kernelProxySalt = _marketComponentSalt(p.marketId, "KERNEL");
        bytes32 accountantProxySalt = _marketComponentSalt(p.marketId, "ACCOUNTANT");

        result.seniorTranche = ROYCO_FACTORY.predictDeterministicAddress(stProxySalt);
        result.juniorTranche = ROYCO_FACTORY.predictDeterministicAddress(jtProxySalt);
        result.kernel = ROYCO_FACTORY.predictDeterministicAddress(kernelProxySalt);
        result.accountant = ROYCO_FACTORY.predictDeterministicAddress(accountantProxySalt);

        // 2. Deploy YDM — idempotent across templates if `(componentTag, version)` matches.
        (result.ydm,) = _deployYDM(p.ydm);

        // 3. Deploy impls (CREATE3 with constructor args baked in).
        address stImpl = _deploySeniorTrancheImpl(p.st.asset, result.kernel, _marketComponentSalt(p.marketId, "ST_IMPL"));
        address jtImpl = _deployJuniorTrancheImpl(p.jt.asset, result.kernel, _marketComponentSalt(p.marketId, "JT_IMPL"));
        address accountantImpl = _deployAccountantImpl(result.kernel, _marketComponentSalt(p.marketId, "ACCOUNTANT_IMPL"));
        address kernelImpl = _deployKernelImplInternal(p, result, _marketComponentSalt(p.marketId, "KERNEL_IMPL"));

        // 4. Deploy proxies pointing at the impls.
        _deployProxy(stImpl, _encodeTrancheInitData(p.st.name, p.st.symbol), stProxySalt);
        _deployProxy(jtImpl, _encodeTrancheInitData(p.jt.name, p.jt.symbol), jtProxySalt);
        _deployProxy(kernelImpl, _buildKernelInitDataInternal(p), kernelProxySalt);
        _deployProxy(accountantImpl, _encodeAccountantInitData(p.accountant, result.ydm), accountantProxySalt);

        // 5. Apply selector→role bindings + post-init grants.
        _applyRoleBindings(_buildRoleBindings(result));

        // 6. (Optional) Configure the entry point's tranche configs for the newly-deployed ST/JT.
        if (p.entryPoint != address(0)) {
            address[] memory tranches = new address[](2);
            tranches[0] = result.seniorTranche;
            tranches[1] = result.juniorTranche;
            IRoycoEntryPoint.TrancheConfig[] memory configs = new IRoycoEntryPoint.TrancheConfig[](2);
            configs[0] = p.stEntryPointConfig;
            configs[1] = p.jtEntryPointConfig;
            ROYCO_FACTORY.executeAsFactory(p.entryPoint, abi.encodeCall(IRoycoEntryPoint.modifyTrancheConfigs, (tranches, configs)));

            result.extras = abi.encode(p.entryPoint, p.stEntryPointConfig, p.jtEntryPointConfig);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VERIFY (cross-wiring checks — shared across all Dawn kernels)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IRoycoProtocolTemplate
    function verify(DeploymentResult calldata _d) external view override {
        address expectedAuthority = ROYCO_FACTORY.ROYCO_AUTHORITY();
        require(AccessManagedUpgradeable(_d.accountant).authority() == expectedAuthority, INVALID_ACCESS_MANAGER());
        require(AccessManagedUpgradeable(_d.kernel).authority() == expectedAuthority, INVALID_ACCESS_MANAGER());
        require(AccessManagedUpgradeable(_d.seniorTranche).authority() == expectedAuthority, INVALID_ACCESS_MANAGER());
        require(AccessManagedUpgradeable(_d.juniorTranche).authority() == expectedAuthority, INVALID_ACCESS_MANAGER());

        require(IRoycoVaultTranche(_d.seniorTranche).TRANCHE_TYPE() == TrancheType.SENIOR, INVALID_TRANCHE_TYPE_ON_SENIOR_TRANCHE());
        require(IRoycoVaultTranche(_d.juniorTranche).TRANCHE_TYPE() == TrancheType.JUNIOR, INVALID_TRANCHE_TYPE_ON_JUNIOR_TRANCHE());
        require(address(IRoycoVaultTranche(_d.seniorTranche).KERNEL()) == _d.kernel, INVALID_KERNEL_ON_SENIOR_TRANCHE());
        require(address(IRoycoVaultTranche(_d.juniorTranche).KERNEL()) == _d.kernel, INVALID_KERNEL_ON_JUNIOR_TRANCHE());

        IRoycoDawnKernel kernel = IRoycoDawnKernel(_d.kernel);
        require(kernel.SENIOR_TRANCHE() == _d.seniorTranche, INVALID_SENIOR_TRANCHE_ON_KERNEL());
        require(kernel.JUNIOR_TRANCHE() == _d.juniorTranche, INVALID_JUNIOR_TRANCHE_ON_KERNEL());
        require(kernel.ST_ASSET() == IRoycoVaultTranche(_d.seniorTranche).asset(), INVALID_ST_ASSET_ON_KERNEL());
        require(kernel.JT_ASSET() == IRoycoVaultTranche(_d.juniorTranche).asset(), INVALID_JT_ASSET_ON_KERNEL());
        require(kernel.ACCOUNTANT() == _d.accountant, INVALID_ACCOUNTANT_ON_KERNEL());

        require(address(IRoycoAccountant(_d.accountant).KERNEL()) == _d.kernel, INVALID_KERNEL_ON_ACCOUNTANT());

        // Optional entry-point check.
        if (_d.extras.length > 0) {
            (address entryPoint, IRoycoEntryPoint.TrancheConfig memory stCfg, IRoycoEntryPoint.TrancheConfig memory jtCfg) =
                abi.decode(_d.extras, (address, IRoycoEntryPoint.TrancheConfig, IRoycoEntryPoint.TrancheConfig));
            _assertEntryPointConfig(entryPoint, _d.seniorTranche, stCfg);
            _assertEntryPointConfig(entryPoint, _d.juniorTranche, jtCfg);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Builds the kernel ctor args from `(p, result)` and forwards to the subclass hook.
    function _deployKernelImplInternal(DawnParams memory _p, DeploymentResult memory _r, bytes32 _salt) private returns (address impl) {
        IRoycoDawnKernel.RoycoDawnKernelConstructionParams memory cp = IRoycoDawnKernel.RoycoDawnKernelConstructionParams({
            seniorTranche: _r.seniorTranche,
            stAsset: _p.st.asset,
            juniorTranche: _r.juniorTranche,
            jtAsset: _p.jt.asset,
            accountant: _r.accountant,
            enforceVaultSharesTransferWhitelist: _p.enforceVaultSharesTransferWhitelist
        });
        return _deployImpl(_kernelComponentId(), _kernelCtorArgs(cp, _p.kernelSpecificParams), _salt);
    }

    /// @dev Assembles the shared `RoycoDawnKernelInitParams` (which carries the AM authority)
    ///      and forwards to the subclass hook to build the full kernel `initialize(...)` calldata.
    function _buildKernelInitDataInternal(DawnParams memory _p) private view returns (bytes memory) {
        IRoycoDawnKernel.RoycoDawnKernelInitParams memory kip = IRoycoDawnKernel.RoycoDawnKernelInitParams({
            initialAuthority: ROYCO_FACTORY.ROYCO_AUTHORITY(),
            protocolFeeRecipient: _p.protocolFeeRecipient,
            stSelfLiquidationBonusWAD: _p.stSelfLiquidationBonusWAD
        });
        return _kernelInitData(kip, _p.kernelSpecificParams);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ROLE BINDINGS (overridable by concrete kernel templates)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Returns the full role-binding set applied to the freshly-deployed market contracts.
     * @dev Default implementation wires the standard Dawn bindings: tranche LP/burner/transfer
     *      agent + pause/unpause/upgrade across all 4 market contracts + kernel admin/sync/oracle
     *      quoter + accountant admin/fee setter + SYNC_ROLE → accountant grant.
     *
     *      Concrete kernel templates can override to ADD more (kernel-specific admin surfaces,
     *      extra quoter setters, etc.) by overriding `_extraRoleBindings` rather than this method.
     */
    function _buildRoleBindings(DeploymentResult memory _r) internal pure virtual returns (RoleBindings memory) {
        (TargetBinding[] memory extraTargets, RoleGrant[] memory extraGrants) = _extraRoleBindings(_r);

        TargetBinding[] memory targets = new TargetBinding[](4 + extraTargets.length);
        targets[0] = _trancheBinding(_r.seniorTranche, ST_LP_ROLE);
        targets[1] = _trancheBinding(_r.juniorTranche, JT_LP_ROLE);
        targets[2] = _kernelBinding(_r.kernel);
        targets[3] = _accountantBinding(_r.accountant);
        for (uint256 i; i < extraTargets.length; ++i) {
            targets[4 + i] = extraTargets[i];
        }

        RoleGrant[] memory grants = new RoleGrant[](1 + extraGrants.length);
        grants[0] = RoleGrant({ roleId: SYNC_ROLE, account: _r.accountant, executionDelay: 0 });
        for (uint256 i; i < extraGrants.length; ++i) {
            grants[1 + i] = extraGrants[i];
        }

        return RoleBindings({ targetBindings: targets, postInitGrants: grants });
    }

    /// @dev Override in concrete kernel templates to append extra bindings + grants.
    ///      Default is empty.
    function _extraRoleBindings(DeploymentResult memory) internal pure virtual returns (TargetBinding[] memory, RoleGrant[] memory) {
        return (new TargetBinding[](0), new RoleGrant[](0));
    }

    function _trancheBinding(address _tranche, uint64 _lpRole) private pure returns (TargetBinding memory) {
        bytes4[] memory s = new bytes4[](9);
        uint64[] memory r = new uint64[](9);
        s[0] = IRoycoVaultTranche.deposit.selector;
        r[0] = _lpRole;
        s[1] = IRoycoVaultTranche.redeem.selector;
        r[1] = _lpRole;
        s[2] = IRoycoAuth.pause.selector;
        r[2] = ADMIN_PAUSER_ROLE;
        s[3] = IRoycoAuth.unpause.selector;
        r[3] = ADMIN_UNPAUSER_ROLE;
        s[4] = UUPSUpgradeable.upgradeToAndCall.selector;
        r[4] = ADMIN_UPGRADER_ROLE;
        s[5] = IRoycoVaultTranche.seizeShares.selector;
        r[5] = TRANSFER_AGENT_ROLE;
        s[6] = IRoycoVaultTranche.seizeAndRedeemShares.selector;
        r[6] = TRANSFER_AGENT_ROLE;
        s[7] = IRoycoVaultTranche.burn.selector;
        r[7] = BURNER_ROLE;
        s[8] = IRoycoVaultTranche.burnFrom.selector;
        r[8] = BURNER_ROLE;
        return TargetBinding({ target: _tranche, selectors: s, roleIds: r });
    }

    function _kernelBinding(address _kernel) private pure returns (TargetBinding memory) {
        bytes4[] memory s = new bytes4[](11);
        uint64[] memory r = new uint64[](11);
        s[0] = IRoycoDawnKernel.setProtocolFeeRecipient.selector;
        r[0] = ADMIN_KERNEL_ROLE;
        s[1] = IRoycoAuth.pause.selector;
        r[1] = ADMIN_PAUSER_ROLE;
        s[2] = IRoycoAuth.unpause.selector;
        r[2] = ADMIN_UNPAUSER_ROLE;
        s[3] = IdenticalAssetsOracleQuoter.setConversionRate.selector;
        r[3] = ADMIN_ORACLE_QUOTER_ROLE;
        s[4] = IdenticalAssetsChainlinkOracleQuoter.setChainlinkOracle.selector;
        r[4] = ADMIN_ORACLE_QUOTER_ROLE;
        s[5] = UUPSUpgradeable.upgradeToAndCall.selector;
        r[5] = ADMIN_UPGRADER_ROLE;
        s[6] = IRoycoDawnKernel.syncTrancheAccounting.selector;
        r[6] = SYNC_ROLE;
        s[7] = IRoycoDawnKernel.setSeniorTrancheSelfLiquidationBonus.selector;
        r[7] = ADMIN_KERNEL_ROLE;
        s[8] = IRoycoDawnKernel.blacklistAccounts.selector;
        r[8] = TRANSFER_AGENT_ROLE;
        s[9] = IRoycoDawnKernel.unblacklistAccounts.selector;
        r[9] = TRANSFER_AGENT_ROLE;
        s[10] = IRoycoDawnKernel.setBlacklistStatus.selector;
        r[10] = TRANSFER_AGENT_ROLE;
        return TargetBinding({ target: _kernel, selectors: s, roleIds: r });
    }

    function _accountantBinding(address _accountant) private pure returns (TargetBinding memory) {
        bytes4[] memory s = new bytes4[](14);
        uint64[] memory r = new uint64[](14);
        s[0] = IRoycoAccountant.setYDM.selector;
        r[0] = ADMIN_ACCOUNTANT_ROLE;
        s[1] = IRoycoAccountant.setSeniorTrancheProtocolFee.selector;
        r[1] = ADMIN_PROTOCOL_FEE_SETTER_ROLE;
        s[2] = IRoycoAccountant.setJuniorTrancheProtocolFee.selector;
        r[2] = ADMIN_PROTOCOL_FEE_SETTER_ROLE;
        s[3] = IRoycoAccountant.setCoverage.selector;
        r[3] = ADMIN_ACCOUNTANT_ROLE;
        s[4] = IRoycoAccountant.setBeta.selector;
        r[4] = ADMIN_ACCOUNTANT_ROLE;
        s[5] = IRoycoAccountant.setLiquidationUtilization.selector;
        r[5] = ADMIN_ACCOUNTANT_ROLE;
        s[6] = IRoycoAccountant.setFixedTermDuration.selector;
        r[6] = ADMIN_ACCOUNTANT_ROLE;
        s[7] = IRoycoAuth.pause.selector;
        r[7] = ADMIN_PAUSER_ROLE;
        s[8] = IRoycoAuth.unpause.selector;
        r[8] = ADMIN_UNPAUSER_ROLE;
        s[9] = UUPSUpgradeable.upgradeToAndCall.selector;
        r[9] = ADMIN_UPGRADER_ROLE;
        s[10] = IRoycoAccountant.setSeniorTrancheDustTolerance.selector;
        r[10] = ADMIN_ACCOUNTANT_ROLE;
        s[11] = IRoycoAccountant.setYieldShareProtocolFee.selector;
        r[11] = ADMIN_PROTOCOL_FEE_SETTER_ROLE;
        s[12] = IRoycoAccountant.setCoverageConfiguration.selector;
        r[12] = ADMIN_ACCOUNTANT_ROLE;
        s[13] = IRoycoAccountant.setJuniorTrancheDustTolerance.selector;
        r[13] = ADMIN_ACCOUNTANT_ROLE;
        return TargetBinding({ target: _accountant, selectors: s, roleIds: r });
    }

    /// @dev Reads back the entry point's stored config for a tranche and asserts every field matches.
    function _assertEntryPointConfig(address _entryPoint, address _tranche, IRoycoEntryPoint.TrancheConfig memory _expected) internal view {
        IRoycoEntryPoint.EnrichedTrancheConfig memory got = IRoycoEntryPoint(_entryPoint).getTrancheConfig(_tranche);
        require(
            got.baseConfig.enabled == _expected.enabled && got.baseConfig.yieldRecipient == _expected.yieldRecipient
                && got.baseConfig.depositDelaySeconds == _expected.depositDelaySeconds
                && got.baseConfig.redemptionDelaySeconds == _expected.redemptionDelaySeconds,
            INVALID_ENTRY_POINT_TRANCHE_CONFIG()
        );
    }
}
