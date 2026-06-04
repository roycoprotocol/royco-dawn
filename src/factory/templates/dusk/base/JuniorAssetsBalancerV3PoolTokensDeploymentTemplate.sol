// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IGyroECLPPool } from "../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/pool-gyro/IGyroECLPPool.sol";
import { IRateProvider } from "../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { IProtocolFeeController } from "../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IProtocolFeeController.sol";
import { IVault } from "../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { IVaultAdmin } from "../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultAdmin.sol";
import {
    HooksConfig as BalancerV3HooksConfig,
    PoolRoleAccounts as BalancerV3PoolRoleAccounts,
    TokenConfig as BalancerV3TokenConfig,
    TokenType as BalancerV3TokenType
} from "../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { GyroECLPPoolFactory } from "../../../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
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
import { ConstituentTokenType } from "../../../../kernels/base/quoter/dusk/junior-assets/liquidity-position/balancer-v3/RoycoDuskRateProvider.sol";
import { TrancheType } from "../../../../libraries/Types.sol";
import {
    ADMIN_ACCOUNTANT_ROLE,
    ADMIN_BALANCER_POOL_MANAGER_ROLE,
    ADMIN_KERNEL_ROLE,
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
import { COMPONENT_ID_DUSK_BALANCER_HOOKS, COMPONENT_ID_DUSK_BALANCER_RATE_PROVIDER } from "../../Components.sol";
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

    /// @notice Gyro E-CLP pool params.
    struct GyroECLPPoolParams {
        string name;
        string symbol;
        IGyroECLPPool.EclpParams eclpParams;
        IGyroECLPPool.DerivedEclpParams derivedEclpParams;
        uint256 swapFeePercentage;
        bool enableDonation;
        bool disableUnbalancedLiquidity;
        bool jtBalancerPoolStShareShouldPayYieldFees;
        address jtBalancerPoolQuoteToken;
        bool jtBalancerPoolQuotePaysYieldFees;
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
    /// @custom:field gyroECLPPoolParams - The params for the Gyro E-CLP pool.
    /// @custom:field kernelSpecificParams - The kernel-specific params.
    /// @custom:field protocolFeeRecipient - The protocol fee recipient.
    /// @custom:field stSelfLiquidationBonusWAD - The senior tranche self-liquidation bonus WAD.
    /// @custom:field enforceVaultSharesTransferWhitelist - If true, the vault shares transfer whitelist is enforced.
    struct DuskBalancerParams {
        bytes32 marketId;
        SeniorTrancheParams st;
        BPTJuniorTrancheParams jt;
        AccountantParams accountant;
        GyroECLPPoolParams gyroECLPPoolParams;
        YDMParams ydm;
        address protocolFeeRecipient;
        uint64 stSelfLiquidationBonusWAD;
        bytes kernelSpecificParams;
        bool enforceVaultSharesTransferWhitelist;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // RESULT
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The result of the extra contracts deployed.
    /// @custom:field seniorTrancheShareRateProvider - The address of the senior tranche share rate provider.
    /// @custom:field quoteAssetRateProvider - The address of the quote asset rate provider.
    /// @custom:field balancerPoolHooks - The address of the Balancer V3 pool hooks contract.
    struct ExtraContractsDeployedResult {
        address seniorTrancheShareRateProvider;
        address quoteAssetRateProvider;
        address balancerPoolHooks;
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

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The salt tag for the senior tranche share rate provider.
    bytes32 private constant SENIOR_TRANCHE_SHARE_RATE_PROVIDER_SALT_SUFFIX = bytes32("ST_SHARE_RATE_PROVIDER");
    /// @notice The salt tag for the quote asset rate provider.
    bytes32 private constant QUOTE_ASSET_RATE_PROVIDER_SALT_SUFFIX = bytes32("QUOTE_ASSET_RATE_PROVIDER");

    // ═══════════════════════════════════════════════════════════════════════════
    // IMMUTABLES
    // ═══════════════════════════════════════════════════════════════════════════

    // The dummy hooks contract implementation that will be replaced by the actual hooks contract.
    RoycoDuskBalancerV3HooksStub public immutable HOOKS_STUB;

    // The factory for the Balancer V3 pool.
    GyroECLPPoolFactory public immutable BALANCER_V3_POOL_FACTORY;

    // The vault for the Balancer V3 pool.
    IVault public immutable BALANCER_V3_VAULT;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTION
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(IRoycoFactory _factory, GyroECLPPoolFactory _balancerV3PoolFactory) BaseDeploymentTemplate(_factory) {
        // Wire the Balancer V3 pool factory + vault.
        BALANCER_V3_POOL_FACTORY = _balancerV3PoolFactory;
        BALANCER_V3_VAULT = IVault(address(_balancerV3PoolFactory.getVault()));

        // Deploy the dummy hooks impl. The hooks proxy points here during pool registration
        // (when the kernel doesn't exist yet) and gets upgraded to the real hooks impl after
        // the kernel is live. The stub takes no constructor args — it has no vault binding.
        HOOKS_STUB = new RoycoDuskBalancerV3HooksStub();
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
        require(p.gyroECLPPoolParams.jtBalancerPoolQuoteToken != address(0), INVALID_PARAMS());
        require(p.protocolFeeRecipient != address(0), INVALID_PARAMS());
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
        ExtraContractsDeployedResult memory dusk;
        address balancerPool;

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

        // Deploy the hooks proxy (initial impl = stub) + the Balancer V3 pool. The pool needs the
        // hooks proxy to be live before pool.create() is called, since the pool factory bakes
        // the hooks address into the pool's config.
        (balancerPool, dusk.balancerPoolHooks, dusk.seniorTrancheShareRateProvider, dusk.quoteAssetRateProvider) =
            _deployBalancerV3Pool(p.gyroECLPPoolParams, p.marketId, result.seniorTranche);

        // JT asset = the pool. Deploy JT impl (with pool baked as immutable asset) + proxy.
        address jtImpl = _deployJuniorTrancheImpl(balancerPool, result.kernel, _marketComponentSalt(p.marketId, "JT_IMPL"));
        _deployProxy(jtImpl, _encodeTrancheInitData(p.jt.name, p.jt.symbol), jtProxySalt);

        // Deploy accountant impl + proxy.
        address accountantImpl = _deployAccountantImpl(result.kernel, _marketComponentSalt(p.marketId, "ACCOUNTANT_IMPL"));
        _deployProxy(accountantImpl, _encodeAccountantInitData(p.accountant, result.ydm), accountantProxySalt);

        // Deploy kernel impl + proxy. Hoisted into a helper to limit local-variable count
        _deployKernelImplAndProxy(p, result, balancerPool, kernelProxySalt);

        // Now that the kernel is live, deploy the rate providers + upgrade the hooks proxy from
        // the stub to the real hooks impl.
        _deployBalancerV3PeripheralContracts(p.marketId, result.kernel, dusk.balancerPoolHooks);

        // Verify the pool's wiring lines up with what we built.
        _assertPoolWiredCorrectly(balancerPool, result.seniorTranche, p.gyroECLPPoolParams.jtBalancerPoolQuoteToken, dusk.balancerPoolHooks);

        // Apply selector→role bindings + post-init grants.
        _applyRoleBindings(_buildRoleBindings(result));

        // Encode `(pool, ExtraContractsDeployedResult)` in extras so downstream consumers + `verify()` can read.
        result.extras = abi.encode(balancerPool, dusk);
    }

    /// @notice Deploys the hooks PROXY (initial impl = stub) + the rate-provider-bearing Gyro 2-CLP pool.
    function _deployKernelImplAndProxy(
        DuskBalancerParams memory _p,
        DeploymentResult memory _result,
        address _balancerPool,
        bytes32 _kernelProxySalt
    )
        internal
    {
        IRoycoDuskKernel.RoycoDuskKernelConstructionParams memory cp = IRoycoDuskKernel.RoycoDuskKernelConstructionParams({
            dawnKernelParams: IRoycoDawnKernel.RoycoDawnKernelConstructionParams({
                seniorTranche: _result.seniorTranche,
                stAsset: _p.st.asset,
                juniorTranche: _result.juniorTranche,
                jtAsset: _balancerPool,
                accountant: _result.accountant,
                enforceVaultSharesTransferWhitelist: _p.enforceVaultSharesTransferWhitelist
            }),
            quoteAsset: _p.gyroECLPPoolParams.jtBalancerPoolQuoteToken
        });
        address kernelImpl = _deployImpl(_kernelComponentId(), abi.encode(cp), _marketComponentSalt(_p.marketId, "KERNEL_IMPL"));

        IRoycoDuskKernel.RoycoDuskKernelInitParams memory kip = IRoycoDuskKernel.RoycoDuskKernelInitParams({
            dawnKernelInitParams: IRoycoDawnKernel.RoycoDawnKernelInitParams({
                initialAuthority: ROYCO_FACTORY.ROYCO_AUTHORITY(),
                protocolFeeRecipient: _p.protocolFeeRecipient,
                stSelfLiquidationBonusWAD: _p.stSelfLiquidationBonusWAD
            })
        });
        _deployProxy(kernelImpl, _kernelInitData(kip, _p.kernelSpecificParams), _kernelProxySalt);
    }

    function _deployBalancerV3Pool(
        GyroECLPPoolParams memory _gyroECLPPoolParams,
        bytes32 _marketId,
        address _seniorTranche
    )
        internal
        returns (address balancerV3Pool, address balancerPoolHooks, address seniorTrancheShareRateProvider, address quoteAssetRateProvider)
    {
        // Predict the rate-provider proxy addresses (deployed later in the peripheral step).
        seniorTrancheShareRateProvider =
            ROYCO_FACTORY.predictDeterministicAddress(_marketComponentSalt(_marketId, SENIOR_TRANCHE_SHARE_RATE_PROVIDER_SALT_SUFFIX));
        quoteAssetRateProvider = ROYCO_FACTORY.predictDeterministicAddress(_marketComponentSalt(_marketId, QUOTE_ASSET_RATE_PROVIDER_SALT_SUFFIX));

        // Deploy the hooks PROXY. Initial impl is the stub; we upgrade to the real hooks impl
        // once the kernel address is known. Empty init data: the stub is stateless and has no
        // `initialize` — leaves the Initializable version slot at 0 so the real hooks impl can
        // claim version 1 with the standard `initializer` modifier after `upgradeToAndCall`.
        balancerPoolHooks = _deployProxy(
            address(HOOKS_STUB),
            abi.encodeCall(RoycoDuskBalancerV3HooksStub.initialize, (ROYCO_FACTORY.ROYCO_AUTHORITY())),
            _marketComponentSalt(_marketId, "BALANCER_V3_POOL_HOOKS")
        );

        // Prepare the token configs. Balancer's struct types `token` as `IERC20` and `rateProvider`
        // as `IRateProvider` — cast our address vars accordingly.
        BalancerV3TokenConfig[] memory tokens = new BalancerV3TokenConfig[](2);
        tokens[0] = BalancerV3TokenConfig({
            token: IERC20(_seniorTranche),
            tokenType: BalancerV3TokenType.WITH_RATE,
            rateProvider: IRateProvider(seniorTrancheShareRateProvider),
            paysYieldFees: _gyroECLPPoolParams.jtBalancerPoolStShareShouldPayYieldFees
        });
        tokens[1] = BalancerV3TokenConfig({
            token: IERC20(_gyroECLPPoolParams.jtBalancerPoolQuoteToken),
            tokenType: BalancerV3TokenType.WITH_RATE,
            rateProvider: IRateProvider(quoteAssetRateProvider),
            paysYieldFees: _gyroECLPPoolParams.jtBalancerPoolQuotePaysYieldFees
        });

        // Hand off to a helper for the factory.create call - keeps the ECLP-encoding stack
        // pressure isolated from the rest of `_deployBalancerV3Pool` (Solidity's via_ir was
        // tripping on stack depth otherwise).
        balancerV3Pool = _createBalancerV3Pool(_gyroECLPPoolParams, tokens, balancerPoolHooks, _marketComponentSalt(_marketId, "BALANCER_V3_POOL"));
    }

    /// @dev Pure-create wrapper around `BALANCER_V3_POOL_FACTORY.create` that takes a pre-built
    ///      tokens array + the already-deployed hooks proxy. Isolates the 11-argument create
    ///      call so the encoding of the nested ECLP / DerivedECLP / RoleAccounts structs doesn't
    ///      blow the stack of the larger `_deployBalancerV3Pool` function.
    /// @dev Helper for `_deployBalancerV3PeripheralContracts`. Pulled out as its own function
    ///      so the encode-and-deploy stack frame is isolated and via_ir doesn't blow up.
    function _deployRateProvider(address _kernelAddress, ConstituentTokenType _tokenType, bytes32 _salt) internal {
        _deployImpl(COMPONENT_ID_DUSK_BALANCER_RATE_PROVIDER, abi.encode(_kernelAddress, _tokenType), _salt);
    }

    function _createBalancerV3Pool(
        GyroECLPPoolParams memory _gyroECLPPoolParams,
        BalancerV3TokenConfig[] memory _tokens,
        address _balancerPoolHooks,
        bytes32 _salt
    )
        internal
        returns (address balancerV3Pool)
    {
        address authority = ROYCO_FACTORY.ROYCO_AUTHORITY();
        BalancerV3PoolRoleAccounts memory roleAccounts =
            BalancerV3PoolRoleAccounts({ pauseManager: authority, swapFeeManager: authority, poolCreator: authority });
        balancerV3Pool = BALANCER_V3_POOL_FACTORY.create(
            _gyroECLPPoolParams.name,
            _gyroECLPPoolParams.symbol,
            _tokens,
            _gyroECLPPoolParams.eclpParams,
            _gyroECLPPoolParams.derivedEclpParams,
            roleAccounts,
            _gyroECLPPoolParams.swapFeePercentage,
            _balancerPoolHooks,
            _gyroECLPPoolParams.enableDonation,
            _gyroECLPPoolParams.disableUnbalancedLiquidity,
            _salt
        );
    }

    /**
     * @notice Deploys the Balancer V3 rate-provider proxies (one for the ST share, one for the
     *         quote asset) and upgrades the hooks proxy from the stub to the real hooks impl.
     * @dev Called after the kernel is live — both the rate providers and the real hooks impl
     *      take the kernel address as a constructor arg.
     */
    function _deployBalancerV3PeripheralContracts(bytes32 _marketId, address _kernelAddress, address _balancerPoolHooksProxy) internal {
        address authority = ROYCO_FACTORY.ROYCO_AUTHORITY();

        // Senior-tranche + quote rate providers deployed directly via CREATE3 at the previously-
        // predicted addresses. Helpers isolate the encode-and-deploy stack frame.
        _deployRateProvider(
            _kernelAddress, ConstituentTokenType.SENIOR_TRANCHE_SHARE, _marketComponentSalt(_marketId, SENIOR_TRANCHE_SHARE_RATE_PROVIDER_SALT_SUFFIX)
        );
        _deployRateProvider(_kernelAddress, ConstituentTokenType.QUOTE_ASSET, _marketComponentSalt(_marketId, QUOTE_ASSET_RATE_PROVIDER_SALT_SUFFIX));

        // Deploy the real hooks impl (knows the kernel address) and upgrade the live hooks
        // proxy to point at it. `upgradeToAndCall` re-runs `initialize` on the new impl.
        address balancerPoolHooksImpl = _deployImpl(
            COMPONENT_ID_DUSK_BALANCER_HOOKS, abi.encode(BALANCER_V3_VAULT, _kernelAddress), _marketComponentSalt(_marketId, "BALANCER_POOL_HOOKS_IMPL")
        );
        UUPSUpgradeable(_balancerPoolHooksProxy).upgradeToAndCall(balancerPoolHooksImpl, abi.encodeCall(RoycoDuskBalancerV3HooksStub.initialize, (authority)));
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

        // Decode the Dusk-specific addresses from `extras` and re-assert the Balancer wiring.
        (address pool, ExtraContractsDeployedResult memory dusk) = abi.decode(_d.extras, (address, ExtraContractsDeployedResult));
        require(kernel.JT_ASSET() == pool, INVALID_JT_ASSET_ON_KERNEL());
        _assertPoolWiredCorrectly(pool, _d.seniorTranche, kernel.QUOTE_ASSET(), dusk.balancerPoolHooks);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ROLE BINDINGS (overridable by concrete kernel templates)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Returns the full role-binding set applied to the freshly-deployed market contracts.
     * @dev Same shape as Dawn. Concrete subclasses override `_extraRoleBindings` to append
     *      kernel-specific extras (e.g. additional oracle quoter setters).
     */
    function _buildRoleBindings(DeploymentResult memory _r) internal view virtual returns (RoleBindings memory) {
        (TargetBinding[] memory extraTargets, RoleGrant[] memory extraGrants) = _extraRoleBindings(_r);

        // 4 standard market targets (ST/JT/kernel/accountant) + 2 Balancer targets (Vault +
        // ProtocolFeeController) + any concrete-kernel extras. The Balancer bindings route their
        // gated functions through `AM.execute(target, data)` — Royco's AM is the `pauseManager`
        // / `swapFeeManager` / `poolCreator` on the pool, so when AM forwards a call it appears
        // to the Vault / FeeController as the registered role account.
        TargetBinding[] memory targets = new TargetBinding[](6 + extraTargets.length);
        targets[0] = _trancheBinding(_r.seniorTranche, ST_LP_ROLE);
        targets[1] = _trancheBinding(_r.juniorTranche, JT_LP_ROLE);
        targets[2] = _kernelBinding(_r.kernel);
        targets[3] = _accountantBinding(_r.accountant);
        targets[4] = _balancerVaultBinding(address(BALANCER_V3_VAULT));
        targets[5] = _balancerProtocolFeeControllerBinding(address(BALANCER_V3_VAULT.getProtocolFeeController()));
        for (uint256 i; i < extraTargets.length; ++i) {
            targets[6 + i] = extraTargets[i];
        }

        RoleGrant[] memory grants = new RoleGrant[](1 + extraGrants.length);
        grants[0] = RoleGrant({ roleId: SYNC_ROLE, account: _r.accountant, executionDelay: 0 });
        for (uint256 i; i < extraGrants.length; ++i) {
            grants[1 + i] = extraGrants[i];
        }

        return RoleBindings({ targetBindings: targets, postInitGrants: grants });
    }

    /// @dev Binds the Balancer Vault's pool-admin selectors to Royco roles. AM is the
    ///      `pauseManager` + `swapFeeManager` on the pool; role holders invoke via `AM.execute`.
    function _balancerVaultBinding(address _vault) private pure returns (TargetBinding memory) {
        bytes4[] memory s = new bytes4[](3);
        uint64[] memory r = new uint64[](3);
        s[0] = IVaultAdmin.pausePool.selector;
        r[0] = ADMIN_PAUSER_ROLE;
        s[1] = IVaultAdmin.unpausePool.selector;
        r[1] = ADMIN_UNPAUSER_ROLE;
        s[2] = IVaultAdmin.setStaticSwapFeePercentage.selector;
        r[2] = ADMIN_BALANCER_POOL_MANAGER_ROLE;
        return TargetBinding({ target: _vault, selectors: s, roleIds: r });
    }

    /// @dev Binds the Balancer ProtocolFeeController's pool-creator selectors to the pool-manager
    ///      role. AM is the `poolCreator` on the pool; role holders invoke via `AM.execute`.
    function _balancerProtocolFeeControllerBinding(address _feeController) private pure returns (TargetBinding memory) {
        bytes4[] memory s = new bytes4[](3);
        uint64[] memory r = new uint64[](3);
        s[0] = IProtocolFeeController.setPoolCreatorSwapFeePercentage.selector;
        r[0] = ADMIN_BALANCER_POOL_MANAGER_ROLE;
        s[1] = IProtocolFeeController.setPoolCreatorYieldFeePercentage.selector;
        r[1] = ADMIN_BALANCER_POOL_MANAGER_ROLE;
        // The two-arg `withdrawPoolCreatorFees(address pool, address recipient)` variant. The
        // permissionless no-recipient overload doesn't need an explicit binding since anyone
        // can call it and funds always go to the registered poolCreator.
        s[2] = bytes4(keccak256("withdrawPoolCreatorFees(address,address)"));
        r[2] = ADMIN_BALANCER_POOL_MANAGER_ROLE;
        return TargetBinding({ target: _feeController, selectors: s, roleIds: r });
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

        BalancerV3HooksConfig memory hooksConfig = vault.getHooksConfig(_pool);
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
