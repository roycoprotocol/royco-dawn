// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoFactory } from "../../src/RoycoFactory.sol";
import { RoycoAccountant } from "../../src/accountant/RoycoAccountant.sol";
import { IPool } from "../../src/interfaces/aave/IPool.sol";
import { ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../../src/libraries/Constants.sol";
import { RoycoAccountantInitParams, RoycoAccountantState } from "../../src/libraries/RoycoAccountantStorageLib.sol";
import { RoycoKernelInitParams, RoycoKernelState } from "../../src/libraries/RoycoKernelStorageLib.sol";
import { IRoycoAccountant, IRoycoKernel, MarketDeploymentParams, TrancheDeploymentParams } from "../../src/libraries/Types.sol";
import { MainnetForkWithAaveTestBase } from "./base/MainnetForkWithAaveBaseTest.sol";

contract DeploymentsTest is MainnetForkWithAaveTestBase {
    constructor() {
        BETA_WAD = 1e18; // Same opportunities
    }

    function setUp() public {
        _setUpRoyco();
    }

    /// @notice Verifies senior tranche deployment parameters
    function test_SeniorTrancheDeployment() public {
        // Basic wiring
        assertTrue(address(ST) != address(0), "Senior tranche not deployed");
        // Kernel wiring
        assertEq(ST.kernel(), address(KERNEL), "ST KERNEL address mismatch");
        assertEq(ST.marketId(), MARKET_ID, "ST MARKET_ID mismatch");

        // Asset and metadata
        assertEq(address(ST.asset()), ETHEREUM_MAINNET_USDC_ADDRESS, "ST asset should be USDC");
        assertEq(ST.name(), SENIOR_TRANCH_NAME, "ST name mismatch");
        assertEq(ST.symbol(), SENIOR_TRANCH_SYMBOL, "ST symbol mismatch");

        // Initial NAV and totals
        assertEq(ST.totalSupply(), 0, "ST initial totalSupply should be 0");
        assertEq(ST.getRawNAV(), ZERO_NAV_UNITS, "ST initial raw NAV should be 0");
        assertEq(ST.totalAssets().effectiveNAV, ZERO_NAV_UNITS, "ST initial effective NAV should be 0");
        assertEq(ST.totalAssets().stAssets, ZERO_TRANCHE_UNITS, "ST initial total st assets should be 0");
        assertEq(ST.totalAssets().jtAssets, ZERO_TRANCHE_UNITS, "ST initial total jt assets should be 0");
    }

    /// @notice Verifies junior tranche deployment parameters
    function test_JuniorTrancheDeployment() public {
        // Basic wiring
        assertTrue(address(JT) != address(0), "Junior tranche not deployed");
        // Kernel wiring
        assertEq(JT.kernel(), address(KERNEL), "JT KERNEL address mismatch");
        assertEq(JT.marketId(), MARKET_ID, "JT MARKET_ID mismatch");

        // Asset and metadata
        assertEq(address(JT.asset()), ETHEREUM_MAINNET_USDC_ADDRESS, "JT asset should be USDC");
        assertEq(JT.name(), JUNIOR_TRANCH_NAME, "JT name mismatch");
        assertEq(JT.symbol(), JUNIOR_TRANCH_SYMBOL, "JT symbol mismatch");

        // Initial NAV and totals
        assertEq(JT.totalSupply(), 0, "JT initial totalSupply should be 0");
        assertEq(JT.getRawNAV(), ZERO_NAV_UNITS, "JT initial raw NAV should be 0");
        assertEq(JT.totalAssets().effectiveNAV, ZERO_NAV_UNITS, "JT initial effective NAV should be 0");
        assertEq(JT.totalAssets().stAssets, ZERO_TRANCHE_UNITS, "JT initial total st assets should be 0");
        assertEq(JT.totalAssets().jtAssets, ZERO_TRANCHE_UNITS, "JT initial total jt assets should be 0");
    }

    /// @notice Verifies kernel and accountant deployment parameters and wiring
    function test_KernelAndAccountantDeployment() public {
        // Basic wiring
        assertTrue(address(KERNEL) != address(0), "Kernel not deployed");

        RoycoKernelState memory kernelState = KERNEL.getState();
        RoycoAccountantState memory accountantState = ACCOUNTANT.getState();

        // Tranche wiring
        assertEq(kernelState.seniorTranche, address(ST), "Kernel ST mismatch");
        assertEq(kernelState.juniorTranche, address(JT), "Kernel JT mismatch");
        assertEq(kernelState.accountant, address(ACCOUNTANT), "Kernel accountant mismatch");
        assertEq(kernelState.protocolFeeRecipient, PROTOCOL_FEE_RECIPIENT_ADDRESS, "Kernel protocolFeeRecipient mismatch");

        // Coverage, beta, protocol fee configuration
        assertEq(accountantState.coverageWAD, COVERAGE_WAD, "Kernel coverageWAD mismatch");
        assertEq(accountantState.betaWAD, BETA_WAD, "BETA_WAD mismatch");
        assertEq(accountantState.protocolFeeWAD, PROTOCOL_FEE_WAD, "Kernel protocolFeeWAD mismatch");

        // RDM wiring
        assertEq(accountantState.rdm, address(RDM), "Kernel RDM mismatch");

        // Initial NAV / ASSETS via KERNEL view functions
        assertEq(KERNEL.getSTAssetClaims().effectiveNAV, ZERO_NAV_UNITS, "Kernel ST total effective ASSETS should be 0");
        assertEq(KERNEL.getJTAssetClaims().effectiveNAV, ZERO_NAV_UNITS, "Kernel JT total effective ASSETS should be 0");
        assertEq(KERNEL.getSTRawNAV(), ZERO_NAV_UNITS, "Kernel ST raw NAV should be 0");
        assertEq(KERNEL.getJTRawNAV(), ZERO_NAV_UNITS, "Kernel JT raw NAV should be 0");

        // Aave wiring: pool and AUSDC mapping must be consistent
        address expectedAToken = IPool(ETHEREUM_MAINNET_AAVE_V3_POOL_ADDRESS).getReserveAToken(ETHEREUM_MAINNET_USDC_ADDRESS);
        assertEq(expectedAToken, address(AUSDC), "AUSDC address should match Aave pool data");
    }

    function test_deployMarket_revertsOnEmptySeniorTrancheName() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.seniorTrancheName = "";

        vm.expectRevert(RoycoFactory.InvalidName.selector);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnEmptySeniorTrancheSymbol() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.seniorTrancheSymbol = "";

        vm.expectRevert(RoycoFactory.InvalidSymbol.selector);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnEmptyJuniorTrancheName() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.juniorTrancheName = "";

        vm.expectRevert(RoycoFactory.InvalidName.selector);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnEmptyJuniorTrancheSymbol() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.juniorTrancheSymbol = "";

        vm.expectRevert(RoycoFactory.InvalidSymbol.selector);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnZeroSeniorAsset() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.seniorAsset = address(0);

        vm.expectRevert(RoycoFactory.InvalidAsset.selector);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnZeroJuniorAsset() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.juniorAsset = address(0);

        vm.expectRevert(RoycoFactory.InvalidAsset.selector);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnZeroMarketId() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.marketId = bytes32(0);

        vm.expectRevert(RoycoFactory.InvalidMarketId.selector);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnZeroKernelImplementation() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.kernelImplementation = IRoycoKernel(address(0));

        vm.expectRevert(RoycoFactory.InvalidKernelImplementation.selector);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnZeroAccountantImplementation() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.accountantImplementation = IRoycoAccountant(address(0));

        vm.expectRevert(RoycoFactory.InvalidAccountantImplementation.selector);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnEmptyKernelInitializationData() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.kernelInitializationData = "";

        vm.expectRevert(RoycoFactory.InvalidKernelInitializationData.selector);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnEmptyAccountantInitializationData() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.accountantInitializationData = "";

        vm.expectRevert(RoycoFactory.InvalidAccountantInitializationData.selector);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnZeroSeniorTrancheProxyDeploymentSalt() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.seniorTrancheProxyDeploymentSalt = bytes32(0);

        vm.expectRevert(RoycoFactory.InvalidSeniorTrancheProxyDeploymentSalt.selector);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnZeroJuniorTrancheProxyDeploymentSalt() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.juniorTrancheProxyDeploymentSalt = bytes32(0);

        vm.expectRevert(RoycoFactory.InvalidJuniorTrancheProxyDeploymentSalt.selector);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnZeroKernelProxyDeploymentSalt() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.kernelProxyDeploymentSalt = bytes32(0);

        vm.expectRevert(RoycoFactory.InvalidKernelProxyDeploymentSalt.selector);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnZeroAccountantProxyDeploymentSalt() public {
        (MarketDeploymentParams memory params,,) = _buildValidMarketParams();
        params.accountantProxyDeploymentSalt = bytes32(0);

        vm.expectRevert(RoycoFactory.InvalidAccountantProxyDeploymentSalt.selector);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnFailedSeniorTrancheInitialization() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "FAILED_ST_INIT"));
        (MarketDeploymentParams memory params, bytes32 marketId) = _buildValidMarketParamsForSalt(salt);

        // Provide non-empty but invalid initialization data so the call to the senior tranche fails
        params.seniorTrancheInitializationData = abi.encodeWithSignature("nonExistentFunction(address)", address(this));

        vm.expectRevert(abi.encodeWithSelector(RoycoFactory.FailedToInitializeSeniorTranche.selector, ""));
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnFailedJuniorTrancheInitialization() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "FAILED_JT_INIT"));
        (MarketDeploymentParams memory params, bytes32 marketId) = _buildValidMarketParamsForSalt(salt);

        // Provide non-empty but invalid initialization data so the call to the junior tranche fails
        params.juniorTrancheInitializationData = abi.encodeWithSignature("nonExistentFunction(address)", address(this));

        vm.expectRevert(abi.encodeWithSelector(RoycoFactory.FailedToInitializeJuniorTranche.selector, ""));
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnFailedAccountantInitialization() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "FAILED_ACCOUNTANT_INIT"));
        (MarketDeploymentParams memory params, bytes32 marketId) = _buildValidMarketParamsForSalt(salt);

        // Provide invalid (but non-empty) initialization data so the call to the accountant fails
        params.accountantInitializationData = abi.encodeWithSignature("nonExistentFunction(address)", address(this));

        vm.expectRevert(abi.encodeWithSelector(RoycoFactory.FailedToInitializeAccountant.selector, ""));
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnFailedKernelInitialization() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "FAILED_KERNEL_INIT"));
        (MarketDeploymentParams memory params, bytes32 marketId) = _buildValidMarketParamsForSalt(salt);

        // Provide invalid (but non-empty) initialization data so the call to the kernel fails
        params.kernelInitializationData = abi.encodeWithSignature("nonExistentFunction(address)", address(this));

        vm.expectRevert(abi.encodeWithSelector(RoycoFactory.FailedToInitializeKernel.selector, ""));
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnInvalidAccessManager() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "INVALID_ACCESS_MANAGER"));
        (MarketDeploymentParams memory params, bytes32 marketId) = _buildValidMarketParamsForSalt(salt);

        // Rebuild only the senior tranche initialization data with an invalid authority
        address expectedKernelAddress = FACTORY.predictERC1967ProxyAddress(address(USDC_ERC4626_AaveV3JT_KERNEL_IMPL), salt);

        params.seniorTrancheInitializationData = abi.encodeCall(
            ST_IMPL.initialize,
            (
                TrancheDeploymentParams({ name: SENIOR_TRANCH_NAME, symbol: SENIOR_TRANCH_SYMBOL, kernel: expectedKernelAddress }),
                ETHEREUM_MAINNET_USDC_ADDRESS,
                OWNER_ADDRESS, // invalid authority: should be FACTORY
                marketId
            )
        );

        vm.expectRevert(RoycoFactory.InvalidAccessManager.selector);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnInvalidAccessManagerForAccountant() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "INVALID_ACCESS_MANAGER_ACCOUNTANT"));
        (MarketDeploymentParams memory params,) = _buildValidMarketParamsForSalt(salt);

        // Rebuild only the accountant initialization data with an invalid authority
        address expectedKernelAddress = FACTORY.predictERC1967ProxyAddress(address(USDC_ERC4626_AaveV3JT_KERNEL_IMPL), salt);

        params.accountantInitializationData = abi.encodeCall(
            RoycoAccountant.initialize,
            (
                RoycoAccountantInitParams({
                    kernel: expectedKernelAddress, protocolFeeWAD: PROTOCOL_FEE_WAD, coverageWAD: COVERAGE_WAD, betaWAD: BETA_WAD, rdm: address(RDM)
                }),
                OWNER_ADDRESS // invalid authority: should be FACTORY
            )
        );

        vm.expectRevert(RoycoFactory.InvalidAccessManager.selector);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnInvalidAccessManagerForKernel() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "INVALID_ACCESS_MANAGER_KERNEL"));
        (MarketDeploymentParams memory params,) = _buildValidMarketParamsForSalt(salt);

        // Rebuild only the kernel initialization data with an invalid authority
        address expectedSeniorTrancheAddress = FACTORY.predictERC1967ProxyAddress(address(ST_IMPL), salt);
        address expectedJuniorTrancheAddress = FACTORY.predictERC1967ProxyAddress(address(JT_IMPL), salt);
        address expectedAccountantAddress = FACTORY.predictERC1967ProxyAddress(address(ACCOUNTANT_IMPL), salt);

        params.kernelInitializationData = abi.encodeCall(
            USDC_ERC4626_AaveV3JT_KERNEL_IMPL.initialize,
            (
                RoycoKernelInitParams({
                    seniorTranche: expectedSeniorTrancheAddress,
                    juniorTranche: expectedJuniorTrancheAddress,
                    accountant: expectedAccountantAddress,
                    protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT_ADDRESS
                }),
                OWNER_ADDRESS, // invalid authority: should be FACTORY
                address(MOCK_UNDERLYING_ST_VAULT),
                ETHEREUM_MAINNET_AAVE_V3_POOL_ADDRESS
            )
        );

        vm.expectRevert(RoycoFactory.InvalidAccessManager.selector);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnInvalidAccessManagerForJuniorTranche() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "INVALID_ACCESS_MANAGER_JT"));
        (MarketDeploymentParams memory params, bytes32 marketId) = _buildValidMarketParamsForSalt(salt);

        // Rebuild only the junior tranche initialization data with an invalid authority
        address expectedKernelAddress = FACTORY.predictERC1967ProxyAddress(address(USDC_ERC4626_AaveV3JT_KERNEL_IMPL), salt);

        params.juniorTrancheInitializationData = abi.encodeCall(
            JT_IMPL.initialize,
            (
                TrancheDeploymentParams({ name: JUNIOR_TRANCH_NAME, symbol: JUNIOR_TRANCH_SYMBOL, kernel: expectedKernelAddress }),
                ETHEREUM_MAINNET_USDC_ADDRESS,
                OWNER_ADDRESS, // invalid authority: should be FACTORY
                marketId
            )
        );

        vm.expectRevert(RoycoFactory.InvalidAccessManager.selector);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnInvalidKernelOnSeniorTranche() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "INVALID_KERNEL_ST"));
        (MarketDeploymentParams memory params, bytes32 marketId) = _buildValidMarketParamsForSalt(salt);

        // Use an previously deployed kernel address in the senior tranche initialization params
        // This should revert as the call with deploy a new kernel and check against that
        address wrongKernelAddress = address(KERNEL);

        params.seniorTrancheInitializationData = abi.encodeCall(
            ST_IMPL.initialize,
            (
                TrancheDeploymentParams({ name: SENIOR_TRANCH_NAME, symbol: SENIOR_TRANCH_SYMBOL, kernel: wrongKernelAddress }),
                ETHEREUM_MAINNET_USDC_ADDRESS,
                address(FACTORY),
                marketId
            )
        );

        // The deployment should revert due to inconsistent senior tranche kernel wiring
        vm.expectRevert(RoycoFactory.InvalidKernelOnSeniorTranche.selector);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnInvalidKernelOnJuniorTranche() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "INVALID_KERNEL_JT"));
        (MarketDeploymentParams memory params, bytes32 marketId) = _buildValidMarketParamsForSalt(salt);

        // Use an previously deployed kernel address in the junior tranche initialization params
        // This should revert as the call with deploy a new kernel and check against that
        address wrongKernelAddress = address(KERNEL);

        params.juniorTrancheInitializationData = abi.encodeCall(
            JT_IMPL.initialize,
            (
                TrancheDeploymentParams({ name: JUNIOR_TRANCH_NAME, symbol: JUNIOR_TRANCH_SYMBOL, kernel: wrongKernelAddress }),
                ETHEREUM_MAINNET_USDC_ADDRESS,
                address(FACTORY),
                marketId
            )
        );

        // The deployment should revert due to inconsistent junior tranche kernel wiring
        vm.expectRevert(RoycoFactory.InvalidKernelOnJuniorTranche.selector);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnInvalidAccountantOnKernel() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "INVALID_ACCOUNTANT_ON_KERNEL"));
        (MarketDeploymentParams memory params, bytes32 marketId) = _buildValidMarketParamsForSalt(salt);

        // Use an incorrect accountant address in the kernel initialization params
        address expectedSeniorTrancheAddress = FACTORY.predictERC1967ProxyAddress(address(ST_IMPL), salt);
        address expectedJuniorTrancheAddress = FACTORY.predictERC1967ProxyAddress(address(JT_IMPL), salt);

        params.kernelInitializationData = abi.encodeCall(
            USDC_ERC4626_AaveV3JT_KERNEL_IMPL.initialize,
            (
                RoycoKernelInitParams({
                    seniorTranche: expectedSeniorTrancheAddress,
                    juniorTranche: expectedJuniorTrancheAddress,
                    accountant: address(0xdead), // wrong accountant
                    protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT_ADDRESS
                }),
                address(FACTORY),
                address(MOCK_UNDERLYING_ST_VAULT),
                ETHEREUM_MAINNET_AAVE_V3_POOL_ADDRESS
            )
        );

        vm.expectRevert(RoycoFactory.InvalidAccountantOnKernel.selector);
        FACTORY.deployMarket(params);
    }

    function test_deployMarket_revertsOnInvalidKernelOnAccountant() public {
        bytes32 salt = keccak256(abi.encodePacked("SALT", "INVALID_KERNEL_ON_ACCOUNTANT"));
        (MarketDeploymentParams memory params, bytes32 marketId) = _buildValidMarketParamsForSalt(salt);

        // Use an incorrect kernel address in the accountant initialization params
        params.accountantInitializationData = abi.encodeCall(
            RoycoAccountant.initialize,
            (
                RoycoAccountantInitParams({
                    kernel: address(0xdead), // wrong kernel
                    protocolFeeWAD: PROTOCOL_FEE_WAD,
                    coverageWAD: COVERAGE_WAD,
                    betaWAD: BETA_WAD,
                    rdm: address(RDM)
                }),
                address(FACTORY)
            )
        );

        vm.expectRevert(RoycoFactory.InvalidKernelOnAccountant.selector);
        FACTORY.deployMarket(params);
    }

    /// @dev Helper to construct a valid set of market deployment params that mirrors `_deployMarketWithKernel`
    /// @dev Uses a default salt; useful for tests that only hit parameter validation
    function _buildValidMarketParams() internal returns (MarketDeploymentParams memory params, bytes32 marketId, bytes32 salt) {
        salt = keccak256(abi.encodePacked("SALT"));
        (params, marketId) = _buildValidMarketParamsForSalt(salt);
    }

    /// @dev Helper to construct a valid set of market deployment params for a specific salt
    /// @dev Use this when you need to actually deploy contracts (to avoid Create2 collisions)
    function _buildValidMarketParamsForSalt(bytes32 salt) internal returns (MarketDeploymentParams memory params, bytes32 marketId) {
        marketId = keccak256(abi.encodePacked(SENIOR_TRANCH_NAME, JUNIOR_TRANCH_NAME, block.timestamp));

        // Precompute the expected addresses of the kernel and accountant
        address expectedSeniorTrancheAddress = FACTORY.predictERC1967ProxyAddress(address(ST_IMPL), salt);
        address expectedJuniorTrancheAddress = FACTORY.predictERC1967ProxyAddress(address(JT_IMPL), salt);
        address expectedKernelAddress = FACTORY.predictERC1967ProxyAddress(address(USDC_ERC4626_AaveV3JT_KERNEL_IMPL), salt);
        address expectedAccountantAddress = FACTORY.predictERC1967ProxyAddress(address(ACCOUNTANT_IMPL), salt);

        // Create the initialization data
        bytes memory kernelInitializationData = abi.encodeCall(
            USDC_ERC4626_AaveV3JT_KERNEL_IMPL.initialize,
            (
                RoycoKernelInitParams({
                    seniorTranche: expectedSeniorTrancheAddress,
                    juniorTranche: expectedJuniorTrancheAddress,
                    accountant: expectedAccountantAddress,
                    protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT_ADDRESS
                }),
                address(FACTORY),
                address(MOCK_UNDERLYING_ST_VAULT),
                ETHEREUM_MAINNET_AAVE_V3_POOL_ADDRESS
            )
        );
        bytes memory accountantInitializationData = abi.encodeCall(
            RoycoAccountant.initialize,
            (
                RoycoAccountantInitParams({
                    kernel: expectedKernelAddress, protocolFeeWAD: PROTOCOL_FEE_WAD, coverageWAD: COVERAGE_WAD, betaWAD: BETA_WAD, rdm: address(RDM)
                }),
                address(FACTORY)
            )
        );
        bytes memory seniorTrancheInitializationData = abi.encodeCall(
            ST_IMPL.initialize,
            (
                TrancheDeploymentParams({ name: SENIOR_TRANCH_NAME, symbol: SENIOR_TRANCH_SYMBOL, kernel: expectedKernelAddress }),
                ETHEREUM_MAINNET_USDC_ADDRESS,
                address(FACTORY),
                marketId
            )
        );
        bytes memory juniorTrancheInitializationData = abi.encodeCall(
            JT_IMPL.initialize,
            (
                TrancheDeploymentParams({ name: JUNIOR_TRANCH_NAME, symbol: JUNIOR_TRANCH_SYMBOL, kernel: expectedKernelAddress }),
                ETHEREUM_MAINNET_USDC_ADDRESS,
                address(FACTORY),
                marketId
            )
        );

        params = MarketDeploymentParams({
            seniorTrancheName: SENIOR_TRANCH_NAME,
            seniorTrancheSymbol: SENIOR_TRANCH_SYMBOL,
            juniorTrancheName: JUNIOR_TRANCH_NAME,
            juniorTrancheSymbol: JUNIOR_TRANCH_SYMBOL,
            seniorAsset: ETHEREUM_MAINNET_USDC_ADDRESS,
            juniorAsset: ETHEREUM_MAINNET_USDC_ADDRESS,
            marketId: marketId,
            seniorTrancheImplementation: ST_IMPL,
            juniorTrancheImplementation: JT_IMPL,
            kernelImplementation: IRoycoKernel(address(USDC_ERC4626_AaveV3JT_KERNEL_IMPL)),
            seniorTrancheInitializationData: seniorTrancheInitializationData,
            juniorTrancheInitializationData: juniorTrancheInitializationData,
            accountantImplementation: IRoycoAccountant(address(ACCOUNTANT_IMPL)),
            kernelInitializationData: kernelInitializationData,
            accountantInitializationData: accountantInitializationData,
            seniorTrancheProxyDeploymentSalt: salt,
            juniorTrancheProxyDeploymentSalt: salt,
            kernelProxyDeploymentSalt: salt,
            accountantProxyDeploymentSalt: salt
        });
    }
}
