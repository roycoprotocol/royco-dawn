// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AccessManagedUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";
import { AccessManagerUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/access/manager/AccessManagerUpgradeable.sol";
import { UUPSUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { CREATE3 } from "../../lib/solady/src/utils/CREATE3.sol";
import { IRoycoAccountant } from "../interfaces/IRoycoAccountant.sol";
import { IRoycoFactory } from "../interfaces/IRoycoFactory.sol";
import { IRoycoKernel } from "../interfaces/IRoycoKernel.sol";
import { IRoycoVaultTranche, TrancheType } from "../interfaces/IRoycoVaultTranche.sol";
import { RolesConfiguration } from "./RolesConfiguration.sol";

/**
 * @title RoycoFactory
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Factory contract for deploying and initializing Royco markets (Senior Tranche, Junior Tranche, Kernel, and Accountant)
 * @notice The factory also acts as a singleton access manager for all the Royco markets and their constituent contracts
 * @dev The factory deploys each market's constituent contracts using the UUPS proxy pattern
 */
contract RoycoFactory is AccessManagerUpgradeable, RolesConfiguration, IRoycoFactory, UUPSUpgradeable {
    /// @dev Storage slot for RoycoFactoryState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoFactoryState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROYCO_FACTORY_STORAGE_SLOT = 0xd5259699f97e0f34b934576b7add74d31128c481e849a0afbdca7e6e84f8b300;

    /**
     * @dev The storage state of the Royco factory
     * @custom:storage-location erc7201:Royco.storage.RoycoFactoryState
     * @custom:mapping seniorTrancheToJuniorTranche - Mapping from a senior tranche to its corresponding junior tranche
     * @custom:mapping juniorTrancheToSeniorTranche - Mapping from a junior tranche to its corresponding senior tranche
     * @custom:field scheduledOperationsExpirySeconds - The expiry time for scheduled operations in seconds
     */
    struct RoycoFactoryState {
        mapping(address st => address jt) seniorTrancheToJuniorTranche;
        mapping(address jt => address st) juniorTrancheToSeniorTranche;
        uint32 scheduledOperationsExpirySeconds;
    }

    /// @notice Constructs the factory
    /// @dev Disable the initializers
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the factory
     * @param _admin The admin of the factory
     * @param _deployer The deployer address that can deploy new markets
     * @param _scheduledOperationsExpirySeconds The expiry time for scheduled operations in seconds
     * @param _roles The roles to assign to the factory
     */
    function initialize(
        address _admin,
        address _deployer,
        uint32 _scheduledOperationsExpirySeconds,
        RoleAssignmentConfiguration[] calldata _roles
    )
        external
        virtual
        initializer
    {
        // Initialize the access manager
        __AccessManager_init(_admin);
        // Initialize the factory
        __RoycoFactory_init_unchained(_deployer, _scheduledOperationsExpirySeconds, _roles);
    }

    /**
     * @notice Initializes the factory
     * @param _deployer The deployer address that can deploy new markets
     * @param _scheduledOperationsExpirySeconds The expiry time for scheduled operations in seconds
     * @param _roles The roles to assign to the factory
     */
    function __RoycoFactory_init_unchained(
        address _deployer,
        uint32 _scheduledOperationsExpirySeconds,
        RoleAssignmentConfiguration[] calldata _roles
    )
        internal
        onlyInitializing
    {
        // Set the scheduled operations expiry seconds
        _setScheduledOperationsExpiry(_scheduledOperationsExpirySeconds);

        // Grant the deployer the deployer role
        _grantRole(DEPLOYER_ROLE, _deployer, 0, 0);
        // Set the deployer role on the deployMarket function
        _setTargetFunctionRole(address(this), IRoycoFactory.deployMarket.selector, DEPLOYER_ROLE);

        // Configure the factory upgrader role
        _setTargetFunctionRole(address(this), UUPSUpgradeable.upgradeToAndCall.selector, ADMIN_UPGRADER_ROLE);

        // Configure all other market roles
        for (uint256 i = 0; i < _roles.length; i++) {
            RoleAssignmentConfiguration calldata roleAssignment = _roles[i];

            // Get role config to set up admin and guardian
            RoleConfig memory roleConfig = getRoleConfig(roleAssignment.role);

            // Grant the role to the assignee (skip if assignee is zero, e.g., ST_LP_ROLE which is handled separately)
            if (roleAssignment.assignee != address(0)) {
                _grantRole(roleAssignment.role, roleAssignment.assignee, 0, roleAssignment.executionDelay);
            }

            // Set the role admin if different from default (0)
            if (roleConfig.adminRole != _ADMIN_ROLE) {
                _setRoleAdmin(roleAssignment.role, roleConfig.adminRole);
            }

            // Set the role guardian
            _setRoleGuardian(roleAssignment.role, roleConfig.guardianRole);
        }
    }

    /// @inheritdoc IRoycoFactory
    function seniorTrancheToJuniorTranche(address _seniorTranche) external view override(IRoycoFactory) returns (address juniorTranche) {
        return _getRoycoFactoryStorage().seniorTrancheToJuniorTranche[_seniorTranche];
    }

    /// @inheritdoc IRoycoFactory
    function juniorTrancheToSeniorTranche(address _juniorTranche) external view override(IRoycoFactory) returns (address seniorTranche) {
        return _getRoycoFactoryStorage().juniorTrancheToSeniorTranche[_juniorTranche];
    }

    /// @inheritdoc IRoycoFactory
    function predictDeterministicAddress(bytes32 _salt) external view override(IRoycoFactory) returns (address deployed) {
        deployed = CREATE3.predictDeterministicAddress(_salt);
    }

    /// @inheritdoc IRoycoFactory
    function deployMarket(MarketDeploymentParams calldata _params) external override(IRoycoFactory) onlyAuthorized returns (RoycoMarket memory roycoMarket) {
        // Validate the deployment parameters
        _validateDeploymentParams(_params);

        // Deploy the Royco market
        roycoMarket = _deployMarket(_params);

        // Validate the deployment
        _validateDeployment(roycoMarket);

        // Ensure that the accountant can sync the market state
        _grantRole(SYNC_ROLE, address(roycoMarket.accountant), 0, 0);

        // Configure the roles
        _configureRoles(roycoMarket, _params.roles);

        // Update the mappings between the two deployed tranches
        address seniorTranche = address(roycoMarket.seniorTranche);
        address juniorTranche = address(roycoMarket.juniorTranche);
        RoycoFactoryState storage $ = _getRoycoFactoryStorage();
        $.seniorTrancheToJuniorTranche[seniorTranche] = juniorTranche;
        $.juniorTrancheToSeniorTranche[juniorTranche] = seniorTranche;

        emit MarketDeployed(roycoMarket, _params);
    }

    /// @inheritdoc IRoycoFactory
    function setScheduledOperationsExpiry(uint32 _scheduledOperationsExpirySeconds) external override(IRoycoFactory) onlyAuthorized {
        require(_scheduledOperationsExpirySeconds > 0, INVALID_SCHEDULED_OPERATIONS_EXPIRY_SECONDS());
        _getRoycoFactoryStorage().scheduledOperationsExpirySeconds = _scheduledOperationsExpirySeconds;
    }

    /// @inheritdoc AccessManagerUpgradeable
    function expiration() public view override(AccessManagerUpgradeable) returns (uint32) {
        return _getRoycoFactoryStorage().scheduledOperationsExpirySeconds;
    }

    /**
     * @notice Sets the scheduled operations expiry seconds
     * @param _scheduledOperationsExpirySeconds The expiry time for scheduled operations in seconds
     */
    function _setScheduledOperationsExpiry(uint32 _scheduledOperationsExpirySeconds) internal {
        require(_scheduledOperationsExpirySeconds != 0, INVALID_SCHEDULED_OPERATIONS_EXPIRY_SECONDS());
        _getRoycoFactoryStorage().scheduledOperationsExpirySeconds = _scheduledOperationsExpirySeconds;
        emit ScheduledOperationsExpirySecondsSet(_scheduledOperationsExpirySeconds);
    }

    /**
     * @notice Deploys the contracts for a new Royco market
     * @param _params The parameters for deploying a new Royco market
     * @return roycoMarket The deployed components constituting the Royco market
     */
    function _deployMarket(MarketDeploymentParams calldata _params) internal virtual returns (RoycoMarket memory roycoMarket) {
        // Deploy the senior tranche
        roycoMarket.seniorTranche = IRoycoVaultTranche(
            _deployERC1967ProxyDeterministic(
                address(_params.seniorTrancheImplementation), _params.seniorTrancheInitializationData, _params.seniorTrancheProxyDeploymentSalt
            )
        );

        // Deploy the junior tranche
        roycoMarket.juniorTranche = IRoycoVaultTranche(
            _deployERC1967ProxyDeterministic(
                address(_params.juniorTrancheImplementation), _params.juniorTrancheInitializationData, _params.juniorTrancheProxyDeploymentSalt
            )
        );

        // Deploy the kernel
        roycoMarket.kernel = IRoycoKernel(
            _deployERC1967ProxyDeterministic(address(_params.kernelImplementation), _params.kernelInitializationData, _params.kernelProxyDeploymentSalt)
        );

        // Deploy the accountant
        roycoMarket.accountant = IRoycoAccountant(
            _deployERC1967ProxyDeterministic(
                address(_params.accountantImplementation), _params.accountantInitializationData, _params.accountantProxyDeploymentSalt
            )
        );
    }

    /// @notice Validates the deployment parameters
    /// @param _params The parameters to validate
    function _validateDeploymentParams(MarketDeploymentParams calldata _params) internal pure {
        require(bytes(_params.seniorTrancheName).length > 0, INVALID_NAME());
        require(bytes(_params.seniorTrancheSymbol).length > 0, INVALID_SYMBOL());
        require(bytes(_params.juniorTrancheName).length > 0, INVALID_NAME());
        require(bytes(_params.juniorTrancheSymbol).length > 0, INVALID_SYMBOL());
        // Validate the implementation addresses
        require(address(_params.kernelImplementation) != address(0), INVALID_KERNEL_IMPLEMENTATION());
        require(address(_params.accountantImplementation) != address(0), INVALID_ACCOUNTANT_IMPLEMENTATION());
        require(address(_params.seniorTrancheImplementation) != address(0), INVALID_SENIOR_TRANCHE_IMPLEMENTATION());
        require(address(_params.juniorTrancheImplementation) != address(0), INVALID_JUNIOR_TRANCHE_IMPLEMENTATION());
        // Validate the initialization data
        require(_params.kernelInitializationData.length > 0, INVALID_KERNEL_INITIALIZATION_DATA());
        require(_params.accountantInitializationData.length > 0, INVALID_ACCOUNTANT_INITIALIZATION_DATA());
        // Validate the deployment salts
        require(_params.seniorTrancheProxyDeploymentSalt != bytes32(0), INVALID_SENIOR_TRANCHE_PROXY_DEPLOYMENT_SALT());
        require(_params.juniorTrancheProxyDeploymentSalt != bytes32(0), INVALID_JUNIOR_TRANCHE_PROXY_DEPLOYMENT_SALT());
        require(_params.kernelProxyDeploymentSalt != bytes32(0), INVALID_KERNEL_PROXY_DEPLOYMENT_SALT());
        require(_params.accountantProxyDeploymentSalt != bytes32(0), INVALID_ACCOUNTANT_PROXY_DEPLOYMENT_SALT());
    }

    /// @notice Validates the deployments
    /// @param _roycoMarket The deployed Royco market to validate
    function _validateDeployment(RoycoMarket memory _roycoMarket) internal view {
        // Check that the access manager is set on the contracts
        require(AccessManagedUpgradeable(address(_roycoMarket.accountant)).authority() == address(this), INVALID_ACCESS_MANAGER());
        require(AccessManagedUpgradeable(address(_roycoMarket.kernel)).authority() == address(this), INVALID_ACCESS_MANAGER());
        require(AccessManagedUpgradeable(address(_roycoMarket.seniorTranche)).authority() == address(this), INVALID_ACCESS_MANAGER());
        require(AccessManagedUpgradeable(address(_roycoMarket.juniorTranche)).authority() == address(this), INVALID_ACCESS_MANAGER());

        // Verify the Tranche Configurations
        require(_roycoMarket.seniorTranche.TRANCHE_TYPE() == TrancheType.SENIOR, INVALID_TRANCHE_TYPE_ON_SENIOR_TRANCHE());
        require(_roycoMarket.juniorTranche.TRANCHE_TYPE() == TrancheType.JUNIOR, INVALID_TRANCHE_TYPE_ON_JUNIOR_TRANCHE());
        require(address(_roycoMarket.seniorTranche.KERNEL()) == address(_roycoMarket.kernel), INVALID_KERNEL_ON_SENIOR_TRANCHE());
        require(address(_roycoMarket.juniorTranche.KERNEL()) == address(_roycoMarket.kernel), INVALID_KERNEL_ON_JUNIOR_TRANCHE());

        // Verify the Kernel's Configuration
        require(_roycoMarket.kernel.SENIOR_TRANCHE() == address(_roycoMarket.seniorTranche), INVALID_SENIOR_TRANCHE_ON_KERNEL());
        require(_roycoMarket.kernel.JUNIOR_TRANCHE() == address(_roycoMarket.juniorTranche), INVALID_JUNIOR_TRANCHE_ON_KERNEL());
        require(_roycoMarket.kernel.ST_ASSET() == address(_roycoMarket.seniorTranche.asset()), INVALID_ST_ASSET_ON_KERNEL());
        require(_roycoMarket.kernel.JT_ASSET() == address(_roycoMarket.juniorTranche.asset()), INVALID_JT_ASSET_ON_KERNEL());
        require(_roycoMarket.kernel.ACCOUNTANT() == address(_roycoMarket.accountant), INVALID_ACCOUNTANT_ON_KERNEL());

        // Verify the Accountant's Configuration
        require(address(_roycoMarket.accountant.KERNEL()) == address(_roycoMarket.kernel), INVALID_KERNEL_ON_ACCOUNTANT());
    }

    /**
     * @notice Configures the roles for the deployed contracts
     * @param _roycoMarket The deployed contracts to configure
     * @param _roles The roles to configure
     */
    function _configureRoles(RoycoMarket memory _roycoMarket, RolesTargetConfiguration[] calldata _roles) internal {
        for (uint256 i = 0; i < _roles.length; ++i) {
            RolesTargetConfiguration calldata role = _roles[i];

            // Validate that the selectors and roles length match
            require(role.selectors.length == role.roles.length, ROLES_CONFIGURATION_LENGTH_MISMATCH());

            // Validate that the target is one of the deployed contracts
            address target = role.target;
            require(
                target == address(_roycoMarket.accountant) || target == address(_roycoMarket.kernel) || target == address(_roycoMarket.seniorTranche)
                    || target == address(_roycoMarket.juniorTranche),
                INVALID_TARGET(target)
            );

            for (uint256 j = 0; j < role.selectors.length; ++j) {
                _setTargetFunctionRole(target, role.selectors[j], role.roles[j]);
            }
        }
    }

    /**
     * @notice Deploys an ERC1967 proxy deterministically using CREATE3
     * @param _implementation The implementation address
     * @param _initData The initialization data for the proxy
     * @param _salt The salt for the deployment
     * @return proxy The deployed proxy address
     */
    function _deployERC1967ProxyDeterministic(address _implementation, bytes memory _initData, bytes32 _salt) internal returns (address proxy) {
        address predictedAddress = CREATE3.predictDeterministicAddress(_salt);
        require(predictedAddress.code.length == 0, ALREADY_DEPLOYED(predictedAddress, _salt));

        proxy = CREATE3.deployDeterministic(abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(_implementation, _initData)), _salt);
    }

    /// @dev Restricts the upgrade to only authorized parties
    function _authorizeUpgrade(address _newImplementation) internal override(UUPSUpgradeable) onlyAuthorized {
        require(_newImplementation.code.length > 0, INVALID_IMPLEMENTATION());
    }

    /**
     * @notice Returns a storage pointer to the RoycoFactoryState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer to the factory's state
     */
    function _getRoycoFactoryStorage() private pure returns (RoycoFactoryState storage $) {
        assembly {
            $.slot := ROYCO_FACTORY_STORAGE_SLOT
        }
    }
}
