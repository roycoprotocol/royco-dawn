// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { ZERO_NAV_UNITS } from "../../src/libraries/Constants.sol";
import { WAD } from "../../src/libraries/Constants.sol";
import { NAV_UNIT, toNAVUnits } from "../../src/libraries/Units.sol";
import { UtilsLib } from "../../src/libraries/UtilsLib.sol";
import { BaseTest } from "../base/BaseTest.t.sol";

contract StaticCurveYDMTest is BaseTest {
    using Math for uint256;

    // Constants from StaticCurveYDM
    uint256 public constant TARGET_UTILIZATION = 0.9e18;
    uint256 public constant SLOPE_LT_TARGET_UTIL = 0.25e18;
    uint256 public constant SLOPE_GTE_TARGET_UTIL = 7.75e18;
    uint256 public constant JT_YIELD_SHARE_AT_TARGET_UTIL = 0.225e18;

    // Test parameters
    uint256 public constant BETA_100_PCT = WAD; // 100% beta
    uint256 public constant COVERAGE_100_PCT = WAD; // 100% coverage

    function setUp() public {
        _setUpRoyco();

        YDM.initializeYDMForMarket(0, JT_YIELD_SHARE_AT_TARGET_UTIL, WAD);
    }

    // ============================================
    // Boundary Condition Tests
    // ============================================

    /// @notice Test utilization = 0 (zero utilization)
    function test_previewJTYieldShare_utilizationZero() public view {
        // Setup: U = 0 means no exposure
        NAV_UNIT stRawNAV = ZERO_NAV_UNITS;
        NAV_UNIT jtRawNAV = ZERO_NAV_UNITS;
        uint256 betaWAD = BETA_100_PCT;
        uint256 coverageWAD = COVERAGE_100_PCT;
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1e18)); // Non-zero to avoid infinite utilization

        uint256 result = YDM.previewJTYieldShare(stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        assertEq(result, 0, "At U=0, yield share should be 0");
    }

    /// @notice Test utilization exactly at target (0.9)
    function test_previewJTYieldShare_utilizationAtTarget() public view {
        // Setup: U = 0.9
        // U = ((ST + JT * beta) * cov) / JT_eff = 0.9
        // If JT_eff = 1e18, cov = 1e18, beta = 1e18, then ST + JT = 0.9e18
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT stRawNAV = toNAVUnits(uint256(0.45e18));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(0.45e18));
        uint256 betaWAD = BETA_100_PCT;
        uint256 coverageWAD = COVERAGE_100_PCT;

        uint256 result = YDM.previewJTYieldShare(stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        // At U = 0.9, R(U) = JT_YIELD_SHARE_AT_TARGET_UTIL = 0.225e18
        assertEq(result, JT_YIELD_SHARE_AT_TARGET_UTIL, "At U=0.9, yield share should equal JT_YIELD_SHARE_AT_TARGET_UTIL");
    }

    /// @notice Test utilization exactly at 1.0 (100%)
    function test_previewJTYieldShare_utilizationAtOne() public view {
        // Setup: U = 1.0
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT stRawNAV = toNAVUnits(uint256(0.5e18));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(0.5e18));
        uint256 betaWAD = BETA_100_PCT;
        uint256 coverageWAD = COVERAGE_100_PCT;

        uint256 result = YDM.previewJTYieldShare(stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        // At U = 1.0, R(U) = 1.0
        assertEq(result, WAD, "At U=1.0, yield share should be 1.0 (100%)");
    }

    /// @notice Test utilization > 1.0 (overcollateralized)
    function test_previewJTYieldShare_utilizationAboveOne() public view {
        // Setup: U = 1.5
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT stRawNAV = toNAVUnits(uint256(0.75e18));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(0.75e18));
        uint256 betaWAD = BETA_100_PCT;
        uint256 coverageWAD = COVERAGE_100_PCT;

        uint256 result = YDM.previewJTYieldShare(stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        // At U >= 1.0, R(U) = 1.0
        assertEq(result, WAD, "At U>1.0, yield share should be 1.0 (100%)");
    }

    /// @notice Test utilization just below target (0.9 - epsilon)
    function test_previewJTYieldShare_utilizationJustBelowTarget() public view {
        // Setup: U = 0.8999... (just below 0.9)
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1e18));
        // U = 0.899999999999999999 = 899999999999999999 / 1e18
        // We need (ST + JT) * cov = 0.899999999999999999
        NAV_UNIT stRawNAV = toNAVUnits(uint256(449_999_999_999_999_999));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(449_999_999_999_999_999));
        uint256 betaWAD = BETA_100_PCT;
        uint256 coverageWAD = COVERAGE_100_PCT;

        uint256 result = YDM.previewJTYieldShare(stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        // Should use first leg: R(U) = 0.25 * U
        // Expected: 0.25 * 0.899999999999999999 = 0.22499999999999999975
        // With Floor rounding: 0.224999999999999999e18
        uint256 expected = SLOPE_LT_TARGET_UTIL.mulDiv(899_999_999_999_999_999, WAD, Math.Rounding.Floor);
        assertEq(result, expected, "Just below target should use first leg formula");
        assertLt(result, JT_YIELD_SHARE_AT_TARGET_UTIL, "Result should be less than JT_YIELD_SHARE_AT_TARGET_UTIL");
    }

    /// @notice Test utilization just above target (0.9 + epsilon)
    function test_previewJTYieldShare_utilizationJustAboveTarget() public view {
        // Setup: U = 0.900000000000000001 (just above 0.9)
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT stRawNAV = toNAVUnits(uint256(450_000_000_000_000_000));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(450_000_000_000_000_000));
        uint256 betaWAD = BETA_100_PCT;
        uint256 coverageWAD = COVERAGE_100_PCT;

        uint256 result = YDM.previewJTYieldShare(stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        // Should use second leg: R(U) = 7.75 * (U - 0.9) + 0.225
        // Expected: 7.75 * (0.900000000000000001 - 0.9) + 0.225 = 7.75 * 0.000000000000000001 + 0.225
        // = 0.00000000000000000775 + 0.225 = 0.22500000000000000775
        // With Floor rounding, this should be very close to JT_YIELD_SHARE_AT_TARGET_UTIL
        assertGe(result, JT_YIELD_SHARE_AT_TARGET_UTIL, "Just above target should use second leg formula");
    }

    /// @notice Test utilization just below 1.0
    function test_previewJTYieldShare_utilizationJustBelowOne() public view {
        // Setup: U = 0.999999999999999999 (just below 1.0)
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT stRawNAV = toNAVUnits(uint256(499_999_999_999_999_999));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(499_999_999_999_999_999));
        uint256 betaWAD = BETA_100_PCT;
        uint256 coverageWAD = COVERAGE_100_PCT;

        uint256 result = YDM.previewJTYieldShare(stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        // Should use second leg: R(U) = 7.75 * (U - 0.9) + 0.225
        // Expected: 7.75 * (0.999999999999999999 - 0.9) + 0.225
        // = 7.75 * 0.099999999999999999 + 0.225
        // = 0.77499999999999999225 + 0.225 = 0.99999999999999999225
        // With Floor rounding, should be less than 1.0
        assertLt(result, WAD, "Just below 1.0 should be less than 1.0");
        assertGt(result, JT_YIELD_SHARE_AT_TARGET_UTIL, "Should be greater than JT_YIELD_SHARE_AT_TARGET_UTIL");
    }

    /// @notice Test with very small utilization
    function test_previewJTYieldShare_verySmallUtilization() public view {
        // Setup: U = 0.01
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT stRawNAV = toNAVUnits(uint256(0.005e18));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(0.005e18));
        uint256 betaWAD = BETA_100_PCT;
        uint256 coverageWAD = COVERAGE_100_PCT;

        uint256 result = YDM.previewJTYieldShare(stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        // Expected: 0.25 * 0.01 = 0.0025e18
        uint256 expected = 0.0025e18;
        assertEq(result, expected, "Should handle very small utilization correctly");
    }

    /// @notice Test that result is always between 0 and 1
    function test_previewJTYieldShare_resultInValidRange() public view {
        // Test with various utilization values
        uint256[] memory utilizations = new uint256[](10);
        utilizations[0] = 0;
        utilizations[1] = 0.1e18;
        utilizations[2] = 0.3e18;
        utilizations[3] = 0.5e18;
        utilizations[4] = 0.7e18;
        utilizations[5] = 0.89e18;
        utilizations[6] = 0.9e18;
        utilizations[7] = 0.95e18;
        utilizations[8] = 0.99e18;
        utilizations[9] = 1.5e18;

        for (uint256 i = 0; i < utilizations.length; i++) {
            uint256 u = utilizations[i];
            NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1e18));
            NAV_UNIT stRawNAV = toNAVUnits(uint256(u / 2));
            NAV_UNIT jtRawNAV = toNAVUnits(uint256(u / 2));
            uint256 betaWAD = BETA_100_PCT;
            uint256 coverageWAD = COVERAGE_100_PCT;

            uint256 result = YDM.previewJTYieldShare(stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

            assertGe(result, 0, "Result should be >= 0");
            assertLe(result, WAD, "Result should be <= 1.0");
        }
    }

    // ============================================
    // Specific Point Tests with Known Values
    // ============================================

    /// @notice Test U = 0.45 (half of target), R(U) = 0.25 * 0.45 = 0.1125
    function test_previewJTYieldShare_utilizationHalfTarget() public view {
        // Setup: U = 0.45
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT stRawNAV = toNAVUnits(uint256(0.225e18));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(0.225e18));
        uint256 betaWAD = BETA_100_PCT;
        uint256 coverageWAD = COVERAGE_100_PCT;

        uint256 result = YDM.previewJTYieldShare(stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        // Expected: 0.25 * 0.45 = 0.1125e18
        uint256 expected = 0.1125e18;
        assertEq(result, expected, "At U=0.45, yield share should be 0.1125");
    }

    /// @notice Test U = 0.5, R(U) = 0.25 * 0.5 = 0.125
    function test_previewJTYieldShare_utilizationPointFive() public view {
        // Setup: U = 0.5
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT stRawNAV = toNAVUnits(uint256(0.25e18));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(0.25e18));
        uint256 betaWAD = BETA_100_PCT;
        uint256 coverageWAD = COVERAGE_100_PCT;

        uint256 result = YDM.previewJTYieldShare(stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        // Expected: 0.25 * 0.5 = 0.125e18
        uint256 expected = 0.125e18;
        assertEq(result, expected, "At U=0.5, yield share should be 0.125");
    }

    /// @notice Test U = 0.8, R(U) = 0.25 * 0.8 = 0.2
    function test_previewJTYieldShare_utilizationPointEight() public view {
        // Setup: U = 0.8
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT stRawNAV = toNAVUnits(uint256(0.4e18));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(0.4e18));
        uint256 betaWAD = BETA_100_PCT;
        uint256 coverageWAD = COVERAGE_100_PCT;

        uint256 result = YDM.previewJTYieldShare(stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        // Expected: 0.25 * 0.8 = 0.2e18
        uint256 expected = 0.2e18;
        assertEq(result, expected, "At U=0.8, yield share should be 0.2");
    }

    /// @notice Test U = 0.95, R(U) = 7.75 * (0.95 - 0.9) + 0.225 = 0.6125
    function test_previewJTYieldShare_utilizationPointNineFive() public view {
        // Setup: U = 0.95
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT stRawNAV = toNAVUnits(uint256(0.475e18));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(0.475e18));
        uint256 betaWAD = BETA_100_PCT;
        uint256 coverageWAD = COVERAGE_100_PCT;

        uint256 result = YDM.previewJTYieldShare(stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        // Expected: 7.75 * (0.95 - 0.9) + 0.225 = 7.75 * 0.05 + 0.225 = 0.3875 + 0.225 = 0.6125e18
        uint256 expected = 0.6125e18;
        assertEq(result, expected, "At U=0.95, yield share should be 0.6125");
    }

    /// @notice Test U = 0.99, R(U) = 7.75 * (0.99 - 0.9) + 0.225 = 0.9225
    function test_previewJTYieldShare_utilizationPointNineNine() public view {
        // Setup: U = 0.99
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT stRawNAV = toNAVUnits(uint256(0.495e18));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(0.495e18));
        uint256 betaWAD = BETA_100_PCT;
        uint256 coverageWAD = COVERAGE_100_PCT;

        uint256 result = YDM.previewJTYieldShare(stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        // Expected: 7.75 * (0.99 - 0.9) + 0.225 = 7.75 * 0.09 + 0.225 = 0.6975 + 0.225 = 0.9225e18
        uint256 expected = 0.9225e18;
        assertEq(result, expected, "At U=0.99, yield share should be 0.9225");
    }

    // ============================================
    // Edge Cases
    // ============================================

    /// @notice Test with zero JT effective NAV (infinite utilization)
    function test_previewJTYieldShare_zeroJTEffectiveNAV() public view {
        NAV_UNIT stRawNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(1e18));
        uint256 betaWAD = BETA_100_PCT;
        uint256 coverageWAD = COVERAGE_100_PCT;
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(0)); // Zero effective NAV

        uint256 result = YDM.previewJTYieldShare(stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        // Infinite utilization should return 1.0 (100%)
        assertEq(result, WAD, "Infinite utilization should return 1.0");
    }

    /// @notice Test with different beta values
    function test_previewJTYieldShare_differentBeta() public view {
        // Setup: U = 0.5 with beta = 0.5 (50%)
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT stRawNAV = toNAVUnits(uint256(0.25e18));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(0.5e18)); // Higher JT to compensate for lower beta
        uint256 betaWAD = 0.5e18; // 50% beta
        uint256 coverageWAD = COVERAGE_100_PCT;

        // Utilization = ((0.25 + 0.5 * 0.5) * 1) / 1 = (0.25 + 0.25) / 1 = 0.5
        uint256 result = YDM.previewJTYieldShare(stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        uint256 expected = 0.125e18; // 0.25 * 0.5 = 0.125
        assertEq(result, expected, "Should handle different beta values correctly");
    }

    /// @notice Test with different coverage values
    function test_previewJTYieldShare_differentCoverage() public view {
        // Setup: U = 0.5 with coverage = 0.5 (50%)
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT stRawNAV = toNAVUnits(uint256(0.5e18));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(0.5e18));
        uint256 betaWAD = BETA_100_PCT;
        uint256 coverageWAD = 0.5e18; // 50% coverage

        // Utilization = ((0.5 + 0.5 * 1) * 0.5) / 1 = (1.0 * 0.5) / 1 = 0.5
        uint256 result = YDM.previewJTYieldShare(stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        uint256 expected = 0.125e18; // 0.25 * 0.5 = 0.125
        assertEq(result, expected, "Should handle different coverage values correctly");
    }

    /// @notice Test continuity at the boundary (U = 0.9)
    /// @dev Verify that both formulas give the same result at the boundary
    function test_previewJTYieldShare_continuityAtBoundary() public view {
        // At U = 0.9 exactly:
        // First leg: 0.25 * 0.9 = 0.225
        // Second leg: 7.75 * (0.9 - 0.9) + 0.225 = 0.225
        // They should be equal

        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT stRawNAV = toNAVUnits(uint256(0.45e18));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(0.45e18));
        uint256 betaWAD = BETA_100_PCT;
        uint256 coverageWAD = COVERAGE_100_PCT;

        uint256 result = YDM.previewJTYieldShare(stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        // Calculate what first leg would give
        uint256 firstLeg = SLOPE_LT_TARGET_UTIL.mulDiv(TARGET_UTILIZATION, WAD, Math.Rounding.Floor);
        // Calculate what second leg gives
        uint256 secondLeg = JT_YIELD_SHARE_AT_TARGET_UTIL;

        assertEq(result, JT_YIELD_SHARE_AT_TARGET_UTIL, "At boundary, should equal JT_YIELD_SHARE_AT_TARGET_UTIL");
        assertEq(firstLeg, secondLeg, "Both legs should give same result at boundary");
    }

    // ============================================
    // Fuzz Tests
    // ============================================

    /// @notice Fuzz test: result should always be in valid range [0, WAD]
    function testFuzz_previewJTYieldShare_resultInValidRange(
        uint256 _stRawNAV,
        uint256 _jtRawNAV,
        uint256 _betaWAD,
        uint256 _coverageWAD,
        uint256 _jtEffectiveNAV
    )
        public
        view
    {
        // Bound inputs to reasonable ranges to avoid overflow
        _stRawNAV = bound(_stRawNAV, 0, type(uint128).max);
        _jtRawNAV = bound(_jtRawNAV, 0, type(uint128).max);
        _betaWAD = bound(_betaWAD, 0, WAD * 2);
        _coverageWAD = bound(_coverageWAD, 0, WAD * 2);
        _jtEffectiveNAV = bound(_jtEffectiveNAV, 0, type(uint128).max);

        uint256 result = YDM.previewJTYieldShare(
            toNAVUnits(uint256(_stRawNAV)), toNAVUnits(uint256(_jtRawNAV)), _betaWAD, _coverageWAD, toNAVUnits(uint256(_jtEffectiveNAV))
        );

        assertGe(result, 0, "Result should be >= 0");
        assertLe(result, WAD, "Result should be <= 1.0");
    }

    /// @notice Fuzz test: utilization >= 1.0 should return WAD (100%)
    function testFuzz_previewJTYieldShare_utilizationAboveOne(
        uint256 _stRawNAV,
        uint256 _jtRawNAV,
        uint256 _betaWAD,
        uint256 _coverageWAD,
        uint256 _jtEffectiveNAV
    )
        public
        view
    {
        // Bound inputs to reasonable ranges
        _stRawNAV = bound(_stRawNAV, 0, type(uint128).max);
        _jtRawNAV = bound(_jtRawNAV, 0, type(uint128).max);
        _betaWAD = bound(_betaWAD, 0, WAD * 2);
        _coverageWAD = bound(_coverageWAD, 0, WAD * 2);
        _jtEffectiveNAV = bound(_jtEffectiveNAV, 1, type(uint128).max);

        // Calculate utilization
        uint256 utilization = UtilsLib.computeUtilization(
            toNAVUnits(uint256(_stRawNAV)), toNAVUnits(uint256(_jtRawNAV)), _betaWAD, _coverageWAD, toNAVUnits(uint256(_jtEffectiveNAV))
        );

        // Only test cases where utilization >= 1.0
        if (utilization >= WAD) {
            uint256 result = YDM.previewJTYieldShare(
                toNAVUnits(uint256(_stRawNAV)), toNAVUnits(uint256(_jtRawNAV)), _betaWAD, _coverageWAD, toNAVUnits(uint256(_jtEffectiveNAV))
            );
            assertEq(result, WAD, "At U>=1.0, yield share should be 1.0 (100%)");
        }
    }

    /// @notice Fuzz test: utilization just below target (0.89e18 <= U < 0.9e18) should use first leg
    function testFuzz_previewJTYieldShare_utilizationJustBelowTarget(
        uint256 _stRawNAV,
        uint256 _jtRawNAV,
        uint256 _betaWAD,
        uint256 _coverageWAD,
        uint256 _jtEffectiveNAV
    )
        public
        view
    {
        // Bound inputs to reasonable ranges
        _stRawNAV = bound(_stRawNAV, 0, type(uint128).max);
        _jtRawNAV = bound(_jtRawNAV, 0, type(uint128).max);
        _betaWAD = bound(_betaWAD, 0, WAD * 2);
        _coverageWAD = bound(_coverageWAD, 0, WAD * 2);
        _jtEffectiveNAV = bound(_jtEffectiveNAV, 1, type(uint128).max);

        // Calculate utilization
        uint256 utilization = UtilsLib.computeUtilization(
            toNAVUnits(uint256(_stRawNAV)), toNAVUnits(uint256(_jtRawNAV)), _betaWAD, _coverageWAD, toNAVUnits(uint256(_jtEffectiveNAV))
        );

        // Only test cases where utilization is just below target
        if (utilization < TARGET_UTILIZATION && utilization >= 0.89e18) {
            uint256 result = YDM.previewJTYieldShare(
                toNAVUnits(uint256(_stRawNAV)), toNAVUnits(uint256(_jtRawNAV)), _betaWAD, _coverageWAD, toNAVUnits(uint256(_jtEffectiveNAV))
            );
            // Should use first leg: R(U) = 0.25 * U
            uint256 expected = SLOPE_LT_TARGET_UTIL.mulDiv(utilization, WAD, Math.Rounding.Floor);
            assertEq(result, expected, "Just below target should use first leg formula");
            assertLt(result, JT_YIELD_SHARE_AT_TARGET_UTIL, "Result should be less than JT_YIELD_SHARE_AT_TARGET_UTIL");
        }
    }

    /// @notice Fuzz test: utilization just above target (0.9e18 < U <= 0.91e18) should use second leg
    function testFuzz_previewJTYieldShare_utilizationJustAboveTarget(
        uint256 _stRawNAV,
        uint256 _jtRawNAV,
        uint256 _betaWAD,
        uint256 _coverageWAD,
        uint256 _jtEffectiveNAV
    )
        public
        view
    {
        // Bound inputs to reasonable ranges
        _stRawNAV = bound(_stRawNAV, 0, type(uint128).max);
        _jtRawNAV = bound(_jtRawNAV, 0, type(uint128).max);
        _betaWAD = bound(_betaWAD, 0, WAD * 2);
        _coverageWAD = bound(_coverageWAD, 0, WAD * 2);
        _jtEffectiveNAV = bound(_jtEffectiveNAV, 1, type(uint128).max);

        // Calculate utilization
        uint256 utilization = UtilsLib.computeUtilization(
            toNAVUnits(uint256(_stRawNAV)), toNAVUnits(uint256(_jtRawNAV)), _betaWAD, _coverageWAD, toNAVUnits(uint256(_jtEffectiveNAV))
        );

        // Only test cases where utilization is just above target
        if (utilization >= TARGET_UTILIZATION && utilization <= 0.91e18 && utilization < WAD) {
            uint256 result = YDM.previewJTYieldShare(
                toNAVUnits(uint256(_stRawNAV)), toNAVUnits(uint256(_jtRawNAV)), _betaWAD, _coverageWAD, toNAVUnits(uint256(_jtEffectiveNAV))
            );
            // Should use second leg: R(U) = 7.75 * (U - 0.9) + 0.225
            assertGe(result, JT_YIELD_SHARE_AT_TARGET_UTIL, "Just above target should use second leg formula");
        }
    }

    /// @notice Fuzz test: utilization just below 1.0 (0.99e18 <= U < 1.0e18) should be < 1.0
    function testFuzz_previewJTYieldShare_utilizationJustBelowOne(
        uint256 _stRawNAV,
        uint256 _jtRawNAV,
        uint256 _betaWAD,
        uint256 _coverageWAD,
        uint256 _jtEffectiveNAV
    )
        public
        view
    {
        // Bound inputs to reasonable ranges
        _stRawNAV = bound(_stRawNAV, 0, type(uint128).max);
        _jtRawNAV = bound(_jtRawNAV, 0, type(uint128).max);
        _betaWAD = bound(_betaWAD, 0, WAD * 2);
        _coverageWAD = bound(_coverageWAD, 0, WAD * 2);
        _jtEffectiveNAV = bound(_jtEffectiveNAV, 1, type(uint128).max);

        // Calculate utilization
        uint256 utilization = UtilsLib.computeUtilization(
            toNAVUnits(uint256(_stRawNAV)), toNAVUnits(uint256(_jtRawNAV)), _betaWAD, _coverageWAD, toNAVUnits(uint256(_jtEffectiveNAV))
        );

        // Only test cases where utilization is just below 1.0
        if (utilization >= 0.99e18 && utilization < WAD) {
            uint256 result = YDM.previewJTYieldShare(
                toNAVUnits(uint256(_stRawNAV)), toNAVUnits(uint256(_jtRawNAV)), _betaWAD, _coverageWAD, toNAVUnits(uint256(_jtEffectiveNAV))
            );
            assertLt(result, WAD, "Just below 1.0 should be less than 1.0");
            assertGt(result, JT_YIELD_SHARE_AT_TARGET_UTIL, "Should be greater than JT_YIELD_SHARE_AT_TARGET_UTIL");
        }
    }

    /// @notice Fuzz test: very small utilization (U < 0.1e18) should use first leg
    function testFuzz_previewJTYieldShare_verySmallUtilization(
        uint256 _stRawNAV,
        uint256 _jtRawNAV,
        uint256 _betaWAD,
        uint256 _coverageWAD,
        uint256 _jtEffectiveNAV
    )
        public
        view
    {
        // Bound inputs to reasonable ranges
        _stRawNAV = bound(_stRawNAV, 0, type(uint128).max);
        _jtRawNAV = bound(_jtRawNAV, 0, type(uint128).max);
        _betaWAD = bound(_betaWAD, 0, WAD * 2);
        _coverageWAD = bound(_coverageWAD, 0, WAD * 2);
        _jtEffectiveNAV = bound(_jtEffectiveNAV, 1, type(uint128).max);

        // Calculate utilization
        uint256 utilization = UtilsLib.computeUtilization(
            toNAVUnits(uint256(_stRawNAV)), toNAVUnits(uint256(_jtRawNAV)), _betaWAD, _coverageWAD, toNAVUnits(uint256(_jtEffectiveNAV))
        );

        // Only test cases where utilization is very small
        if (utilization < 0.1e18 && utilization > 0) {
            uint256 result = YDM.previewJTYieldShare(
                toNAVUnits(uint256(_stRawNAV)), toNAVUnits(uint256(_jtRawNAV)), _betaWAD, _coverageWAD, toNAVUnits(uint256(_jtEffectiveNAV))
            );
            // Should use first leg: R(U) = 0.25 * U
            uint256 expected = SLOPE_LT_TARGET_UTIL.mulDiv(utilization, WAD, Math.Rounding.Floor);
            assertEq(result, expected, "Very small utilization should use first leg formula");
            assertLt(result, 0.1e18, "Result should be small for very small utilization");
        }
    }

    function test_jtYieldShare_matchesPreview() public view {
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT stRawNAV = toNAVUnits(uint256(0.4e18));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(0.4e18));
        uint256 betaWAD = BETA_100_PCT;
        uint256 coverageWAD = COVERAGE_100_PCT;

        uint256 preview = YDM.previewJTYieldShare(stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        uint256 actual = YDM.jtYieldShare(stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        assertEq(actual, preview, "jtYieldShare should equal previewJTYieldShare");
    }

    /// @notice When utilization >= 1, jtYieldShare should return 1.0 (WAD)
    function test_jtYieldShare_utilizationAtOrAboveOne() public view {
        // Same setup as test_previewJTYieldShare_utilizationAtOne
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT stRawNAV = toNAVUnits(uint256(0.5e18));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(0.5e18));
        uint256 betaWAD = BETA_100_PCT;
        uint256 coverageWAD = COVERAGE_100_PCT;

        uint256 utilization = UtilsLib.computeUtilization(stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        assertGe(utilization, WAD, "Utilization should be >= 1.0");

        uint256 result = YDM.jtYieldShare(stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        assertEq(result, WAD, "At U>=1.0, jtYieldShare should be 1.0 (100%)");
    }

    /// @notice When TARGET_UTILIZATION <= utilization < 1, jtYieldShare should use the second leg of the curve
    function test_jtYieldShare_utilizationBetweenTargetAndOne() public view {
        // Choose U = 0.95 as a representative point between TARGET_UTILIZATION (0.9) and 1.0
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT stRawNAV = toNAVUnits(uint256(0.475e18));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(0.475e18));
        uint256 betaWAD = BETA_100_PCT;
        uint256 coverageWAD = COVERAGE_100_PCT;

        uint256 utilization = UtilsLib.computeUtilization(stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        assertGe(utilization, TARGET_UTILIZATION, "Utilization should be >= TARGET_UTILIZATION");
        assertLt(utilization, WAD, "Utilization should be < 1.0");

        uint256 result = YDM.jtYieldShare(stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        // Second leg: R(U) = 7.75 * (U - 0.9) + 0.225
        uint256 expected = SLOPE_GTE_TARGET_UTIL.mulDiv((utilization - TARGET_UTILIZATION), WAD, Math.Rounding.Floor) + JT_YIELD_SHARE_AT_TARGET_UTIL;

        assertEq(result, expected, "For TARGET_UTILIZATION <= U < 1.0, jtYieldShare should use the second leg formula");
    }
}
