// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IYDM } from "../interfaces/IYDM.sol";
import { TARGET_UTILIZATION_WAD, WAD } from "../libraries/Constants.sol";
import { NAV_UNIT } from "../libraries/Units.sol";
import { UtilsLib } from "../libraries/UtilsLib.sol";

/**
 * @title StaticCurveYDM
 * @notice Royco's static curve yield distribution model (YDM)
 * @dev Responsible for computing the yield distribution between the senior and junior tranches of a Royco market
 * @dev The curve is defined as piece-wise function parameterized by the utilization of a Royco market
 */
contract StaticCurveYDM is IYDM {
    using Math for uint256;

    /**
     * @notice Represents the state of a market's YDM
     * @custom:field slopeGteTargetWAD - The slope when the market's utilization is greater than or equal to the target utilization, scaled to WAD precision
     * @custom:field slopeLtTargetWAD - The slope when the market's utilization is less than the target utilization, scaled to WAD precision
     * @custom:field jtYieldShareAtTargetWAD - The JT yield share at target utilization, scaled to WAD precision
     */
    struct StaticYieldCurve {
        uint96 slopeGteTargetWAD;
        uint96 slopeLtTargetWAD;
        uint64 jtYieldShareAtTargetWAD;
    }

    /// @dev A mapping from market accountants to its market's current YDM curve
    /// @dev The curve is static
    mapping(address accountant => StaticYieldCurve curve) public accountantToCurve;

    /**
     * @notice Emitted when the static curve YDM is initialized for a market
     * @param accountant The accountant for the market that the YDM was initialized for
     * @param slopeGteTargetWAD The slope when the market's utilization is greater than or equal to the target utilization, scaled to WAD precision
     * @param slopeLtTargetWAD The slope when the market's utilization is less than the target utilization, scaled to WAD precision
     * @param jtYieldShareAtTargetWAD The JT yield share at target utilization, scaled to WAD precision
     */
    event StaticCurveYdmInitialized(address indexed accountant, uint256 slopeGteTargetWAD, uint256 slopeLtTargetWAD, uint256 jtYieldShareAtTargetWAD);

    /// @inheritdoc IYDM
    function initializeYDMForMarket(uint256 _jtYieldShareAtTargetUtilWAD, uint256 _jtYieldShareAtFullUtilWAD) external override(IYDM) {
        // Ensure that the static YDM curve is valid
        require(_jtYieldShareAtTargetUtilWAD <= _jtYieldShareAtFullUtilWAD && _jtYieldShareAtFullUtilWAD <= WAD, INVALID_YDM_INITIALIZATION());

        // Initialize the YDM curve for this market
        StaticYieldCurve storage curve = accountantToCurve[msg.sender];
        curve.slopeGteTargetWAD =
            uint96(((_jtYieldShareAtFullUtilWAD - _jtYieldShareAtTargetUtilWAD).mulDiv(WAD, (WAD - TARGET_UTILIZATION_WAD), Math.Rounding.Floor)));
        curve.slopeLtTargetWAD = uint96((_jtYieldShareAtTargetUtilWAD.mulDiv(WAD, TARGET_UTILIZATION_WAD, Math.Rounding.Floor)));
        curve.jtYieldShareAtTargetWAD = uint64(_jtYieldShareAtTargetUtilWAD);

        emit StaticCurveYdmInitialized(msg.sender, curve.slopeGteTargetWAD, curve.slopeLtTargetWAD, curve.jtYieldShareAtTargetWAD);
    }

    /// @inheritdoc IYDM
    function previewJTYieldShare(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        uint256 _betaWAD,
        uint256 _coverageWAD,
        NAV_UNIT _jtEffectiveNAV
    )
        external
        view
        override(IYDM)
        returns (uint256)
    {
        return _jtYieldShare(_stRawNAV, _jtRawNAV, _betaWAD, _coverageWAD, _jtEffectiveNAV);
    }

    /// @inheritdoc IYDM
    function jtYieldShare(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        uint256 _betaWAD,
        uint256 _coverageWAD,
        NAV_UNIT _jtEffectiveNAV
    )
        external
        view
        override(IYDM)
        returns (uint256)
    {
        return _jtYieldShare(_stRawNAV, _jtRawNAV, _betaWAD, _coverageWAD, _jtEffectiveNAV);
    }

    /// @dev View helper to compute the instantaneous JT yield share based on the defined static curve
    function _jtYieldShare(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        uint256 _betaWAD,
        uint256 _coverageWAD,
        NAV_UNIT _jtEffectiveNAV
    )
        internal
        view
        returns (uint256)
    {
        /**
         * Yield Distribution Model (piecewise curve):
         *
         *   Y(U) = S_lt * U                      if U < 0.9  (below target)
         *        = S_gte * (U - 0.9) + Y_T       if U >= 0.9 (at or above target)
         *
         * Y(U)  → Percentage of ST yield paid to the junior tranche
         * U     → Utilization = ((ST_RAW_NAV + (JT_RAW_NAV * BETA_%)) * COV_%) / JT_EFFECTIVE_NAV
         * S_lt  → Slope below target utilization (derived from Y_T / 0.9)
         * S_gte → Slope at or above target utilization (derived from (Y_full - Y_T) / 0.1)
         * Y_T   → JT yield share at target utilization (90%)
         *
         * Below 90% utilization, JT yield allocation rises based on S_lt.
         * At or above 90% utilization, JT yield allocation rises more steeply based on S_gte,
         * penalizing high utilization and incentivizing JT deposits or ST withdrawals.
         * Output is capped at 100% when utilization reaches or exceeds 100%.
         */
        // Compute the utilization of the market
        uint256 utilizationWAD = UtilsLib.computeUtilization(_stRawNAV, _jtRawNAV, _betaWAD, _coverageWAD, _jtEffectiveNAV);
        utilizationWAD = utilizationWAD > WAD ? WAD : utilizationWAD;

        // Retrieve the static curve for this market
        StaticYieldCurve storage curve = accountantToCurve[msg.sender];
        // Compute Y(U), rounding in favor the senior tranche
        if (utilizationWAD >= TARGET_UTILIZATION_WAD) {
            // If utilization is at or above the target (kink), apply the second leg of Y(U)
            return uint256(curve.slopeGteTargetWAD).mulDiv((utilizationWAD - TARGET_UTILIZATION_WAD), WAD, Math.Rounding.Floor) + curve.jtYieldShareAtTargetWAD;
        } else {
            // If utilization is below the target (kink), apply the first leg of Y(U)
            return uint256(curve.slopeLtTargetWAD).mulDiv(utilizationWAD, WAD, Math.Rounding.Floor);
        }
    }
}
