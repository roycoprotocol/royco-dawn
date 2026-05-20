// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { Gyro2CLPPoolFactory } from "../../../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/Gyro2CLPPoolFactory.sol";
import { TokenConfig as BalancerV3TokenConfig, PoolRoleAccounts as BalancerV3PoolRoleAccounts, TokenType as BalancerV3TokenType, HooksConfig as BalancerV3HooksConfig } from "../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { BalancerPoolToken } from "../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/BalancerPoolToken.sol";
import { AccessManagedUpgradeable } from "../../../../../lib/openzeppelin-contracts-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";
import { UUPSUpgradeable } from "../../../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "../../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IRoycoAccountant } from "../../../../interfaces/IRoycoAccountant.sol";
import { IRoycoAuth } from "../../../../interfaces/IRoycoAuth.sol";
import { IRoycoDawnKernel } from "../../../../interfaces/IRoycoDawnKernel.sol";
import { IRoycoDuskKernel } from "../../../../interfaces/IRoycoDuskKernel.sol";
import { IRoycoEntryPoint } from "../../../../interfaces/IRoycoEntryPoint.sol";
import { IRoycoVaultTranche } from "../../../../interfaces/IRoycoVaultTranche.sol";
import { IRoycoFactory } from "../../../../interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../../interfaces/factory/IRoycoProtocolTemplate.sol";
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
import { Vault } from "../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/Vault.sol";
import { COMPONENT_ID_DUSK_BALANCER_HOOKS } from "../../Components.sol";
import { RoycoDuskBalancerV3HooksStub } from "./stub/RoycoDuskBalancerV3HooksStub.sol";

/**
 * @title JuniorAssetsBalancerV3PoolTokensDeploymentTemplate
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Abstract base for every Dusk-Balancer market deployment template. 
 */
abstract contract JuniorAssetsBalancerV3PoolTokensDeploymentTemplate is BaseDeploymentTemplate {
    // ═══════════════════════════════════════════════════════════════════════════
    // PARAM STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Gyro 2-CLP pool params.
    /// @custom:field name - The name of the pool.
    /// @custom:field symbol - The symbol of the pool.
    /// @custom:field tokens - The tokens of the pool.
    /// @custom:field sqrtAlpha - The square root of the alpha of the pool.
    /// @custom:field sqrtBeta - The square root of the beta of the pool.
    /// @custom:field roleAccounts - The role accounts of the pool.
    /// @custom:field swapFeePercentage - The swap fee percentage of the pool.
    /// @custom:field poolHooksContract - The contract that implements the hooks for the pool.
    /// @custom:field enableDonation - If true, the pool will support the donation add liquidity mechanism.
    /// @custom:field disableUnbalancedLiquidity - If true, only proportional add and remove liquidity are accepted.
    /// @custom:field jtBalancerPoolStShareShouldPayYieldFees - If true, the ST share in the Balancer pool should pay yield fees.
    /// @custom:field jtBalancerPoolQuoteToken - The quote token of the Balancer pool.
    /// @custom:field jtBalancerPoolQuoteTokenType - The type of the quote token of the Balancer pool.
    /// @custom:field jtBalancerPoolQuoteRateProvider - The rate provider of the quote token of the Balancer pool.
    /// @custom:field jtBalancerPoolQuotePaysYieldFees - If true, the quote token of the Balancer pool should pay yield fees.
    /// @custom:field salt - The salt value that will be passed to deployment.
    struct Gyro2CLPPoolParams {
        string name;
        string symbol;
        uint256 sqrtAlpha;
        uint256 sqrtBeta;
        uint256 swapFeePercentage;
        address poolHooksContract;
        bool enableDonation;
        bool disableUnbalancedLiquidity;
        bool jtBalancerPoolStShareShouldPayYieldFees;
        address jtBalancerPoolQuoteToken;
        BalancerV3TokenType jtBalancerPoolQuoteTokenType;
        IRateProvider jtBalancerPoolQuoteRateProvider;
        bool jtBalancerPoolQuotePaysYieldFees;
        bytes32 salt;
    }

    /// @notice BPT junior tranche params.
    /// @custom:field name - The name of the BPT.
    /// @custom:field symbol - The symbol of the BPT.
    struct BPTJuniorTrancheParams {
        string name;
        string symbol;
    }

    /// @notice Top-level params struct passed to `deployMarket(bytes)`.
    /// @custom:field marketId - The ID of the market.
    /// @custom:field st - The params for the senior tranche.
    /// @custom:field jt - The params for the junior tranche.
    /// @custom:field accountant - The params for the accountant.
    /// @custom:field ydm - The params for the YDM.
    /// @custom:field gyro2CLPPoolParams - The params for the Gyro 2-CLP pool.
    /// @custom:field kernelSpecificParams - The kernel-specific params.
    /// @custom:field enforceVaultSharesTransferWhitelist - If true, the vault shares transfer whitelist is enforced.
    struct DuskBalancerParams {
        bytes32 marketId;
        SeniorTrancheParams st;
        BPTJuniorTrancheParams jt;
        AccountantParams accountant;
        Gyro2CLPPoolParams gyro2CLPPoolParams;
        YDMParams ydm;
        bytes kernelSpecificParams;
        bool enforceVaultSharesTransferWhitelist;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error INVALID_ACCESS_MANAGER();
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
    error INVALID_QUOTE_ASSET_ON_KERNEL();
    error INVALID_ENTRY_POINT_TRANCHE_CONFIG();
    /// @notice Thrown when the supplied pool is not registered with the Balancer V3 Vault.
    error POOL_NOT_REGISTERED_WITH_VAULT();
    /// @notice Thrown when the pool's hooks contract doesn't match the one this template deployed.
    error POOL_HOOKS_MISMATCH(address expected, address actual);
    /// @notice Thrown when the pool's token set doesn't match `[ST_PROXY, quoteAsset]` (any order).
    error POOL_TOKEN_CONFIGURATION_MISMATCH();

    // The dummy hooks contract implementation that will be replaced by the actual hooks contract.
    RoycoDuskBalancerV3HooksStub public immutable HOOKS_STUB;

    // The factory for the Balancer V3 pool.
    Gyro2CLPPoolFactory public immutable BALANCER_V3_POOL_FACTORY;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTION
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(IRoycoFactory _factory, Gyro2CLPPoolFactory _balancerV3PoolFactory) BaseDeploymentTemplate(_factory) {
        // Deploy the dummy hooks contract implementation.
        HOOKS_STUB = new RoycoDuskBalancerV3HooksStub();

        // Set the factory for the Balancer V3 pool.
        BALANCER_V3_POOL_FACTORY = _balancerV3PoolFactory;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PER-KERNEL HOOKS (subclasses override)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Returns the SSTORE2 component ID that holds this kernel's creation code.
    function _kernelComponentId() internal pure virtual returns (bytes32);

    /// @dev Returns the ABI-encoded kernel `initialize(...)` calldata. Subclasses use
    ///      `abi.encodeCall(ConcreteKernel.initialize, (kip, ...kernel-specific extras))`.
    function _kernelInitData(
        IRoycoDuskKernel.RoycoDuskKernelInitParams memory _kip,
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
    function validateParams(bytes calldata _params) external pure override(IRoycoProtocolTemplate) {
        DuskBalancerParams memory p = abi.decode(_params, (DuskBalancerParams));
        require(p.marketId != bytes32(0), INVALID_PARAMS());
        require(bytes(p.st.name).length > 0, INVALID_PARAMS());
        require(bytes(p.st.symbol).length > 0, INVALID_PARAMS());
        require(p.st.asset != address(0), INVALID_PARAMS());
        require(bytes(p.jt.name).length > 0, INVALID_PARAMS());
        require(bytes(p.jt.symbol).length > 0, INVALID_PARAMS());
        require(p.quoteAsset != address(0), INVALID_PARAMS());
        require(p.balancerPool != address(0), INVALID_PARAMS());
        require(p.ydm.componentTag != bytes32(0), INVALID_PARAMS());
        require(p.ydm.version != bytes32(0), INVALID_PARAMS());
        require(p.accountant.ydmInitializationData.length > 0, INVALID_PARAMS());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IRoycoProtocolTemplate
    function deployMarket(bytes calldata _params) external override(IRoycoProtocolTemplate) onlyRoycoFactory returns (DeploymentResult memory result) {
        DuskBalancerParams memory p = abi.decode(_params, (DuskBalancerParams));

        // Predict the 4 market proxy addresses.
        bytes32 stProxySalt = _marketComponentSalt(p.marketId, "ST");
        bytes32 jtProxySalt = _marketComponentSalt(p.marketId, "JT");
        bytes32 kernelProxySalt = _marketComponentSalt(p.marketId, "KERNEL");
        bytes32 accountantProxySalt = _marketComponentSalt(p.marketId, "ACCOUNTANT");

        result.seniorTranche = ROYCO_FACTORY.predictDeterministicAddress(stProxySalt);
        result.juniorTranche = ROYCO_FACTORY.predictDeterministicAddress(jtProxySalt);
        result.kernel = ROYCO_FACTORY.predictDeterministicAddress(kernelProxySalt);
        result.accountant = ROYCO_FACTORY.predictDeterministicAddress(accountantProxySalt);

        // Deploy YDM (idempotent across templates).
        (result.ydm,) = _deployYDM(p.ydm);

        // Deploy ST impl + proxy first — the pool needs ST_PROXY at its registered tokens
        //    (the caller already created the pool with the predicted ST_PROXY address).
        address stImpl = _deploySeniorTrancheImpl(p.st.asset, result.kernel, _marketComponentSalt(p.marketId, "ST_IMPL"));
        _deployProxy(stImpl, _encodeTrancheInitData(p.st.name, p.st.symbol), stProxySalt);

        // Deploy the Balancer V3 Hooks contract with a dummy implementation that will be replaced by the actual hooks contract.
        _deployProxy(address(HOOKS_STUB), "", _marketComponentSalt(p.marketId, "HOOKS"));

        // Deploy the Gyro 2-CLP pool.
        BalancerV3TokenConfig[] memory tokens = new BalancerV3TokenConfig[](2);
        tokens[0] = BalancerV3TokenConfig({
            token: result.seniorTranche,
            tokenType: BalancerV3TokenType.WITH_RATE,
            // TODO: Deploy the rate provider
            rateProvider: address(0),
            paysYieldFees: p.gyro2CLPPoolParams.jtBalancerPoolStShareShouldPayYieldFees
        });
        tokens[1] = BalancerV3TokenConfig({
            token: p.jtBalancerPoolQuoteToken,
            tokenType: p.jtBalancerPoolQuoteTokenType,
            rateProvider: p.jtBalancerPoolQuoteRateProvider,
            paysYieldFees: p.jtBalancerPoolQuotePaysYieldFees
        });


        address gyro2CLPPool = BALANCER_V3_POOL_FACTORY.create(
            p.gyro2CLPPoolParams.name,
            p.gyro2CLPPoolParams.symbol,
            p.gyro2CLPPoolParams.tokens,
            p.gyro2CLPPoolParams.sqrtAlpha,
            p.gyro2CLPPoolParams.sqrtBeta,
        );

        // // 5. Verify the pre-deployed pool matches what this market expects.
        // _assertPoolWiredCorrectly(p.balancerPool, result.seniorTranche, p.quoteAsset, hooks);

        // // 6. JT asset = the pool. Deploy JT impl (with pool baked as immutable asset) + proxy.
        // address jtImpl = _deployJuniorTrancheImpl(p.balancerPool, result.kernel, _marketComponentSalt(p.marketId, "JT_IMPL"));
        // _deployProxy(jtImpl, _encodeTrancheInitData(p.jt.name, p.jt.symbol), jtProxySalt);

        // // 7. Deploy accountant impl + proxy.
        // address accountantImpl = _deployAccountantImpl(result.kernel, _marketComponentSalt(p.marketId, "ACCOUNTANT_IMPL"));
        // _deployProxy(accountantImpl, _encodeAccountantInitData(p.accountant, result.ydm), accountantProxySalt);

        // // 8. Deploy kernel impl + proxy.
        // {
        //     IRoycoDuskKernel.RoycoDuskKernelConstructionParams memory cp = IRoycoDuskKernel.RoycoDuskKernelConstructionParams({
        //         dawnKernelParams: IRoycoDawnKernel.RoycoDawnKernelConstructionParams({
        //             seniorTranche: result.seniorTranche,
        //             stAsset: p.st.asset,
        //             juniorTranche: result.juniorTranche,
        //             jtAsset: p.balancerPool,
        //             accountant: result.accountant,
        //             enforceVaultSharesTransferWhitelist: p.enforceVaultSharesTransferWhitelist
        //         }),
        //         quoteAsset: p.quoteAsset
        //     });
        //     address kernelImpl = _deployImpl(_kernelComponentId(), abi.encode(cp), _marketComponentSalt(p.marketId, "KERNEL_IMPL"));

        //     IRoycoDuskKernel.RoycoDuskKernelInitParams memory kip = IRoycoDuskKernel.RoycoDuskKernelInitParams({
        //         dawnKernelInitParams: IRoycoDawnKernel.RoycoDawnKernelInitParams({
        //             initialAuthority: ROYCO_FACTORY.ROYCO_AUTHORITY(),
        //             protocolFeeRecipient: address(0), // Subclasses can override via _kernelInitData if they need it
        //             stSelfLiquidationBonusWAD: 0
        //         })
        //     });
        //     _deployProxy(kernelImpl, _kernelInitData(kip, p.kernelSpecificParams), kernelProxySalt);
        // }

        // // 9. Apply selector→role bindings + post-init grants. Concrete templates can override
        // //    `_buildRoleBindings` to add more.
        // _applyRoleBindings(_buildRoleBindings(result));

        // // 10. (Optional) Configure the entry point's tranche configs for the new ST/JT.
        // if (p.entryPoint != address(0)) {
        //     address[] memory tranches = new address[](2);
        //     tranches[0] = result.seniorTranche;
        //     tranches[1] = result.juniorTranche;
        //     IRoycoEntryPoint.TrancheConfig[] memory configs = new IRoycoEntryPoint.TrancheConfig[](2);
        //     configs[0] = p.stEntryPointConfig;
        //     configs[1] = p.jtEntryPointConfig;
        //     ROYCO_FACTORY.executeAsFactory(p.entryPoint, abi.encodeCall(IRoycoEntryPoint.modifyTrancheConfigs, (tranches, configs)));
        // }

        // // Encode `(pool, hooks, entryPoint, stCfg, jtCfg)` in extras for downstream consumers
        // // and for `verify()` to read back.
        // result.extras = abi.encode(p.balancerPool, hooks, p.entryPoint, p.stEntryPointConfig, p.jtEntryPointConfig);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VERIFY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IRoycoProtocolTemplate
    function verify(DeploymentResult calldata _d) external view override(IRoycoProtocolTemplate) {
        address expectedAuthority = ROYCO_FACTORY.ROYCO_AUTHORITY();
        require(AccessManagedUpgradeable(_d.accountant).authority() == expectedAuthority, INVALID_ACCESS_MANAGER());
        require(AccessManagedUpgradeable(_d.kernel).authority() == expectedAuthority, INVALID_ACCESS_MANAGER());
        require(AccessManagedUpgradeable(_d.seniorTranche).authority() == expectedAuthority, INVALID_ACCESS_MANAGER());
        require(AccessManagedUpgradeable(_d.juniorTranche).authority() == expectedAuthority, INVALID_ACCESS_MANAGER());

        require(IRoycoVaultTranche(_d.seniorTranche).TRANCHE_TYPE() == TrancheType.SENIOR, INVALID_TRANCHE_TYPE_ON_SENIOR_TRANCHE());
        require(IRoycoVaultTranche(_d.juniorTranche).TRANCHE_TYPE() == TrancheType.JUNIOR, INVALID_TRANCHE_TYPE_ON_JUNIOR_TRANCHE());
        require(address(IRoycoVaultTranche(_d.seniorTranche).KERNEL()) == _d.kernel, INVALID_KERNEL_ON_SENIOR_TRANCHE());
        require(address(IRoycoVaultTranche(_d.juniorTranche).KERNEL()) == _d.kernel, INVALID_KERNEL_ON_JUNIOR_TRANCHE());

        IRoycoDuskKernel kernel = IRoycoDuskKernel(_d.kernel);
        require(kernel.SENIOR_TRANCHE() == _d.seniorTranche, INVALID_SENIOR_TRANCHE_ON_KERNEL());
        require(kernel.JUNIOR_TRANCHE() == _d.juniorTranche, INVALID_JUNIOR_TRANCHE_ON_KERNEL());
        require(kernel.ST_ASSET() == IRoycoVaultTranche(_d.seniorTranche).asset(), INVALID_ST_ASSET_ON_KERNEL());
        require(kernel.JT_ASSET() == IRoycoVaultTranche(_d.juniorTranche).asset(), INVALID_JT_ASSET_ON_KERNEL());
        require(kernel.ACCOUNTANT() == _d.accountant, INVALID_ACCOUNTANT_ON_KERNEL());

        require(address(IRoycoAccountant(_d.accountant).KERNEL()) == _d.kernel, INVALID_KERNEL_ON_ACCOUNTANT());

        (address pool, address hooks, address entryPoint, IRoycoEntryPoint.TrancheConfig memory stCfg, IRoycoEntryPoint.TrancheConfig memory jtCfg) =
            abi.decode(_d.extras, (address, address, address, IRoycoEntryPoint.TrancheConfig, IRoycoEntryPoint.TrancheConfig));
        require(kernel.JT_ASSET() == pool, INVALID_JT_ASSET_ON_KERNEL());
        _assertPoolWiredCorrectly(pool, _d.seniorTranche, kernel.QUOTE_ASSET(), hooks);

        if (entryPoint != address(0)) {
            _assertEntryPointConfig(entryPoint, _d.seniorTranche, stCfg);
            _assertEntryPointConfig(entryPoint, _d.juniorTranche, jtCfg);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ROLE BINDINGS (overridable by concrete kernel templates)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Returns the full role-binding set applied to the freshly-deployed market contracts.
     * @dev Same shape as Dawn. Concrete subclasses override `_extraRoleBindings` to append
     *      kernel-specific extras (e.g. additional oracle quoter setters).
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

    /// @dev Override in concrete kernel templates to append extra bindings + grants. Default empty.
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
        // Standard Dusk kernel binding set. Concrete kernel templates that expose extra
        // oracle/quoter selectors should add them via `_extraRoleBindings`.
        bytes4[] memory s = new bytes4[](7);
        uint64[] memory r = new uint64[](7);
        s[0] = IRoycoDawnKernel.setProtocolFeeRecipient.selector;
        r[0] = ADMIN_KERNEL_ROLE;
        s[1] = IRoycoAuth.pause.selector;
        r[1] = ADMIN_PAUSER_ROLE;
        s[2] = IRoycoAuth.unpause.selector;
        r[2] = ADMIN_UNPAUSER_ROLE;
        s[3] = UUPSUpgradeable.upgradeToAndCall.selector;
        r[3] = ADMIN_UPGRADER_ROLE;
        s[4] = IRoycoDawnKernel.syncTrancheAccounting.selector;
        r[4] = SYNC_ROLE;
        s[5] = IRoycoDawnKernel.setSeniorTrancheSelfLiquidationBonus.selector;
        r[5] = ADMIN_KERNEL_ROLE;
        s[6] = IRoycoDawnKernel.blacklistAccounts.selector;
        r[6] = TRANSFER_AGENT_ROLE;
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

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Asserts the Balancer V3 pool is registered with the Vault, has tokens
    ///      `{ST_PROXY, quoteAsset}` (any order), and is bound to `_expectedHooks`.
    function _assertPoolWiredCorrectly(address _pool, address _stProxy, address _quoteAsset, address _expectedHooks) internal view {
        IVault vault = BalancerPoolToken(_pool).getVault();
        require(vault.isPoolRegistered(_pool), POOL_NOT_REGISTERED_WITH_VAULT());

        address[] memory tokens;
        {
            IERC20[] memory ierc20Tokens = vault.getPoolTokens(_pool);
            tokens = new address[](ierc20Tokens.length);
            for (uint256 i; i < ierc20Tokens.length; ++i) {
                tokens[i] = address(ierc20Tokens[i]);
            }
        }
        require(tokens.length == 2, POOL_TOKEN_CONFIGURATION_MISMATCH());
        bool match0 = tokens[0] == _stProxy && tokens[1] == _quoteAsset;
        bool match1 = tokens[0] == _quoteAsset && tokens[1] == _stProxy;
        require(match0 || match1, POOL_TOKEN_CONFIGURATION_MISMATCH());

        HooksConfig memory hooksConfig = vault.getHooksConfig(_pool);
        require(hooksConfig.hooksContract == _expectedHooks, POOL_HOOKS_MISMATCH(_expectedHooks, hooksConfig.hooksContract));
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
