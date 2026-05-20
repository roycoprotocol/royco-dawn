// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";

import { COMPONENT_ID_KERNEL_IDENTICAL_MAKINA } from "../../../../src/factory/templates/Components.sol";
import { IdenticalMakinaDeploymentTemplate } from "../../../../src/factory/templates/dawn/IdenticalMakinaDeploymentTemplate.sol";
import { IMachine } from "../../../../src/interfaces/external/makina/IMachine.sol";
import { Identical_Makina_ST_JT_MachineToAdminOracle_Kernel } from "../../../../src/kernels/Identical_Makina_ST_JT_MachineToAdminOracle_Kernel.sol";
import { WAD, WAD_DECIMALS } from "../../../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../../../src/libraries/Units.sol";

import { YieldBearingERC4626_TestBase } from "../base/YieldBearingERC4626_TestBase.t.sol";

/// @title Makina_DUSD_Test
/// @notice Tests Identical_Makina_ST_JT_MachineToAdminOracle_Kernel with Makina's DUSD
/// @dev Both ST and JT use DUSD (Makina machine shares) as the tranche asset
///
/// DUSD is a Makina machine share where:
///   - Tranche Unit: DUSD shares (Makina machine shares)
///   - Accounting Asset: USDC (the underlying)
///   - NAV Unit: USD
/// The quoter uses IMachine.convertToAssets() for share-to-accounting-asset conversion,
/// and an admin-set rate for accounting-asset-to-NAV (USDC->USD), which is ~1:1 for stablecoins.
contract Makina_DUSD_Test is YieldBearingERC4626_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice DUSD on Ethereum mainnet
    address internal constant DUSD = 0x1e33E98aF620F1D563fcD3cfd3C75acE841204ef;

    /// @notice Makina machine for DUSD
    address internal constant MAKINA_MACHINE = 0x6b006870C83b1Cd49E766Ac9209f8d68763Df721;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for DUSD
    function getTestConfig() public pure override returns (TestConfig memory) {
        return
            TestConfig({
                forkBlock: 24_532_268,
                forkRpcUrlEnvVar: "MAINNET_RPC_URL",
                stAsset: DUSD,
                jtAsset: DUSD,
                initialFunding: 1_000_000_000e18 // 1B DUSD
            });
    }

    /// @notice Returns the initial USDC->USD conversion rate (in WAD precision)
    /// @dev For USDC (a stablecoin), this is 1:1, so we return WAD (1e18)
    function _getInitialConversionRate() internal pure override returns (uint256) {
        return WAD; // 1:1 USDC to USD
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses MarketDeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the DUSD kernel + market via the Makina template.
    function _deployKernelAndMarket() internal override returns (MarketDeployment memory) {
        IdenticalMakinaDeploymentTemplate template = new IdenticalMakinaDeploymentTemplate(FACTORY);
        DawnDeploymentParams memory p;
        p.marketId = keccak256("MAKINA_DUSD_TEST");
        p.template = address(template);
        p.kernelComponentId = COMPONENT_ID_KERNEL_IDENTICAL_MAKINA;
        p.kernelCreationCode = type(Identical_Makina_ST_JT_MachineToAdminOracle_Kernel).creationCode;
        p.stAsset = config.stAsset;
        p.jtAsset = config.jtAsset;
        p.kernelSpecificParams = abi.encode(
            IdenticalMakinaDeploymentTemplate.KernelParams({ makinaMachine: MAKINA_MACHINE, initialConversionRateWAD: _getInitialConversionRate() })
        );
        p.stProtocolFeeWAD = ST_PROTOCOL_FEE_WAD;
        p.jtProtocolFeeWAD = JT_PROTOCOL_FEE_WAD;
        p.yieldShareProtocolFeeWAD = 0;
        p.coverageWAD = COVERAGE_WAD;
        p.betaWAD = BETA_WAD;
        p.liquidationUtilizationWAD = LIQUIDATION_UTILIZATION_WAD;
        p.fixedTermDurationSeconds = FIXED_TERM_DURATION_SECONDS;
        p.stNAVDustTolerance = DUST_TOLERANCE;
        p.jtNAVDustTolerance = DUST_TOLERANCE;
        p.enforceVaultSharesTransferWhitelist = false;
        p.stSelfLiquidationBonusWAD = 0;
        return _deployDawnMarket(p);
    }

    // NOTE: simulateVaultSharePriceYield() and simulateVaultSharePriceLoss() are inherited from
    // YieldBearingERC4626_TestBase and work correctly because they call the overridden internal
    // functions _getCurrentSharePriceWAD() and _mockConvertToAssets() below.

    /// @notice Computes the share amount to pass to convertToAssets() to get WAD-scaled output
    /// @dev This matches the kernel's MACHINE_SHARES_TO_CONVERT_TO_ASSETS calculation
    function _getSharesToConvertToAssets() internal view override returns (uint256) {
        return 10 ** (WAD_DECIMALS + IERC20Metadata(config.stAsset).decimals() - IERC20Metadata(IMachine(MAKINA_MACHINE).accountingToken()).decimals());
    }

    /// @notice Gets the current share price (either mocked or from the actual Makina machine)
    /// @return The share price in WAD precision
    function _getCurrentSharePriceWAD() internal view override returns (uint256) {
        if (mockedSharePriceWAD != 0) {
            return mockedSharePriceWAD;
        }
        // Get the actual share price from the Makina machine using the same input the kernel uses
        return IMachine(MAKINA_MACHINE).convertToAssets(_getSharesToConvertToAssets());
    }

    /// @notice Mocks the convertToAssets function on the Makina machine
    /// @param _newSharePriceWAD The new share price in WAD precision
    function _mockConvertToAssets(uint256 _newSharePriceWAD) internal override {
        mockedSharePriceWAD = _newSharePriceWAD;

        // Mock convertToAssets on the Makina machine with the same input the kernel uses
        uint256 sharesToConvert = _getSharesToConvertToAssets();
        vm.mockCall(MAKINA_MACHINE, abi.encodeWithSelector(IMachine.convertToAssets.selector, sharesToConvert), abi.encode(_newSharePriceWAD));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for DUSD (18 decimals)
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(3e12)); // 0.000003 DUSD tolerance
    }

    /// @notice Returns max NAV delta for DUSD
    /// @dev Converts the tranche unit tolerance to NAV using the kernel's conversion
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONVERSION RATE OVERRIDES (use Makina kernel instead of ERC4626 kernel)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Gets the current conversion rate using the Makina kernel's getter (in WAD precision)
    function _getConversionRate() internal view override returns (uint256) {
        return Identical_Makina_ST_JT_MachineToAdminOracle_Kernel(address(KERNEL)).getStoredConversionRateWAD();
    }

    /// @notice Sets the conversion rate using the Makina kernel's setter (in WAD precision)
    /// @dev Requires ADMIN_ORACLE_QUOTER_ROLE, which is granted to ORACLE_QUOTER_ADMIN_ADDRESS
    function _setConversionRate(uint256 _newRateWAD) internal override {
        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        Identical_Makina_ST_JT_MachineToAdminOracle_Kernel(address(KERNEL)).setConversionRate(_newRateWAD, true);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MAKINA-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies that the Makina machine is correctly configured
    function test_makina_machineConfiguration() external view {
        // Verify share token is DUSD
        address shareToken = IMachine(MAKINA_MACHINE).shareToken();
        assertEq(shareToken, DUSD, "Makina machine share token should be DUSD");

        // Verify accounting token exists
        address accountingToken = IMachine(MAKINA_MACHINE).accountingToken();
        assertTrue(accountingToken != address(0), "Makina machine accounting token should not be zero");

        // Verify the machine has a valid share price
        uint256 sharePrice = IMachine(MAKINA_MACHINE).convertToAssets(_getSharesToConvertToAssets());
        assertGt(sharePrice, 0, "Makina machine share price should be > 0");
    }

    /// @notice Verifies the kernel's MAKINA_MACHINE immutable is set correctly
    function test_makina_kernelConfiguration() external view {
        address kernelMachine = Identical_Makina_ST_JT_MachineToAdminOracle_Kernel(address(KERNEL)).MAKINA_MACHINE();
        assertEq(kernelMachine, MAKINA_MACHINE, "Kernel's MAKINA_MACHINE should match expected");
    }

    /// @notice Verifies initial conversion rate is set correctly
    function test_makina_initialConversionRate() external view {
        uint256 storedRate = _getConversionRate();
        assertEq(storedRate, WAD, "Stored rate should be WAD (1:1 for stablecoin)");
    }

    /// @notice Test that simulated yield works correctly for Makina DUSD
    function testFuzz_makina_simulatedYield_increasesNAV(uint256 _amount, uint256 _yieldBps) external {
        _amount = bound(_amount, _minDepositAmount(), config.initialFunding / 10);
        _yieldBps = bound(_yieldBps, 10, 1000); // 0.1% to 10% yield

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _getConversionRate();

        // Simulate yield by increasing the USDC->USD rate
        uint256 yieldWAD = _yieldBps * 1e14;
        simulateJTYield(yieldWAD);

        uint256 rateAfter = _getConversionRate();
        assertGt(rateAfter, rateBefore, "Rate should increase after yield");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after yield");
    }

    /// @notice Test loss simulation for Makina DUSD
    function testFuzz_makina_simulatedLoss_decreasesNAV(uint256 _amount, uint256 _lossBps) external {
        _amount = bound(_amount, _minDepositAmount(), config.initialFunding / 10);
        _lossBps = bound(_lossBps, 10, 500); // 0.1% to 5% loss

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _getConversionRate();

        uint256 lossWAD = _lossBps * 1e14;
        simulateJTLoss(lossWAD);

        uint256 rateAfter = _getConversionRate();
        assertLt(rateAfter, rateBefore, "Rate should decrease after loss");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after loss");
    }

    /// @notice Test Makina machine share price yield affects NAV
    function testFuzz_makina_machineSharePriceYield(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 1, 20);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        simulateVaultSharePriceYield(_yieldPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after Makina machine share price yield");
    }

    /// @notice Test Makina machine share price loss affects NAV
    function testFuzz_makina_machineSharePriceLoss(uint256 _jtAmount, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _lossPercentage = bound(_lossPercentage, 1, 20);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        simulateVaultSharePriceLoss(_lossPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after Makina machine share price loss");
    }

    /// @notice Test combined yield: both machine share price AND stored rate increase
    function testFuzz_makina_combinedYield_bothComponents(uint256 _jtAmount, uint256 _sharePriceYieldBps, uint256 _rateYieldBps) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _sharePriceYieldBps = bound(_sharePriceYieldBps, 10, 500); // 0.1% to 5%
        _rateYieldBps = bound(_rateYieldBps, 10, 500); // 0.1% to 5%

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Apply both yields
        simulateVaultSharePriceYield(_sharePriceYieldBps * 1e14);
        _simulateYield(_rateYieldBps * 1e14);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after combined yield");
    }

    /// @notice Test that getTrancheUnitToNAVUnitConversionRateWAD returns expected value
    function test_makina_conversionRateCalculation() external view {
        uint256 sharePriceWAD = IMachine(MAKINA_MACHINE).convertToAssets(_getSharesToConvertToAssets());
        uint256 storedRateWAD = _getConversionRate();

        uint256 expectedConversionRate = (sharePriceWAD * storedRateWAD) / WAD;
        uint256 actualConversionRate = Identical_Makina_ST_JT_MachineToAdminOracle_Kernel(address(KERNEL)).getTrancheUnitToNAVUnitConversionRateWAD();

        assertEq(actualConversionRate, expectedConversionRate, "Conversion rate should equal sharePrice * storedRate / WAD");
    }
}
