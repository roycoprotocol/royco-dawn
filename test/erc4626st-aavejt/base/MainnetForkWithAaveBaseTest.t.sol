// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Vm } from "../../../lib/forge-std/src/Vm.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { RoycoAccountant } from "../../../src/accountant/RoycoAccountant.sol";
import { RoycoKernel } from "../../../src/kernels/base/RoycoKernel.sol";
import { RoycoKernelInitParams } from "../../../src/libraries/RoycoKernelStorageLib.sol";
import { DeployedContracts, IRoycoAccountant, IRoycoKernel, MarketDeploymentParams } from "../../../src/libraries/Types.sol";
import { TrancheDeploymentParams } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoVaultTranche } from "../../../src/tranches/RoycoVaultTranche.sol";
import { BaseTest } from "../../base/BaseTest.t.sol";
import { ERC4626Mock } from "../../mock/ERC4626Mock.sol";

abstract contract MainnetForkWithAaveTestBase is BaseTest {
    // TODO: Review All
    TRANCHE_UNIT internal AAVE_MAX_ABS_TRANCH_UNIT_DELTA = toTrancheUnits(3);
    NAV_UNIT internal AAVE_MAX_ABS_NAV_DELTA = toNAVUnits(toUint256(AAVE_MAX_ABS_TRANCH_UNIT_DELTA));
    uint256 internal constant MAX_REDEEM_RELATIVE_DELTA = 1 * BPS;
    uint256 internal constant MAX_CONVERT_TO_ASSETS_RELATIVE_DELTA = 1 * BPS;
    uint256 internal constant AAVE_PREVIEW_DEPOSIT_RELATIVE_DELTA = 1 * BPS;
    uint24 internal constant JT_REDEMPTION_DELAY_SECONDS = 1_000_000;

    Vm.Wallet internal RESERVE;
    address internal RESERVE_ADDRESS;

    // Deployed contracts
    ERC4626Mock internal MOCK_UNDERLYING_ST_VAULT;

    // External Contracts
    IERC20 internal USDC;
    IERC20 internal AUSDC;

    constructor() {
        BETA_WAD = 0; // Different opportunities
        USDC = IERC20(ETHEREUM_MAINNET_USDC_ADDRESS);
        AUSDC = IERC20(aTokenAddresses[1][ETHEREUM_MAINNET_USDC_ADDRESS]);
    }

    function _setUpRoyco() internal override {
        // Setup wallets
        RESERVE = vm.createWallet("RESERVE");
        RESERVE_ADDRESS = RESERVE.addr;
        vm.label(RESERVE_ADDRESS, "RESERVE");

        // Deploy core
        super._setUpRoyco();
        vm.label(address(USDC), "USDC");
        vm.label(address(AUSDC), "aUSDC");

        // Deal USDC to all configured addresses for mainnet fork tests
        _dealUSDCToAddresses();

        // Deploy mock senior tranche underlying vault
        MOCK_UNDERLYING_ST_VAULT = new ERC4626Mock(ETHEREUM_MAINNET_USDC_ADDRESS, RESERVE_ADDRESS);
        vm.label(address(MOCK_UNDERLYING_ST_VAULT), "MockSTUnderlyingVault");
        // Have the reserve approve the mock senior tranche underlying vault to spend USDC
        vm.prank(RESERVE_ADDRESS);
        IERC20(ETHEREUM_MAINNET_USDC_ADDRESS).approve(address(MOCK_UNDERLYING_ST_VAULT), type(uint256).max);

        // Deploy the markets
        (DeployedContracts memory deployedContracts, bytes32 marketID) = _deployMarketWithKernel();
        _setDeployedMarket(
            RoycoVaultTranche(address(deployedContracts.seniorTranche)),
            RoycoVaultTranche(address(deployedContracts.juniorTranche)),
            RoycoKernel(address(deployedContracts.kernel)),
            RoycoAccountant(address(deployedContracts.accountant)),
            marketID
        );
    }

    /// @notice Deals USDC tokens to all configured addresses for mainnet fork tests
    /// @dev Each address receives 10M USDC (10_000_000e6) to ensure sufficient balance for testing
    function _dealUSDCToAddresses() internal {
        uint256 usdcAmount = 10_000_000e6; // 10M USDC (6 decimals)

        // Deal to admin/role addresses
        deal(ETHEREUM_MAINNET_USDC_ADDRESS, OWNER_ADDRESS, usdcAmount);
        deal(ETHEREUM_MAINNET_USDC_ADDRESS, PAUSER_ADDRESS, usdcAmount);
        deal(ETHEREUM_MAINNET_USDC_ADDRESS, UPGRADER_ADDRESS, usdcAmount);
        deal(ETHEREUM_MAINNET_USDC_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, usdcAmount);

        // Deal to provider addresses
        deal(ETHEREUM_MAINNET_USDC_ADDRESS, ALICE_ADDRESS, usdcAmount);
        deal(ETHEREUM_MAINNET_USDC_ADDRESS, BOB_ADDRESS, usdcAmount);
        deal(ETHEREUM_MAINNET_USDC_ADDRESS, CHARLIE_ADDRESS, usdcAmount);
        deal(ETHEREUM_MAINNET_USDC_ADDRESS, DAN_ADDRESS, usdcAmount);

        // Deal to reserve address
        deal(ETHEREUM_MAINNET_USDC_ADDRESS, RESERVE_ADDRESS, usdcAmount);
    }

    function _deployMarketWithKernel() internal returns (DeployedContracts memory deployedContracts, bytes32 marketID) {
        marketID = keccak256(abi.encodePacked(SENIOR_TRANCH_NAME, JUNIOR_TRANCH_NAME, block.timestamp));

        // Precompute the expected addresses of the kernel and accountant
        bytes32 salt = keccak256(abi.encodePacked("SALT"));
        address expectedSeniorTrancheAddress = FACTORY.predictERC1967ProxyAddress(address(ST_IMPL), salt);
        address expectedJuniorTrancheAddress = FACTORY.predictERC1967ProxyAddress(address(JT_IMPL), salt);
        address expectedKernelAddress = FACTORY.predictERC1967ProxyAddress(address(ERC4626_ST_AaveV3_JT_IdenticalAssets_Kernel_IMPL), salt);
        address expectedAccountantAddress = FACTORY.predictERC1967ProxyAddress(address(ACCOUNTANT_IMPL), salt);

        // Create the initialization data
        bytes memory kernelInitializationData = abi.encodeCall(
            ERC4626_ST_AaveV3_JT_IdenticalAssets_Kernel_IMPL.initialize,
            (
                RoycoKernelInitParams({
                    initialAuthority: address(FACTORY),
                    seniorTranche: expectedSeniorTrancheAddress,
                    juniorTranche: expectedJuniorTrancheAddress,
                    accountant: expectedAccountantAddress,
                    protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT_ADDRESS,
                    jtRedemptionDelayInSeconds: JT_REDEMPTION_DELAY_SECONDS
                }),
                address(MOCK_UNDERLYING_ST_VAULT),
                ETHEREUM_MAINNET_AAVE_V3_POOL_ADDRESS
            )
        );
        bytes memory accountantInitializationData = abi.encodeCall(
            RoycoAccountant.initialize,
            (
                IRoycoAccountant.RoycoAccountantInitParams({
                    kernel: expectedKernelAddress,
                    stProtocolFeeWAD: ST_PROTOCOL_FEE_WAD,
                    jtProtocolFeeWAD: JT_PROTOCOL_FEE_WAD,
                    coverageWAD: COVERAGE_WAD,
                    betaWAD: BETA_WAD,
                    ydm: address(YDM),
                    ydmInitializationData: abi.encodeCall(YDM.initializeYDMForMarket, (0, 0.225e18, 1e18))
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
                marketID
            )
        );
        bytes memory juniorTrancheInitializationData = abi.encodeCall(
            JT_IMPL.initialize,
            (
                TrancheDeploymentParams({ name: JUNIOR_TRANCH_NAME, symbol: JUNIOR_TRANCH_SYMBOL, kernel: expectedKernelAddress }),
                ETHEREUM_MAINNET_USDC_ADDRESS,
                address(FACTORY),
                marketID
            )
        );

        deployedContracts = FACTORY.deployMarket(
            MarketDeploymentParams({
                seniorTrancheName: SENIOR_TRANCH_NAME,
                seniorTrancheSymbol: SENIOR_TRANCH_SYMBOL,
                juniorTrancheName: JUNIOR_TRANCH_SYMBOL,
                juniorTrancheSymbol: JUNIOR_TRANCH_SYMBOL,
                seniorAsset: ETHEREUM_MAINNET_USDC_ADDRESS,
                juniorAsset: ETHEREUM_MAINNET_USDC_ADDRESS,
                marketId: marketID,
                seniorTrancheImplementation: ST_IMPL,
                juniorTrancheImplementation: JT_IMPL,
                kernelImplementation: IRoycoKernel(address(ERC4626_ST_AaveV3_JT_IdenticalAssets_Kernel_IMPL)),
                seniorTrancheInitializationData: seniorTrancheInitializationData,
                juniorTrancheInitializationData: juniorTrancheInitializationData,
                accountantImplementation: IRoycoAccountant(address(ACCOUNTANT_IMPL)),
                kernelInitializationData: kernelInitializationData,
                accountantInitializationData: accountantInitializationData,
                seniorTrancheProxyDeploymentSalt: salt,
                juniorTrancheProxyDeploymentSalt: salt,
                kernelProxyDeploymentSalt: salt,
                accountantProxyDeploymentSalt: salt,
                roles: _generateRolesConfiguration(expectedSeniorTrancheAddress, expectedJuniorTrancheAddress, expectedKernelAddress, expectedAccountantAddress)
            })
        );
    }

    /// @notice Returns the fork configuration
    /// @return forkBlock The fork block
    /// @return forkRpcUrl The fork RPC URL
    function _forkConfiguration() internal override returns (uint256 forkBlock, string memory forkRpcUrl) {
        forkBlock = 23_997_023;
        forkRpcUrl = vm.envString("MAINNET_RPC_URL");
        if (bytes(forkRpcUrl).length == 0) {
            fail("MAINNET_RPC_URL environment variable is not set");
        }
    }

    /// @notice Generates a provider address for the mainnet fork with Aave test base
    /// @param _index The index of the provider
    /// @return provider The provider wallet
    function _generateProvider(uint256 _index) internal virtual override returns (Vm.Wallet memory provider) {
        provider = super._generateProvider(_index);

        // Fund the provider with 10M USDC
        deal(ETHEREUM_MAINNET_USDC_ADDRESS, provider.addr, 10_000_000e6);
    }
}
