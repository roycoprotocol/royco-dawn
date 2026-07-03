// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { FixedPointMathLib } from "../../lib/solady/src/utils/FixedPointMathLib.sol";
import { IYDM, MarketState } from "../interfaces/IYDM.sol";
import { TARGET_UTILIZATION_WAD, TARGET_UTILIZATION_WAD_INT, WAD, WAD_INT } from "../libraries/Constants.sol";
import { NAV_UNIT } from "../libraries/Units.sol";
import { UtilsLib } from "../libraries/UtilsLib.sol";

/**
 * @title AdaptiveCurveYDM_V1
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Royco's adaptive curve yield distribution model (YDM) V1
 * @dev Responsible for computing the yield distribution between the senior and junior tranches of a Royco market
 * @dev The curve is defined as an adaptive piece-wise function parameterized by the utilization of a Royco market, steepness of the curve, and yield share at the kink (Y_T)
 * @dev The curve adapts its yield share at the kink up or down based on the market's relative delta from kink utilization over time
 * @dev The slopes above/below the kink also adapt up or down based on the adaptation of the yield share at the kink
 * @dev Inspired by Morpho's AdaptiveCurveIrm: https://github.com/morpho-org/morpho-blue-irm
 */
contract AdaptiveCurveYDM_V1 is IYDM {
    /**
     * @notice The maximum speed at which the curve adapts per second scaled to WAD precision
     * @dev This represents how quickly the curve shifts up or down at the edges, 100% and 0% utilization respectively
     * @dev The actual speed that the curve shifts at is based on the current relative distance from the target utilization
     */
    int256 public constant MAX_ADAPTATION_SPEED_WAD = 50e18 / int256(365 days);

    /// @dev The minimum JT yield share at target utilization
    /// @dev Set to 1 basis point
    uint256 public constant MIN_JT_YIELD_SHARE_AT_TARGET_WAD = 0.0001e18;

    /// @dev The maximum JT yield share at target utilization
    uint256 public constant MAX_JT_YIELD_SHARE_AT_TARGET_WAD = WAD;

    /// @dev The maximum linear adaptation that can be applied to the curve.
    /// @dev This value is chosen to prevent overflows when computing expWAD
    int256 private constant MAX_LINEAR_ADAPTATION_WAD = 135_305_999_368_893_231_589 - 1;

    /**
     * @notice Represents the state of a market's YDM
     * @custom:field jtYieldShareAtTargetWAD - The current JT yield share at target utilization, scaled to WAD precision
     * @custom:field lastAdaptationTimestamp - The last time adaptations were applied to this market's curve
     * @custom:field steepnessAfterTargetWAD - The steepness of the curve for this market post-kink: ratio of yield share at 100% utilization to yield share at target
     */
    struct AdaptiveYieldCurve {
        uint64 jtYieldShareAtTargetWAD;
        uint32 lastAdaptationTimestamp;
        uint160 steepnessAfterTargetWAD;
    }

    /// @dev A mapping from market accountants to its market's current YDM curve
    /// @dev The curve is adapted by market forces over time
    mapping(address accountant => AdaptiveYieldCurve curve) public accountantToCurve;

    /**
     * @notice Emitted when the adaptive curve YDM is initialized for a market
     * @param accountant The accountant for the market that the YDM was initialized for
     * @param steepnessAfterTargetWAD The steepness of the curve for this market (ratio of yield share at 100% utilization to yield share at target), scaled to WAD precision
     * @param initialJtYieldShareAtTargetWAD The initial JT yield share at target utilization, scaled to WAD precision
     */
    event AdaptiveCurveYdmInitialized(address indexed accountant, uint256 steepnessAfterTargetWAD, uint256 initialJtYieldShareAtTargetWAD);

    /**
     * @notice Emitted when the JT yield share is updated and the curve is adapted (in a PERPETUAL state)
     * @param accountant The accountant for the market that the yield share was updated for
     * @param avgJtYieldShareWAD The average JT yield share during the period since the last adaptation (returned to the accountant)
     * @param newJtYieldShareAtTargetWAD The new JT yield share at the target utilization after applying adaptations
     */
    event YdmAdaptedOutput(address indexed accountant, uint256 avgJtYieldShareWAD, uint256 newJtYieldShareAtTargetWAD);

    /**
     * @notice Initializes the YDM curve for a particular Royco market
     * @dev Must be called during the initialization of the accountant for the Royco market
     * @param _jtYieldShareAtTargetUtilWAD The initial JT yield share at target utilization, scaled to WAD precision
     * @param _jtYieldShareAtFullUtilWAD The initial JT yield share at 100% utilization, scaled to WAD precision
     */
    function initializeYDMForMarket(uint64 _jtYieldShareAtTargetUtilWAD, uint64 _jtYieldShareAtFullUtilWAD) external {
        // Ensure that the initial YDM curve is valid
        require(
            _jtYieldShareAtTargetUtilWAD >= MIN_JT_YIELD_SHARE_AT_TARGET_WAD && _jtYieldShareAtTargetUtilWAD <= MAX_JT_YIELD_SHARE_AT_TARGET_WAD
                && _jtYieldShareAtTargetUtilWAD <= _jtYieldShareAtFullUtilWAD && _jtYieldShareAtFullUtilWAD <= WAD,
            INVALID_YDM_INITIALIZATION()
        );

        // Initialize the YDM curve for this market
        AdaptiveYieldCurve storage curve = accountantToCurve[msg.sender];
        curve.jtYieldShareAtTargetWAD = _jtYieldShareAtTargetUtilWAD;
        curve.steepnessAfterTargetWAD = uint160((_jtYieldShareAtFullUtilWAD * WAD) / _jtYieldShareAtTargetUtilWAD);
        // Ensure that the last adaptation timestamp is zero on initialization: only pertains to reinitialization
        delete accountantToCurve[msg.sender].lastAdaptationTimestamp;

        emit AdaptiveCurveYdmInitialized(msg.sender, curve.steepnessAfterTargetWAD, _jtYieldShareAtTargetUtilWAD);
    }

    /// @inheritdoc IYDM
    function previewJTYieldShare(
        MarketState _marketState,
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        uint256 _betaWAD,
        uint256 _coverageWAD,
        NAV_UNIT _jtEffectiveNAV
    )
        external
        view
        override(IYDM)
        returns (uint256 jtYieldShareWAD)
    {
        // Compute and return the current JT yield share post-adaptation
        (jtYieldShareWAD,) = _jtYieldShare(_marketState, _stRawNAV, _jtRawNAV, _betaWAD, _coverageWAD, _jtEffectiveNAV);
    }

    /// @inheritdoc IYDM
    function jtYieldShare(
        MarketState _marketState,
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        uint256 _betaWAD,
        uint256 _coverageWAD,
        NAV_UNIT _jtEffectiveNAV
    )
        external
        override(IYDM)
        returns (uint256 jtYieldShareWAD)
    {
        // Compute the current JT yield share and the new position of the curve and post-adaptation
        uint256 newJtYieldShareAtTargetWAD;
        (jtYieldShareWAD, newJtYieldShareAtTargetWAD) = _jtYieldShare(_marketState, _stRawNAV, _jtRawNAV, _betaWAD, _coverageWAD, _jtEffectiveNAV);

        // Apply the adaptations to the curve
        AdaptiveYieldCurve storage curve = accountantToCurve[msg.sender];
        curve.jtYieldShareAtTargetWAD = uint64(newJtYieldShareAtTargetWAD);
        curve.lastAdaptationTimestamp = uint32(block.timestamp);

        emit YdmAdaptedOutput(msg.sender, jtYieldShareWAD, uint256(newJtYieldShareAtTargetWAD));
    }

    /**
     * @notice Computes the JT yield share for a market, applying any pending adaptation
     * @dev Uses trapezoidal approximation to compute the average continuously adapting yield share for more accurate time-weighted results
     * @param _marketState The state of this Royco market (perpetual or fixed term)
     * @param _stRawNAV The raw net asset value of the senior tranche invested assets
     * @param _jtRawNAV The raw net asset value of the junior tranche invested assets
     * @param _betaWAD The JT's sensitivity to the same downside stress that affects ST scaled to WAD precision
     *                 For example, beta is 0 when JT is in the RFR and 1 when JT is in the same opportunity as senior
     * @param _coverageWAD The ratio of current exposure that is expected to be covered by the junior capital scaled to WAD precision
     * @param _jtEffectiveNAV JT's net asset value after applying provided coverage, JT yield, ST yield distribution, and JT losses
     *                        Equivalent to its remaining loss-absorption buffer to cover ST's and its own drawdowns
     * @return jtYieldShareWAD The percentage of the ST's yield allocated to its JT, scaled to WAD precision
     *                         It is implied that (WAD - jtYieldShareWAD) will be the percentage allocated to ST, excluding any protocol fees
     * @return newJtYieldShareAtTargetWAD The updated yield share at target utilization after adaptation, scaled to WAD precision
     */
    function _jtYieldShare(
        MarketState _marketState,
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        uint256 _betaWAD,
        uint256 _coverageWAD,
        NAV_UNIT _jtEffectiveNAV
    )
        internal
        view
        returns (uint256 jtYieldShareWAD, uint256 newJtYieldShareAtTargetWAD)
    {
        // Compute the utilization of the market and bound it to 100%
        uint256 utilizationWAD = UtilsLib.computeUtilization(_stRawNAV, _jtRawNAV, _betaWAD, _coverageWAD, _jtEffectiveNAV);
        if (utilizationWAD > WAD) utilizationWAD = WAD;

        // Compute the max delta from the target utilization in the region of the curve that the market is currently in (above or below the kink)
        uint256 maxDeltaFromTargetInRegionWAD = utilizationWAD > TARGET_UTILIZATION_WAD ? (WAD - TARGET_UTILIZATION_WAD) : TARGET_UTILIZATION_WAD;
        // Normalize the actual delta from the target utilization relative to the max delta in the current region
        int256 normalizedDeltaFromTargetWAD = ((int256(utilizationWAD) - TARGET_UTILIZATION_WAD_INT) * WAD_INT) / int256(maxDeltaFromTargetInRegionWAD);

        // Retrieve the current YDM curve for the market
        AdaptiveYieldCurve memory curve = accountantToCurve[msg.sender];
        uint256 initialJtYieldShareAtTargetWAD = curve.jtYieldShareAtTargetWAD;
        require(initialJtYieldShareAtTargetWAD != 0, UNINITIALIZED_YDM());
        // Only adapt the curve if the market is in a perpetual state and market forces are enabled to affect utilization
        uint256 avgJtYieldShareAtTargetWAD;
        if (_marketState == MarketState.PERPETUAL) {
            // Compute the adaptation speed based on the normalized delta: scale the max adaptation speed by the relative delta from the target based on the region
            int256 currentAdaptationSpeedWAD = (MAX_ADAPTATION_SPEED_WAD * normalizedDeltaFromTargetWAD) / WAD_INT;
            // Compute the linear adaptation that will be applied to the curve based on the speed
            uint256 elapsed = curve.lastAdaptationTimestamp == 0 ? 0 : block.timestamp - curve.lastAdaptationTimestamp;
            int256 linearAdaptationWAD = currentAdaptationSpeedWAD * int256(elapsed);

            // Compute the new JT yield share at target utilization
            newJtYieldShareAtTargetWAD = _computeJtYieldShareAtTarget(initialJtYieldShareAtTargetWAD, linearAdaptationWAD);

            // Compute the average JT yield share at target utilization
            uint256 midJtYieldShareAtTargetWAD = _computeJtYieldShareAtTarget(initialJtYieldShareAtTargetWAD, linearAdaptationWAD / 2);
            avgJtYieldShareAtTargetWAD = (initialJtYieldShareAtTargetWAD + newJtYieldShareAtTargetWAD + (2 * midJtYieldShareAtTargetWAD)) / 4;
        } else {
            newJtYieldShareAtTargetWAD = avgJtYieldShareAtTargetWAD = initialJtYieldShareAtTargetWAD;
        }

        // Compute the YDM curve's output with the continuously adapting JT yield share since the last adaptation
        jtYieldShareWAD = _computeCurrentJtYieldShare(curve.steepnessAfterTargetWAD, normalizedDeltaFromTargetWAD, avgJtYieldShareAtTargetWAD);
    }

    /**
     * @notice Computes the JT yield share at target utilization for a market post-adaptation
     * @param _lastJtYieldShareAtTargetWAD The last recorded JT yield share at target utilization
     * @param _linearAdaptationWAD The linear adaptation to apply to the curve based on the normalized delta, time elapsed, and speed of adaptation
     * @return jtYieldShareAtTargetWAD The JT yield share at target utilization after applying the adaptation
     */
    function _computeJtYieldShareAtTarget(
        uint256 _lastJtYieldShareAtTargetWAD,
        int256 _linearAdaptationWAD
    )
        internal
        pure
        returns (uint256 jtYieldShareAtTargetWAD)
    {
        // Compute the new JT yield share at the target by applying the exponentiated linear adaptation to the previous yield share
        // Exponentiation ensures that the JT yield share is always non-negative
        // Clamp the linear adaptation to the maximum value to prevent overflows when applying expWAD
        _linearAdaptationWAD = _linearAdaptationWAD > MAX_LINEAR_ADAPTATION_WAD ? MAX_LINEAR_ADAPTATION_WAD : _linearAdaptationWAD;

        jtYieldShareAtTargetWAD = uint256((int256(_lastJtYieldShareAtTargetWAD) * FixedPointMathLib.expWad(_linearAdaptationWAD)) / WAD_INT);
        // Clamp the JT yield share to the market defined bounds
        if (jtYieldShareAtTargetWAD < MIN_JT_YIELD_SHARE_AT_TARGET_WAD) return MIN_JT_YIELD_SHARE_AT_TARGET_WAD;
        if (jtYieldShareAtTargetWAD > MAX_JT_YIELD_SHARE_AT_TARGET_WAD) return MAX_JT_YIELD_SHARE_AT_TARGET_WAD;
    }

    /**
     * @notice Computes the yield share at current utilization for a market post-adaptation
     * @param _steepnessWAD The steepness of the curve for this market (ratio of yield share at 100% utilization to yield share at target)
     * @param _normalizedDeltaFromTargetWAD The delta of the current utilization relative to target utilization, normalized as a ratio of absolute delta to max delta
     * @param _jtYieldShareAtTargetWAD The JT yield share at target utilization
     * @return jtYieldShareWAD The JT yield share at current utilization
     */
    function _computeCurrentJtYieldShare(
        uint256 _steepnessWAD,
        int256 _normalizedDeltaFromTargetWAD,
        uint256 _jtYieldShareAtTargetWAD
    )
        internal
        pure
        returns (uint256 jtYieldShareWAD)
    {
        /**
         * Adaptive Curve Yield Distribution Model (adaptive piecewise curve):
         *
         *   Y(U) = ((1 - 1/S) * Δ + 1) * Y_T   if U < 0.9   (below target)
         *          ((S - 1) * Δ + 1) * Y_T     if U >= 0.9  (at or above target)
         *
         * Y(U) → Percentage of ST yield paid to the junior tranche
         * U    → Utilization = ((ST_RAW_NAV + (JT_RAW_NAV * β)) * COV) / JT_EFFECTIVE_NAV
         * S    → Steepness of the curve for this market (ratio of yield share at 100% utilization to yield share at target)
         * Δ    → Normalized delta from target utilization: Δ ∈ [-1, 1]
         *        Above target: Δ = (U - 0.9) / 0.1
         *        Below target: Δ = (U - 0.9) / 0.9
         * Y_T  → JT yield share at target utilization (adapts over time based on market forces)
         *
         * Key properties:
         * - At U = 0.9 (target): Y(U) = Y_T
         * - At U = 1.0 (full):   Y(U) = S * Y_T
         * - At U = 0.0 (empty):  Y(U) = Y_T / S
         *
         * Adaptation mechanism:
         * - High utilization → Y_T adapts upward → entire curve scales up → JT receives more yield to attract deposits
         * - Low utilization  → Y_T adapts downward → entire curve scales down → JT receives less yield as capital is abundant
         *
         * Steepness (S) is fixed at initialization and determines the curve's shape (ratio between JT yield share target and full utilization)
         * Y_T is the single adaptive parameter that shifts the curve vertically in response to market forces
         */

        // Compute the coefficient based on the region of the curve that the market is currently in
        int256 coefficient = _normalizedDeltaFromTargetWAD < 0
            ? WAD_INT - ((WAD_INT * WAD_INT) / int256(_steepnessWAD))  // 1 - 1/S if below the kink
            : int256(_steepnessWAD) - WAD_INT; // S - 1 if at or above the kink

        jtYieldShareWAD = uint256((((coefficient * _normalizedDeltaFromTargetWAD / WAD_INT) + WAD_INT) * int256(_jtYieldShareAtTargetWAD)) / WAD_INT);
        if (jtYieldShareWAD > WAD) jtYieldShareWAD = WAD;
    }
}
