// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoAccountant } from "./IRoycoAccountant.sol";
import { IRoycoDawnKernel } from "./IRoycoDawnKernel.sol";
import { IRoycoVaultTranche } from "./IRoycoVaultTranche.sol";

/// @title IRoycoFactory
/// @notice Interface for the RoycoFactory contract that deploys Royco markets
interface IRoycoFactory {
    /// @notice Thrown when an already deployed contract is predicted
    error ALREADY_DEPLOYED(address deployedAddress, bytes32 salt);

    /// @notice Thrown when an invalid implementation is provided
    error INVALID_IMPLEMENTATION();

    /// @notice Thrown when an invalid name is provided
    error INVALID_NAME();

    /// @notice Thrown when an invalid symbol is provided
    error INVALID_SYMBOL();

    /// @notice Thrown when an invalid kernel implementation is provided
    error INVALID_KERNEL_IMPLEMENTATION();

    /// @notice Thrown when an invalid accountant implementation is provided
    error INVALID_ACCOUNTANT_IMPLEMENTATION();

    /// @notice Thrown when an invalid senior tranche proxy deployment salt is provided
    error INVALID_SENIOR_TRANCHE_PROXY_DEPLOYMENT_SALT();

    /// @notice Thrown when an invalid junior tranche proxy deployment salt is provided
    error INVALID_JUNIOR_TRANCHE_PROXY_DEPLOYMENT_SALT();

    /// @notice Thrown when an invalid kernel proxy deployment salt is provided
    error INVALID_KERNEL_PROXY_DEPLOYMENT_SALT();

    /// @notice Thrown when an invalid accountant proxy deployment salt is provided
    error INVALID_ACCOUNTANT_PROXY_DEPLOYMENT_SALT();

    /// @notice Thrown when an invalid senior tranche implementation is provided
    error INVALID_SENIOR_TRANCHE_IMPLEMENTATION();

    /// @notice Thrown when an invalid junior tranche implementation is provided
    error INVALID_JUNIOR_TRANCHE_IMPLEMENTATION();

    /// @notice Thrown when an invalid access manager is configured on a deployed contract
    error INVALID_ACCESS_MANAGER();

    /// @notice Thrown when the tranche type configured on the senior tranche is not TrancheType.SENIOR
    error INVALID_TRANCHE_TYPE_ON_SENIOR_TRANCHE();

    /// @notice Thrown when the tranche type configured on the junior tranche is not TrancheType.JUNIOR
    error INVALID_TRANCHE_TYPE_ON_JUNIOR_TRANCHE();

    /// @notice Thrown when the kernel address configured on the senior tranche is invalid
    error INVALID_KERNEL_ON_SENIOR_TRANCHE();

    /// @notice Thrown when the kernel address configured on the junior tranche is invalid
    error INVALID_KERNEL_ON_JUNIOR_TRANCHE();

    /// @notice Thrown when the accountant address configured on the kernel is invalid
    error INVALID_ACCOUNTANT_ON_KERNEL();

    /// @notice Thrown when the kernel address configured on the accountant is invalid
    error INVALID_KERNEL_ON_ACCOUNTANT();

    /// @notice Thrown when kernel initialization data is invalid
    error INVALID_KERNEL_INITIALIZATION_DATA();

    /// @notice Thrown when accountant initialization data is invalid
    error INVALID_ACCOUNTANT_INITIALIZATION_DATA();

    /// @notice Thrown when the roles configuration length mismatch
    error ROLES_CONFIGURATION_LENGTH_MISMATCH();

    /// @notice Thrown when the target is invalid
    error INVALID_TARGET(address target);

    /// @notice Thrown when the senior tranche address configured on the kernel is invalid
    error INVALID_SENIOR_TRANCHE_ON_KERNEL();

    /// @notice Thrown when the junior tranche address configured on the kernel is invalid
    error INVALID_JUNIOR_TRANCHE_ON_KERNEL();

    /// @notice Thrown when the ST asset address configured on the kernel is invalid
    error INVALID_ST_ASSET_ON_KERNEL();

    /// @notice Thrown when the JT asset address configured on the kernel is invalid
    error INVALID_JT_ASSET_ON_KERNEL();

    /// @notice Thrown when the scheduled operations expiry seconds is invalid
    error INVALID_SCHEDULED_OPERATIONS_EXPIRY_SECONDS();

    /// @notice Emitted when a new market is deployed
    event MarketDeployed(RoycoMarket roycoMarket, MarketDeploymentParams params);

    /// @notice Emitted when the scheduled operations expiry seconds is set
    event ScheduledOperationsExpirySecondsSet(uint32 scheduledOperationsExpirySeconds);

    /**
     * @notice Parameters for deploying a new market
     * @custom:field seniorTrancheName - The name of the senior tranche
     * @custom:field seniorTrancheSymbol - The symbol of the senior tranche
     * @custom:field juniorTrancheName - The name of the junior tranche
     * @custom:field juniorTrancheSymbol - The symbol of the junior tranche
     * @custom:field kernelImplementation - The implementation address for the kernel
     * @custom:field accountantImplementation - The implementation address for the accountant
     * @custom:field seniorTrancheImplementation - The implementation address for the senior tranche
     * @custom:field juniorTrancheImplementation - The implementation address for the junior tranche
     * @custom:field kernelInitializationData - The initialization data for the kernel
     * @custom:field accountantInitializationData - The initialization data for the accountant
     * @custom:field seniorTrancheInitializationData - The initialization data for the senior tranche
     * @custom:field juniorTrancheInitializationData - The initialization data for the junior tranche
     * @custom:field seniorTrancheProxyDeploymentSalt - The salt for the senior tranche proxy deployment
     * @custom:field juniorTrancheProxyDeploymentSalt - The salt for the junior tranche proxy deployment
     * @custom:field kernelProxyDeploymentSalt - The salt for the kernel proxy deployment
     * @custom:field accountantProxyDeploymentSalt - The salt for the accountant proxy deployment
     */
    struct MarketDeploymentParams {
        // Tranche Deployment Parameters
        string seniorTrancheName;
        string seniorTrancheSymbol;
        string juniorTrancheName;
        string juniorTrancheSymbol;
        // Implementation Addresses
        IRoycoVaultTranche seniorTrancheImplementation;
        IRoycoVaultTranche juniorTrancheImplementation;
        IRoycoDawnKernel kernelImplementation;
        IRoycoAccountant accountantImplementation;
        // Proxy Initialization Data
        bytes seniorTrancheInitializationData;
        bytes juniorTrancheInitializationData;
        bytes kernelInitializationData;
        bytes accountantInitializationData;
        // CREATE3 Salts
        bytes32 seniorTrancheProxyDeploymentSalt;
        bytes32 juniorTrancheProxyDeploymentSalt;
        bytes32 kernelProxyDeploymentSalt;
        bytes32 accountantProxyDeploymentSalt;
        // Initial Roles Configuration
        RolesTargetConfiguration[] roles;
    }

    /**
     * @notice For a given target address, the configuration for a role
     * @custom:field target - The target address of the role
     * @custom:field selectors - The selectors of the role
     * @custom:field roles - The roles of the role
     */
    struct RolesTargetConfiguration {
        address target;
        bytes4[] selectors;
        uint64[] roles;
    }

    /**
     * @notice The contracts constituting a Royco market
     * @custom:field seniorTranche - The senior tranche contract
     * @custom:field juniorTranche - The junior tranche contract
     * @custom:field kernel - The kernel contract
     * @custom:field accountant - The accountant contract
     */
    struct RoycoMarket {
        IRoycoVaultTranche seniorTranche;
        IRoycoVaultTranche juniorTranche;
        IRoycoDawnKernel kernel;
        IRoycoAccountant accountant;
    }

    /**
     * @notice Configuration for assigning a role to an address
     * @custom:field role - The role to assign
     * @custom:field roleAdminRole - The admin role that can assign the role, 0 if none
     * @custom:field assignee - The address to assign the role to
     * @custom:field executionDelay - The delay after which the role can be assigned
     */
    struct RoleAssignmentConfiguration {
        uint64 role;
        uint64 roleAdminRole;
        address assignee;
        uint32 executionDelay;
    }

    /**
     * @notice Deploys a new market with senior tranche, junior tranche, and kernel
     * @param _params The parameters for deploying a new market
     * @return roycoMarket The deployed components constituting the Royco market
     */
    function deployMarket(MarketDeploymentParams calldata _params) external returns (RoycoMarket memory roycoMarket);

    /**
     * @notice Sets the scheduled operations expiry seconds
     * @param _scheduledOperationsExpirySeconds The expiry time for scheduled operations in seconds
     */
    function setScheduledOperationsExpiry(uint32 _scheduledOperationsExpirySeconds) external;

    /**
     * @notice Predicts the address of a contract deployed using CREATE3
     * @param _salt The salt for the deployment
     * @return deployed The predicted contract address
     */
    function predictDeterministicAddress(bytes32 _salt) external view returns (address deployed);

    /**
     * @notice Returns the junior tranche for a given senior tranche
     * @param _seniorTranche The senior tranche address
     * @return juniorTranche The junior tranche address
     */
    function seniorTrancheToJuniorTranche(address _seniorTranche) external view returns (address juniorTranche);

    /**
     * @notice Returns the senior tranche for a given junior tranche
     * @param _juniorTranche The junior tranche address
     * @return seniorTranche The senior tranche address
     */
    function juniorTrancheToSeniorTranche(address _juniorTranche) external view returns (address seniorTranche);
}
