// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AccessManagedUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";
import { UUPSUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { AccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { CREATE3 } from "../../lib/solady/src/utils/CREATE3.sol";
import { RoycoBase } from "../base/RoycoBase.sol";
import { IBaseTemplate } from "../interfaces/factory/IBaseTemplate.sol";
import { IRoycoFactory } from "../interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../interfaces/factory/IRoycoProtocolTemplate.sol";
import { ADMIN_ENTRY_POINT_ROLE, ADMIN_FACTORY_ROLE, ADMIN_ROLE, ADMIN_UPGRADER_ROLE, DEPLOYER_ROLE } from "./RolesConfiguration.sol";

/**
 * @title RoycoFactory
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Template-driven factory for Royco markets.
 */
contract RoycoFactory is AccessManagedUpgradeable, RoycoBase, IRoycoFactory {
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoFactoryV2State")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROYCO_FACTORY_STORAGE_SLOT = 0x40ecf137e43ccc3fb8e0ec956edc7094cfc159472690a44f90b2be053a987500;

    /// @dev Holds the address of the template currently inside an `executeMarketDeployment` window; `address(0)` otherwise.
    address private transient _activeTemplate;

    // ═══════════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Only the currently-running template can call.
    /// @dev Invariant: the active template is always enabled.
    modifier onlyActiveTemplate() {
        require(msg.sender == _activeTemplate, ONLY_ACTIVE_TEMPLATE());
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTION + INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the factory proxy against a pre-deployed `AccessManager`.
     * @param _roycoAccessManager Pre-deployed AM. Must already grant `ADMIN_ROLE` to this
     *        factory's address.
     */
    function initialize(address _roycoAccessManager) external initializer {
        require(_roycoAccessManager != address(0), ACCESS_MANAGER_CANNOT_BE_ZERO_ADDRESS());
        require(_roycoAccessManager.code.length > 0, ACCESS_MANAGER_HAS_NO_CODE());

        AccessManager am = AccessManager(_roycoAccessManager);

        // Verify the factory holds ADMIN_ROLE on the AM
        (bool factoryIsAdmin,) = am.hasRole(ADMIN_ROLE, address(this));
        require(factoryIsAdmin, FACTORY_NOT_ADMIN_ON_ACCESS_MANAGER());

        // Wire the factory's `authority()` to the AM.
        __RoycoBase_init(_roycoAccessManager);

        // Bind factory-level gated selectors to their roles.
        bytes4[] memory deployerSelectors = new bytes4[](1);
        deployerSelectors[0] = IRoycoFactory.executeMarketDeployment.selector;
        am.setTargetFunctionRole(address(this), deployerSelectors, DEPLOYER_ROLE);

        bytes4[] memory upgraderSelectors = new bytes4[](1);
        upgraderSelectors[0] = UUPSUpgradeable.upgradeToAndCall.selector;
        am.setTargetFunctionRole(address(this), upgraderSelectors, ADMIN_UPGRADER_ROLE);

        bytes4[] memory adminFactorySelectors = new bytes4[](2);
        adminFactorySelectors[0] = IRoycoFactory.registerTemplate.selector;
        adminFactorySelectors[1] = IRoycoFactory.disableTemplate.selector;
        am.setTargetFunctionRole(address(this), adminFactorySelectors, ADMIN_FACTORY_ROLE);

        // Grant the factory `ADMIN_ENTRY_POINT_ROLE` on the AM
        am.grantRole(ADMIN_ENTRY_POINT_ROLE, address(this), 0);
    }

    /// @inheritdoc IRoycoFactory
    function ROYCO_AUTHORITY() external view override(IRoycoFactory) returns (address) {
        return authority();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IRoycoFactory
    function registerTemplate(
        address _template,
        bytes32[] calldata _componentIds,
        bytes[] calldata _creationCodes
    )
        external
        override(IRoycoFactory)
        whenNotPaused
        restricted
    {
        require(_template != address(0), TEMPLATE_CANNOT_BE_ZERO_ADDRESS());

        RoycoFactoryState storage $ = _getRoycoFactoryStorage();
        require(!$.isTemplateEnabled[_template], TEMPLATE_ALREADY_REGISTERED());

        // Sanity: template was constructed pointing at this factory.
        require(address(IBaseTemplate(_template).ROYCO_FACTORY()) == address(this), TEMPLATE_BOUND_TO_DIFFERENT_FACTORY());

        // Atomically initialize the template's SSTORE2-backed bytecode storage.
        IBaseTemplate(_template).initialize(_componentIds, _creationCodes);

        $.isTemplateEnabled[_template] = true;
        emit TemplateRegistered(_template);
    }

    /// @inheritdoc IRoycoFactory
    function disableTemplate(address _template) external override(IRoycoFactory) restricted {
        _getRoycoFactoryStorage().isTemplateEnabled[_template] = false;
        emit TemplateDisabled(_template);
    }

    /// @inheritdoc IRoycoFactory
    function isTemplateEnabled(address _template) external view override(IRoycoFactory) returns (bool) {
        return _getRoycoFactoryStorage().isTemplateEnabled[_template];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYER ENTRYPOINT
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IRoycoFactory
    function executeMarketDeployment(
        address _template,
        bytes calldata _params
    )
        external
        override(IRoycoFactory)
        restricted
        whenNotPaused
        returns (IRoycoProtocolTemplate.DeploymentResult memory result)
    {
        RoycoFactoryState storage $ = _getRoycoFactoryStorage();

        require($.isTemplateEnabled[_template], TEMPLATE_NOT_ENABLED());
        require(_activeTemplate == address(0), NO_ACTIVE_TEMPLATE());

        // Bind the active template.
        _activeTemplate = _template;
        emit MarketDeploymentStarted(_template, msg.sender);

        // Deploy the market.
        result = IBaseTemplate(_template).deployMarket(_params);

        // Verify the market.
        IBaseTemplate(_template).verify(result);

        // Explicit clear for clarity; transient storage auto-clears at tx-end as a backstop.
        _activeTemplate = address(0);

        // Store the senior and junior tranche addresses in the factory storage.
        $.seniorTrancheToJuniorTranche[result.seniorTranche] = result.juniorTranche;
        $.juniorTrancheToSeniorTranche[result.juniorTranche] = result.seniorTranche;

        emit MarketDeploymentCompleted(_template, result);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TEMPLATE-CALLABLE PRIMITIVES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IRoycoFactory
    function deployDeterministicContract(
        bytes calldata _creationCode,
        bytes32 _salt
    )
        external
        override(IRoycoFactory)
        onlyActiveTemplate
        whenNotPaused
        returns (address deployed, bool alreadyDeployed)
    {
        // Check if the contract already exists at the predicted address.
        deployed = CREATE3.predictDeterministicAddress(_salt);
        if (deployed.code.length > 0) return (deployed, true);

        // Deploy the contract.
        return (CREATE3.deployDeterministic(_creationCode, _salt), false);
    }

    /// @inheritdoc IRoycoFactory
    function deployDeterministicProxy(
        address _implementation,
        bytes calldata _initData,
        bytes32 _salt
    )
        external
        override(IRoycoFactory)
        onlyActiveTemplate
        whenNotPaused
        returns (address deployed, bool alreadyDeployed)
    {
        // Check if the proxy already exists at the predicted address.
        deployed = CREATE3.predictDeterministicAddress(_salt);
        if (deployed.code.length > 0) return (deployed, true);

        // Deploy the proxy.
        bytes memory creationCode = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(_implementation, _initData));
        deployed = CREATE3.deployDeterministic(creationCode, _salt);
        return (deployed, false);
    }

    /// @inheritdoc IRoycoFactory
    function predictDeterministicAddress(bytes32 _salt) external view override(IRoycoFactory) returns (address) {
        return CREATE3.predictDeterministicAddress(_salt);
    }

    /// @inheritdoc IRoycoFactory
    function setMarketTargetFunctionRole(address _target, bytes4 _selector, uint64 _roleId) external override(IRoycoFactory) whenNotPaused onlyActiveTemplate {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = _selector;
        AccessManager(authority()).setTargetFunctionRole(_target, selectors, _roleId);
    }

    /// @inheritdoc IRoycoFactory
    function grantMarketRole(uint64 _roleId, address _account, uint32 _executionDelay) external override(IRoycoFactory) whenNotPaused onlyActiveTemplate {
        AccessManager(authority()).grantRole(_roleId, _account, _executionDelay);
    }

    /// @inheritdoc IRoycoFactory
    function executeAsFactory(
        address _target,
        bytes calldata _data
    )
        external
        override(IRoycoFactory)
        whenNotPaused
        onlyActiveTemplate
        returns (bytes memory result)
    {
        bool success;
        (success, result) = _target.call(_data);
        require(success, FACTORY_CALL_FAILED(result));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GETTERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IRoycoFactory
    function seniorTrancheToJuniorTranche(address _seniorTranche) external view override(IRoycoFactory) returns (address juniorTranche) {
        return _getRoycoFactoryStorage().seniorTrancheToJuniorTranche[_seniorTranche];
    }

    /// @inheritdoc IRoycoFactory
    function juniorTrancheToSeniorTranche(address _juniorTranche) external view override(IRoycoFactory) returns (address seniorTranche) {
        return _getRoycoFactoryStorage().juniorTrancheToSeniorTranche[_juniorTranche];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════════════

    function _getRoycoFactoryStorage() private pure returns (IRoycoFactory.RoycoFactoryState storage $) {
        assembly {
            $.slot := ROYCO_FACTORY_STORAGE_SLOT
        }
    }
}

