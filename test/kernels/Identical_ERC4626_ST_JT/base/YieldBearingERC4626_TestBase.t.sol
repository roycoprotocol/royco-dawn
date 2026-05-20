// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata, IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {
    Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel
} from "../../../../src/kernels/dawn/Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel.sol";
import { WAD, WAD_DECIMALS, ZERO_NAV_UNITS } from "../../../../src/libraries/Constants.sol";
import { AssetClaims, SyncedAccountingState, TrancheType } from "../../../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../../src/libraries/Units.sol";
import { AbstractKernelTestSuite } from "../../abstract/AbstractKernelTestSuite.t.sol";

/// @title YieldBearingERC4626_TestBase
/// @notice Base test contract for Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel
/// @dev Implements the test hooks for yield-bearing ERC4626 assets where ST and JT use identical assets
///
/// IMPORTANT: This kernel stores the `vaultAsset-to-NAV` conversion rate (e.g., NUSD->USD for sNUSD).
/// The actual tranche-to-NAV conversion combines:
///   1. ERC4626.convertToAssets(WAD) - share to vault asset rate
///   2. storedRate (in WAD) - vault asset to NAV rate
/// Result: trancheToNAV = shareToAsset * storedRate / WAD
abstract contract YieldBearingERC4626_TestBase is AbstractKernelTestSuite {
    // ═══════════════════════════════════════════════════════════════════════════
    // STATE FOR MOCKED SHARE PRICE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tracks the mocked share price (in WAD precision)
    /// @dev When non-zero, this value is used to mock convertToAssets() calls
    uint256 internal mockedSharePriceWAD;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIGURATION (To be overridden by protocol-specific implementations)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the initial vault-asset-to-NAV conversion rate (in WAD precision)
    /// @dev For stablecoins like sNUSD (where NUSD ≈ USD), this should be WAD (1e18)
    /// Override this for non-stablecoin vaults where the vault asset has a different NAV
    function _getInitialConversionRate() internal view virtual returns (uint256) {
        // Default: 1:1 conversion in WAD precision (for stablecoins)
        return WAD;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // NAV MANIPULATION HOOKS IMPLEMENTATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Simulates yield for ST by increasing the conversion rate
    function simulateSTYield(uint256 _percentageWAD) public virtual override {
        _simulateYield(_percentageWAD);
    }

    /// @notice Simulates yield for JT by increasing the conversion rate
    /// @dev For identical assets, ST and JT share the same conversion rate
    function simulateJTYield(uint256 _percentageWAD) public virtual override {
        _simulateYield(_percentageWAD);
    }

    /// @notice Simulates loss for ST by decreasing the conversion rate
    function simulateSTLoss(uint256 _percentageWAD) public virtual override {
        _simulateLoss(_percentageWAD);
    }

    /// @notice Simulates loss for JT by decreasing the conversion rate
    /// @dev For identical assets, ST and JT share the same conversion rate
    function simulateJTLoss(uint256 _percentageWAD) public virtual override {
        _simulateLoss(_percentageWAD);
    }

    /// @notice Sets the conversion rate for ST (in WAD precision)
    function setSTConversionRate(uint256 _rateWAD) public virtual {
        _setConversionRate(_rateWAD);
    }

    /// @notice Sets the conversion rate for JT (in WAD precision)
    /// @dev For identical assets, this is the same as ST
    function setJTConversionRate(uint256 _rateWAD) public virtual {
        _setConversionRate(_rateWAD);
    }

    /// @notice Deals ST asset to an address
    function dealSTAsset(address _to, uint256 _amount) public virtual override {
        deal(config.stAsset, _to, _amount);
    }

    /// @notice Deals JT asset to an address
    function dealJTAsset(address _to, uint256 _amount) public virtual override {
        deal(config.jtAsset, _to, _amount);
    }

    /// @notice Returns max tranche unit delta for comparisons
    function maxTrancheUnitDelta() public view virtual override returns (TRANCHE_UNIT) {
        // Default: 1e12 tolerance (good for 18 decimal tokens)
        return toTrancheUnits(uint256(1e12));
    }

    /// @notice Returns max NAV delta for comparisons
    /// @dev Converts the tranche unit tolerance to NAV using the kernel's conversion
    function maxNAVDelta() public view virtual override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VAULT SHARE PRICE MANIPULATION (ERC4626 convertToAssets component)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Simulates vault share price yield by mocking convertToAssets()
    /// @param _percentageWAD The percentage increase in WAD (e.g., 0.05e18 = 5%)
    function simulateVaultSharePriceYield(uint256 _percentageWAD) public virtual {
        uint256 currentSharePrice = _getCurrentSharePriceWAD();
        uint256 newSharePrice = currentSharePrice * (WAD + _percentageWAD) / WAD;
        _mockConvertToAssets(newSharePrice);
    }

    /// @notice Simulates vault share price loss by mocking convertToAssets()
    /// @param _percentageWAD The percentage decrease in WAD (e.g., 0.05e18 = 5%)
    function simulateVaultSharePriceLoss(uint256 _percentageWAD) public virtual {
        uint256 currentSharePrice = _getCurrentSharePriceWAD();
        uint256 newSharePrice = currentSharePrice * (WAD - _percentageWAD) / WAD;
        _mockConvertToAssets(newSharePrice);
    }

    /// @notice Computes the share amount to pass to convertToAssets() to get WAD-scaled output
    /// @dev This matches the kernel's SHARES_TO_CONVERT_TO_ASSETS calculation
    function _getSharesToConvertToAssets() internal view virtual returns (uint256) {
        return 10 ** (WAD_DECIMALS + IERC4626(config.stAsset).decimals() - IERC20Metadata(IERC4626(config.stAsset).asset()).decimals());
    }

    /// @notice Gets the current share price (either mocked or from the actual vault)
    /// @return The share price in WAD precision
    function _getCurrentSharePriceWAD() internal view virtual returns (uint256) {
        if (mockedSharePriceWAD != 0) {
            return mockedSharePriceWAD;
        }
        // Get the actual share price from the vault using the same input the kernel uses
        return IERC4626(config.stAsset).convertToAssets(_getSharesToConvertToAssets());
    }

    /// @notice Mocks the convertToAssets function on the vault
    /// @param _newSharePriceWAD The new share price in WAD precision
    function _mockConvertToAssets(uint256 _newSharePriceWAD) internal virtual {
        mockedSharePriceWAD = _newSharePriceWAD;

        // Mock convertToAssets with the same input the kernel uses (SHARES_TO_CONVERT_TO_ASSETS)
        uint256 sharesToConvert = _getSharesToConvertToAssets();
        vm.mockCall(config.stAsset, abi.encodeWithSelector(IERC4626.convertToAssets.selector, sharesToConvert), abi.encode(_newSharePriceWAD));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS (STORED CONVERSION RATE)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Simulates yield by increasing the conversion rate
    /// @param _percentageWAD The yield percentage in WAD (e.g., 0.05e18 = 5%)
    function _simulateYield(uint256 _percentageWAD) internal {
        uint256 currentRate = _getConversionRate();
        // Apply percentage increase: newRate = currentRate * (1 + percentage)
        uint256 newRate = currentRate * (WAD + _percentageWAD) / WAD;
        _setConversionRate(newRate);
    }

    /// @notice Simulates loss by decreasing the conversion rate
    /// @param _percentageWAD The loss percentage in WAD (e.g., 0.05e18 = 5%)
    function _simulateLoss(uint256 _percentageWAD) internal {
        uint256 currentRate = _getConversionRate();
        // Apply percentage decrease: newRate = currentRate * (1 - percentage)
        uint256 newRate = currentRate * (WAD - _percentageWAD) / WAD;
        _setConversionRate(newRate);
    }

    /// @notice Gets the current conversion rate using the kernel's getter (in WAD precision)
    function _getConversionRate() internal view virtual returns (uint256) {
        return Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel(address(KERNEL)).getStoredConversionRateWAD();
    }

    /// @notice Sets the conversion rate using the kernel's setter (in WAD precision)
    /// @dev Requires ADMIN_ORACLE_QUOTER_ROLE, which is granted to ORACLE_QUOTER_ADMIN_ADDRESS
    function _setConversionRate(uint256 _newRateWAD) internal virtual {
        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel(address(KERNEL)).setConversionRate(_newRateWAD, true);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STORED CONVERSION RATE TESTS (baseAsset-to-NAV component)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tests that stored conversion rate yield increases NAV
    /// @dev This tests the baseAsset-to-NAV component of the conversion rate
    function testFuzz_storedConversionRate_yield_updatesNAV(uint256 _jtAmount, uint256 _yieldBps) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldBps = bound(_yieldBps, 10, 1000); // 0.1% to 10% yield

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _getConversionRate();

        // Simulate yield by increasing the stored conversion rate
        uint256 yieldWAD = _yieldBps * 1e14; // Convert bps to WAD
        _simulateYield(yieldWAD);

        uint256 rateAfter = _getConversionRate();
        assertGt(rateAfter, rateBefore, "Stored rate should increase after yield");

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after stored conversion rate yield");
    }

    /// @notice Tests that stored conversion rate loss decreases NAV
    /// @dev This tests the baseAsset-to-NAV component of the conversion rate
    function testFuzz_storedConversionRate_loss_updatesNAV(uint256 _jtAmount, uint256 _lossBps) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _lossBps = bound(_lossBps, 10, 500); // 0.1% to 5% loss

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _getConversionRate();

        // Simulate loss by decreasing the stored conversion rate
        uint256 lossWAD = _lossBps * 1e14; // Convert bps to WAD
        _simulateLoss(lossWAD);

        uint256 rateAfter = _getConversionRate();
        assertLt(rateAfter, rateBefore, "Stored rate should decrease after loss");

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after stored conversion rate loss");
    }

    /// @notice Tests that stored conversion rate yield with ST deposits distributes correctly
    function testFuzz_storedConversionRate_yield_distributesToJT(uint256 _jtAmount, uint256 _stPercentage, uint256 _yieldBps) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 10, 50);
        _yieldBps = bound(_yieldBps, 10, 1000); // 0.1% to 10% yield

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;

        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        NAV_UNIT jtNavBefore = JT.totalAssets().nav;

        // Simulate yield via stored conversion rate
        uint256 yieldWAD = _yieldBps * 1e14;
        _simulateYield(yieldWAD);

        // Warp time for yield distribution
        vm.warp(vm.getBlockTimestamp() + 1 days);

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT jtNavAfter = JT.totalAssets().nav;

        // JT should receive portion of yield based on YDM
        assertGe(jtNavAfter, jtNavBefore, "JT NAV should increase or stay same from stored rate yield");
    }

    /// @notice Tests that stored conversion rate is correctly stored and retrievable
    function testFuzz_storedConversionRate_exactRateStorage(uint256 _jtAmount, uint256 _yieldBps) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldBps = bound(_yieldBps, 10, 1000);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        uint256 rateBefore = _getConversionRate();

        // Simulate yield via stored conversion rate
        uint256 yieldWAD = _yieldBps * 1e14;
        _simulateYield(yieldWAD);

        // Verify exact rate calculation: newRate = rateBefore * (1 + yield)
        uint256 expectedRate = rateBefore * (WAD + yieldWAD) / WAD;
        assertEq(_getConversionRate(), expectedRate, "Stored rate should match expected after yield");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // Rate should remain unchanged after sync (sync doesn't modify stored rate)
        assertEq(_getConversionRate(), expectedRate, "Stored rate should be unchanged after sync");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VAULT SHARE PRICE TESTS (ERC4626 convertToAssets component)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tests that vault share price yield increases NAV
    /// @dev This tests the ERC4626.convertToAssets() component of the conversion rate
    function testFuzz_vaultSharePrice_yield_updatesNAV(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 1, 50); // 1-50% yield

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Simulate vault share price yield (mocks convertToAssets)
        simulateVaultSharePriceYield(_yieldPercentage * 1e16); // Convert to WAD

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after vault share price yield");
    }

    /// @notice Tests that vault share price loss decreases NAV
    /// @dev This tests the ERC4626.convertToAssets() component of the conversion rate
    function testFuzz_vaultSharePrice_loss_updatesNAV(uint256 _jtAmount, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _lossPercentage = bound(_lossPercentage, 1, 30); // 1-30% loss

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Simulate vault share price loss (mocks convertToAssets)
        simulateVaultSharePriceLoss(_lossPercentage * 1e16); // Convert to WAD

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after vault share price loss");
    }

    /// @notice Tests that vault share price yield with ST deposits distributes correctly
    function testFuzz_vaultSharePrice_yield_distributesToJT(uint256 _jtAmount, uint256 _stPercentage, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 10, 50);
        _yieldPercentage = bound(_yieldPercentage, 1, 20);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;

        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        NAV_UNIT jtNavBefore = JT.totalAssets().nav;

        // Simulate vault share price yield
        simulateVaultSharePriceYield(_yieldPercentage * 1e16);

        // Warp time for yield distribution
        vm.warp(vm.getBlockTimestamp() + 1 days);

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT jtNavAfter = JT.totalAssets().nav;

        // JT should receive portion of yield based on YDM
        assertGe(jtNavAfter, jtNavBefore, "JT NAV should increase or stay same from vault share price yield");
    }

    /// @notice Tests that share price is correctly tracked and used in conversion rate
    function testFuzz_vaultSharePrice_exactPriceTracking(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 1, 30);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        uint256 sharePriceBefore = _getCurrentSharePriceWAD();
        uint256 storedRate = _getConversionRate();

        // Simulate vault share price yield
        uint256 yieldWAD = _yieldPercentage * 1e16;
        simulateVaultSharePriceYield(yieldWAD);

        // Verify exact share price calculation
        uint256 expectedSharePrice = sharePriceBefore * (WAD + yieldWAD) / WAD;
        assertEq(_getCurrentSharePriceWAD(), expectedSharePrice, "Share price should match expected after yield");

        // Verify kernel's conversion rate formula: sharePrice * storedRate / WAD
        uint256 expectedConversionRate = expectedSharePrice * storedRate / WAD;
        uint256 actualConversionRate = Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel(address(KERNEL)).getTrancheUnitToNAVUnitConversionRateWAD();
        assertEq(actualConversionRate, expectedConversionRate, "Kernel conversion rate should equal sharePrice * storedRate / WAD");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // COMBINED SHARE PRICE + STORED RATE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tests combined yield verifies the multiplicative relationship: totalRate = sharePrice * storedRate / WAD
    function testFuzz_combined_yield_verifiesMultiplicativeRate(uint256 _jtAmount, uint256 _sharePriceYieldBps, uint256 _storedRateYieldBps) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _sharePriceYieldBps = bound(_sharePriceYieldBps, 10, 500); // 0.1% to 5%
        _storedRateYieldBps = bound(_storedRateYieldBps, 10, 500); // 0.1% to 5%

        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Record initial state
        uint256 sharePriceBefore = _getCurrentSharePriceWAD();
        uint256 storedRateBefore = _getConversionRate();
        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Apply both yields
        uint256 sharePriceYieldWAD = _sharePriceYieldBps * 1e14;
        uint256 storedRateYieldWAD = _storedRateYieldBps * 1e14;
        simulateVaultSharePriceYield(sharePriceYieldWAD);
        _simulateYield(storedRateYieldWAD);

        // Calculate expected rates
        uint256 expectedSharePrice = sharePriceBefore * (WAD + sharePriceYieldWAD) / WAD;
        uint256 expectedStoredRate = storedRateBefore * (WAD + storedRateYieldWAD) / WAD;

        // Verify rates match expected
        assertEq(_getCurrentSharePriceWAD(), expectedSharePrice, "Share price should match expected after yield");
        assertEq(_getConversionRate(), expectedStoredRate, "Stored rate should match expected after yield");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after combined yield");
    }

    /// @notice Tests mixed direction: share price UP + stored rate DOWN, verifies exact rate calculations
    function testFuzz_combined_mixedDirection_sharePriceUp_storedRateDown(uint256 _jtAmount, uint256 _sharePriceYieldBps, uint256 _storedRateLossBps) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _sharePriceYieldBps = bound(_sharePriceYieldBps, 100, 500); // 1% to 5% yield
        _storedRateLossBps = bound(_storedRateLossBps, 10, 100); // 0.1% to 1% loss

        _depositJT(ALICE_ADDRESS, _jtAmount);

        uint256 sharePriceBefore = _getCurrentSharePriceWAD();
        uint256 storedRateBefore = _getConversionRate();

        // Apply share price yield and stored rate loss
        uint256 sharePriceYieldWAD = _sharePriceYieldBps * 1e14;
        uint256 storedRateLossWAD = _storedRateLossBps * 1e14;
        simulateVaultSharePriceYield(sharePriceYieldWAD);
        _simulateLoss(storedRateLossWAD);

        // Verify individual rate changes
        uint256 expectedSharePrice = sharePriceBefore * (WAD + sharePriceYieldWAD) / WAD;
        uint256 expectedStoredRate = storedRateBefore * (WAD - storedRateLossWAD) / WAD;
        assertEq(_getCurrentSharePriceWAD(), expectedSharePrice, "Share price should increase by expected amount");
        assertEq(_getConversionRate(), expectedStoredRate, "Stored rate should decrease by expected amount");

        // Verify the combined conversion rate follows the multiplicative formula
        uint256 expectedCombinedRate = expectedSharePrice * expectedStoredRate / WAD;
        uint256 actualCombinedRate = Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel(address(KERNEL)).getTrancheUnitToNAVUnitConversionRateWAD();
        assertEq(actualCombinedRate, expectedCombinedRate, "Combined rate should equal sharePrice * storedRate / WAD");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();
    }

    /// @notice Tests mixed direction: share price DOWN + stored rate UP, verifies exact rate calculations
    function testFuzz_combined_mixedDirection_sharePriceDown_storedRateUp(uint256 _jtAmount, uint256 _sharePriceLossBps, uint256 _storedRateYieldBps) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _sharePriceLossBps = bound(_sharePriceLossBps, 10, 100); // 0.1% to 1% loss
        _storedRateYieldBps = bound(_storedRateYieldBps, 100, 500); // 1% to 5% yield

        _depositJT(ALICE_ADDRESS, _jtAmount);

        uint256 sharePriceBefore = _getCurrentSharePriceWAD();
        uint256 storedRateBefore = _getConversionRate();

        // Apply share price loss and stored rate yield
        uint256 sharePriceLossWAD = _sharePriceLossBps * 1e14;
        uint256 storedRateYieldWAD = _storedRateYieldBps * 1e14;
        simulateVaultSharePriceLoss(sharePriceLossWAD);
        _simulateYield(storedRateYieldWAD);

        // Verify individual rate changes
        uint256 expectedSharePrice = sharePriceBefore * (WAD - sharePriceLossWAD) / WAD;
        uint256 expectedStoredRate = storedRateBefore * (WAD + storedRateYieldWAD) / WAD;
        assertEq(_getCurrentSharePriceWAD(), expectedSharePrice, "Share price should decrease by expected amount");
        assertEq(_getConversionRate(), expectedStoredRate, "Stored rate should increase by expected amount");

        // Verify the combined conversion rate follows the multiplicative formula
        uint256 expectedCombinedRate = expectedSharePrice * expectedStoredRate / WAD;
        uint256 actualCombinedRate = Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel(address(KERNEL)).getTrancheUnitToNAVUnitConversionRateWAD();
        assertEq(actualCombinedRate, expectedCombinedRate, "Combined rate should equal sharePrice * storedRate / WAD");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();
    }

    /// @notice Tests combined loss verifies exact rate calculations
    function testFuzz_combined_loss_verifiesExactRates(uint256 _jtAmount, uint256 _sharePriceLossBps, uint256 _storedRateLossBps) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _sharePriceLossBps = bound(_sharePriceLossBps, 10, 200); // 0.1% to 2%
        _storedRateLossBps = bound(_storedRateLossBps, 10, 200); // 0.1% to 2%

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 sharePriceBefore = _getCurrentSharePriceWAD();
        uint256 storedRateBefore = _getConversionRate();

        // Apply both losses
        uint256 sharePriceLossWAD = _sharePriceLossBps * 1e14;
        uint256 storedRateLossWAD = _storedRateLossBps * 1e14;
        simulateVaultSharePriceLoss(sharePriceLossWAD);
        _simulateLoss(storedRateLossWAD);

        // Verify exact rate calculations
        uint256 expectedSharePrice = sharePriceBefore * (WAD - sharePriceLossWAD) / WAD;
        uint256 expectedStoredRate = storedRateBefore * (WAD - storedRateLossWAD) / WAD;
        assertEq(_getCurrentSharePriceWAD(), expectedSharePrice, "Share price should match expected after loss");
        assertEq(_getConversionRate(), expectedStoredRate, "Stored rate should match expected after loss");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after combined loss");
    }

    /// @notice Tests that getTrancheUnitToNAVUnitConversionRateWAD returns sharePrice * storedRate / WAD
    function testFuzz_combined_conversionRate_verifiesMultiplicativeFormula(
        uint256 _jtAmount,
        uint256 _sharePriceChangeBps,
        uint256 _storedRateChangeBps
    )
        external
    {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _sharePriceChangeBps = bound(_sharePriceChangeBps, 10, 300);
        _storedRateChangeBps = bound(_storedRateChangeBps, 10, 300);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Apply changes
        simulateVaultSharePriceYield(_sharePriceChangeBps * 1e14);
        _simulateYield(_storedRateChangeBps * 1e14);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // Get the actual conversion rate from the kernel
        uint256 actualConversionRate = Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel(address(KERNEL)).getTrancheUnitToNAVUnitConversionRateWAD();

        // Calculate expected: sharePrice * storedRate / WAD
        uint256 sharePrice = _getCurrentSharePriceWAD();
        uint256 storedRate = _getConversionRate();
        uint256 expectedConversionRate = sharePrice * storedRate / WAD;

        assertEq(actualConversionRate, expectedConversionRate, "Conversion rate should equal sharePrice * storedRate / WAD");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SHARE PRICE IMPACT ON REDEMPTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tests that redemption NAV value increases proportionally with share price yield
    function testFuzz_vaultSharePrice_yield_increasesRedemptionValue(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 5, 30); // 5-30% yield

        _depositJT(ALICE_ADDRESS, _jtAmount);

        uint256 sharesBefore = JT.balanceOf(ALICE_ADDRESS);
        NAV_UNIT navValueBefore = JT.totalAssets().nav;
        uint256 sharePriceBefore = _getCurrentSharePriceWAD();

        // Simulate share price yield
        uint256 yieldWAD = _yieldPercentage * 1e16;
        simulateVaultSharePriceYield(yieldWAD);

        // Verify share price increased by expected amount
        uint256 expectedSharePrice = sharePriceBefore * (WAD + yieldWAD) / WAD;
        assertEq(_getCurrentSharePriceWAD(), expectedSharePrice, "Share price should match expected yield");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // Shares should be unchanged but worth more
        uint256 sharesAfter = JT.balanceOf(ALICE_ADDRESS);
        assertEq(sharesAfter, sharesBefore, "Share balance should not change");

        // NAV should have increased
        NAV_UNIT navValueAfter = JT.totalAssets().nav;
        assertGt(navValueAfter, navValueBefore, "NAV value of shares should increase after yield");

        // Verify proportional increase (approximately): navAfter ≈ navBefore * (1 + yield)
        uint256 expectedMinNav = toUint256(navValueBefore) * (WAD + yieldWAD / 2) / WAD; // Allow for some variance
        assertGt(toUint256(navValueAfter), expectedMinNav, "NAV should increase proportionally to yield");
    }

    /// @notice Tests that redemption NAV value decreases proportionally with share price loss
    function testFuzz_vaultSharePrice_loss_decreasesRedemptionValue(uint256 _jtAmount, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _lossPercentage = bound(_lossPercentage, 5, 20); // 5-20% loss

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navValueBefore = JT.totalAssets().nav;
        uint256 sharePriceBefore = _getCurrentSharePriceWAD();

        // Simulate share price loss
        uint256 lossWAD = _lossPercentage * 1e16;
        simulateVaultSharePriceLoss(lossWAD);

        // Verify share price decreased by expected amount
        uint256 expectedSharePrice = sharePriceBefore * (WAD - lossWAD) / WAD;
        assertEq(_getCurrentSharePriceWAD(), expectedSharePrice, "Share price should match expected loss");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navValueAfter = JT.totalAssets().nav;
        assertLt(navValueAfter, navValueBefore, "NAV value should decrease after loss");

        // Verify proportional decrease: navAfter < navBefore * (1 - loss/2) to account for variance
        uint256 expectedMaxNav = toUint256(navValueBefore) * (WAD - lossWAD / 2) / WAD;
        assertLt(toUint256(navValueAfter), expectedMaxNav, "NAV should decrease proportionally to loss");
    }

    /// @notice Tests full redemption after share price yield returns all shares
    function testFuzz_vaultSharePrice_redemptionAfterYield(uint256 _jtAmount, uint256 _yieldPercentage, uint256 _redeemPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 1, 20);
        _redeemPercentage = bound(_redeemPercentage, 10, 100);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        uint256 assetBalanceBefore = IERC20Metadata(config.jtAsset).balanceOf(ALICE_ADDRESS);

        // Simulate share price yield
        simulateVaultSharePriceYield(_yieldPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // Calculate shares to redeem
        uint256 totalShares = JT.balanceOf(ALICE_ADDRESS);
        uint256 sharesToRedeem = totalShares * _redeemPercentage / 100;

        if (sharesToRedeem == 0) return;

        // Execute redemption
        vm.prank(ALICE_ADDRESS);
        AssetClaims memory claims = JT.redeem(sharesToRedeem, ALICE_ADDRESS, ALICE_ADDRESS);

        // Verify shares were burned
        assertEq(JT.balanceOf(ALICE_ADDRESS), totalShares - sharesToRedeem, "Shares should be burned");

        // Verify assets were received
        assertGt(toUint256(claims.jtAssets), 0, "Should receive assets from redemption");
        uint256 assetBalanceAfter = IERC20Metadata(config.jtAsset).balanceOf(ALICE_ADDRESS);
        assertEq(assetBalanceAfter, assetBalanceBefore + toUint256(claims.jtAssets), "Asset balance should increase by redeemed amount");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SHARE PRICE IMPACT ON MAX DEPOSIT/REDEEM
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tests that maxSTDeposit increases after JT yield (more coverage available)
    function testFuzz_vaultSharePrice_yield_increasesMaxSTDeposit(uint256 _jtAmount, uint256 _stPercentage, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 10, 50);
        _yieldPercentage = bound(_yieldPercentage, 5, 30);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDepositInitial = ST.maxDeposit(CHARLIE_ADDRESS);
        assertGt(toUint256(maxSTDepositInitial), 0, "Initial maxSTDeposit should be > 0 after JT deposit");

        // Deposit some ST to have utilization (use less than max to leave room)
        uint256 stAmount = toUint256(maxSTDepositInitial) * _stPercentage / 100;
        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        TRANCHE_UNIT maxSTDepositAfterDeposit = ST.maxDeposit(CHARLIE_ADDRESS);
        assertLt(toUint256(maxSTDepositAfterDeposit), toUint256(maxSTDepositInitial), "maxSTDeposit should decrease after ST deposit");

        // Simulate share price yield (increases JT NAV -> more coverage for ST)
        simulateVaultSharePriceYield(_yieldPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        TRANCHE_UNIT maxSTDepositAfterYield = ST.maxDeposit(CHARLIE_ADDRESS);

        // After yield, JT NAV increases, so ST coverage increases -> more ST can be deposited
        assertGe(
            toUint256(maxSTDepositAfterYield), toUint256(maxSTDepositAfterDeposit), "maxSTDeposit should increase or stay same after JT yield (more coverage)"
        );
    }

    /// @notice Tests that maxSTDeposit changes after JT loss (less coverage available)
    /// @dev The relationship is: after loss, JT NAV decreases, which reduces coverage for ST
    function testFuzz_vaultSharePrice_loss_reducesJTNAV(uint256 _jtAmount, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _lossPercentage = bound(_lossPercentage, 5, 20);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT jtNAVBefore = JT.totalAssets().nav;
        TRANCHE_UNIT maxSTDepositBefore = ST.maxDeposit(CHARLIE_ADDRESS);
        assertGt(toUint256(maxSTDepositBefore), 0, "maxSTDeposit should be > 0 after JT deposit");

        // Simulate share price loss (decreases JT NAV -> less coverage for ST)
        simulateVaultSharePriceLoss(_lossPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT jtNAVAfter = JT.totalAssets().nav;

        // Verify JT NAV decreased (this is the fundamental effect of the loss)
        assertLt(jtNAVAfter, jtNAVBefore, "JT NAV should decrease after loss");

        // Verify the decrease is proportional to the loss
        uint256 lossWAD = _lossPercentage * 1e16;
        uint256 expectedMaxNav = toUint256(jtNAVBefore) * (WAD - lossWAD / 2) / WAD; // Allow variance
        assertLt(toUint256(jtNAVAfter), expectedMaxNav, "JT NAV decrease should be proportional to loss");
    }

    /// @notice Tests that JT maxRedeem remains valid and can execute full redemption after yield
    function testFuzz_vaultSharePrice_yield_maxRedeemStaysValid(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 5, 30);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        uint256 shareBalance = JT.balanceOf(ALICE_ADDRESS);
        uint256 maxRedeemBefore = JT.maxRedeem(ALICE_ADDRESS);
        assertGt(maxRedeemBefore, 0, "maxRedeem should be > 0 after deposit");

        // maxRedeem should be close to share balance (1% tolerance for rounding)
        assertApproxEqRel(maxRedeemBefore, shareBalance, 1e16, "maxRedeem should be close to share balance");

        // Simulate share price yield
        simulateVaultSharePriceYield(_yieldPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        uint256 maxRedeemAfter = JT.maxRedeem(ALICE_ADDRESS);
        assertGt(maxRedeemAfter, 0, "maxRedeem should remain > 0 after yield");

        // maxRedeem should still be close to share balance (1% tolerance)
        assertApproxEqRel(maxRedeemAfter, shareBalance, 1e16, "maxRedeem should be close to share balance after yield");

        // Verify can actually redeem max
        vm.prank(ALICE_ADDRESS);
        AssetClaims memory claims = JT.redeem(maxRedeemAfter, ALICE_ADDRESS, ALICE_ADDRESS);
        assertGt(toUint256(claims.jtAssets), 0, "Should receive assets from max redeem");

        // Most shares should be redeemed (allow small dust)
        assertLe(JT.balanceOf(ALICE_ADDRESS), shareBalance / 100, "Should have redeemed most shares");
    }

    /// @notice Tests that JT maxRedeem is constrained when ST has priority claims
    function testFuzz_vaultSharePrice_loss_constrainsJTMaxRedeem(uint256 _jtAmount, uint256 _stPercentage, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 30, 80); // Significant ST position
        _lossPercentage = bound(_lossPercentage, 5, 15);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Deposit ST to create senior claims
        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;
        // Cap to BOB's available balance (low coverage markets can have maxSTDeposit > initialFunding)
        uint256 bobBalance = IERC4626(config.stAsset).balanceOf(BOB_ADDRESS);
        if (stAmount > bobBalance) stAmount = bobBalance;
        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        uint256 jtShareBalance = JT.balanceOf(ALICE_ADDRESS);
        uint256 maxRedeemBefore = JT.maxRedeem(ALICE_ADDRESS);

        // With ST deposits, JT maxRedeem may be less than full balance (coverage constraint)
        assertLe(maxRedeemBefore, jtShareBalance, "maxRedeem should be <= share balance");

        // Simulate loss (reduces JT NAV -> tighter coverage constraint)
        simulateVaultSharePriceLoss(_lossPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        uint256 maxRedeemAfter = JT.maxRedeem(ALICE_ADDRESS);

        // After loss, JT NAV is lower -> coverage is tighter -> maxRedeem should be same or less
        assertLe(maxRedeemAfter, maxRedeemBefore, "maxRedeem should decrease or stay same after loss with ST claims");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // IMPERMANENT LOSS WITH SHARE PRICE DROP
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tests that significant loss creates impermanent loss and disables ST deposits
    function testFuzz_vaultSharePrice_significantLoss_createsImpermanentLoss(uint256 _jtAmount, uint256 _stPercentage, uint256 _lossPercentage) external {
        // Use smaller bounds to avoid balance issues
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 10, config.initialFunding / 100);
        _stPercentage = bound(_stPercentage, 50, 80); // High ST utilization
        _lossPercentage = bound(_lossPercentage, 25, 35); // Significant but bounded loss

        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Deposit ST with high utilization
        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;
        // Cap to BOB's available balance (low coverage markets can have maxSTDeposit > initialFunding)
        uint256 bobBalance = IERC4626(config.stAsset).balanceOf(BOB_ADDRESS);
        if (stAmount > bobBalance) stAmount = bobBalance;
        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        // Record state before loss
        (SyncedAccountingState memory stateBefore,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);
        NAV_UNIT impermanentLossBefore = stateBefore.stImpermanentLoss;

        // Simulate significant share price loss
        uint256 lossWAD = _lossPercentage * 1e16;
        simulateVaultSharePriceLoss(lossWAD);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // Check impermanent loss state after sync
        (SyncedAccountingState memory stateAfter,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);
        NAV_UNIT impermanentLossAfter = stateAfter.stImpermanentLoss;

        // Verify state transition: impermanent loss should be tracked
        if (impermanentLossAfter > impermanentLossBefore) {
            // Verify ST deposits are disabled (accountant state transition)
            TRANCHE_UNIT maxSTDepositAfterLoss = ST.maxDeposit(CHARLIE_ADDRESS);
            assertEq(toUint256(maxSTDepositAfterLoss), 0, "ST deposits should be disabled during impermanent loss");

            // Verify impermanent loss is non-zero and tracked in state
            assertGt(toUint256(impermanentLossAfter), 0, "Impermanent loss should be tracked in accountant state");
        }
    }

    /// @notice Tests that share price recovery reduces impermanent loss and re-enables ST deposits
    function testFuzz_vaultSharePrice_recovery_reducesImpermanentLoss(uint256 _jtAmount, uint256 _stPercentage, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 50, 80);
        _lossPercentage = bound(_lossPercentage, 15, 25);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;
        // Cap to BOB's available balance (low coverage markets can have maxSTDeposit > initialFunding)
        uint256 bobBalance = IERC4626(config.stAsset).balanceOf(BOB_ADDRESS);
        if (stAmount > bobBalance) stAmount = bobBalance;
        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        // Record initial share price
        uint256 initialSharePrice = _getCurrentSharePriceWAD();

        // Simulate loss to create impermanent loss
        uint256 lossWAD = _lossPercentage * 1e16;
        simulateVaultSharePriceLoss(lossWAD);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        (SyncedAccountingState memory stateAfterLoss,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);
        NAV_UNIT impermanentLossAfterDrop = stateAfterLoss.stImpermanentLoss;

        // Now recover: simulate yield that brings share price back to original
        // Current price is initialSharePrice * (1 - loss), need to multiply by 1/(1-loss) to get back
        uint256 currentSharePrice = _getCurrentSharePriceWAD();
        uint256 recoveryMultiplier = (initialSharePrice * WAD) / currentSharePrice;
        uint256 recoveryYield = recoveryMultiplier - WAD; // This is the yield needed to recover

        simulateVaultSharePriceYield(recoveryYield);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // Verify share price recovered to expected value
        assertApproxEqRel(_getCurrentSharePriceWAD(), initialSharePrice, 1e15, "Share price should recover to approximately initial");

        // Check impermanent loss state transition after recovery
        (SyncedAccountingState memory stateAfterRecovery,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);
        NAV_UNIT impermanentLossAfterRecovery = stateAfterRecovery.stImpermanentLoss;

        // Verify state transition: impermanent loss should be reduced
        assertLe(toUint256(impermanentLossAfterRecovery), toUint256(impermanentLossAfterDrop), "Impermanent loss should decrease after share price recovery");

        // If impermanent loss is cleared, verify JT NAV is positive again
        if (impermanentLossAfterRecovery == ZERO_NAV_UNITS) {
            NAV_UNIT jtNAVAfterRecovery = JT.totalAssets().nav;
            assertGt(toUint256(jtNAVAfterRecovery), 0, "JT NAV should be positive after impermanent loss is cleared");
        }
    }

    /// @notice Tests that multiple JT depositors maintain proportional ownership after loss
    function testFuzz_vaultSharePrice_loss_multipleDepositors_proportionalOwnership(uint256 _jtAmount1, uint256 _jtAmount2, uint256 _lossPercentage) external {
        _jtAmount1 = bound(_jtAmount1, _minDepositAmount(), config.initialFunding / 20);
        _jtAmount2 = bound(_jtAmount2, _minDepositAmount(), config.initialFunding / 20);
        _lossPercentage = bound(_lossPercentage, 1, 20);

        // Two JT depositors
        _depositJT(ALICE_ADDRESS, _jtAmount1);
        _depositJT(CHARLIE_ADDRESS, _jtAmount2);

        // Record share balances
        uint256 aliceShares = JT.balanceOf(ALICE_ADDRESS);
        uint256 charlieShares = JT.balanceOf(CHARLIE_ADDRESS);
        uint256 totalSharesBefore = JT.totalSupply();
        NAV_UNIT totalNAVBefore = JT.totalAssets().nav;

        // Simulate share price loss
        uint256 lossWAD = _lossPercentage * 1e16;
        simulateVaultSharePriceLoss(lossWAD);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT totalNAVAfter = JT.totalAssets().nav;
        uint256 totalSharesAfter = JT.totalSupply();

        // Verify state: NAV decreased but shares unchanged
        assertLt(totalNAVAfter, totalNAVBefore, "Total NAV should decrease after loss");
        assertEq(totalSharesAfter, totalSharesBefore, "Total shares should be unchanged");

        // Verify individual share balances unchanged (loss affects NAV per share, not share count)
        assertEq(JT.balanceOf(ALICE_ADDRESS), aliceShares, "Alice shares should be unchanged");
        assertEq(JT.balanceOf(CHARLIE_ADDRESS), charlieShares, "Charlie shares should be unchanged");

        // Verify proportional ownership is maintained (each user's % of total shares unchanged)
        uint256 aliceOwnershipBps = (aliceShares * 10_000) / totalSharesAfter;
        uint256 charlieOwnershipBps = (charlieShares * 10_000) / totalSharesAfter;
        uint256 expectedAliceOwnershipBps = (aliceShares * 10_000) / totalSharesBefore;
        uint256 expectedCharlieOwnershipBps = (charlieShares * 10_000) / totalSharesBefore;
        assertEq(aliceOwnershipBps, expectedAliceOwnershipBps, "Alice ownership percentage should be unchanged");
        assertEq(charlieOwnershipBps, expectedCharlieOwnershipBps, "Charlie ownership percentage should be unchanged");
    }

    /// @notice Tests sequential price changes track share price state correctly
    function testFuzz_vaultSharePrice_sequential_changes_tracksState(
        uint256 _jtAmount,
        uint256 _change1Bps,
        uint256 _change2Bps,
        uint256 _change3Bps
    )
        external
    {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _change1Bps = bound(_change1Bps, 10, 200); // 0.1% to 2%
        _change2Bps = bound(_change2Bps, 10, 200);
        _change3Bps = bound(_change3Bps, 10, 200);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        uint256 sharePriceInitial = _getCurrentSharePriceWAD();
        NAV_UNIT navInitial = JT.totalAssets().nav;

        // Change 1: Up - verify exact calculation
        uint256 change1WAD = _change1Bps * 1e14;
        simulateVaultSharePriceYield(change1WAD);
        uint256 expectedPrice1 = sharePriceInitial * (WAD + change1WAD) / WAD;
        assertEq(_getCurrentSharePriceWAD(), expectedPrice1, "Share price after change 1 should match expected");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();
        NAV_UNIT navAfter1 = JT.totalAssets().nav;
        assertGt(navAfter1, navInitial, "NAV should increase after yield");

        // Change 2: Down - verify exact calculation
        uint256 change2WAD = _change2Bps * 1e14;
        simulateVaultSharePriceLoss(change2WAD);
        uint256 expectedPrice2 = expectedPrice1 * (WAD - change2WAD) / WAD;
        assertEq(_getCurrentSharePriceWAD(), expectedPrice2, "Share price after change 2 should match expected");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();
        NAV_UNIT navAfter2 = JT.totalAssets().nav;
        assertLt(navAfter2, navAfter1, "NAV should decrease after loss");

        // Change 3: Up - verify exact calculation
        uint256 change3WAD = _change3Bps * 1e14;
        simulateVaultSharePriceYield(change3WAD);
        uint256 expectedPrice3 = expectedPrice2 * (WAD + change3WAD) / WAD;
        assertEq(_getCurrentSharePriceWAD(), expectedPrice3, "Share price after change 3 should match expected");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();
        NAV_UNIT navAfter3 = JT.totalAssets().nav;
        assertGt(navAfter3, navAfter2, "NAV should increase after final yield");
    }
}
