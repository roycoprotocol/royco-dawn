// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IAccessManager } from "../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { RoycoFactory } from "../src/RoycoFactory.sol";
import { RoycoAccountant } from "../src/accountant/RoycoAccountant.sol";
import { RoycoRoles } from "../src/auth/RoycoRoles.sol";
import { IRoycoAccountant } from "../src/interfaces/IRoycoAccountant.sol";
import { IRoycoAuth } from "../src/interfaces/IRoycoAuth.sol";
import { IRoycoFactory } from "../src/interfaces/IRoycoFactory.sol";
import { IRoycoKernel } from "../src/interfaces/kernel/IRoycoKernel.sol";
import { IRoycoAsyncCancellableVault } from "../src/interfaces/tranche/IRoycoAsyncCancellableVault.sol";
import { IRoycoAsyncVault } from "../src/interfaces/tranche/IRoycoAsyncVault.sol";
import { IRoycoVaultTranche } from "../src/interfaces/tranche/IRoycoVaultTranche.sol";
import { ERC4626_ST_AaveV3_JT_IdenticalAssets_Kernel } from "../src/kernels/ERC4626_ST_AaveV3_JT_IdenticalAssets_Kernel.sol";
import { RoycoKernelInitParams } from "../src/libraries/RoycoKernelStorageLib.sol";
import { DeployedContracts, MarketDeploymentParams, RolesConfiguration, TrancheDeploymentParams } from "../src/libraries/Types.sol";
import { RoycoJT } from "../src/tranches/RoycoJT.sol";
import { RoycoST } from "../src/tranches/RoycoST.sol";
import { StaticCurveYDM } from "../src/ydm/StaticCurveYDM.sol";
import { Create2DeployUtils } from "./Create2DeployUtils.sol";
import { Script } from "lib/forge-std/src/Script.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

contract DeployScript is Script, Create2DeployUtils, RoycoRoles {
    // Deployment salts for CREATE2
    bytes32 constant ACCOUNTANT_IMPL_SALT = keccak256("ROYCO_ACCOUNTANT_IMPLEMENTATION_V1");
    bytes32 constant KERNEL_IMPL_SALT = keccak256("ROYCO_KERNEL_IMPLEMENTATION_V1");
    bytes32 constant ST_TRANCHE_IMPL_SALT = keccak256("ROYCO_ST_TRANCHE_IMPLEMENTATION_V1");
    bytes32 constant JT_TRANCHE_IMPL_SALT = keccak256("ROYCO_JT_TRANCHE_IMPLEMENTATION_V1");
    bytes32 constant YDM_SALT = keccak256("ROYCO_YDM_IMPLEMENTATION_V1");
    bytes32 constant FACTORY_SALT_BASE = keccak256("ROYCO_FACTORY_IMPLEMENTATION_V1");
    bytes32 constant MARKET_DEPLOYMENT_SALT = keccak256("ROYCO_MARKET_DEPLOYMENT_V2");

    function run() external {
        // Read deployer private key
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementations using CREATE2
        RoycoAccountant accountantImpl = _deployAccountantImpl();
        ERC4626_ST_AaveV3_JT_IdenticalAssets_Kernel kernelImpl = _deployKernelImpl();
        RoycoST stTrancheImpl = _deploySTTrancheImpl();
        RoycoJT jtTrancheImpl = _deployJTTrancheImpl();
        StaticCurveYDM ydm = _deployYDM();
        RoycoFactory factory = _deployFactory();

        // Deploy market using factory
        _deployMarket(factory, accountantImpl, kernelImpl, stTrancheImpl, jtTrancheImpl, address(ydm));

        // Transfer factory ownership to new admin if provided
        _transferFactoryOwnership(factory, deployerPrivateKey);

        vm.stopBroadcast();
    }

    function _deployAccountantImpl() internal returns (RoycoAccountant) {
        bytes memory creationCode = type(RoycoAccountant).creationCode;

        (address addr, bool alreadyDeployed) = deployWithSanityChecks(ACCOUNTANT_IMPL_SALT, creationCode, false);
        if (alreadyDeployed) {
            console2.log("Accountant implementation already deployed at:", addr);
        } else {
            console2.log("Accountant implementation deployed at:", addr);
        }
        return RoycoAccountant(addr);
    }

    function _deployKernelImpl() internal returns (ERC4626_ST_AaveV3_JT_IdenticalAssets_Kernel) {
        bytes memory creationCode = type(ERC4626_ST_AaveV3_JT_IdenticalAssets_Kernel).creationCode;

        (address addr, bool alreadyDeployed) = deployWithSanityChecks(KERNEL_IMPL_SALT, creationCode, false);
        if (alreadyDeployed) {
            console2.log("Kernel implementation already deployed at:", addr);
        } else {
            console2.log("Kernel implementation deployed at:", addr);
        }
        return ERC4626_ST_AaveV3_JT_IdenticalAssets_Kernel(addr);
    }

    function _deploySTTrancheImpl() internal returns (RoycoST) {
        bytes memory creationCode = type(RoycoST).creationCode;

        (address addr, bool alreadyDeployed) = deployWithSanityChecks(ST_TRANCHE_IMPL_SALT, creationCode, false);
        if (alreadyDeployed) {
            console2.log("ST tranche implementation already deployed at:", addr);
        } else {
            console2.log("ST tranche implementation deployed at:", addr);
        }
        return RoycoST(addr);
    }

    function _deployJTTrancheImpl() internal returns (RoycoJT) {
        bytes memory creationCode = type(RoycoJT).creationCode;

        (address addr, bool alreadyDeployed) = deployWithSanityChecks(JT_TRANCHE_IMPL_SALT, creationCode, false);
        if (alreadyDeployed) {
            console2.log("JT tranche implementation already deployed at:", addr);
        } else {
            console2.log("JT tranche implementation deployed at:", addr);
        }
        return RoycoJT(addr);
    }

    function _deployYDM() internal returns (StaticCurveYDM) {
        bytes memory creationCode = type(StaticCurveYDM).creationCode;

        (address addr, bool alreadyDeployed) = deployWithSanityChecks(YDM_SALT, creationCode, false);
        if (alreadyDeployed) {
            console2.log("YDM already deployed at:", addr);
        } else {
            console2.log("YDM deployed at:", addr);
        }
        return StaticCurveYDM(addr);
    }

    function _deployFactory() internal returns (RoycoFactory) {
        address factoryAdmin = vm.envAddress("FACTORY_ADMIN");
        bytes memory creationCode = abi.encodePacked(type(RoycoFactory).creationCode, abi.encode(factoryAdmin));

        (address addr, bool alreadyDeployed) = deployWithSanityChecks(FACTORY_SALT_BASE, creationCode, false);
        if (alreadyDeployed) {
            console2.log("Factory already deployed at:", addr);
        } else {
            console2.log("Factory deployed at:", addr);
        }
        return RoycoFactory(addr);
    }

    function _deployMarket(
        RoycoFactory factory,
        RoycoAccountant accountantImpl,
        ERC4626_ST_AaveV3_JT_IdenticalAssets_Kernel kernelImpl,
        RoycoST stTrancheImpl,
        RoycoJT jtTrancheImpl,
        address ydmAddress
    )
        internal
    {
        // Read configuration from environment variables
        bytes32 marketId = vm.envBytes32("MARKET_ID");

        // Precompute expected proxy addresses using inline salt
        bytes32 salt = MARKET_DEPLOYMENT_SALT;
        address expectedSeniorTrancheAddress = factory.predictERC1967ProxyAddress(address(stTrancheImpl), salt);
        address expectedJuniorTrancheAddress = factory.predictERC1967ProxyAddress(address(jtTrancheImpl), salt);
        address expectedKernelAddress = factory.predictERC1967ProxyAddress(address(kernelImpl), salt);
        address expectedAccountantAddress = factory.predictERC1967ProxyAddress(address(accountantImpl), salt);

        console2.log("Expected Senior Tranche Address:", expectedSeniorTrancheAddress);
        console2.log("Expected Junior Tranche Address:", expectedJuniorTrancheAddress);
        console2.log("Expected Kernel Address:", expectedKernelAddress);
        console2.log("Expected Accountant Address:", expectedAccountantAddress);

        // Build initialization data
        address factoryAddress = address(factory);
        bytes memory kernelInitializationData =
            _buildKernelInitializationData(expectedSeniorTrancheAddress, expectedJuniorTrancheAddress, expectedAccountantAddress, factoryAddress);
        bytes memory accountantInitializationData = _buildAccountantInitializationData(expectedKernelAddress, ydmAddress, factoryAddress);
        bytes memory seniorTrancheInitializationData = _buildSeniorTrancheInitializationData(expectedKernelAddress, marketId, factoryAddress);
        bytes memory juniorTrancheInitializationData = _buildJuniorTrancheInitializationData(expectedKernelAddress, marketId, factoryAddress);

        // Build roles configuration
        RolesConfiguration[] memory roles =
            _buildRolesConfiguration(expectedSeniorTrancheAddress, expectedJuniorTrancheAddress, expectedKernelAddress, expectedAccountantAddress);

        // Build market deployment params
        MarketDeploymentParams memory params = MarketDeploymentParams({
            seniorTrancheName: vm.envString("SENIOR_TRANCHE_NAME"),
            seniorTrancheSymbol: vm.envString("SENIOR_TRANCHE_SYMBOL"),
            juniorTrancheName: vm.envString("JUNIOR_TRANCHE_NAME"),
            juniorTrancheSymbol: vm.envString("JUNIOR_TRANCHE_SYMBOL"),
            seniorAsset: vm.envAddress("SENIOR_ASSET"),
            juniorAsset: vm.envAddress("JUNIOR_ASSET"),
            marketId: marketId,
            seniorTrancheImplementation: IRoycoVaultTranche(address(stTrancheImpl)),
            juniorTrancheImplementation: IRoycoVaultTranche(address(jtTrancheImpl)),
            kernelImplementation: IRoycoKernel(address(kernelImpl)),
            accountantImplementation: IRoycoAccountant(address(accountantImpl)),
            seniorTrancheInitializationData: seniorTrancheInitializationData,
            juniorTrancheInitializationData: juniorTrancheInitializationData,
            kernelInitializationData: kernelInitializationData,
            accountantInitializationData: accountantInitializationData,
            seniorTrancheProxyDeploymentSalt: salt,
            juniorTrancheProxyDeploymentSalt: salt,
            kernelProxyDeploymentSalt: salt,
            accountantProxyDeploymentSalt: salt,
            roles: roles
        });

        // Deploy market
        console2.log("Deploying market...");
        DeployedContracts memory deployedContracts = factory.deployMarket(params);

        console2.log("Market deployed successfully!");
        console2.log("Senior Tranche:", address(deployedContracts.seniorTranche));
        console2.log("Junior Tranche:", address(deployedContracts.juniorTranche));
        console2.log("Kernel:", address(deployedContracts.kernel));
        console2.log("Accountant:", address(deployedContracts.accountant));
    }

    function _buildKernelInitializationData(
        address expectedSeniorTrancheAddress,
        address expectedJuniorTrancheAddress,
        address expectedAccountantAddress,
        address factoryAddress
    )
        internal
        view
        returns (bytes memory)
    {
        address protocolFeeRecipient = vm.envAddress("PROTOCOL_FEE_RECIPIENT");
        address stVault = vm.envAddress("ST_VAULT_ADDRESS");
        address aaveV3Pool = vm.envAddress("AAVE_V3_POOL_ADDRESS");
        uint24 jtRedemptionDelay = uint24(vm.envUint("JT_REDEMPTION_DELAY_SECONDS"));

        RoycoKernelInitParams memory kernelParams = RoycoKernelInitParams({
            initialAuthority: factoryAddress,
            seniorTranche: expectedSeniorTrancheAddress,
            juniorTranche: expectedJuniorTrancheAddress,
            accountant: expectedAccountantAddress,
            protocolFeeRecipient: protocolFeeRecipient,
            jtRedemptionDelayInSeconds: jtRedemptionDelay
        });

        return abi.encodeCall(ERC4626_ST_AaveV3_JT_IdenticalAssets_Kernel.initialize, (kernelParams, stVault, aaveV3Pool));
    }

    function _buildAccountantInitializationData(address expectedKernelAddress, address ydmAddress, address factoryAddress)
        internal
        view
        returns (bytes memory)
    {
        uint64 stProtocolFeeWAD = uint64(vm.envUint("ST_PROTOCOL_FEE_WAD"));
        uint64 jtProtocolFeeWAD = uint64(vm.envUint("JT_PROTOCOL_FEE_WAD"));
        uint64 coverageWAD = uint64(vm.envUint("COVERAGE_WAD"));
        uint96 betaWAD = uint96(vm.envUint("BETA_WAD"));

        IRoycoAccountant.RoycoAccountantInitParams memory accountantParams = IRoycoAccountant.RoycoAccountantInitParams({
            kernel: expectedKernelAddress,
            stProtocolFeeWAD: stProtocolFeeWAD,
            jtProtocolFeeWAD: jtProtocolFeeWAD,
            coverageWAD: coverageWAD,
            betaWAD: betaWAD,
            ydm: ydmAddress,
            ydmInitializationData: new bytes(0)
        });

        return abi.encodeCall(RoycoAccountant.initialize, (accountantParams, factoryAddress));
    }

    function _buildSeniorTrancheInitializationData(
        address expectedKernelAddress,
        bytes32 marketId,
        address factoryAddress
    )
        internal
        view
        returns (bytes memory)
    {
        string memory name = vm.envString("SENIOR_TRANCHE_NAME");
        string memory symbol = vm.envString("SENIOR_TRANCHE_SYMBOL");

        TrancheDeploymentParams memory trancheParams = TrancheDeploymentParams({ name: name, symbol: symbol, kernel: expectedKernelAddress });

        address seniorAsset = vm.envAddress("SENIOR_ASSET");

        return abi.encodeCall(RoycoST.initialize, (trancheParams, seniorAsset, factoryAddress, marketId));
    }

    function _buildJuniorTrancheInitializationData(
        address expectedKernelAddress,
        bytes32 marketId,
        address factoryAddress
    )
        internal
        view
        returns (bytes memory)
    {
        string memory name = vm.envString("JUNIOR_TRANCHE_NAME");
        string memory symbol = vm.envString("JUNIOR_TRANCHE_SYMBOL");

        TrancheDeploymentParams memory trancheParams = TrancheDeploymentParams({ name: name, symbol: symbol, kernel: expectedKernelAddress });

        address juniorAsset = vm.envAddress("JUNIOR_ASSET");

        return abi.encodeCall(RoycoJT.initialize, (trancheParams, juniorAsset, factoryAddress, marketId));
    }

    function _buildRolesConfiguration(
        address seniorTranche,
        address juniorTranche,
        address kernel,
        address accountant
    )
        internal
        view
        returns (RolesConfiguration[] memory roles)
    {
        // Get role addresses from environment
        address pauser = vm.envAddress("PAUSER_ADDRESS");
        address upgrader = vm.envAddress("UPGRADER_ADDRESS");
        address depositRole = vm.envAddress("DEPOSIT_ROLE_ADDRESS");
        address redeemRole = vm.envAddress("REDEEM_ROLE_ADDRESS");
        address syncRole = vm.envAddress("SYNC_ROLE_ADDRESS");
        address kernelAdmin = vm.envAddress("KERNEL_ADMIN_ROLE_ADDRESS");

        // Count how many role configurations we need
        uint256 roleCount = 4; // ST, JT, Kernel, Accountant

        roles = new RolesConfiguration[](roleCount);
        uint256 index = 0;

        // Senior Tranche roles
        bytes4[] memory stSelectors = new bytes4[](12);
        uint64[] memory stRoles = new uint64[](12);

        stSelectors[0] = IRoycoVaultTranche.deposit.selector;
        stRoles[0] = DEPOSIT_ROLE;
        stSelectors[1] = IRoycoVaultTranche.redeem.selector;
        stRoles[1] = REDEEM_ROLE;
        stSelectors[2] = IRoycoAsyncVault.requestDeposit.selector;
        stRoles[2] = DEPOSIT_ROLE;
        stSelectors[3] = IRoycoAsyncVault.requestRedeem.selector;
        stRoles[3] = REDEEM_ROLE;
        stSelectors[4] = IRoycoAsyncCancellableVault.cancelDepositRequest.selector;
        stRoles[4] = CANCEL_DEPOSIT_ROLE;
        stSelectors[5] = IRoycoAsyncCancellableVault.claimCancelDepositRequest.selector;
        stRoles[5] = CANCEL_DEPOSIT_ROLE;
        stSelectors[6] = IRoycoAsyncCancellableVault.cancelRedeemRequest.selector;
        stRoles[6] = CANCEL_REDEEM_ROLE;
        stSelectors[7] = IRoycoAsyncCancellableVault.claimCancelRedeemRequest.selector;
        stRoles[7] = CANCEL_REDEEM_ROLE;
        stSelectors[8] = IRoycoAuth.pause.selector;
        stRoles[8] = PAUSER_ROLE;
        stSelectors[9] = IRoycoAuth.unpause.selector;
        stRoles[9] = PAUSER_ROLE;
        stSelectors[10] = bytes4(0xe4cca4b0);
        stRoles[10] = DEPOSIT_ROLE;
        stSelectors[11] = bytes4(0x9f40a7b3);
        stRoles[11] = REDEEM_ROLE;

        roles[index++] = RolesConfiguration({ target: seniorTranche, selectors: stSelectors, roles: stRoles });

        // Junior Tranche roles (same as senior)
        bytes4[] memory jtSelectors = new bytes4[](10);
        uint64[] memory jtRoles = new uint64[](10);
        for (uint256 i = 0; i < 10; i++) {
            jtSelectors[i] = stSelectors[i];
            jtRoles[i] = stRoles[i];
        }

        roles[index++] = RolesConfiguration({ target: juniorTranche, selectors: jtSelectors, roles: jtRoles });

        // Kernel roles
        bytes4[] memory kernelSelectors = new bytes4[](5);
        uint64[] memory kernelRoleValues = new uint64[](5);

        kernelSelectors[0] = IRoycoKernel.setProtocolFeeRecipient.selector;
        kernelRoleValues[0] = KERNEL_ADMIN_ROLE;
        kernelSelectors[1] = IRoycoKernel.syncTrancheAccounting.selector;
        kernelRoleValues[1] = SYNC_ROLE;
        kernelSelectors[2] = IRoycoAuth.pause.selector;
        kernelRoleValues[2] = PAUSER_ROLE;
        kernelSelectors[3] = IRoycoAuth.unpause.selector;
        kernelRoleValues[3] = PAUSER_ROLE;
        kernelSelectors[4] = IRoycoKernel.setJuniorTrancheRedemptionDelay.selector;
        kernelRoleValues[4] = KERNEL_ADMIN_ROLE;

        roles[index++] = RolesConfiguration({ target: kernel, selectors: kernelSelectors, roles: kernelRoleValues });

        // Accountant roles
        bytes4[] memory accountantSelectors = new bytes4[](7);
        uint64[] memory accountantRoleValues = new uint64[](7);

        accountantSelectors[0] = IRoycoAccountant.setYDM.selector;
        accountantRoleValues[0] = KERNEL_ADMIN_ROLE;
        accountantSelectors[1] = IRoycoAccountant.setSeniorTrancheProtocolFee.selector;
        accountantRoleValues[1] = KERNEL_ADMIN_ROLE;
        accountantSelectors[2] = IRoycoAccountant.setJuniorTrancheProtocolFee.selector;
        accountantRoleValues[2] = KERNEL_ADMIN_ROLE;
        accountantSelectors[3] = IRoycoAccountant.setCoverage.selector;
        accountantRoleValues[3] = KERNEL_ADMIN_ROLE;
        accountantSelectors[4] = IRoycoAccountant.setBeta.selector;
        accountantRoleValues[4] = KERNEL_ADMIN_ROLE;
        accountantSelectors[5] = IRoycoAuth.pause.selector;
        accountantRoleValues[5] = PAUSER_ROLE;
        accountantSelectors[6] = IRoycoAuth.unpause.selector;
        accountantRoleValues[6] = PAUSER_ROLE;

        roles[index++] = RolesConfiguration({ target: accountant, selectors: accountantSelectors, roles: accountantRoleValues });
    }

    function _transferFactoryOwnership(RoycoFactory factory, uint256 deployerPrivateKey) internal {
        address newAdmin = vm.envAddress("FACTORY_OWNER_ADDRESS");

        address deployerAddress = vm.addr(deployerPrivateKey);

        // Check if deployer is already the admin
        (bool isDeployerAdmin,) = IAccessManager(address(factory)).hasRole(0, deployerAddress);
        if (!isDeployerAdmin) {
            revert("Deployer is not factory admin, cannot transfer ownership");
        }

        // Check if new admin is already admin
        (bool isNewAdminAdmin,) = IAccessManager(address(factory)).hasRole(0, newAdmin);
        if (isNewAdminAdmin) {
            console2.log("New admin already has ADMIN_ROLE, skipping transfer");
            return;
        }

        console2.log("Transferring factory ownership to:", newAdmin);

        // Grant ADMIN_ROLE to new admin (execution delay = 0 for immediate effect)
        IAccessManager(address(factory)).grantRole(0, newAdmin, 0);

        console2.log("Factory ownership transferred successfully");
        console2.log("New factory admin:", newAdmin);

        // Revoke deployer's admin role
        IAccessManager(address(factory)).revokeRole(0, deployerAddress);
        console2.log("Deployer admin role revoked");
    }
}
