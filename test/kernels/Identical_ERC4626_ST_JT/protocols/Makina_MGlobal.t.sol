// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";

import { DeployScript } from "../../../../script/Deploy.s.sol";
import { MarketDeploymentConfig } from "../../../../script/config/MarketDeploymentConfig.sol";
import { IRoycoFactory } from "../../../../src/interfaces/IRoycoFactory.sol";
import { IMachine } from "../../../../src/interfaces/external/makina/IMachine.sol";
import { Identical_Makina_ST_JT_MachineToAdminOracle_Kernel } from "../../../../src/kernels/Identical_Makina_ST_JT_MachineToAdminOracle_Kernel.sol";
import { WAD, WAD_DECIMALS } from "../../../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../../../src/libraries/Units.sol";

import { YieldBearingERC4626_TestBase } from "../base/YieldBearingERC4626_TestBase.t.sol";

/// @title Makina_MGlobal_Test
/// @notice Tests `Identical_Makina_ST_JT_MachineToAdminOracle_Kernel` against Makina's DMG
///         market — same kernel topology as the DUSD market but backed by a different Makina machine + share token.
/// @dev DMG is a Makina machine share where:
///        - Tranche Unit: DMG shares (Makina machine shares)
///        - Accounting Asset: USDC (the machine's accounting token, 6 decimals)
///        - NAV Unit: USD
///      The quoter uses `IMachine.convertToAssets()` for share→accounting and an admin-set
///      rate for accounting→NAV (USDC→USD, ~1:1 for stablecoins). The market config lives in
///      `MarketDeploymentConfig.MAKINA_MGLOBAL` ("DMG").
contract Makina_MGlobal_Test is YieldBearingERC4626_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice DMG share token on Ethereum mainnet (Makina machine share)
    address internal constant DMG = 0x761C3B16a5Afdd7A1869C4B979cFF3383d5Fe98B;

    /// @notice Makina machine backing DMG
    address internal constant MAKINA_MACHINE = 0xC4fFab8540AC27E40D4e2930517aA711e9C00c5b;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for DMG
    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({
            // DMG / its Makina machine were deployed after the fork blocks used by older
            // mainnet kernel tests; pin to a recent block known to include both.
            forkBlock: 25_092_000,
            forkRpcUrlEnvVar: "MAINNET_RPC_URL",
            stAsset: DMG,
            jtAsset: DMG,
            initialFunding: 1_000_000_000e18 // 1B DMG
        });
    }

    /// @notice Returns the initial USDC→USD conversion rate (in WAD precision)
    /// @dev For USDC (a stablecoin), this is 1:1, so we return WAD (1e18)
    function _getInitialConversionRate() internal pure override returns (uint256) {
        return WAD; // 1:1 USDC to USD
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses MarketDeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the DMG kernel + market using parameters from `MarketDeploymentConfig`.
    function _deployKernelAndMarket() internal override returns (DeployScript.DeploymentResult memory) {
        MarketDeploymentConfig.MarketConfig memory marketConfig = DEPLOY_SCRIPT.getMarketConfig("DMG");

        // Override the initial conversion rate for testing so we always start at 1:1.
        marketConfig.kernelSpecificParams = abi.encode(
            DeployScript.IdenticalMakinaSTMakinaJTKernelParams({ makinaMachine: MAKINA_MACHINE, initialConversionRateWAD: _getInitialConversionRate() })
        );

        uint32 scheduledOperationsExpirySeconds = DEPLOY_SCRIPT.getChainConfig(block.chainid).scheduledOperationsExpirySeconds;
        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        return DEPLOY_SCRIPT.deploy(
            marketConfig, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, scheduledOperationsExpirySeconds, roleAssignments, DEPLOYER.privateKey
        );
    }

    // NOTE: simulateVaultSharePriceYield() and simulateVaultSharePriceLoss() are inherited from
    // YieldBearingERC4626_TestBase and work correctly because they call the overridden internal
    // functions _getCurrentSharePriceWAD() and _mockConvertToAssets() below.

    /// @notice Computes the share amount to pass to convertToAssets() to get WAD-scaled output.
    /// @dev Matches the kernel's `MACHINE_SHARES_TO_CONVERT_TO_ASSETS` calculation
    ///      (`10 ** (WAD_DECIMALS + shareDecimals - accountingDecimals)`).
    function _getSharesToConvertToAssets() internal view override returns (uint256) {
        return 10 ** (WAD_DECIMALS + IERC20Metadata(config.stAsset).decimals() - IERC20Metadata(IMachine(MAKINA_MACHINE).accountingToken()).decimals());
    }

    /// @notice Gets the current share price (mocked when overridden, else from the live machine).
    /// @return The share price in WAD precision
    function _getCurrentSharePriceWAD() internal view override returns (uint256) {
        if (mockedSharePriceWAD != 0) {
            return mockedSharePriceWAD;
        }
        return IMachine(MAKINA_MACHINE).convertToAssets(_getSharesToConvertToAssets());
    }

    /// @notice Mocks `convertToAssets` on the Makina machine.
    function _mockConvertToAssets(uint256 _newSharePriceWAD) internal override {
        mockedSharePriceWAD = _newSharePriceWAD;
        uint256 sharesToConvert = _getSharesToConvertToAssets();
        vm.mockCall(MAKINA_MACHINE, abi.encodeWithSelector(IMachine.convertToAssets.selector, sharesToConvert), abi.encode(_newSharePriceWAD));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for DMG (18-decimal share token).
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(3e12)); // 0.000003 DMG tolerance
    }

    /// @notice Returns max NAV delta for DMG by converting the tranche-unit tolerance via the kernel.
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONVERSION RATE OVERRIDES (use Makina kernel instead of ERC4626 kernel)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Gets the current accounting→NAV conversion rate from the Makina kernel (WAD).
    function _getConversionRate() internal view override returns (uint256) {
        return Identical_Makina_ST_JT_MachineToAdminOracle_Kernel(address(KERNEL)).getStoredConversionRateWAD();
    }

    /// @notice Sets the accounting→NAV conversion rate via the Makina kernel's admin setter.
    /// @dev Requires `ADMIN_ORACLE_QUOTER_ROLE`, granted to `ORACLE_QUOTER_ADMIN_ADDRESS` in tests.
    function _setConversionRate(uint256 _newRateWAD) internal override {
        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        Identical_Makina_ST_JT_MachineToAdminOracle_Kernel(address(KERNEL)).setConversionRate(_newRateWAD, true);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MAKINA-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies that the Makina machine is correctly configured.
    function test_makina_machineConfiguration() external view {
        // Share token must be DMG
        address shareToken = IMachine(MAKINA_MACHINE).shareToken();
        assertEq(shareToken, DMG, "Makina machine share token should be DMG");

        // Accounting token must be non-zero
        address accountingToken = IMachine(MAKINA_MACHINE).accountingToken();
        assertTrue(accountingToken != address(0), "Makina machine accounting token should not be zero");

        // Live share price must be non-zero
        uint256 sharePrice = IMachine(MAKINA_MACHINE).convertToAssets(_getSharesToConvertToAssets());
        assertGt(sharePrice, 0, "Makina machine share price should be > 0");
    }

    /// @notice Verifies the kernel's `MAKINA_MACHINE` immutable is set correctly.
    function test_makina_kernelConfiguration() external view {
        address kernelMachine = Identical_Makina_ST_JT_MachineToAdminOracle_Kernel(address(KERNEL)).MAKINA_MACHINE();
        assertEq(kernelMachine, MAKINA_MACHINE, "Kernel's MAKINA_MACHINE should match expected");
    }

    /// @notice Verifies the initial conversion rate is set correctly.
    function test_makina_initialConversionRate() external view {
        uint256 storedRate = _getConversionRate();
        assertEq(storedRate, WAD, "Stored rate should be WAD (1:1 for stablecoin)");
    }

    /// @notice Yield via stored-rate increase should bump NAV.
    function testFuzz_makina_simulatedYield_increasesNAV(uint256 _amount, uint256 _yieldBps) external {
        _amount = bound(_amount, _minDepositAmount(), config.initialFunding / 10);
        _yieldBps = bound(_yieldBps, 10, 1000); // 0.1% to 10% yield

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _getConversionRate();

        uint256 yieldWAD = _yieldBps * 1e14;
        simulateJTYield(yieldWAD);

        uint256 rateAfter = _getConversionRate();
        assertGt(rateAfter, rateBefore, "Rate should increase after yield");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after yield");
    }

    /// @notice Loss via stored-rate decrease should drop NAV.
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

    /// @notice Machine share-price yield (the other leg) should also bump NAV.
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

    /// @notice Machine share-price loss should drop NAV.
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

    /// @notice Combined yield from both legs (share-price and stored rate) bumps NAV.
    function testFuzz_makina_combinedYield_bothComponents(uint256 _jtAmount, uint256 _sharePriceYieldBps, uint256 _rateYieldBps) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _sharePriceYieldBps = bound(_sharePriceYieldBps, 10, 500); // 0.1% to 5%
        _rateYieldBps = bound(_rateYieldBps, 10, 500); // 0.1% to 5%

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        simulateVaultSharePriceYield(_sharePriceYieldBps * 1e14);
        _simulateYield(_rateYieldBps * 1e14);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after combined yield");
    }

    /// @notice `getTrancheUnitToNAVUnitConversionRateWAD` should equal `sharePrice * storedRate / WAD`.
    function test_makina_conversionRateCalculation() external view {
        uint256 sharePriceWAD = IMachine(MAKINA_MACHINE).convertToAssets(_getSharesToConvertToAssets());
        uint256 storedRateWAD = _getConversionRate();

        uint256 expectedConversionRate = (sharePriceWAD * storedRateWAD) / WAD;
        uint256 actualConversionRate = Identical_Makina_ST_JT_MachineToAdminOracle_Kernel(address(KERNEL)).getTrancheUnitToNAVUnitConversionRateWAD();

        assertEq(actualConversionRate, expectedConversionRate, "Conversion rate should equal sharePrice * storedRate / WAD");
    }
}
