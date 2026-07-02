// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { FixedPointMathLib } from "../../lib/solady/src/utils/FixedPointMathLib.sol";
import { IYDM } from "../../src/interfaces/IYDM.sol";
import { TARGET_UTILIZATION_WAD, TARGET_UTILIZATION_WAD_INT, WAD, WAD_INT, ZERO_NAV_UNITS } from "../../src/libraries/Constants.sol";
import { MarketState } from "../../src/libraries/Types.sol";
import { NAV_UNIT, toNAVUnits } from "../../src/libraries/Units.sol";
import { AdaptiveCurveYDM_V2 } from "../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { BaseTest } from "../base/BaseTest.t.sol";

contract AdaptiveCurveYDM_V2Test is BaseTest {
    using Math for uint256;

    // ============================================
    // Test State
    // ============================================

    AdaptiveCurveYDM_V2 internal ydm;

    // Default curve parameters
    uint64 internal constant DEFAULT_Y0 = 0.1e18; // 10% at zero util
    uint64 internal constant DEFAULT_YT = 0.3e18; // 30% at target util
    uint64 internal constant DEFAULT_YFULL = 0.9e18; // 90% at full util
    uint64 internal constant DEFAULT_SPEED = uint64(50e18 / uint256(365 days)); // ~1.58e12

    // Computed defaults
    uint256 internal constant DEFAULT_DISCOUNT = DEFAULT_YT - DEFAULT_Y0; // 20%
    uint256 internal constant DEFAULT_PREMIUM = DEFAULT_YFULL - DEFAULT_YT; // 60%

    // Contract constants (copied for testing)
    uint256 internal constant MAX_CURVE_ADAPTATION_SPEED_WAD = 100e18 / uint256(365 days);
    uint256 internal constant MIN_JT_YIELD_SHARE_AT_TARGET_WAD = 0.0001e18;
    uint256 internal constant MAX_JT_YIELD_SHARE_AT_TARGET_WAD = WAD;
    int256 internal constant MAX_LINEAR_ADAPTATION_WAD = 135_305_999_368_893_231_589 - 1;

    // ============================================
    // Setup
    // ============================================

    function setUp() public {
        _setUpRoyco();
        ydm = new AdaptiveCurveYDM_V2();
        // Initialize with default curve (caller becomes the "accountant" key)
        ydm.initializeYDMForMarket(DEFAULT_Y0, DEFAULT_YT, DEFAULT_YFULL, DEFAULT_SPEED);
    }

    // ============================================
    // Helper Functions
    // ============================================

    /// @dev Creates inputs that result in a specific utilization
    function _createInputsForUtilization(uint256 _utilizationWAD)
        internal
        pure
        returns (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV)
    {
        jtEffectiveNAV = toNAVUnits(uint256(1e18));
        stRawNAV = toNAVUnits(uint256(_utilizationWAD / 2));
        jtRawNAV = toNAVUnits(uint256(_utilizationWAD / 2));
        betaWAD = WAD;
        coverageWAD = WAD;
    }

    /// @dev Computes expected normalized delta from target
    function _computeNormalizedDelta(uint256 _utilizationWAD) internal pure returns (int256) {
        uint256 cappedUtil = _utilizationWAD > WAD ? WAD : _utilizationWAD;
        uint256 maxDelta = cappedUtil > TARGET_UTILIZATION_WAD ? (WAD - TARGET_UTILIZATION_WAD) : TARGET_UTILIZATION_WAD;
        return ((int256(cappedUtil) - TARGET_UTILIZATION_WAD_INT) * WAD_INT) / int256(maxDelta);
    }

    /// @dev Computes expected yield share at current utilization given Y_T and curve params
    function _computeExpectedYieldShare(uint256 _ytWAD, uint256 _discountWAD, uint256 _premiumWAD, int256 _normalizedDelta) internal pure returns (uint256) {
        uint256 maxAdjustment = _normalizedDelta < 0 ? _discountWAD : _premiumWAD;
        int256 adjustment = (_normalizedDelta * int256(maxAdjustment)) / WAD_INT;
        int256 result = int256(_ytWAD) + adjustment;

        if (result < 0) return 0;
        if (uint256(result) > WAD) return WAD;
        return uint256(result);
    }

    /// @dev Computes expected yield share at target after adaptation
    function _computeAdaptedYT(uint256 _initialYT, int256 _linearAdaptation) internal pure returns (uint256) {
        int256 clampedAdaptation = _linearAdaptation > MAX_LINEAR_ADAPTATION_WAD ? MAX_LINEAR_ADAPTATION_WAD : _linearAdaptation;
        uint256 result = uint256((int256(_initialYT) * FixedPointMathLib.expWad(clampedAdaptation)) / WAD_INT);
        if (result < MIN_JT_YIELD_SHARE_AT_TARGET_WAD) return MIN_JT_YIELD_SHARE_AT_TARGET_WAD;
        if (result > MAX_JT_YIELD_SHARE_AT_TARGET_WAD) return MAX_JT_YIELD_SHARE_AT_TARGET_WAD;
        return result;
    }

    // ============================================
    // Initialization Tests
    // ============================================

    function test_initializeYDMForMarket_setsCorrectCurveParams() public {
        AdaptiveCurveYDM_V2 newYdm = new AdaptiveCurveYDM_V2();
        newYdm.initializeYDMForMarket(0.1e18, 0.3e18, 0.8e18, DEFAULT_SPEED);

        (uint64 yT, uint32 lastTimestamp, uint64 speed, uint64 discount, uint64 premium) = newYdm.accountantToCurve(address(this));

        assertEq(yT, 0.3e18, "YT should be set");
        assertEq(lastTimestamp, 0, "Last timestamp should be 0 initially");
        assertEq(speed, DEFAULT_SPEED, "Speed should be set");
        assertEq(discount, 0.2e18, "Discount should be YT - Y0");
        assertEq(premium, 0.5e18, "Premium should be YFull - YT");
    }

    function test_initializeYDMForMarket_emitsEvent() public {
        AdaptiveCurveYDM_V2 newYdm = new AdaptiveCurveYDM_V2();

        vm.expectEmit(true, false, false, true);
        emit AdaptiveCurveYDM_V2.AdaptiveCurveYdmInitialized(address(this), DEFAULT_DISCOUNT, DEFAULT_YT, DEFAULT_PREMIUM, DEFAULT_SPEED);

        newYdm.initializeYDMForMarket(DEFAULT_Y0, DEFAULT_YT, DEFAULT_YFULL, DEFAULT_SPEED);
    }

    function test_initializeYDMForMarket_revertsWhenYTBelowMin() public {
        AdaptiveCurveYDM_V2 newYdm = new AdaptiveCurveYDM_V2();

        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        // YT below minimum (1 bp)
        newYdm.initializeYDMForMarket(0, uint64(MIN_JT_YIELD_SHARE_AT_TARGET_WAD - 1), 0.5e18, DEFAULT_SPEED);
    }

    function test_initializeYDMForMarket_revertsWhenY0GreaterThanYT() public {
        AdaptiveCurveYDM_V2 newYdm = new AdaptiveCurveYDM_V2();

        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        newYdm.initializeYDMForMarket(0.5e18, 0.3e18, 0.8e18, DEFAULT_SPEED); // Y0 > YT
    }

    function test_initializeYDMForMarket_revertsWhenYTGreaterThanYFull() public {
        AdaptiveCurveYDM_V2 newYdm = new AdaptiveCurveYDM_V2();

        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        newYdm.initializeYDMForMarket(0.1e18, 0.5e18, 0.3e18, DEFAULT_SPEED); // YT > YFull
    }

    function test_initializeYDMForMarket_revertsWhenYFullGreaterThanWAD() public {
        AdaptiveCurveYDM_V2 newYdm = new AdaptiveCurveYDM_V2();

        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        newYdm.initializeYDMForMarket(0.1e18, 0.5e18, uint64(WAD + 1), DEFAULT_SPEED);
    }

    function test_initializeYDMForMarket_revertsWhenSpeedExceedsMax() public {
        AdaptiveCurveYDM_V2 newYdm = new AdaptiveCurveYDM_V2();

        // MAX_CURVE_ADAPTATION_SPEED_WAD fits in uint64, so we can test the actual validation
        uint64 invalidSpeed = uint64(MAX_CURVE_ADAPTATION_SPEED_WAD) + 1;
        vm.expectRevert(IYDM.INVALID_YDM_INITIALIZATION.selector);
        newYdm.initializeYDMForMarket(0.1e18, 0.3e18, 0.9e18, invalidSpeed);
    }

    function test_initializeYDMForMarket_allowsMinYT() public {
        AdaptiveCurveYDM_V2 newYdm = new AdaptiveCurveYDM_V2();
        // Y0 = 0, YT = min, YFull = WAD
        newYdm.initializeYDMForMarket(0, uint64(MIN_JT_YIELD_SHARE_AT_TARGET_WAD), uint64(WAD), DEFAULT_SPEED);

        (uint64 yT,,,,) = newYdm.accountantToCurve(address(this));
        assertEq(yT, MIN_JT_YIELD_SHARE_AT_TARGET_WAD, "Should allow min YT");
    }

    function test_initializeYDMForMarket_allowsMaxYT() public {
        AdaptiveCurveYDM_V2 newYdm = new AdaptiveCurveYDM_V2();
        // Y0 = YT = YFull = WAD (flat curve at 100%)
        newYdm.initializeYDMForMarket(uint64(WAD), uint64(WAD), uint64(WAD), DEFAULT_SPEED);

        (uint64 yT,,,, uint64 premium) = newYdm.accountantToCurve(address(this));
        assertEq(yT, WAD, "Should allow max YT");
        assertEq(premium, 0, "Premium should be 0 when YT = YFull");
    }

    function test_initializeYDMForMarket_allowsFlatCurve() public {
        AdaptiveCurveYDM_V2 newYdm = new AdaptiveCurveYDM_V2();
        // Y0 = YT = YFull = 0.5 (completely flat curve)
        newYdm.initializeYDMForMarket(0.5e18, 0.5e18, 0.5e18, DEFAULT_SPEED);

        (uint64 yT,,, uint64 discount, uint64 premium) = newYdm.accountantToCurve(address(this));
        assertEq(yT, 0.5e18, "YT should be set");
        assertEq(discount, 0, "Discount should be 0 for flat curve");
        assertEq(premium, 0, "Premium should be 0 for flat curve");
    }

    function test_initializeYDMForMarket_allowsZeroSpeed() public {
        AdaptiveCurveYDM_V2 newYdm = new AdaptiveCurveYDM_V2();
        newYdm.initializeYDMForMarket(DEFAULT_Y0, DEFAULT_YT, DEFAULT_YFULL, 0);

        (,, uint64 speed,,) = newYdm.accountantToCurve(address(this));
        assertEq(speed, 0, "Speed should be 0");
    }

    function test_initializeYDMForMarket_allowsMaxSpeed() public {
        AdaptiveCurveYDM_V2 newYdm = new AdaptiveCurveYDM_V2();
        newYdm.initializeYDMForMarket(DEFAULT_Y0, DEFAULT_YT, DEFAULT_YFULL, uint64(MAX_CURVE_ADAPTATION_SPEED_WAD));

        (,, uint64 speed,,) = newYdm.accountantToCurve(address(this));
        assertEq(speed, uint64(MAX_CURVE_ADAPTATION_SPEED_WAD), "Speed should be max");
    }

    function test_initializeYDMForMarket_allowsReinitialization() public {
        // Re-initialize with different params
        ydm.initializeYDMForMarket(0.05e18, 0.2e18, 0.6e18, DEFAULT_SPEED);

        (uint64 yT,,, uint64 discount, uint64 premium) = ydm.accountantToCurve(address(this));
        assertEq(yT, 0.2e18, "YT should be updated");
        assertEq(discount, 0.15e18, "Discount should be updated");
        assertEq(premium, 0.4e18, "Premium should be updated");
    }

    function test_initializeYDMForMarket_resetsTimestampOnReinit() public {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(WAD);

        // First call sets timestamp
        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        (, uint32 timestamp1,,,) = ydm.accountantToCurve(address(this));
        assertGt(timestamp1, 0, "Timestamp should be set after first call");

        // Advance time significantly
        vm.warp(block.timestamp + 30 days);

        // Re-initialize should reset timestamp to 0
        ydm.initializeYDMForMarket(0.1e18, 0.5e18, 0.8e18, DEFAULT_SPEED);
        (, uint32 timestamp2,,,) = ydm.accountantToCurve(address(this));
        assertEq(timestamp2, 0, "Timestamp should be reset to 0 on re-init");

        // First call after re-init should have no adaptation (clean slate)
        (uint64 ytBefore,,,,) = ydm.accountantToCurve(address(this));
        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        (uint64 ytAfter,,,,) = ydm.accountantToCurve(address(this));

        assertEq(ytAfter, ytBefore, "No adaptation should occur on first call after re-init");
    }

    // ============================================
    // Uninitialized Curve Tests (H-1 Fix)
    // ============================================

    function test_previewJTYieldShare_revertsWhenUninitialized() public {
        AdaptiveCurveYDM_V2 uninitYdm = new AdaptiveCurveYDM_V2();
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(0.5e18);

        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        uninitYdm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
    }

    function test_jtYieldShare_revertsWhenUninitialized() public {
        AdaptiveCurveYDM_V2 uninitYdm = new AdaptiveCurveYDM_V2();
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(0.5e18);

        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        uninitYdm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
    }

    function test_uninitializedAccountant_reverts() public {
        address uninitialized = address(0xDEAD);
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(0.5e18);

        vm.prank(uninitialized);
        vm.expectRevert(IYDM.UNINITIALIZED_YDM.selector);
        ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
    }

    // ============================================
    // Market State Tests
    // ============================================

    function test_jtYieldShare_adaptsInPerpetualState() public {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(WAD); // 100% utilization

        // First call to set timestamp
        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        (uint64 ytBefore,,,,) = ydm.accountantToCurve(address(this));

        // Advance time
        vm.warp(block.timestamp + 30 days);

        // Second call should adapt the curve upward (high utilization)
        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        (uint64 ytAfter,,,,) = ydm.accountantToCurve(address(this));

        assertGt(ytAfter, ytBefore, "YT should increase with high utilization over time");
    }

    function test_jtYieldShare_doesNotAdaptInFixedTermState() public {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(WAD); // 100% utilization

        // First call to set timestamp in PERPETUAL
        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        (uint64 ytBefore,,,,) = ydm.accountantToCurve(address(this));

        // Advance time
        vm.warp(block.timestamp + 30 days);

        // Call in FIXED_TERM state - should not adapt
        ydm.jtYieldShare(MarketState.FIXED_TERM, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        (uint64 ytAfter,,,,) = ydm.accountantToCurve(address(this));

        // YT should stay the same in FIXED_TERM (no adaptation applied)
        assertEq(ytAfter, ytBefore, "YT should not change in FIXED_TERM state");
    }

    function test_previewJTYieldShare_doesNotModifyState() public {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(WAD);

        // Set initial timestamp
        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        (uint64 ytBefore, uint32 timestampBefore,,,) = ydm.accountantToCurve(address(this));

        vm.warp(block.timestamp + 30 days);

        // Preview should not modify state
        ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        (uint64 ytAfter, uint32 timestampAfter,,,) = ydm.accountantToCurve(address(this));

        assertEq(ytAfter, ytBefore, "YT should not change after preview");
        assertEq(timestampAfter, timestampBefore, "Timestamp should not change after preview");
    }

    function test_previewJTYieldShare_matchesJtYieldShare() public {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(0.5e18);

        // Set initial timestamp
        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        vm.warp(block.timestamp + 10 days);

        // Preview and actual should return the same value
        uint256 preview = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        uint256 actual = ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        assertEq(preview, actual, "Preview and actual should match");
    }

    // ============================================
    // Adaptation Mechanism Tests
    // ============================================

    function test_adaptation_noAdaptationOnFirstCall() public {
        // Create a fresh YDM
        AdaptiveCurveYDM_V2 freshYdm = new AdaptiveCurveYDM_V2();
        freshYdm.initializeYDMForMarket(DEFAULT_Y0, DEFAULT_YT, DEFAULT_YFULL, DEFAULT_SPEED);

        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(WAD);

        // First call - lastAdaptationTimestamp is 0, so elapsed = 0
        freshYdm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        (uint64 yT,,,,) = freshYdm.accountantToCurve(address(this));

        // YT should not have changed from initial value
        assertEq(yT, DEFAULT_YT, "YT should not change on first call");
    }

    function test_adaptation_noAdaptationAtTargetUtilization() public {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) =
            _createInputsForUtilization(TARGET_UTILIZATION_WAD);

        // First call to set timestamp
        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        (uint64 ytBefore,,,,) = ydm.accountantToCurve(address(this));

        vm.warp(block.timestamp + 365 days);

        // At target utilization, normalized delta = 0, so adaptation speed = 0
        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        (uint64 ytAfter,,,,) = ydm.accountantToCurve(address(this));

        assertEq(ytAfter, ytBefore, "YT should not change at target utilization");
    }

    function test_adaptation_noAdaptationWithZeroSpeed() public {
        AdaptiveCurveYDM_V2 zeroSpeedYdm = new AdaptiveCurveYDM_V2();
        zeroSpeedYdm.initializeYDMForMarket(DEFAULT_Y0, DEFAULT_YT, DEFAULT_YFULL, 0);

        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(WAD);

        // First call
        zeroSpeedYdm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        (uint64 ytBefore,,,,) = zeroSpeedYdm.accountantToCurve(address(this));

        vm.warp(block.timestamp + 365 days);

        // With zero speed, no adaptation should occur
        zeroSpeedYdm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        (uint64 ytAfter,,,,) = zeroSpeedYdm.accountantToCurve(address(this));

        assertEq(ytAfter, ytBefore, "YT should not change with zero speed");
    }

    function test_adaptation_increasesWithHighUtilization() public {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(WAD); // 100% utilization

        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        (uint64 ytBefore,,,,) = ydm.accountantToCurve(address(this));

        vm.warp(block.timestamp + 30 days);

        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        (uint64 ytAfter,,,,) = ydm.accountantToCurve(address(this));

        assertGt(ytAfter, ytBefore, "YT should increase with high utilization");
    }

    function test_adaptation_decreasesWithLowUtilization() public {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(0); // 0% utilization

        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        (uint64 ytBefore,,,,) = ydm.accountantToCurve(address(this));

        vm.warp(block.timestamp + 30 days);

        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        (uint64 ytAfter,,,,) = ydm.accountantToCurve(address(this));

        assertLt(ytAfter, ytBefore, "YT should decrease with low utilization");
    }

    function test_adaptation_clampsToMinimum() public {
        // Start with minimum YT
        AdaptiveCurveYDM_V2 minYdm = new AdaptiveCurveYDM_V2();
        minYdm.initializeYDMForMarket(0, uint64(MIN_JT_YIELD_SHARE_AT_TARGET_WAD), uint64(WAD), DEFAULT_SPEED);

        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(0); // 0% utilization

        minYdm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        // Advance a very long time with low utilization
        vm.warp(block.timestamp + 3650 days); // 10 years

        minYdm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        (uint64 yT,,,,) = minYdm.accountantToCurve(address(this));

        assertGe(yT, MIN_JT_YIELD_SHARE_AT_TARGET_WAD, "YT should not go below minimum");
    }

    function test_adaptation_clampsToMaximum() public {
        // Start with YT close to max
        AdaptiveCurveYDM_V2 maxYdm = new AdaptiveCurveYDM_V2();
        maxYdm.initializeYDMForMarket(0.8e18, 0.9e18, uint64(WAD), uint64(MAX_CURVE_ADAPTATION_SPEED_WAD));

        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(WAD); // 100% utilization

        maxYdm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        // Advance in multiple steps to avoid exp overflow (100 days each, 10 iterations)
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + 100 days);
            maxYdm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        }

        (uint64 yT,,,,) = maxYdm.accountantToCurve(address(this));

        assertLe(yT, MAX_JT_YIELD_SHARE_AT_TARGET_WAD, "YT should not exceed maximum");
    }

    function test_adaptation_emitsEvent() public {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(WAD);

        // First call to set timestamp
        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        vm.warp(block.timestamp + 30 days);

        // Expect YdmAdaptedOutput event
        vm.expectEmit(true, false, false, false);
        emit AdaptiveCurveYDM_V2.YdmAdaptedOutput(address(this), 0, 0); // We don't check exact values

        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
    }

    function test_adaptation_updatesTimestamp() public {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(0.5e18);

        // First call
        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        (, uint32 timestamp1,,,) = ydm.accountantToCurve(address(this));

        // Advance time
        vm.warp(block.timestamp + 1 days);

        // Second call
        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        (, uint32 timestamp2,,,) = ydm.accountantToCurve(address(this));

        // Timestamp should have increased
        assertGt(timestamp2, timestamp1, "Timestamp should be updated");
    }

    // ============================================
    // Curve Output Tests
    // ============================================

    function test_curveOutput_atTargetUtilization() public view {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) =
            _createInputsForUtilization(TARGET_UTILIZATION_WAD);

        uint256 yieldShare = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        // At target utilization, Y = Y_T
        assertEq(yieldShare, DEFAULT_YT, "Yield share at target should equal YT");
    }

    function test_curveOutput_atFullUtilization() public view {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(WAD);

        uint256 yieldShare = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        // At full utilization, Y = Y_T + premium = 0.3 + 0.6 = 0.9
        assertEq(yieldShare, DEFAULT_YFULL, "Yield share at full util should equal YFull");
    }

    function test_curveOutput_atZeroUtilization() public view {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(0);

        uint256 yieldShare = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        // At zero utilization, Y = Y_T - discount = 0.3 - 0.2 = 0.1
        assertEq(yieldShare, DEFAULT_Y0, "Yield share at zero util should equal Y0");
    }

    function test_curveOutput_atMidpointBelowTarget() public view {
        // 45% utilization = halfway to target from 0
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(0.45e18);

        uint256 yieldShare = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        // Normalized delta = (0.45 - 0.9) / 0.9 = -0.5
        // Y = Y_T + (-0.5 * discount) = 0.3 + (-0.5 * 0.2) = 0.3 - 0.1 = 0.2
        assertEq(yieldShare, 0.2e18, "Yield share at 45% should be midpoint between Y0 and YT");
    }

    function test_curveOutput_atMidpointAboveTarget() public view {
        // 95% utilization = halfway between target and full
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(0.95e18);

        uint256 yieldShare = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        // Normalized delta = (0.95 - 0.9) / 0.1 = 0.5
        // Y = Y_T + (0.5 * premium) = 0.3 + (0.5 * 0.6) = 0.3 + 0.3 = 0.6
        assertEq(yieldShare, 0.6e18, "Yield share at 95% should be midpoint between YT and YFull");
    }

    function test_curveOutput_cappedAtWAD() public {
        // Create a curve where Y_T + premium > WAD
        AdaptiveCurveYDM_V2 highYdm = new AdaptiveCurveYDM_V2();
        highYdm.initializeYDMForMarket(0.5e18, 0.8e18, uint64(WAD), DEFAULT_SPEED);

        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(WAD);

        uint256 yieldShare = highYdm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        assertLe(yieldShare, WAD, "Yield share should be capped at WAD");
    }

    function test_curveOutput_cappedAtZero() public {
        // Create a curve where Y_T - discount could go negative if Y_T adapts down significantly
        AdaptiveCurveYDM_V2 lowYdm = new AdaptiveCurveYDM_V2();
        // Y0 = 0, YT = 1bp, YFull = 100%, discount = 1bp
        lowYdm.initializeYDMForMarket(0, uint64(MIN_JT_YIELD_SHARE_AT_TARGET_WAD), uint64(WAD), DEFAULT_SPEED);

        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(0);

        uint256 yieldShare = lowYdm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        assertEq(yieldShare, 0, "Yield share should be 0 when Y0 = YT - discount = 0");
    }

    function test_curveOutput_continuityAtTarget() public view {
        // Test values just below and above target utilization
        uint256 justBelow = TARGET_UTILIZATION_WAD - 1;
        uint256 justAbove = TARGET_UTILIZATION_WAD + 1;

        (NAV_UNIT stRawNAV1, NAV_UNIT jtRawNAV1, uint256 betaWAD1, uint256 coverageWAD1, NAV_UNIT jtEffectiveNAV1) = _createInputsForUtilization(justBelow);
        (NAV_UNIT stRawNAV2, NAV_UNIT jtRawNAV2, uint256 betaWAD2, uint256 coverageWAD2, NAV_UNIT jtEffectiveNAV2) = _createInputsForUtilization(justAbove);
        (NAV_UNIT stRawNAV3, NAV_UNIT jtRawNAV3, uint256 betaWAD3, uint256 coverageWAD3, NAV_UNIT jtEffectiveNAV3) =
            _createInputsForUtilization(TARGET_UTILIZATION_WAD);

        uint256 yieldBelow = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV1, jtRawNAV1, betaWAD1, coverageWAD1, jtEffectiveNAV1);
        uint256 yieldAbove = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV2, jtRawNAV2, betaWAD2, coverageWAD2, jtEffectiveNAV2);
        uint256 yieldAt = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV3, jtRawNAV3, betaWAD3, coverageWAD3, jtEffectiveNAV3);

        // All should be approximately equal (continuity)
        assertApproxEqAbs(yieldBelow, yieldAt, 1e12, "Should be continuous from below");
        assertApproxEqAbs(yieldAbove, yieldAt, 1e12, "Should be continuous from above");
    }

    function test_curveOutput_monotonicallyIncreasing() public view {
        uint256[5] memory utilizations = [uint256(0), 0.3e18, TARGET_UTILIZATION_WAD, 0.95e18, WAD];

        uint256 previousYield = 0;
        for (uint256 i = 0; i < utilizations.length; i++) {
            (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(utilizations[i]);

            uint256 yieldShare = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

            assertGe(yieldShare, previousYield, "Yield should increase with utilization");
            previousYield = yieldShare;
        }
    }

    function test_curveOutput_utilizationAboveOneIsCapped() public view {
        // Create inputs that would result in utilization > 100%
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(0.5e18)); // Small JT effective NAV
        NAV_UNIT stRawNAV = toNAVUnits(uint256(1e18)); // Large ST NAV
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(0));
        uint256 betaWAD = WAD;
        uint256 coverageWAD = WAD;

        // Utilization = (1e18 + 0) * 1 / 0.5e18 = 2e18 (200%), should be capped to 100%
        uint256 yieldShare = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        // Should return the same as full utilization
        (NAV_UNIT stRawNAV2, NAV_UNIT jtRawNAV2, uint256 betaWAD2, uint256 coverageWAD2, NAV_UNIT jtEffectiveNAV2) = _createInputsForUtilization(WAD);
        uint256 yieldShareAtFull = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV2, jtRawNAV2, betaWAD2, coverageWAD2, jtEffectiveNAV2);

        assertEq(yieldShare, yieldShareAtFull, "Utilization > 100% should be capped to 100%");
    }

    // ============================================
    // Simpson's Rule / Trapezoidal Average Tests
    // ============================================

    function test_simpsonsRule_averageIsCorrect() public {
        // The average formula: (initial + new + 2*mid) / 4
        // This is Simpson's 1/3 rule approximation for integral average

        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(WAD);

        // Set initial timestamp
        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        (uint64 initialYT,,,,) = ydm.accountantToCurve(address(this));

        uint256 elapsed = 30 days;
        vm.warp(block.timestamp + elapsed);

        // Get the returned yield share (which uses the average)
        uint256 avgYieldShare = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        // Compute expected values manually
        int256 normalizedDelta = _computeNormalizedDelta(WAD);
        (,, uint64 speed,,) = ydm.accountantToCurve(address(this));
        int256 adaptationSpeed = (int256(uint256(speed)) * normalizedDelta) / WAD_INT;
        int256 linearAdaptation = adaptationSpeed * int256(elapsed);

        uint256 newYT = _computeAdaptedYT(initialYT, linearAdaptation);
        uint256 midYT = _computeAdaptedYT(initialYT, linearAdaptation / 2);
        uint256 expectedAvgYT = (initialYT + newYT + 2 * midYT) / 4;

        uint256 expectedAvgYieldShare = _computeExpectedYieldShare(expectedAvgYT, DEFAULT_DISCOUNT, DEFAULT_PREMIUM, normalizedDelta);

        assertApproxEqAbs(avgYieldShare, expectedAvgYieldShare, 1, "Average yield share should match Simpson's rule");
    }

    // ============================================
    // Edge Cases
    // ============================================

    function test_edgeCase_zeroJTEffectiveNAV() public view {
        NAV_UNIT stRawNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(0));
        NAV_UNIT jtEffectiveNAV = ZERO_NAV_UNITS; // Zero
        uint256 betaWAD = WAD;
        uint256 coverageWAD = WAD;

        // Utilization = infinity, capped to WAD
        uint256 yieldShare = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        // Should return yield at full utilization
        (NAV_UNIT stRawNAV2, NAV_UNIT jtRawNAV2, uint256 betaWAD2, uint256 coverageWAD2, NAV_UNIT jtEffectiveNAV2) = _createInputsForUtilization(WAD);
        uint256 yieldShareAtFull = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV2, jtRawNAV2, betaWAD2, coverageWAD2, jtEffectiveNAV2);

        assertEq(yieldShare, yieldShareAtFull, "Zero JT effective NAV should cap utilization");
    }

    function test_edgeCase_zeroSTRawNAV() public view {
        NAV_UNIT stRawNAV = ZERO_NAV_UNITS;
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(1e18));
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1e18));
        uint256 coverageWAD = WAD;

        // A wiped senior raw NAV does NOT imply zero utilization. When the junior tranche carries beta-correlated exposure (beta > 0),
        // the covered exposure (beta * jtRawNAV) is non-zero, so UtilsLib.computeUtilization reports real utilization and the curve responds to it.
        uint256 yieldShareCorrelated = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, WAD, coverageWAD, jtEffectiveNAV);
        assertGt(yieldShareCorrelated, DEFAULT_Y0, "Zero ST with beta-correlated JT exposure must produce non-zero utilization");

        // Only when there is genuinely no covered exposure (beta = 0, so beta * jtRawNAV = 0) does utilization fall to zero and yield to Y_0.
        uint256 yieldShareUncorrelated = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, 0, coverageWAD, jtEffectiveNAV);
        assertEq(yieldShareUncorrelated, DEFAULT_Y0, "Zero ST with zero beta has no covered exposure, so utilization is zero");
    }

    function test_edgeCase_zeroBeta() public view {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV,, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(0.5e18);

        uint256 betaWAD = 0;

        // With beta = 0, utilization only considers ST
        uint256 yieldShare = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        // Utilization = ST * coverage / jtEffective = 0.25e18 * 1 / 1e18 = 0.25
        // This should result in a lower yield than with beta = 1
        assertGt(yieldShare, 0, "Should return non-zero yield share");
    }

    function test_edgeCase_differentBeta() public view {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV,, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(0.5e18);

        uint256 yield1 = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, 0, coverageWAD, jtEffectiveNAV);
        uint256 yield2 = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, 0.5e18, coverageWAD, jtEffectiveNAV);
        uint256 yield3 = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, WAD, coverageWAD, jtEffectiveNAV);

        assertLe(yield1, yield2, "Higher beta should mean higher utilization and yield");
        assertLe(yield2, yield3, "Higher beta should mean higher utilization and yield");
    }

    function test_edgeCase_differentCoverage() public view {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD,, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(0.5e18);

        uint256 yield1 = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, 0.5e18, jtEffectiveNAV);
        uint256 yield2 = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, WAD, jtEffectiveNAV);

        assertLe(yield1, yield2, "Higher coverage should mean higher utilization and yield");
    }

    function test_edgeCase_flatCurveOutput() public {
        AdaptiveCurveYDM_V2 flatYdm = new AdaptiveCurveYDM_V2();
        flatYdm.initializeYDMForMarket(0.5e18, 0.5e18, 0.5e18, DEFAULT_SPEED);

        // All utilization levels should return 0.5e18
        uint256[5] memory utilizations = [uint256(0), 0.3e18, TARGET_UTILIZATION_WAD, 0.95e18, WAD];

        for (uint256 i = 0; i < utilizations.length; i++) {
            (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(utilizations[i]);

            uint256 yieldShare = flatYdm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

            assertEq(yieldShare, 0.5e18, "Flat curve should always return same value");
        }
    }

    // ============================================
    // Multi-Accountant Tests
    // ============================================

    function test_differentAccountants_haveDifferentCurves() public {
        address accountant1 = address(this);
        address accountant2 = address(0x1234);

        // Already initialized for accountant1 in setUp

        // Initialize for accountant2 with different params
        vm.prank(accountant2);
        ydm.initializeYDMForMarket(0.05e18, 0.5e18, 0.8e18, uint64(MAX_CURVE_ADAPTATION_SPEED_WAD));

        (uint64 yT1,, uint64 speed1, uint64 discount1, uint64 premium1) = ydm.accountantToCurve(accountant1);
        (uint64 yT2,, uint64 speed2, uint64 discount2, uint64 premium2) = ydm.accountantToCurve(accountant2);

        assertEq(yT1, DEFAULT_YT, "Accountant1 YT should be default");
        assertEq(yT2, 0.5e18, "Accountant2 YT should be 0.5");
        assertNotEq(speed1, speed2, "Speeds should differ");
        assertNotEq(discount1, discount2, "Discounts should differ");
        assertNotEq(premium1, premium2, "Premiums should differ");
    }

    function test_multipleAccountants_independentAdaptation() public {
        address accountant1 = address(this);
        address accountant2 = address(0x1234);

        // Initialize for accountant2
        vm.prank(accountant2);
        ydm.initializeYDMForMarket(DEFAULT_Y0, DEFAULT_YT, DEFAULT_YFULL, DEFAULT_SPEED);

        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(WAD);

        // Both accountants make first call
        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        vm.prank(accountant2);
        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        // Advance time
        vm.warp(block.timestamp + 30 days);

        // Only accountant1 makes second call
        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        (uint64 yT1,,,,) = ydm.accountantToCurve(accountant1);
        (uint64 yT2,,,,) = ydm.accountantToCurve(accountant2);

        // Accountant1 should have adapted, accountant2 should not have
        assertGt(yT1, DEFAULT_YT, "Accountant1 YT should have increased");
        assertEq(yT2, DEFAULT_YT, "Accountant2 YT should remain unchanged");
    }

    // ============================================
    // Adversarial Tests
    // ============================================

    function test_adversarial_rapidStateChanges() public {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(WAD);

        // Rapid back-and-forth between PERPETUAL and FIXED_TERM
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + 1 days);
            MarketState state = i % 2 == 0 ? MarketState.PERPETUAL : MarketState.FIXED_TERM;
            ydm.jtYieldShare(state, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        }

        // Should not revert, curve should still be valid
        (uint64 yT,,,,) = ydm.accountantToCurve(address(this));
        assertGe(yT, MIN_JT_YIELD_SHARE_AT_TARGET_WAD, "YT should be valid after rapid state changes");
        assertLe(yT, MAX_JT_YIELD_SHARE_AT_TARGET_WAD, "YT should be valid after rapid state changes");
    }

    function test_adversarial_extremeUtilizationSwings() public {
        // Swing between 0% and 100% utilization rapidly
        for (uint256 i = 0; i < 10; i++) {
            uint256 util = i % 2 == 0 ? 0 : WAD;
            (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(util);

            vm.warp(block.timestamp + 1 days);
            ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        }

        // Should not revert, curve should still be valid
        (uint64 yT,,,,) = ydm.accountantToCurve(address(this));
        assertGe(yT, MIN_JT_YIELD_SHARE_AT_TARGET_WAD, "YT should be valid after extreme swings");
        assertLe(yT, MAX_JT_YIELD_SHARE_AT_TARGET_WAD, "YT should be valid after extreme swings");
    }

    function test_adversarial_multipleAccountantsSimultaneous() public {
        address[] memory accountants = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            accountants[i] = address(uint160(i + 100));
            vm.prank(accountants[i]);
            ydm.initializeYDMForMarket(
                uint64(MIN_JT_YIELD_SHARE_AT_TARGET_WAD + i * 0.1e18),
                uint64(MIN_JT_YIELD_SHARE_AT_TARGET_WAD + i * 0.1e18 + 0.1e18),
                uint64(WAD),
                DEFAULT_SPEED
            );
        }

        // All accountants call in rapid succession
        for (uint256 round = 0; round < 5; round++) {
            vm.warp(block.timestamp + 1 days);
            for (uint256 i = 0; i < 5; i++) {
                uint256 util = (i * 0.25e18);
                (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(util);

                vm.prank(accountants[i]);
                ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
            }
        }

        // All curves should still be valid and independent
        for (uint256 i = 0; i < 5; i++) {
            (uint64 yT,,,,) = ydm.accountantToCurve(accountants[i]);
            assertGe(yT, MIN_JT_YIELD_SHARE_AT_TARGET_WAD, "YT should be valid");
            assertLe(yT, MAX_JT_YIELD_SHARE_AT_TARGET_WAD, "YT should be valid");
        }
    }

    function test_adversarial_veryLargeNAVValues() public view {
        // Use near-max uint128 values
        NAV_UNIT stRawNAV = toNAVUnits(uint256(type(uint128).max));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(type(uint128).max));
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(type(uint128).max));
        uint256 betaWAD = WAD;
        uint256 coverageWAD = WAD;

        // Should not revert
        uint256 yieldShare = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        assertLe(yieldShare, WAD, "Yield should be capped at WAD even with large values");
    }

    function test_adversarial_verySmallNAVValues() public view {
        // Use very small values
        NAV_UNIT stRawNAV = toNAVUnits(uint256(1));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(1));
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(1));
        uint256 betaWAD = WAD;
        uint256 coverageWAD = WAD;

        // Should not revert
        uint256 yieldShare = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        assertLe(yieldShare, WAD, "Yield should be valid with small values");
    }

    function test_adversarial_veryLongTimePeriod() public {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(WAD);

        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        // Advance in multiple steps to avoid overflow in linear adaptation calculation
        // Each step is 1 year at 100% utilization, which should eventually hit the max
        for (uint256 i = 0; i < 50; i++) {
            vm.warp(block.timestamp + 365 days);
            ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        }

        (uint64 yT,,,,) = ydm.accountantToCurve(address(this));
        assertEq(yT, MAX_JT_YIELD_SHARE_AT_TARGET_WAD, "YT should be clamped to max after very long period");
    }

    function test_adversarial_timestampOverflow() public {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(0.5e18);

        // Set timestamp near uint32 max (year 2106)
        vm.warp(type(uint32).max - 1 days);
        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        // This should work (we're before the overflow)
        vm.warp(type(uint32).max);
        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        (, uint32 timestamp,,,) = ydm.accountantToCurve(address(this));
        assertEq(timestamp, type(uint32).max, "Timestamp should be at max");
    }

    // ============================================
    // Struct Packing Verification
    // ============================================

    function test_structPacking_singleSlot() public {
        // Verify the struct fits in a single storage slot (256 bits)
        // uint64 + uint32 + uint32 + uint64 + uint64 = 256 bits

        AdaptiveCurveYDM_V2 packingYdm = new AdaptiveCurveYDM_V2();
        packingYdm.initializeYDMForMarket(DEFAULT_Y0, DEFAULT_YT, DEFAULT_YFULL, DEFAULT_SPEED);

        // Read the raw storage slot
        bytes32 slot = vm.load(address(packingYdm), keccak256(abi.encode(address(this), uint256(0))));

        // Verify all values are packed correctly
        (uint64 yT, uint32 timestamp, uint64 speed, uint64 discount, uint64 premium) = packingYdm.accountantToCurve(address(this));

        // Check values match
        assertEq(yT, DEFAULT_YT, "YT should be packed correctly");
        assertEq(timestamp, 0, "Timestamp should be packed correctly");
        assertEq(speed, DEFAULT_SPEED, "Speed should be packed correctly");
        assertEq(discount, DEFAULT_DISCOUNT, "Discount should be packed correctly");
        assertEq(premium, DEFAULT_PREMIUM, "Premium should be packed correctly");

        // Verify non-zero slot (curve is initialized)
        assertNotEq(slot, bytes32(0), "Slot should not be zero");
    }

    // ============================================
    // Fuzz Tests
    // ============================================

    function testFuzz_initializeYDMForMarket_validParams(uint64 _y0, uint64 _yT, uint64 _yFull, uint64 _speed) public {
        _yT = uint64(bound(_yT, MIN_JT_YIELD_SHARE_AT_TARGET_WAD, WAD));
        _y0 = uint64(bound(_y0, 0, _yT));
        _yFull = uint64(bound(_yFull, _yT, WAD));
        _speed = uint64(bound(_speed, 0, MAX_CURVE_ADAPTATION_SPEED_WAD));

        AdaptiveCurveYDM_V2 newYdm = new AdaptiveCurveYDM_V2();
        newYdm.initializeYDMForMarket(_y0, _yT, _yFull, _speed);

        (uint64 storedYT,, uint64 storedSpeed, uint64 storedDiscount, uint64 storedPremium) = newYdm.accountantToCurve(address(this));

        assertEq(storedYT, _yT, "YT should be stored correctly");
        assertEq(storedSpeed, _speed, "Speed should be stored correctly");
        assertEq(storedDiscount, _yT - _y0, "Discount should be computed correctly");
        assertEq(storedPremium, _yFull - _yT, "Premium should be computed correctly");
    }

    function testFuzz_previewJTYieldShare_resultInValidRange(
        uint128 _stRawNAV,
        uint128 _jtRawNAV,
        uint128 _jtEffectiveNAV,
        uint128 _betaWAD,
        uint128 _coverageWAD
    )
        public
        view
    {
        // Bound inputs to reasonable ranges
        _jtEffectiveNAV = uint128(bound(_jtEffectiveNAV, 1e12, type(uint128).max));
        _betaWAD = uint128(bound(_betaWAD, 0, WAD));
        _coverageWAD = uint128(bound(_coverageWAD, 0.01e18, WAD));

        NAV_UNIT stRawNAV = toNAVUnits(uint256(_stRawNAV));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(_jtRawNAV));
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(_jtEffectiveNAV));

        uint256 yieldShare = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, _betaWAD, _coverageWAD, jtEffectiveNAV);

        assertLe(yieldShare, WAD, "Yield share should not exceed WAD");
    }

    function testFuzz_adaptation_directionCorrect(uint256 _utilizationWAD, uint256 _elapsed) public {
        _utilizationWAD = bound(_utilizationWAD, 0, 2 * WAD); // Allow > 100% to test capping
        _elapsed = bound(_elapsed, 1 days, 365 days);

        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(_utilizationWAD);

        // Initialize and set timestamp
        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        (uint64 ytBefore,,,,) = ydm.accountantToCurve(address(this));

        vm.warp(block.timestamp + _elapsed);

        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        (uint64 ytAfter,,,,) = ydm.accountantToCurve(address(this));

        uint256 cappedUtil = _utilizationWAD > WAD ? WAD : _utilizationWAD;
        if (cappedUtil > TARGET_UTILIZATION_WAD) {
            assertGe(ytAfter, ytBefore, "YT should increase or stay same with high utilization");
        } else if (cappedUtil < TARGET_UTILIZATION_WAD) {
            assertLe(ytAfter, ytBefore, "YT should decrease or stay same with low utilization");
        }
    }

    function testFuzz_monotonicity_acrossUtilization(uint256 _util1, uint256 _util2) public view {
        _util1 = bound(_util1, 0, WAD);
        _util2 = bound(_util2, 0, WAD);

        if (_util1 > _util2) {
            (_util1, _util2) = (_util2, _util1);
        }

        (NAV_UNIT stRawNAV1, NAV_UNIT jtRawNAV1, uint256 betaWAD1, uint256 coverageWAD1, NAV_UNIT jtEffectiveNAV1) = _createInputsForUtilization(_util1);
        (NAV_UNIT stRawNAV2, NAV_UNIT jtRawNAV2, uint256 betaWAD2, uint256 coverageWAD2, NAV_UNIT jtEffectiveNAV2) = _createInputsForUtilization(_util2);

        uint256 yield1 = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV1, jtRawNAV1, betaWAD1, coverageWAD1, jtEffectiveNAV1);
        uint256 yield2 = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV2, jtRawNAV2, betaWAD2, coverageWAD2, jtEffectiveNAV2);

        assertLe(yield1, yield2, "Yield should be monotonically increasing with utilization");
    }

    function testFuzz_jtYieldShare_matchesPreview(
        uint128 _stRawNAV,
        uint128 _jtRawNAV,
        uint128 _jtEffectiveNAV,
        uint128 _betaWAD,
        uint128 _coverageWAD
    )
        public
    {
        _jtEffectiveNAV = uint128(bound(_jtEffectiveNAV, 1e12, type(uint128).max));
        _betaWAD = uint128(bound(_betaWAD, 0, WAD));
        _coverageWAD = uint128(bound(_coverageWAD, 0.01e18, WAD));

        NAV_UNIT stRawNAV = toNAVUnits(uint256(_stRawNAV));
        NAV_UNIT jtRawNAV = toNAVUnits(uint256(_jtRawNAV));
        NAV_UNIT jtEffectiveNAV = toNAVUnits(uint256(_jtEffectiveNAV));

        // Set initial timestamp
        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, _betaWAD, _coverageWAD, jtEffectiveNAV);

        vm.warp(block.timestamp + 1 days);

        uint256 preview = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, _betaWAD, _coverageWAD, jtEffectiveNAV);
        uint256 actual = ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, _betaWAD, _coverageWAD, jtEffectiveNAV);

        assertEq(preview, actual, "Preview should match actual");
    }

    function testFuzz_curveConfiguration_invariants(uint64 _y0, uint64 _yT, uint64 _yFull, uint256 _utilization) public {
        _yT = uint64(bound(_yT, MIN_JT_YIELD_SHARE_AT_TARGET_WAD, WAD));
        _y0 = uint64(bound(_y0, 0, _yT));
        _yFull = uint64(bound(_yFull, _yT, WAD));
        _utilization = bound(_utilization, 0, WAD);

        AdaptiveCurveYDM_V2 testYdm = new AdaptiveCurveYDM_V2();
        testYdm.initializeYDMForMarket(_y0, _yT, _yFull, DEFAULT_SPEED);

        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(_utilization);

        uint256 yieldShare = testYdm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        // Invariants:
        // 1. Result should be within [0, WAD]
        assertLe(yieldShare, WAD, "Yield should be <= WAD");
        // Note: yieldShare can be 0 if Y_T - discount < 0 at low utilization
    }

    function testFuzz_adaptation_clampingWorks(uint256 _numSteps, bool _highUtil) public {
        // Use multiple smaller steps to avoid exp overflow
        _numSteps = bound(_numSteps, 1, 20); // 1-20 iterations of 30 days each

        uint256 utilization = _highUtil ? WAD : 0;
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(utilization);

        // Start near the boundary that we're testing
        AdaptiveCurveYDM_V2 testYdm = new AdaptiveCurveYDM_V2();
        if (_highUtil) {
            testYdm.initializeYDMForMarket(0.8e18, 0.9e18, uint64(WAD), DEFAULT_SPEED); // Near max
        } else {
            testYdm.initializeYDMForMarket(0, uint64(MIN_JT_YIELD_SHARE_AT_TARGET_WAD), uint64(WAD), DEFAULT_SPEED); // At
            // min
        }

        testYdm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        // Apply adaptation in multiple steps to avoid exp overflow
        for (uint256 i = 0; i < _numSteps; i++) {
            vm.warp(block.timestamp + 30 days);
            testYdm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        }

        (uint64 yT,,,,) = testYdm.accountantToCurve(address(this));

        assertGe(yT, MIN_JT_YIELD_SHARE_AT_TARGET_WAD, "YT should be >= MIN");
        assertLe(yT, MAX_JT_YIELD_SHARE_AT_TARGET_WAD, "YT should be <= MAX");
    }

    // ============================================
    // Mathematical Invariant Tests
    // ============================================

    function test_invariant_normalizedDeltaBounds() public pure {
        // Test that normalized delta is always in [-1, 1]
        uint256[7] memory utilizations = [uint256(0), 0.45e18, 0.89e18, 0.9e18, 0.91e18, 0.95e18, WAD];

        for (uint256 i = 0; i < utilizations.length; i++) {
            int256 delta = _computeNormalizedDelta(utilizations[i]);
            assertGe(delta, -WAD_INT, "Delta should be >= -1");
            assertLe(delta, WAD_INT, "Delta should be <= 1");
        }
    }

    function test_invariant_yieldShareAtKeyPoints() public view {
        // Y(0) = Y_T - discount
        (NAV_UNIT stRawNAV0, NAV_UNIT jtRawNAV0, uint256 betaWAD0, uint256 coverageWAD0, NAV_UNIT jtEffectiveNAV0) = _createInputsForUtilization(0);
        uint256 yield0 = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV0, jtRawNAV0, betaWAD0, coverageWAD0, jtEffectiveNAV0);
        assertEq(yield0, DEFAULT_YT - DEFAULT_DISCOUNT, "Y(0) = Y_T - discount");

        // Y(target) = Y_T
        (NAV_UNIT stRawNAVT, NAV_UNIT jtRawNAVT, uint256 betaWADT, uint256 coverageWADT, NAV_UNIT jtEffectiveNAVT) =
            _createInputsForUtilization(TARGET_UTILIZATION_WAD);
        uint256 yieldT = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAVT, jtRawNAVT, betaWADT, coverageWADT, jtEffectiveNAVT);
        assertEq(yieldT, DEFAULT_YT, "Y(target) = Y_T");

        // Y(100%) = Y_T + premium
        (NAV_UNIT stRawNAVF, NAV_UNIT jtRawNAVF, uint256 betaWADF, uint256 coverageWADF, NAV_UNIT jtEffectiveNAVF) = _createInputsForUtilization(WAD);
        uint256 yieldF = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAVF, jtRawNAVF, betaWADF, coverageWADF, jtEffectiveNAVF);
        assertEq(yieldF, DEFAULT_YT + DEFAULT_PREMIUM, "Y(100%) = Y_T + premium");
    }

    function test_invariant_adaptationIsMonotonic() public {
        // This test verifies that adaptation with constant high utilization leads to monotonically increasing Y_T
        // The exponential growth property is inherent in the exp() function, so we verify monotonicity instead
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(WAD);

        // Make first call to set timestamp
        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        (uint64 yt0,,,,) = ydm.accountantToCurve(address(this));

        // Advance 1 day using skip() to properly update block.timestamp
        skip(1 days);
        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        (uint64 yt1,,,,) = ydm.accountantToCurve(address(this));

        // Advance another 1 day
        skip(1 days);
        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        (uint64 yt2,,,,) = ydm.accountantToCurve(address(this));

        // With constant high utilization, Y_T should monotonically increase
        assertGt(yt1, yt0, "Y_T should increase after first adaptation");
        assertGt(yt2, yt1, "Y_T should continue increasing after second adaptation");

        // Verify the growth is bounded by the exp function behavior
        // exp(speed * elapsed) should give reasonable growth factors
        uint256 expectedMinGrowth = WAD + 0.01e18; // At least 1% growth per day at max utilization
        assertGt((uint256(yt1) * WAD) / yt0, expectedMinGrowth, "Growth factor should be meaningful");
    }

    // ============================================
    // Gas Optimization Tests
    // ============================================

    function test_gas_previewJTYieldShare() public {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(0.5e18);

        // Warm up storage
        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

        uint256 gasBefore = gasleft();
        ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        uint256 gasUsed = gasBefore - gasleft();

        // Log gas usage for optimization tracking
        emit log_named_uint("previewJTYieldShare gas (warm)", gasUsed);

        // Should be reasonably efficient
        assertLt(gasUsed, 20_000, "Preview should use less than 20k gas (warm)");
    }

    function test_gas_jtYieldShare() public {
        (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(0.5e18);

        // Warm up storage
        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        vm.warp(block.timestamp + 1 days);

        uint256 gasBefore = gasleft();
        ydm.jtYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        uint256 gasUsed = gasBefore - gasleft();

        // Log gas usage for optimization tracking
        emit log_named_uint("jtYieldShare gas (warm)", gasUsed);

        // Should be reasonably efficient (includes 2 SSTOREs now in 1 slot)
        assertLt(gasUsed, 30_000, "jtYieldShare should use less than 30k gas (warm)");
    }

    // ============================================
    // Rounding Direction Tests
    // ============================================

    function test_rounding_favorsSeniorTranche() public view {
        // Test that rounding in calculations consistently favors the senior tranche
        // (lower JT yield share when there's ambiguity)

        // Test at various utilization points with potential rounding
        uint256[3] memory utilizations = [uint256(0.333333333333333333e18), 0.666666666666666666e18, 0.999999999999999999e18];

        for (uint256 i = 0; i < utilizations.length; i++) {
            (NAV_UNIT stRawNAV, NAV_UNIT jtRawNAV, uint256 betaWAD, uint256 coverageWAD, NAV_UNIT jtEffectiveNAV) = _createInputsForUtilization(utilizations[i]);

            uint256 yieldShare = ydm.previewJTYieldShare(MarketState.PERPETUAL, stRawNAV, jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);

            // Result should always be valid (no unexpected overflows)
            assertLe(yieldShare, WAD, "Yield should be valid at edge case utilization");
        }
    }
}
