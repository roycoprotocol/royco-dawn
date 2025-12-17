// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AccessManagedUpgradeable } from "../lib/openzeppelin-contracts-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";
import { AccessManager } from "../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { ERC1967Proxy } from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { UUPSUpgradeable } from "../lib/openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import { Create2 } from "../lib/openzeppelin-contracts/contracts/utils/Create2.sol";
import { RoycoRoles } from "./auth/RoycoRoles.sol";
import { IRoycoAccountant } from "./interfaces/IRoycoAccountant.sol";
import { IRoycoAuth } from "./interfaces/IRoycoAuth.sol";
import { IRoycoKernel } from "./interfaces/kernel/IRoycoKernel.sol";
import { IRoycoAsyncCancellableVault } from "./interfaces/tranche/IRoycoAsyncCancellableVault.sol";
import { IRoycoAsyncVault } from "./interfaces/tranche/IRoycoAsyncVault.sol";
import { IRoycoVaultTranche } from "./interfaces/tranche/IRoycoVaultTranche.sol";
import { BaseAsyncJTRedemptionDelayKernel } from "./kernels/base/junior/BaseAsyncJTRedemptionDelayKernel.sol";
import { DeployedContracts, MarketDeploymentParams } from "./libraries/Types.sol";

/// @title RoycoFactory
/// @notice Factory contract for deploying Royco tranches (ST and JT) and their associated kernel using ERC1967 proxies
/// @notice The factory also acts as the shared access manager for all the Royco market
/// @dev This factory deploys upgradeable tranche contracts using the UUPS proxy pattern
contract RoycoFactory is AccessManager, RoycoRoles {
    /// @notice Thrown when an invalid name is provided
    error InvalidName();
    /// @notice Thrown when an invalid symbol is provided
    error InvalidSymbol();
    /// @notice Thrown when an invalid asset is provided
    error InvalidAsset();
    /// @notice Thrown when an invalid market id is provided
    error InvalidMarketId();
    /// @notice Thrown when an invalid kernel implementation is provided
    error InvalidKernelImplementation();
    /// @notice Thrown when an invalid accountant implementation is provided
    error InvalidAccountantImplementation();
    /// @notice Thrown when an invalid senior tranche proxy deployment salt is provided
    error InvalidSeniorTrancheProxyDeploymentSalt();
    /// @notice Thrown when an invalid junior tranche proxy deployment salt is provided
    error InvalidJuniorTrancheProxyDeploymentSalt();
    /// @notice Thrown when an invalid kernel proxy deployment salt is provided
    error InvalidKernelProxyDeploymentSalt();
    /// @notice Thrown when an invalid accountant proxy deployment salt is provided
    error InvalidAccountantProxyDeploymentSalt();
    /// @notice Thrown when an invalid senior tranche implementation is provided
    error InvalidSeniorTrancheImplementation();
    /// @notice Thrown when an invalid junior tranche implementation is provided
    error InvalidJuniorTrancheImplementation();
    /// @notice Thrown when an invalid access manager is configured on a deployed contract
    error InvalidAccessManager();
    /// @notice Thrown when the kernel address configured on the senior tranche is invalid
    error InvalidKernelOnSeniorTranche();
    /// @notice Thrown when the kernel address configured on the junior tranche is invalid
    error InvalidKernelOnJuniorTranche();
    /// @notice Thrown when the accountant address configured on the kernel is invalid
    error InvalidAccountantOnKernel();
    /// @notice Thrown when the kernel address configured on the accountant is invalid
    error InvalidKernelOnAccountant();
    /// @notice Thrown when kernel initialization data is invalid
    error InvalidKernelInitializationData();
    /// @notice Thrown when accountant initialization data is invalid
    error InvalidAccountantInitializationData();
    /// @notice Thrown when the kernel failed to initialize
    error FailedToInitializeKernel(bytes data);
    /// @notice Thrown when the accountant failed to initialize
    error FailedToInitializeAccountant(bytes data);
    /// @notice Thrown when the senior tranche failed to initialize
    error FailedToInitializeSeniorTranche(bytes data);
    /// @notice Thrown when the junior tranche failed to initialize
    error FailedToInitializeJuniorTranche(bytes data);

    /// @notice Emitted when a new market is deployed
    event MarketDeployed(DeployedContracts deployedContracts, MarketDeploymentParams params);
    /// @notice Emitted when a role delay is set
    event RoleDelaySet(uint64 role, uint256 delay);

    /// @notice Initializes the factory with tranche implementation addresses
    constructor(address _initialAdmin) AccessManager(_initialAdmin) { }

    /// @notice Deploys a new market with senior tranche, junior tranche, and kernel
    /// @param _params The parameters for deploying a new market
    function deployMarket(MarketDeploymentParams calldata _params) external onlyAuthorized returns (DeployedContracts memory deployedContracts) {
        // Validate the deployment parameters
        _validateDeploymentParams(_params);

        // Deploy the contracts
        deployedContracts = _deployContracts(_params);

        // Validate the deployment
        _validateDeployment(deployedContracts);

        // Configure the roles
        _configureRoles(deployedContracts);

        emit MarketDeployed(deployedContracts, _params);
    }

    /// @notice Predicts the address of a tranche proxy
    /// @param _implementation The implementation address
    /// @param _salt The salt for the deployment
    /// @return proxy The predicted proxy address
    function predictERC1967ProxyAddress(address _implementation, bytes32 _salt) external view returns (address proxy) {
        proxy = Create2.computeAddress(_salt, keccak256(abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(_implementation, ""))));
    }

    /// @notice Deploys the contracts for a new market
    /// @param _params The parameters for deploying a new market
    /// @return deployedContracts The deployed contracts
    function _deployContracts(MarketDeploymentParams calldata _params) internal virtual returns (DeployedContracts memory deployedContracts) {
        // Deploy the kernel, accountant and tranches with empty initialization data
        // It is expected that the kernel initialization data contains the address of the accountant and vice versa
        // Therefore, it is expected that the proxy address is precomputed based on an uninitialized erc1967 proxy initcode
        // and that the proxy is initalized separately after deployment, in the same transaction

        // Deploy the accountant with empty initialization data
        deployedContracts.accountant =
            IRoycoAccountant(_deployERC1967ProxyDeterministic(address(_params.accountantImplementation), _params.accountantProxyDeploymentSalt));

        // Deploy the kernel with empty initialization data
        deployedContracts.kernel = IRoycoKernel(_deployERC1967ProxyDeterministic(address(_params.kernelImplementation), _params.kernelProxyDeploymentSalt));

        // Deploy the senior tranche with empty initialization data
        deployedContracts.seniorTranche =
            IRoycoVaultTranche(_deployERC1967ProxyDeterministic(address(_params.seniorTrancheImplementation), _params.seniorTrancheProxyDeploymentSalt));

        // Deploy the junior tranche with empty initialization data
        deployedContracts.juniorTranche =
            IRoycoVaultTranche(_deployERC1967ProxyDeterministic(address(_params.juniorTrancheImplementation), _params.juniorTrancheProxyDeploymentSalt));

        // Initialize the senior tranche
        (bool success, bytes memory data) = address(deployedContracts.seniorTranche).call(_params.seniorTrancheInitializationData);
        require(success, FailedToInitializeSeniorTranche(data));

        // Initialize the junior tranche
        (success, data) = address(deployedContracts.juniorTranche).call(_params.juniorTrancheInitializationData);
        require(success, FailedToInitializeJuniorTranche(data));

        // Initialize the accountant
        (success, data) = address(deployedContracts.accountant).call(_params.accountantInitializationData);
        require(success, FailedToInitializeAccountant(data));

        // Initialize the kernel
        (success, data) = address(deployedContracts.kernel).call(_params.kernelInitializationData);
        require(success, FailedToInitializeKernel(data));
    }

    /// @notice Validates the deployment
    /// @param _deployedContracts The deployed contracts to validate
    function _validateDeployment(DeployedContracts memory _deployedContracts) internal view {
        // Check that the access manager is set on the contracts
        require(AccessManagedUpgradeable(address(_deployedContracts.accountant)).authority() == address(this), InvalidAccessManager());
        require(AccessManagedUpgradeable(address(_deployedContracts.kernel)).authority() == address(this), InvalidAccessManager());
        require(AccessManagedUpgradeable(address(_deployedContracts.seniorTranche)).authority() == address(this), InvalidAccessManager());
        require(AccessManagedUpgradeable(address(_deployedContracts.juniorTranche)).authority() == address(this), InvalidAccessManager());

        // Check that the kernel is set on the tranches
        require(address(_deployedContracts.seniorTranche.kernel()) == address(_deployedContracts.kernel), InvalidKernelOnSeniorTranche());
        require(address(_deployedContracts.juniorTranche.kernel()) == address(_deployedContracts.kernel), InvalidKernelOnJuniorTranche());

        // Check that the accountant is set on the kernel
        require(address(_deployedContracts.kernel.getState().accountant) == address(_deployedContracts.accountant), InvalidAccountantOnKernel());

        // Check that the kernel is set on the accountant
        require(address(_deployedContracts.accountant.getState().kernel) == address(_deployedContracts.kernel), InvalidKernelOnAccountant());
    }

    /// @notice Validates the deployment parameters
    /// @param _params The parameters to validate
    function _validateDeploymentParams(MarketDeploymentParams calldata _params) internal pure {
        require(bytes(_params.seniorTrancheName).length > 0, InvalidName());
        require(bytes(_params.seniorTrancheSymbol).length > 0, InvalidSymbol());
        require(bytes(_params.juniorTrancheName).length > 0, InvalidName());
        require(bytes(_params.juniorTrancheSymbol).length > 0, InvalidSymbol());
        require(_params.seniorAsset != address(0), InvalidAsset());
        require(_params.juniorAsset != address(0), InvalidAsset());
        require(_params.marketId != bytes32(0), InvalidMarketId());
        // Validate the implementation addresses
        require(address(_params.kernelImplementation) != address(0), InvalidKernelImplementation());
        require(address(_params.accountantImplementation) != address(0), InvalidAccountantImplementation());
        // Validate the initialization data
        require(_params.kernelInitializationData.length > 0, InvalidKernelInitializationData());
        require(_params.accountantInitializationData.length > 0, InvalidAccountantInitializationData());
        // Validate the deployment salts
        require(_params.seniorTrancheProxyDeploymentSalt != bytes32(0), InvalidSeniorTrancheProxyDeploymentSalt());
        require(_params.juniorTrancheProxyDeploymentSalt != bytes32(0), InvalidJuniorTrancheProxyDeploymentSalt());
        require(_params.kernelProxyDeploymentSalt != bytes32(0), InvalidKernelProxyDeploymentSalt());
        require(_params.accountantProxyDeploymentSalt != bytes32(0), InvalidAccountantProxyDeploymentSalt());
    }

    /// @notice Configures the roles for the deployed contracts
    /// @param _deployedContracts The deployed contracts to configure
    function _configureRoles(DeployedContracts memory _deployedContracts) internal {
        // Configure the roles for the accountant
        _setTargetFunctionRole(address(_deployedContracts.accountant), UUPSUpgradeable.upgradeToAndCall.selector, UPGRADER_ROLE);
        _setTargetFunctionRole(address(_deployedContracts.accountant), IRoycoAuth.pause.selector, PAUSER_ROLE);
        _setTargetFunctionRole(address(_deployedContracts.accountant), IRoycoAuth.unpause.selector, PAUSER_ROLE);

        // Configure the roles for the kernel
        _setTargetFunctionRole(address(_deployedContracts.kernel), UUPSUpgradeable.upgradeToAndCall.selector, UPGRADER_ROLE);
        _setTargetFunctionRole(address(_deployedContracts.kernel), IRoycoAuth.pause.selector, PAUSER_ROLE);
        _setTargetFunctionRole(address(_deployedContracts.kernel), IRoycoAuth.unpause.selector, PAUSER_ROLE);
        _setTargetFunctionRole(address(_deployedContracts.kernel), IRoycoKernel.syncTrancheAccounting.selector, SYNC_ROLE);
        _setTargetFunctionRole(address(_deployedContracts.kernel), BaseAsyncJTRedemptionDelayKernel.setRedemptionDelay.selector, KERNEL_ADMIN_ROLE);

        // Configure the roles for the senior tranche
        _configureRolesForTranche(_deployedContracts.seniorTranche);

        // Configure the roles for the junior tranche
        _configureRolesForTranche(_deployedContracts.juniorTranche);
    }

    /// @notice Configures the roles for a tranche
    /// @param _tranche The tranche to configure the roles for
    function _configureRolesForTranche(IRoycoVaultTranche _tranche) internal {
        _setTargetFunctionRole(address(_tranche), UUPSUpgradeable.upgradeToAndCall.selector, UPGRADER_ROLE);
        _setTargetFunctionRole(address(_tranche), IRoycoAuth.pause.selector, PAUSER_ROLE);
        _setTargetFunctionRole(address(_tranche), IRoycoAuth.unpause.selector, PAUSER_ROLE);
        _setTargetFunctionRole(address(_tranche), IRoycoVaultTranche.deposit.selector, DEPOSIT_ROLE);
        _setTargetFunctionRole(address(_tranche), IRoycoVaultTranche.redeem.selector, REDEEM_ROLE);
        _setTargetFunctionRole(address(_tranche), IRoycoAsyncVault.requestDeposit.selector, DEPOSIT_ROLE);
        _setTargetFunctionRole(address(_tranche), IRoycoAsyncVault.requestRedeem.selector, REDEEM_ROLE);
        _setTargetFunctionRole(address(_tranche), IRoycoAsyncCancellableVault.cancelDepositRequest.selector, CANCEL_DEPOSIT_ROLE);
        _setTargetFunctionRole(address(_tranche), IRoycoAsyncCancellableVault.cancelRedeemRequest.selector, CANCEL_REDEEM_ROLE);
        _setTargetFunctionRole(address(_tranche), IRoycoAsyncCancellableVault.claimCancelDepositRequest.selector, CANCEL_DEPOSIT_ROLE);
        _setTargetFunctionRole(address(_tranche), IRoycoAsyncCancellableVault.claimCancelRedeemRequest.selector, CANCEL_REDEEM_ROLE);
    }

    /// @notice Deploys a tranche using ERC1967 proxy deterministically
    /// @param _implementation The implementation address
    /// @param _salt The salt for the deployment
    /// @return proxy The deployed proxy address
    function _deployERC1967ProxyDeterministic(address _implementation, bytes32 _salt) internal returns (address proxy) {
        proxy = Create2.deploy(0, _salt, abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(_implementation, "")));
    }
}
