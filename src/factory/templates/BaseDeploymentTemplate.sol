// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Initializable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { SSTORE2 } from "../../../lib/solady/src/utils/SSTORE2.sol";
import { RoycoAccountant } from "../../accountant/RoycoAccountant.sol";
import { IRoycoAccountant } from "../../interfaces/IRoycoAccountant.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { IBaseTemplate } from "../../interfaces/factory/IBaseTemplate.sol";
import { IRoycoFactory } from "../../interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../interfaces/factory/IRoycoProtocolTemplate.sol";
import { NAV_UNIT } from "../../libraries/Units.sol";
import { RoycoSeniorTranche } from "../../tranches/RoycoSeniorTranche.sol";
import {
    COMPONENT_ID_ACCOUNTANT_IMPL,
    COMPONENT_ID_JUNIOR_TRANCHE_IMPL,
    COMPONENT_ID_SENIOR_TRANCHE_IMPL,
    COMPONENT_ID_YDM_ADAPTIVE_CURVE_V2
} from "./Components.sol";

/**
 * @title BaseDeploymentTemplate
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Abstract base every Royco protocol template inherits from. Standardizes:
 *           - Component param shapes (ST / JT / Accountant / YDM) so concrete templates
 *             share a vocabulary for the bits that don't vary across recipes.
 *           - SSTORE2-backed bytecode storage loaded once via factory-driven `initialize`.
 *           - Salt-derivation helpers (`_marketComponentSalt`, `_singletonSalt`).
 *           - Internal deployment helpers that call back into the factory's primitives.
 *           - A declarative role-bindings struct + a generic `_applyRoleBindings` loop.
 */
abstract contract BaseDeploymentTemplate is Initializable, IBaseTemplate {
    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Thrown when a market component (everything except YDM) was already deployed at
    ///         its CREATE3 address — signals a `marketId` collision that would re-use the
    ///         pre-existing contract instead of producing a fresh market.
    error MARKET_COMPONENT_ALREADY_DEPLOYED(address deployedAt, bytes32 salt);

    // ═══════════════════════════════════════════════════════════════════════════
    // STANDARD COMPONENT PARAM SHAPES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Shape every template uses for the senior tranche.
    /// @dev Salt is derived from the top-level `marketId` + the tag `"ST"` — not in params.
    struct SeniorTrancheParams {
        string name;
        string symbol;
        address asset;
    }

    /// @notice Shape every template uses for the junior tranche.
    /// @dev Salt is derived from the top-level `marketId` + the tag `"JT"` — not in params.
    /// @dev For Dusk markets the `asset` field is filled in by the template after the
    ///      Balancer pool is deployed (callers pass `address(0)`).
    struct JuniorTrancheParams {
        string name;
        string symbol;
        address asset;
    }

    /// @notice Shape every template uses for the accountant.
    /// @dev Salt derived from `(marketId, "ACCOUNTANT")`. YDM address derived from `YDMParams`.
    struct AccountantParams {
        uint64 stProtocolFeeWAD;
        uint64 jtProtocolFeeWAD;
        uint64 yieldShareProtocolFeeWAD;
        uint64 coverageWAD;
        uint96 betaWAD;
        uint256 liquidationUtilizationWAD;
        uint24 fixedTermDurationSeconds;
        NAV_UNIT stNAVDustTolerance;
        NAV_UNIT jtNAVDustTolerance;
        bytes ydmInitializationData;
    }

    /// @notice Shape every template uses for the YDM singleton.
    /// @dev YDM creation code lives in SSTORE2 keyed by `COMPONENT_ID_YDM_ADAPTIVE_CURVE_V2`. Salt is derived
    ///      from `_singletonSalt(componentTag, version)` so Dawn and Dusk templates passing
    ///      the same `(componentTag, version)` land on the same address.
    struct YDMParams {
        bytes32 componentTag; // e.g. bytes32("YDM_ADAPTIVE_CURVE_V2")
        bytes32 version; // e.g. bytes32("V1")
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DECLARATIVE ROLE BINDINGS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice One target's selector→role map.
    /// @dev `selectors[i]` is bound to `roleIds[i]`. Lengths must match.
    struct TargetBinding {
        address target;
        bytes4[] selectors;
        uint64[] roleIds;
    }

    /// @notice A role grant applied after deployment (e.g. SYNC_ROLE → accountant).
    struct RoleGrant {
        uint64 roleId;
        address account;
        uint32 executionDelay;
    }

    /// @notice The full role-wiring config a template applies via `_applyRoleBindings`.
    struct RoleBindings {
        TargetBinding[] targetBindings;
        RoleGrant[] postInitGrants;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // IMMUTABLE STATE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IBaseTemplate
    IRoycoFactory public immutable override(IBaseTemplate) ROYCO_FACTORY;

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev SSTORE2 pointer table — one pointer per component ID, set during `initialize`.
    mapping(bytes32 componentId => address sstore2Pointer) private _bytecodePointers;

    // ═══════════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Gates a function to be callable only by the factory this template is bound to.
    modifier onlyRoycoFactory() {
        require(msg.sender == address(ROYCO_FACTORY), ONLY_ROYCO_FACTORY());
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR + INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @param _factory The Royco factory this template will be registered with.
    constructor(IRoycoFactory _factory) {
        require(address(_factory) != address(0), ROYCO_FACTORY_CANNOT_BE_ZERO_ADDRESS());
        ROYCO_FACTORY = _factory;
    }

    /// @inheritdoc IRoycoProtocolTemplate
    function initialize(bytes32[] calldata _componentIds, bytes[] calldata _creationCodes) external override(IRoycoProtocolTemplate) initializer {
        require(msg.sender == address(ROYCO_FACTORY), ONLY_ROYCO_FACTORY());
        require(_componentIds.length == _creationCodes.length, LENGTH_MISMATCH());

        uint256 n = _componentIds.length;
        for (uint256 i; i < n; ++i) {
            bytes32 id = _componentIds[i];
            require(_bytecodePointers[id] == address(0), CREATION_CODE_ALREADY_SET(id));
            require(_creationCodes[i].length > 0, CREATION_CODE_CANNOT_BE_EMPTY(id));
            _bytecodePointers[id] = SSTORE2.write(_creationCodes[i]);
        }
    }

    /// @inheritdoc IBaseTemplate
    function bytecodePointer(bytes32 _componentId) external view override(IBaseTemplate) returns (address) {
        return _bytecodePointers[_componentId];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SALT DERIVATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Per-market component salt. Same `(marketId, componentTag)` always produces the
     *         same address regardless of template.
     * @param _marketId Caller-supplied stable identifier for the market.
     * @param _componentTag E.g. `bytes32("ST")`, `bytes32("JT")`, `bytes32("KERNEL")`,
     *        `bytes32("ACCOUNTANT")`, `bytes32("HOOKS")`.
     */
    function _marketComponentSalt(bytes32 _marketId, bytes32 _componentTag) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("ROYCO_MARKET_", _marketId, _componentTag));
    }

    /**
     * @notice Singleton salt. Same `(componentTag, version)` across all templates produces
     *         the same address — used for shared modules like the YDM that should be
     *         deployed once and reused across markets / templates.
     * @param _componentTag E.g. `bytes32("YDM_ADAPTIVE_CURVE_V2")`.
     * @param _version E.g. `bytes32("V1")`. Bump only when the bytecode changes and a new
     *        address is desired.
     */
    function _singletonSalt(bytes32 _componentTag, bytes32 _version) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("ROYCO_SINGLETON_", _componentTag, _version));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Reads a previously-loaded creation code via SSTORE2.
    function _readCreationCode(bytes32 _componentId) internal view returns (bytes memory) {
        address ptr = _bytecodePointers[_componentId];
        require(ptr != address(0), CREATION_CODE_NOT_SET(_componentId));
        return SSTORE2.read(ptr);
    }

    /// @notice Deploys an impl whose creation code lives at `_componentId`, with no constructor args.
    /// @dev Reverts if a contract already exists at the CREATE3 address — every market component
    ///      must be a fresh deployment. The YDM is the only exception and uses `_deployYDM`.
    function _deployImpl(bytes32 _componentId, bytes32 _salt) internal returns (address impl) {
        return _deployImpl(_componentId, "", _salt);
    }

    /// @notice Deploys an impl whose creation code lives at `_componentId`, with ABI-encoded constructor args appended.
    /// @dev Reverts if a contract already exists at the CREATE3 address.
    function _deployImpl(bytes32 _componentId, bytes memory _ctorArgs, bytes32 _salt) internal returns (address impl) {
        bytes memory creationCode = abi.encodePacked(_readCreationCode(_componentId), _ctorArgs);
        bool alreadyDeployed;
        (impl, alreadyDeployed) = ROYCO_FACTORY.deployDeterministicContract(creationCode, _salt);
        require(!alreadyDeployed, MARKET_COMPONENT_ALREADY_DEPLOYED(impl, _salt));
    }

    /// @notice Deploys an ERC1967 proxy pointing at `_impl` with `_initData`.
    /// @dev Reverts if a contract already exists at the CREATE3 address.
    function _deployProxy(address _impl, bytes memory _initData, bytes32 _salt) internal returns (address proxy) {
        bool alreadyDeployed;
        (proxy, alreadyDeployed) = ROYCO_FACTORY.deployDeterministicProxy(_impl, _initData, _salt);
        require(!alreadyDeployed, MARKET_COMPONENT_ALREADY_DEPLOYED(proxy, _salt));
    }

    /// @notice Deploys the YDM singleton, idempotent across templates.
    /// @dev The ONLY component permitted to be already-deployed — bypasses the freshness check
    ///      enforced by `_deployImpl` because two markets legitimately share the same YDM.
    function _deployYDM(YDMParams memory _p) internal returns (address ydm, bool alreadyDeployed) {
        bytes memory creationCode = _readCreationCode(COMPONENT_ID_YDM_ADAPTIVE_CURVE_V2);
        (ydm, alreadyDeployed) = ROYCO_FACTORY.deployDeterministicContract(creationCode, _singletonSalt(_p.componentTag, _p.version));
    }

    /// @notice Deploys the senior-tranche impl for a given (asset, kernel) pair.
    function _deploySeniorTrancheImpl(address _asset, address _kernel, bytes32 _salt) internal returns (address impl) {
        return _deployImpl(COMPONENT_ID_SENIOR_TRANCHE_IMPL, abi.encode(_asset, _kernel), _salt);
    }

    /// @notice Deploys the junior-tranche impl for a given (asset, kernel) pair.
    function _deployJuniorTrancheImpl(address _asset, address _kernel, bytes32 _salt) internal returns (address impl) {
        return _deployImpl(COMPONENT_ID_JUNIOR_TRANCHE_IMPL, abi.encode(_asset, _kernel), _salt);
    }

    /// @notice Deploys the accountant impl for a given kernel.
    function _deployAccountantImpl(address _kernel, bytes32 _salt) internal returns (address impl) {
        return _deployImpl(COMPONENT_ID_ACCOUNTANT_IMPL, abi.encode(_kernel), _salt);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INIT DATA BUILDERS (standard components)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Builds ABI-encoded `initialize(...)` calldata for ST or JT proxies.
    function _encodeTrancheInitData(string memory _name, string memory _symbol) internal view returns (bytes memory) {
        IRoycoVaultTranche.RoycoTrancheInitParams memory params =
            IRoycoVaultTranche.RoycoTrancheInitParams({ name: _name, symbol: _symbol, initialAuthority: ROYCO_FACTORY.ROYCO_AUTHORITY() });
        return abi.encodeCall(RoycoSeniorTranche.initialize, (params));
    }

    /// @notice Builds ABI-encoded `initialize(...)` calldata for an accountant proxy.
    function _encodeAccountantInitData(AccountantParams memory _p, address _ydm) internal view returns (bytes memory) {
        IRoycoAccountant.RoycoAccountantInitParams memory params = IRoycoAccountant.RoycoAccountantInitParams({
            stProtocolFeeWAD: _p.stProtocolFeeWAD,
            jtProtocolFeeWAD: _p.jtProtocolFeeWAD,
            yieldShareProtocolFeeWAD: _p.yieldShareProtocolFeeWAD,
            coverageWAD: _p.coverageWAD,
            betaWAD: _p.betaWAD,
            ydm: _ydm,
            ydmInitializationData: _p.ydmInitializationData,
            fixedTermDurationSeconds: _p.fixedTermDurationSeconds,
            liquidationUtilizationWAD: _p.liquidationUtilizationWAD,
            stNAVDustTolerance: _p.stNAVDustTolerance,
            jtNAVDustTolerance: _p.jtNAVDustTolerance
        });
        return abi.encodeCall(RoycoAccountant.initialize, (params, ROYCO_FACTORY.ROYCO_AUTHORITY()));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ROLE BINDING APPLICATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Applies every binding in `_bindings` by calling back into the factory.
     */
    function _applyRoleBindings(RoleBindings memory _bindings) internal {
        // Go through each target binding and apply the selectors to the target.
        uint256 nTargets = _bindings.targetBindings.length;
        for (uint256 i; i < nTargets; ++i) {
            TargetBinding memory tb = _bindings.targetBindings[i];
            require(tb.selectors.length == tb.roleIds.length, LENGTH_MISMATCH());
            uint256 m = tb.selectors.length;
            for (uint256 j; j < m; ++j) {
                ROYCO_FACTORY.setMarketTargetFunctionRole(tb.target, tb.selectors[j], tb.roleIds[j]);
            }
        }

        // Go through each post-init grant and apply the role to the account.
        uint256 nGrants = _bindings.postInitGrants.length;
        for (uint256 i; i < nGrants; ++i) {
            RoleGrant memory g = _bindings.postInitGrants[i];
            ROYCO_FACTORY.grantMarketRole(g.roleId, g.account, g.executionDelay);
        }
    }
}
