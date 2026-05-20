// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { RoycoAccountant } from "../../src/accountant/RoycoAccountant.sol";
import { BaseDeploymentTemplate } from "../../src/factory/templates/BaseDeploymentTemplate.sol";
import {
    COMPONENT_ID_ACCOUNTANT_IMPL,
    COMPONENT_ID_JUNIOR_TRANCHE_IMPL,
    COMPONENT_ID_KERNEL_REUSD,
    COMPONENT_ID_SENIOR_TRANCHE_IMPL,
    COMPONENT_ID_YDM
} from "../../src/factory/templates/Components.sol";
import { ReUSDDeploymentTemplate } from "../../src/factory/templates/dawn/ReUSDDeploymentTemplate.sol";
import { DawnDeploymentTemplate } from "../../src/factory/templates/dawn/base/DawnDeploymentTemplate.sol";
import { IRoycoAccountant } from "../../src/interfaces/IRoycoAccountant.sol";
import { IRoycoDawnKernel } from "../../src/interfaces/IRoycoDawnKernel.sol";
import { IRoycoEntryPoint } from "../../src/interfaces/IRoycoEntryPoint.sol";
import { IRoycoVaultTranche } from "../../src/interfaces/IRoycoVaultTranche.sol";
import { IYDM } from "../../src/interfaces/IYDM.sol";
import { IInsuranceCapitalLayer } from "../../src/interfaces/external/reUSD/IInsuranceCapitalLayer.sol";
import { IRoycoProtocolTemplate } from "../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { IdenticalAssetsOracleQuoter } from "../../src/kernels/base/quoter/dawn/identical-assets/base/IdenticalAssetsOracleQuoter.sol";
import { ReUSD_ST_JT_ICLOracle_Kernel } from "../../src/kernels/dawn/ReUSD_ST_JT_ICLOracle_Kernel.sol";
import { RoycoAccountant } from "../../src/accountant/RoycoAccountant.sol";
import { RoycoJuniorTranche } from "../../src/tranches/RoycoJuniorTranche.sol";
import { RoycoSeniorTranche } from "../../src/tranches/RoycoSeniorTranche.sol";
import { AdaptiveCurveYDM_V2 } from "../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { WAD, WAD } from "../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../src/libraries/Units.sol";

import { AbstractKernelTestSuite } from "./abstract/AbstractKernelTestSuite.t.sol";

/// @title reUSD_Test
/// @notice Tests ReUSD_ST_JT_ICLOracle_Kernel with reUSD on Ethereum mainnet
/// @dev Both ST and JT use reUSD as the tranche asset
///
/// reUSD is a yield-bearing token where:
///   - Tranche Unit: reUSD tokens
///   - NAV Unit: USD (via USDC quote token)
/// The conversion rate is fetched from the Insurance Capital Layer (ICL).
contract reUSD_Test is AbstractKernelTestSuite {
    // ═══════════════════════════════════════════════════════════════════════════
    // ETHEREUM MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice reUSD on Ethereum mainnet
    address internal constant REUSD = 0x5086bf358635B81D8C47C66d1C8b9E567Db70c72;

    /// @notice Insurance Capital Layer on Ethereum mainnet
    address internal constant ICL = 0x4691C475bE804Fa85f91c2D6D0aDf03114de3093;

    /// @notice USDC on Ethereum mainnet (quote token for ICL)
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE FOR MOCKED ICL
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tracks the mocked ICL conversion rate
    uint256 internal mockedICLConversionRate;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for reUSD
    function getTestConfig() public pure override returns (TestConfig memory) {
        return
            TestConfig({
                forkBlock: 24_187_000,
                forkRpcUrlEnvVar: "MAINNET_RPC_URL",
                stAsset: REUSD,
                jtAsset: REUSD,
                initialFunding: 1_000_000e18 // 1M reUSD
            });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // NAV MANIPULATION HOOKS IMPLEMENTATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Simulates yield for ST by increasing the ICL conversion rate
    function simulateSTYield(uint256 _percentageWAD) public virtual override {
        _simulateICLYield(_percentageWAD);
    }

    /// @notice Simulates yield for JT by increasing the ICL conversion rate
    function simulateJTYield(uint256 _percentageWAD) public virtual override {
        _simulateICLYield(_percentageWAD);
    }

    /// @notice Simulates loss for ST by decreasing the ICL conversion rate
    function simulateSTLoss(uint256 _percentageWAD) public virtual override {
        _simulateICLLoss(_percentageWAD);
    }

    /// @notice Simulates loss for JT by decreasing the ICL conversion rate
    function simulateJTLoss(uint256 _percentageWAD) public virtual override {
        _simulateICLLoss(_percentageWAD);
    }

    /// @notice Deals ST asset to an address
    function dealSTAsset(address _to, uint256 _amount) public virtual override {
        deal(config.stAsset, _to, _amount);
    }

    /// @notice Deals JT asset to an address
    function dealJTAsset(address _to, uint256 _amount) public virtual override {
        deal(config.jtAsset, _to, _amount);
    }

    /// @notice Returns max tranche unit delta for reUSD (18 decimals)
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e12));
    }

    /// @notice Returns max NAV delta for reUSD
    /// @dev Converts the tranche unit tolerance to NAV using the kernel's conversion
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ICL CONVERSION RATE MANIPULATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Gets the current ICL conversion rate (either mocked or from the actual ICL)
    function _getCurrentICLConversionRate() internal view returns (uint256) {
        if (mockedICLConversionRate != 0) {
            return mockedICLConversionRate;
        }
        return IdenticalAssetsOracleQuoter(address(KERNEL)).getTrancheUnitToNAVUnitConversionRateWAD();
    }

    /// @notice Mocks the convertFromShares function on the ICL
    function _mockICLConversionRate(uint256 _newRateWAD) internal {
        mockedICLConversionRate = _newRateWAD;
        vm.mockCall(ICL, IInsuranceCapitalLayer.convertFromShares.selector, abi.encode(_newRateWAD));
    }

    /// @notice Simulates yield by increasing the ICL conversion rate
    function _simulateICLYield(uint256 _percentageWAD) internal {
        uint256 currentRate = _getCurrentICLConversionRate();
        uint256 newRate = currentRate * (WAD + _percentageWAD) / WAD;
        _mockICLConversionRate(newRate);
    }

    /// @notice Simulates loss by decreasing the ICL conversion rate
    function _simulateICLLoss(uint256 _percentageWAD) internal {
        uint256 currentRate = _getCurrentICLConversionRate();
        uint256 newRate = currentRate * (WAD - _percentageWAD) / WAD;
        _mockICLConversionRate(newRate);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // reUSD-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies that the reUSD token is correctly configured
    function test_reUSD_tokenConfiguration() external view {
        uint8 decimals = IERC20Metadata(REUSD).decimals();
        assertEq(decimals, 18, "reUSD should have 18 decimals");

        string memory name = IERC20Metadata(REUSD).name();
        string memory symbol = IERC20Metadata(REUSD).symbol();
        assertTrue(bytes(name).length > 0, "reUSD should have a name");
        assertTrue(bytes(symbol).length > 0, "reUSD should have a symbol");
    }

    /// @notice Verifies that the ICL is correctly configured
    function test_reUSD_ICLConfiguration() external view {
        uint256 rate = IInsuranceCapitalLayer(ICL).convertFromShares(USDC, WAD);
        assertGt(rate, 0, "ICL should return positive conversion rate");
    }

    /// @notice Verifies initial conversion rate is set correctly (from ICL)
    function test_reUSD_initialConversionRate() external view {
        // The stored rate should be 0 (sentinel) meaning it queries ICL
        uint256 storedRate = ReUSD_ST_JT_ICLOracle_Kernel(address(KERNEL)).getStoredConversionRateWAD();
        assertEq(storedRate, 0, "Stored rate should be 0 (sentinel, queries ICL)");

        // The actual conversion rate should be fetched from ICL
        uint256 conversionRate = ReUSD_ST_JT_ICLOracle_Kernel(address(KERNEL)).getTrancheUnitToNAVUnitConversionRateWAD();
        assertGt(conversionRate, 0, "Conversion rate should be positive");
    }

    /// @notice Test that simulated yield works correctly for reUSD
    function testFuzz_reUSD_simulatedYield_increasesNAV(uint256 _amount, uint256 _yieldBps) external {
        _amount = bound(_amount, 1e18, 100_000e18);
        _yieldBps = bound(_yieldBps, 10, 1000);

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _getCurrentICLConversionRate();

        uint256 yieldWAD = _yieldBps * 1e14;
        _simulateICLYield(yieldWAD);

        uint256 rateAfter = _getCurrentICLConversionRate();
        assertGt(rateAfter, rateBefore, "Rate should increase after yield");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after yield");
    }

    /// @notice Test loss simulation for reUSD
    function testFuzz_reUSD_simulatedLoss_decreasesNAV(uint256 _amount, uint256 _lossBps) external {
        _amount = bound(_amount, 1e18, 100_000e18);
        _lossBps = bound(_lossBps, 10, 500);

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _getCurrentICLConversionRate();

        uint256 lossWAD = _lossBps * 1e14;
        _simulateICLLoss(lossWAD);

        uint256 rateAfter = _getCurrentICLConversionRate();
        assertLt(rateAfter, rateBefore, "Rate should decrease after loss");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after loss");
    }

    /// @notice Tests that admin can set conversion rate override
    function test_setConversionRate_success() external {
        uint256 newRate = 1.05e18;

        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        ReUSD_ST_JT_ICLOracle_Kernel(address(KERNEL)).setConversionRate(newRate, true);

        uint256 storedRate = ReUSD_ST_JT_ICLOracle_Kernel(address(KERNEL)).getStoredConversionRateWAD();
        assertEq(storedRate, newRate, "Stored rate should match set rate");
    }

    /// @notice Tests that non-admin cannot set conversion rate
    function test_setConversionRate_revertsOnUnauthorized() external {
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert();
        ReUSD_ST_JT_ICLOracle_Kernel(address(KERNEL)).setConversionRate(1e18, true);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (via the template-driven factory)
    // ═══════════════════════════════════════════════════════════════════════════

    bytes32 internal constant MARKET_ID = keccak256("reUSD_ST_JT_TEST");

    /// @notice Deploys the ReUSD kernel + market by registering `ReUSDDeploymentTemplate` on the
    ///         test-harness factory, building `DawnParams`, and calling `executeMarketDeployment`.
    function _deployKernelAndMarket() internal override returns (MarketDeployment memory) {
        // 1. Deploy + register the ReUSD template.
        ReUSDDeploymentTemplate template = new ReUSDDeploymentTemplate(FACTORY);
        {
            bytes32[] memory ids = new bytes32[](5);
            bytes[] memory codes = new bytes[](5);
            ids[0] = COMPONENT_ID_SENIOR_TRANCHE_IMPL;
            codes[0] = type(RoycoSeniorTranche).creationCode;
            ids[1] = COMPONENT_ID_JUNIOR_TRANCHE_IMPL;
            codes[1] = type(RoycoJuniorTranche).creationCode;
            ids[2] = COMPONENT_ID_ACCOUNTANT_IMPL;
            codes[2] = type(RoycoAccountant).creationCode;
            ids[3] = COMPONENT_ID_YDM;
            codes[3] = type(AdaptiveCurveYDM_V2).creationCode;
            ids[4] = COMPONENT_ID_KERNEL_REUSD;
            codes[4] = type(ReUSD_ST_JT_ICLOracle_Kernel).creationCode;

            // OWNER holds ADMIN_FACTORY_ROLE.
            vm.prank(OWNER_ADDRESS);
            FACTORY.registerTemplate(address(template), ids, codes);
        }

        // 2. Build `DawnParams`. Role bindings are now built inside the template — no need to
        //    pre-predict addresses here.
        DawnDeploymentTemplate.DawnParams memory p = DawnDeploymentTemplate.DawnParams({
            marketId: MARKET_ID,
            st: BaseDeploymentTemplate.SeniorTrancheParams({ name: SENIOR_TRANCHE_NAME, symbol: SENIOR_TRANCHE_SYMBOL, asset: config.stAsset }),
            jt: BaseDeploymentTemplate.JuniorTrancheParams({ name: JUNIOR_TRANCHE_NAME, symbol: JUNIOR_TRANCHE_SYMBOL, asset: config.jtAsset }),
            accountant: BaseDeploymentTemplate.AccountantParams({
                stProtocolFeeWAD: ST_PROTOCOL_FEE_WAD,
                jtProtocolFeeWAD: JT_PROTOCOL_FEE_WAD,
                yieldShareProtocolFeeWAD: 0,
                coverageWAD: COVERAGE_WAD,
                betaWAD: BETA_WAD,
                liquidationUtilizationWAD: LIQUIDATION_UTILIZATION_WAD,
                fixedTermDurationSeconds: FIXED_TERM_DURATION_SECONDS,
                stNAVDustTolerance: DUST_TOLERANCE,
                jtNAVDustTolerance: DUST_TOLERANCE,
                ydmInitializationData: abi.encodeCall(
                    AdaptiveCurveYDM_V2.initializeYDMForMarket, (uint64(0.06e18), uint64(0.06e18), uint64(0.18e18), uint64(0))
                )
            }),
            ydm: BaseDeploymentTemplate.YDMParams({ componentTag: YDM_COMPONENT_TAG, version: YDM_VERSION }),
            kernelSpecificParams: abi.encode(ReUSDDeploymentTemplate.KernelParams({ reusd: REUSD, reusdUsdQuoteToken: USDC, insuranceCapitalLayer: ICL })),
            enforceVaultSharesTransferWhitelist: false,
            protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT_ADDRESS,
            stSelfLiquidationBonusWAD: 0,
            entryPoint: address(0),
            stEntryPointConfig: _emptyEntryPointConfig(),
            jtEntryPointConfig: _emptyEntryPointConfig()
        });

        // 3. Execute deployment.
        vm.prank(DEPLOYER_ADDRESS);
        IRoycoProtocolTemplate.DeploymentResult memory r = FACTORY.executeMarketDeployment(address(template), abi.encode(p));

        return MarketDeployment({
            seniorTranche: IRoycoVaultTranche(r.seniorTranche),
            juniorTranche: IRoycoVaultTranche(r.juniorTranche),
            kernel: IRoycoDawnKernel(r.kernel),
            accountant: IRoycoAccountant(r.accountant),
            ydm: IYDM(r.ydm)
        });
    }

    function _forkConfiguration() internal pure override returns (uint256, string memory) {
        return (24_187_000, "MAINNET_RPC_URL");
    }
}
