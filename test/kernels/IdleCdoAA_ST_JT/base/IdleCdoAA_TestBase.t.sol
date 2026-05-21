// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IIdleCDO } from "../../../../src/interfaces/external/idle-finance/IIdleCDO.sol";
import { IdenticalAssetsOracleQuoter } from "../../../../src/kernels/base/quoter/dawn/identical-assets/base/IdenticalAssetsOracleQuoter.sol";
import { WAD, WAD_DECIMALS, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../../../../src/libraries/Constants.sol";
import { AssetClaims } from "../../../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, UnitsMathLib, toTrancheUnits, toUint256 } from "../../../../src/libraries/Units.sol";
import { AbstractKernelTestSuite } from "../../abstract/AbstractKernelTestSuite.t.sol";

/// @title IdleCdoAA_TestBase
/// @notice Base test contract for Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_Kernel
/// @dev Implements the test hooks for IdleCdoAA assets where ST and JT use identical AA tranche tokens
///
/// IMPORTANT: This kernel derives NAV from the IdleCDO virtualPrice:
///   trancheToNAV = virtualPrice * IDLE_CDO_VIRTUAL_PRICE_MULTIPLIER_FOR_WAD_PRECISION
/// The admin can override with a stored conversion rate (sentinel 0 = use CDO oracle).
abstract contract IdleCdoAA_TestBase is AbstractKernelTestSuite {
    using Math for uint256;
    using UnitsMathLib for NAV_UNIT;
    using UnitsMathLib for TRANCHE_UNIT;

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════

    IERC20 internal AA_TRANCHE;
    IIdleCDO internal CDO;

    /// @dev Tracks the mocked virtual price (0 means use real CDO value)
    uint256 internal mockedVirtualPrice;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIGURATION (To be overridden by protocol-specific implementations)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the IdleCDO contract address
    function _getIdleCDO() internal view virtual returns (address);

    /// @notice Returns the AA tranche token address
    function _getAATrancheToken() internal view virtual returns (address);

    /// @notice Returns the virtual price multiplier for WAD precision conversion
    /// @dev Computed as 10^(WAD_DECIMALS - quoteTokenDecimals) where quoteToken is the IdleCDO's underlying token
    function _getVirtualPriceMultiplier() internal view virtual returns (uint256) {
        uint8 quoteTokenDecimals = IERC20Metadata(CDO.token()).decimals();
        return 10 ** (WAD_DECIMALS - quoteTokenDecimals);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // NAV MANIPULATION HOOKS IMPLEMENTATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Simulates yield generation for ST by mocking the IdleCDO virtualPrice
    function simulateSTYield(uint256 _percentageWAD) public virtual override {
        _simulateVirtualPriceYield(_percentageWAD);
    }

    /// @notice Simulates yield generation for JT by mocking the IdleCDO virtualPrice
    /// @dev ST and JT share the same asset so this has the same effect as simulateSTYield
    function simulateJTYield(uint256 _percentageWAD) public virtual override {
        _simulateVirtualPriceYield(_percentageWAD);
    }

    /// @notice Simulates loss for ST by mocking the IdleCDO virtualPrice
    function simulateSTLoss(uint256 _percentageWAD) public virtual override {
        _simulateVirtualPriceLoss(_percentageWAD);
    }

    /// @notice Simulates loss for JT by mocking the IdleCDO virtualPrice
    /// @dev ST and JT share the same asset so this has the same effect as simulateSTLoss
    function simulateJTLoss(uint256 _percentageWAD) public virtual override {
        _simulateVirtualPriceLoss(_percentageWAD);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIRTUAL PRICE MANIPULATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Gets the current virtual price (either mocked or from actual CDO)
    function _getCurrentVirtualPrice() internal view returns (uint256) {
        if (mockedVirtualPrice != 0) {
            return mockedVirtualPrice;
        }
        return CDO.virtualPrice(_getAATrancheToken());
    }

    /// @notice Mocks the IdleCDO virtualPrice function with a new value
    function _mockVirtualPrice(uint256 _newVirtualPrice) internal {
        mockedVirtualPrice = _newVirtualPrice;
        vm.mockCall(_getIdleCDO(), abi.encodeWithSelector(IIdleCDO.virtualPrice.selector, _getAATrancheToken()), abi.encode(_newVirtualPrice));
    }

    /// @notice Simulates yield by increasing the virtual price proportionally
    function _simulateVirtualPriceYield(uint256 _percentageWAD) internal {
        uint256 currentVirtualPrice = _getCurrentVirtualPrice();
        uint256 newVirtualPrice = currentVirtualPrice * (WAD + _percentageWAD) / WAD;
        _mockVirtualPrice(newVirtualPrice);
    }

    /// @notice Simulates loss by decreasing the virtual price proportionally
    function _simulateVirtualPriceLoss(uint256 _percentageWAD) internal {
        uint256 currentVirtualPrice = _getCurrentVirtualPrice();
        // Ensure we don't underflow by capping loss at 100%
        uint256 lossFactor = _percentageWAD >= WAD ? 0 : WAD - _percentageWAD;
        uint256 newVirtualPrice = currentVirtualPrice * lossFactor / WAD;
        // Ensure virtual price never goes to 0
        if (newVirtualPrice == 0) newVirtualPrice = 1;
        _mockVirtualPrice(newVirtualPrice);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONVERSION RATE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that ST and JT conversions are identical (same asset)
    function test_conversionRate_stAndJtIdentical() public view {
        uint8 decimals = IERC20Metadata(config.stAsset).decimals();
        TRANCHE_UNIT amount = toTrancheUnits(1000 * (10 ** decimals));

        NAV_UNIT stNav = KERNEL.stConvertTrancheUnitsToNAVUnits(amount);
        NAV_UNIT jtNav = KERNEL.jtConvertTrancheUnitsToNAVUnits(amount);

        assertEq(stNav, jtNav, "ST and JT conversions must be identical");
    }

    /// @notice Test round-trip conversion preserves value
    function test_conversionRate_roundTripPreservesValue() public view {
        uint8 decimals = IERC20Metadata(config.stAsset).decimals();

        uint256[] memory testAmounts = new uint256[](4);
        testAmounts[0] = 1 * (10 ** decimals); // 1 token
        testAmounts[1] = 100 * (10 ** decimals); // 100 tokens
        testAmounts[2] = 10_000 * (10 ** decimals); // 10K tokens
        testAmounts[3] = 1; // 1 wei (minimum)

        for (uint256 i = 0; i < testAmounts.length; i++) {
            TRANCHE_UNIT original = toTrancheUnits(testAmounts[i]);

            NAV_UNIT nav = KERNEL.stConvertTrancheUnitsToNAVUnits(original);
            TRANCHE_UNIT back = KERNEL.stConvertNAVUnitsToTrancheUnits(nav);

            assertApproxEqAbs(back, original, 1, "Round-trip conversion must preserve value");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN CONVERSION RATE OVERRIDE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that oracle quoter admin can override conversion rate
    function test_setConversionRate_adminCanOverride() public {
        uint256 newConversionRateWAD = 1.5e18;

        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        IdenticalAssetsOracleQuoter(address(KERNEL)).setConversionRate(newConversionRateWAD, true);

        uint256 storedRate = IdenticalAssetsOracleQuoter(address(KERNEL)).getStoredConversionRateWAD();
        assertEq(storedRate, newConversionRateWAD, "Stored conversion rate should be updated");
    }

    /// @notice Test that overridden conversion rate is used in conversions
    function test_setConversionRate_usedInConversions() public {
        uint8 decimals = IERC20Metadata(config.stAsset).decimals();
        uint256 scaleFactor = _getVirtualPriceMultiplier();

        TRANCHE_UNIT oneToken = toTrancheUnits(10 ** decimals);
        NAV_UNIT initialNav = KERNEL.stConvertTrancheUnitsToNAVUnits(oneToken);

        // Set a new conversion rate: 2x the current virtual price
        uint256 virtualPrice = CDO.virtualPrice(_getAATrancheToken());
        uint256 newConversionRateWAD = virtualPrice * scaleFactor * 2;

        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        IdenticalAssetsOracleQuoter(address(KERNEL)).setConversionRate(newConversionRateWAD, true);

        NAV_UNIT newNav = KERNEL.stConvertTrancheUnitsToNAVUnits(oneToken);

        assertApproxEqRel(toUint256(newNav), toUint256(initialNav) * 2, 0.01e18, "Conversion should use overridden rate");
    }

    /// @notice Test that non-admin cannot override conversion rate
    function test_setConversionRate_revertsForNonAdmin() public {
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert();
        IdenticalAssetsOracleQuoter(address(KERNEL)).setConversionRate(1.5e18, true);
    }

    /// @notice Test setting conversion rate to sentinel value resets to oracle
    function test_setConversionRate_sentinelResetsToOracle() public {
        uint8 decimals = IERC20Metadata(config.stAsset).decimals();
        uint256 scaleFactor = _getVirtualPriceMultiplier();

        // First override the rate
        uint256 overrideRate = 2e18;
        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        IdenticalAssetsOracleQuoter(address(KERNEL)).setConversionRate(overrideRate, true);

        TRANCHE_UNIT oneToken = toTrancheUnits(10 ** decimals);
        NAV_UNIT overriddenNav = KERNEL.stConvertTrancheUnitsToNAVUnits(oneToken);

        // Reset to sentinel (0) to use oracle
        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        IdenticalAssetsOracleQuoter(address(KERNEL)).setConversionRate(0, true);

        NAV_UNIT oracleNav = KERNEL.stConvertTrancheUnitsToNAVUnits(oneToken);

        // Oracle NAV should match CDO virtual price
        uint256 expectedNav = CDO.virtualPrice(_getAATrancheToken()) * scaleFactor;
        assertApproxEqRel(toUint256(oracleNav), expectedNav, 0.001e18, "Should use oracle rate after reset");

        assertTrue(toUint256(oracleNav) != toUint256(overriddenNav) || overrideRate == expectedNav, "Oracle rate should differ from override");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // NAV CALCULATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that raw NAV reflects deposits correctly
    function test_rawNAV_reflectsDeposits() public {
        uint8 decimals = IERC20Metadata(config.stAsset).decimals();
        uint256 scaleFactor = _getVirtualPriceMultiplier();

        assertEq(JT.getRawNAV(), ZERO_NAV_UNITS, "Initial JT NAV should be 0");

        uint256 depositAmount = 10_000 * (10 ** decimals);
        vm.startPrank(ALICE_ADDRESS);
        IERC20(_getAATrancheToken()).approve(address(JT), depositAmount);
        JT.deposit(toTrancheUnits(depositAmount), ALICE_ADDRESS);
        vm.stopPrank();

        NAV_UNIT rawNAV = JT.getRawNAV();
        assertGt(rawNAV, ZERO_NAV_UNITS, "JT NAV should be > 0 after deposit");

        uint256 expectedNAV = depositAmount * CDO.virtualPrice(_getAATrancheToken()) * scaleFactor / (10 ** decimals);
        assertApproxEqRel(toUint256(rawNAV), expectedNAV, 0.01e18, "NAV should match expected value");
    }

    /// @notice Test total assets claim structure
    function test_totalAssets_hasCorrectStructure() public {
        uint8 decimals = IERC20Metadata(config.stAsset).decimals();

        uint256 depositAmount = 10_000 * (10 ** decimals);
        vm.startPrank(ALICE_ADDRESS);
        IERC20(_getAATrancheToken()).approve(address(JT), depositAmount);
        JT.deposit(toTrancheUnits(depositAmount), ALICE_ADDRESS);
        vm.stopPrank();

        AssetClaims memory claims = JT.totalAssets();

        assertGt(claims.nav, ZERO_NAV_UNITS, "NAV should be > 0");
        assertGt(claims.jtAssets, ZERO_TRANCHE_UNITS, "JT assets should be > 0");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIRTUAL PRICE MOCKING TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that simulated yield increases NAV proportionally
    function test_simulateYield_increasesNAV() public {
        uint8 decimals = IERC20Metadata(config.stAsset).decimals();

        uint256 depositAmount = 10_000 * (10 ** decimals);
        _depositJT(ALICE_ADDRESS, depositAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 virtualPriceBefore = _getCurrentVirtualPrice();

        _simulateVirtualPriceYield(0.1e18);

        uint256 virtualPriceAfter = _getCurrentVirtualPrice();
        assertGt(virtualPriceAfter, virtualPriceBefore, "Virtual price should increase after yield");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after yield");
    }

    /// @notice Test that simulated loss decreases NAV proportionally
    function test_simulateLoss_decreasesNAV() public {
        uint8 decimals = IERC20Metadata(config.stAsset).decimals();

        uint256 depositAmount = 10_000 * (10 ** decimals);
        _depositJT(ALICE_ADDRESS, depositAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 virtualPriceBefore = _getCurrentVirtualPrice();

        _simulateVirtualPriceLoss(0.1e18);

        uint256 virtualPriceAfter = _getCurrentVirtualPrice();
        assertLt(virtualPriceAfter, virtualPriceBefore, "Virtual price should decrease after loss");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after loss");
    }
}
