// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { HooksConfig } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { BalancerPoolToken } from "../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/BalancerPoolToken.sol";
import { AccessManagedUpgradeable } from "../../../../lib/openzeppelin-contracts-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";
import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IRoycoAccountant } from "../../../interfaces/IRoycoAccountant.sol";
import { IRoycoDawnKernel } from "../../../interfaces/IRoycoDawnKernel.sol";
import { IRoycoDuskKernel } from "../../../interfaces/IRoycoDuskKernel.sol";
import { IRoycoEntryPoint } from "../../../interfaces/IRoycoEntryPoint.sol";
import { IRoycoVaultTranche } from "../../../interfaces/IRoycoVaultTranche.sol";
import { IRoycoFactory } from "../../../interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../../interfaces/factory/IRoycoProtocolTemplate.sol";
import { TrancheType } from "../../../libraries/Types.sol";
import { BaseDeploymentTemplate } from "../BaseDeploymentTemplate.sol";
import { COMPONENT_ID_DUSK_BALANCER_HOOKS, COMPONENT_ID_DUSK_BALANCER_KERNEL } from "../Components.sol";

/**
 * @title JuniorAssetsBalancerV3PoolTokensDeploymentTemplate
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Dusk-Balancer market template — deploys a Royco Dusk market whose JT asset is a
 *         Balancer V3 pool BPT (ST share ↔ quote asset).
 */
contract JuniorAssetsBalancerV3PoolTokensDeploymentTemplate is BaseDeploymentTemplate {
    // ═══════════════════════════════════════════════════════════════════════════
    // PARAM STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Kernel-level params for a Dusk-Balancer market.
     * @custom:field initCalldata - Full ABI-encoded `kernel.initialize(...)` calldata
     *        produced by the caller. Different concrete kernel variants have different
     *        initialize signatures (quote-asset oracle config, etc.) — keeping this opaque
     *        lets the template avoid hardcoding a specific concrete kernel.
     * @custom:field enforceVaultSharesTransferWhitelist - Standard flag forwarded into the
     *        `RoycoDawnKernelConstructionParams`.
     */
    struct DuskBalancerKernelParams {
        bytes initCalldata;
        bool enforceVaultSharesTransferWhitelist;
    }

    /**
     * @notice Hooks-contract params.
     * @custom:field ctorArgs - ABI-encoded constructor args for the hooks contract.
     *        Template-agnostic — the template treats hooks bytecode as opaque.
     */
    struct HooksParams {
        bytes ctorArgs;
    }

    /// @notice Top-level params struct passed to `deployMarket(bytes)`.
    /// @custom:field jt - The `.asset` field is OVERWRITTEN to the Balancer pool address;
    ///        callers should pass `address(0)`.
    /// @custom:field balancerPool - Pre-deployed Balancer V3 pool. Must be registered with
    ///        the Vault, contain `[ST_PROXY, quoteAsset]` as its two tokens, and reference
    ///        the hooks contract this template will deploy.
    struct DuskBalancerParams {
        bytes32 marketId;
        SeniorTrancheParams st;
        JuniorTrancheParams jt;
        AccountantParams accountant;
        YDMParams ydm;
        DuskBalancerKernelParams kernel;
        HooksParams hooks;
        address balancerPool;
        address quoteAsset;
        RoleBindings roles;
        address entryPoint;
        IRoycoEntryPoint.TrancheConfig stEntryPointConfig;
        IRoycoEntryPoint.TrancheConfig jtEntryPointConfig;
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
    // CONSTRUCTION
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(IRoycoFactory _factory) BaseDeploymentTemplate(_factory) { }

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
        require(p.kernel.initCalldata.length >= 4, INVALID_PARAMS());
        require(p.ydm.componentTag != bytes32(0), INVALID_PARAMS());
        require(p.ydm.version != bytes32(0), INVALID_PARAMS());
        require(p.accountant.ydmInitializationData.length > 0, INVALID_PARAMS());
        // ST ≠ quote asset is enforced inside RoycoDuskKernel's constructor (`QUOTE_ASSET_MUST_NOT_BE_SENIOR_TRANCHE_SHARE`).
        // ST_ASSET ≠ pool is enforced via `TRANCHE_ASSETS_MUST_NOT_BE_IDENTICAL` (the kernel will revert if violated).
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IRoycoProtocolTemplate
    function deployMarket(bytes calldata _params) external override(IRoycoProtocolTemplate) onlyRoycoFactory returns (DeploymentResult memory result) {
        DuskBalancerParams memory p = abi.decode(_params, (DuskBalancerParams));

        // 1. Predict the 4 market proxy addresses.
        bytes32 stProxySalt = _marketComponentSalt(p.marketId, "ST");
        bytes32 jtProxySalt = _marketComponentSalt(p.marketId, "JT");
        bytes32 kernelProxySalt = _marketComponentSalt(p.marketId, "KERNEL");
        bytes32 accountantProxySalt = _marketComponentSalt(p.marketId, "ACCOUNTANT");

        result.seniorTranche = ROYCO_FACTORY.predictDeterministicAddress(stProxySalt);
        result.juniorTranche = ROYCO_FACTORY.predictDeterministicAddress(jtProxySalt);
        result.kernel = ROYCO_FACTORY.predictDeterministicAddress(kernelProxySalt);
        result.accountant = ROYCO_FACTORY.predictDeterministicAddress(accountantProxySalt);

        // 2. Deploy YDM (idempotent across templates).
        (result.ydm,) = _deployYDM(p.ydm);

        // 3. Deploy ST impl + proxy first — the pool needs ST_PROXY at its registered tokens
        //    (the caller already created the pool with the predicted ST_PROXY address).
        address stImpl = _deploySeniorTrancheImpl(p.st.asset, result.kernel, _marketComponentSalt(p.marketId, "ST_IMPL"));
        _deployProxy(stImpl, _encodeTrancheInitData(p.st.name, p.st.symbol), stProxySalt);

        // 4. Deploy the hooks contract via the standard impl helper. The caller computed this
        //    address ahead of time and registered the pool against it; verify it lines up below.
        address hooks = _deployImpl(COMPONENT_ID_DUSK_BALANCER_HOOKS, p.hooks.ctorArgs, _marketComponentSalt(p.marketId, "HOOKS"));

        // 5. Verify the pre-deployed pool matches what this market expects: registered with the
        //    Balancer Vault, paired with `[ST_PROXY, quoteAsset]`, and bound to the hooks we
        //    just deployed.
        _assertPoolWiredCorrectly(p.balancerPool, result.seniorTranche, p.quoteAsset, hooks);

        // 6. JT asset = the pool. Deploy JT impl (with pool baked as immutable asset) + proxy.
        address jtImpl = _deployJuniorTrancheImpl(p.balancerPool, result.kernel, _marketComponentSalt(p.marketId, "JT_IMPL"));
        _deployProxy(jtImpl, _encodeTrancheInitData(p.jt.name, p.jt.symbol), jtProxySalt);

        // 7. Deploy accountant impl + proxy.
        address accountantImpl = _deployAccountantImpl(result.kernel, _marketComponentSalt(p.marketId, "ACCOUNTANT_IMPL"));
        _deployProxy(accountantImpl, _encodeAccountantInitData(p.accountant, result.ydm), accountantProxySalt);

        // 8. Deploy kernel impl + proxy. Kernel ctor reads the pool from the Vault to validate
        //    its token configuration — the pool is live by this point so the read succeeds.
        {
            IRoycoDuskKernel.RoycoDuskKernelConstructionParams memory cp = IRoycoDuskKernel.RoycoDuskKernelConstructionParams({
                dawnKernelParams: IRoycoDawnKernel.RoycoDawnKernelConstructionParams({
                    seniorTranche: result.seniorTranche,
                    stAsset: p.st.asset,
                    juniorTranche: result.juniorTranche,
                    jtAsset: p.balancerPool,
                    accountant: result.accountant,
                    enforceVaultSharesTransferWhitelist: p.kernel.enforceVaultSharesTransferWhitelist
                }),
                quoteAsset: p.quoteAsset
            });
            address kernelImpl = _deployImpl(COMPONENT_ID_DUSK_BALANCER_KERNEL, abi.encode(cp), _marketComponentSalt(p.marketId, "KERNEL_IMPL"));
            _deployProxy(kernelImpl, p.kernel.initCalldata, kernelProxySalt);
        }

        // 9. Apply selector→role bindings + post-init grants (SYNC_ROLE→accountant lives here).
        _applyRoleBindings(p.roles);

        // 10. (Optional) Configure the entry point's tranche configs for the new ST/JT.
        //     Piggybacks on the factory's `ADMIN_ENTRY_POINT_ROLE` via the generic
        //     `executeAsFactory` forwarder — the factory itself has no entry-point ABI.
        if (p.entryPoint != address(0)) {
            address[] memory tranches = new address[](2);
            tranches[0] = result.seniorTranche;
            tranches[1] = result.juniorTranche;
            IRoycoEntryPoint.TrancheConfig[] memory configs = new IRoycoEntryPoint.TrancheConfig[](2);
            configs[0] = p.stEntryPointConfig;
            configs[1] = p.jtEntryPointConfig;
            ROYCO_FACTORY.executeAsFactory(p.entryPoint, abi.encodeCall(IRoycoEntryPoint.modifyTrancheConfigs, (tranches, configs)));
        }

        // Encode `(pool, hooks, entryPoint, stCfg, jtCfg)` in extras for downstream consumers
        // and for `verify()` to read back. `entryPoint` is `address(0)` when unset.
        result.extras = abi.encode(p.balancerPool, hooks, p.entryPoint, p.stEntryPointConfig, p.jtEntryPointConfig);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VERIFY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IRoycoProtocolTemplate
    function verify(DeploymentResult calldata _d) external view override(IRoycoProtocolTemplate) {
        // Authority checks: every market contract must be managed by the factory's AM.
        address expectedAuthority = ROYCO_FACTORY.ROYCO_AUTHORITY();
        require(AccessManagedUpgradeable(_d.accountant).authority() == expectedAuthority, INVALID_ACCESS_MANAGER());
        require(AccessManagedUpgradeable(_d.kernel).authority() == expectedAuthority, INVALID_ACCESS_MANAGER());
        require(AccessManagedUpgradeable(_d.seniorTranche).authority() == expectedAuthority, INVALID_ACCESS_MANAGER());
        require(AccessManagedUpgradeable(_d.juniorTranche).authority() == expectedAuthority, INVALID_ACCESS_MANAGER());

        // Tranche-side wiring.
        require(IRoycoVaultTranche(_d.seniorTranche).TRANCHE_TYPE() == TrancheType.SENIOR, INVALID_TRANCHE_TYPE_ON_SENIOR_TRANCHE());
        require(IRoycoVaultTranche(_d.juniorTranche).TRANCHE_TYPE() == TrancheType.JUNIOR, INVALID_TRANCHE_TYPE_ON_JUNIOR_TRANCHE());
        require(address(IRoycoVaultTranche(_d.seniorTranche).KERNEL()) == _d.kernel, INVALID_KERNEL_ON_SENIOR_TRANCHE());
        require(address(IRoycoVaultTranche(_d.juniorTranche).KERNEL()) == _d.kernel, INVALID_KERNEL_ON_JUNIOR_TRANCHE());

        // Kernel-side wiring.
        IRoycoDuskKernel kernel = IRoycoDuskKernel(_d.kernel);
        require(kernel.SENIOR_TRANCHE() == _d.seniorTranche, INVALID_SENIOR_TRANCHE_ON_KERNEL());
        require(kernel.JUNIOR_TRANCHE() == _d.juniorTranche, INVALID_JUNIOR_TRANCHE_ON_KERNEL());
        require(kernel.ST_ASSET() == IRoycoVaultTranche(_d.seniorTranche).asset(), INVALID_ST_ASSET_ON_KERNEL());
        require(kernel.JT_ASSET() == IRoycoVaultTranche(_d.juniorTranche).asset(), INVALID_JT_ASSET_ON_KERNEL());
        require(kernel.ACCOUNTANT() == _d.accountant, INVALID_ACCOUNTANT_ON_KERNEL());

        // Accountant-side wiring.
        require(address(IRoycoAccountant(_d.accountant).KERNEL()) == _d.kernel, INVALID_KERNEL_ON_ACCOUNTANT());

        // Dusk-specific: quote asset + Balancer wiring.
        (address pool, address hooks, address entryPoint, IRoycoEntryPoint.TrancheConfig memory stCfg, IRoycoEntryPoint.TrancheConfig memory jtCfg) =
            abi.decode(_d.extras, (address, address, address, IRoycoEntryPoint.TrancheConfig, IRoycoEntryPoint.TrancheConfig));
        require(kernel.JT_ASSET() == pool, INVALID_JT_ASSET_ON_KERNEL());
        _assertPoolWiredCorrectly(pool, _d.seniorTranche, kernel.QUOTE_ASSET(), hooks);

        // Optional entry-point check.
        if (entryPoint != address(0)) {
            _assertEntryPointConfig(entryPoint, _d.seniorTranche, stCfg);
            _assertEntryPointConfig(entryPoint, _d.juniorTranche, jtCfg);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Asserts the Balancer V3 pool is registered with the Vault, has tokens
    ///      `{ST_PROXY, quoteAsset}` (any order), and is bound to `_expectedHooks`.
    function _assertPoolWiredCorrectly(address _pool, address _stProxy, address _quoteAsset, address _expectedHooks) internal view {
        // Resolve the Vault via the pool itself (BPT exposes `getVault()`).
        IVault vault = BalancerPoolToken(_pool).getVault();
        require(vault.isPoolRegistered(_pool), POOL_NOT_REGISTERED_WITH_VAULT());

        // Verify tokens are exactly the ST proxy and the quote asset, in either order.
        address[] memory tokens;
        {
            // `getPoolTokens` returns IERC20[] — narrow to address[] for comparison.
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

        // Verify the pool's hooks config references our deployed hooks.
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

