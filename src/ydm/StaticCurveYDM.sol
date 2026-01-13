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
     * @custom:field jtYieldShareAtZeroUtilWAD - The JT yield share at zero utilization, scaled to WAD precision
     * @custom:field slopeLtTargetUtilWAD - The slope when the market's utilization is less than the target utilization, scaled to WAD precision
     * @custom:field jtYieldShareAtTargetUtilWAD - The JT yield share at target utilization, scaled to WAD precision
     * @custom:field slopeGteTargetUtilWAD - The slope when the market's utilization is greater than or equal to the target utilization, scaled to WAD precision
     */
    struct StaticYieldCurve {
        uint128 slopeLtTargetUtilWAD;
        uint128 jtYieldShareAtZeroUtilWAD;
        uint128 jtYieldShareAtTargetUtilWAD;
        uint128 slopeGteTargetUtilWAD;
    }

    /// @dev A mapping from market accountants to its market's current YDM curve
    /// @dev The curve is static
    mapping(address accountant => StaticYieldCurve curve) public accountantToCurve;

    /**
     * @notice Emitted when the static curve YDM is initialized for a market
     * @param accountant The accountant for the market that the YDM was initialized for
     * @param jtYieldShareAtZeroUtilWAD The JT yield share at zero utilization, scaled to WAD precision
     * @param slopeLtTargetUtilWAD The slope when the market's utilization is less than the target utilization, scaled to WAD precision
     * @param slopeGteTargetUtilWAD The slope when the market's utilization is greater than or equal to the target utilization, scaled to WAD precision
     */
    event StaticCurveYdmInitialized(address indexed accountant, uint256 jtYieldShareAtZeroUtilWAD, uint256 slopeLtTargetUtilWAD, uint256 slopeGteTargetUtilWAD);

    /**
     * @notice Initializes the YDM curve for a particular Royco market
     * @dev Must be called during the initialization of the accountant for the Royco market
     * @param _jtYieldShareAtZeroUtilWAD The JT yield share at 0% utilization, scaled to WAD precision
     * @param _jtYieldShareAtTargetUtilWAD The JT yield share at target utilization, scaled to WAD precision
     * @param _jtYieldShareAtFullUtilWAD The JT yield share at 100% utilization, scaled to WAD precision
     */
    function initializeYDMForMarket(uint256 _jtYieldShareAtZeroUtilWAD, uint256 _jtYieldShareAtTargetUtilWAD, uint256 _jtYieldShareAtFullUtilWAD) external {
        // Ensure that the static YDM curve is valid
        require(
            _jtYieldShareAtZeroUtilWAD <= _jtYieldShareAtTargetUtilWAD && _jtYieldShareAtTargetUtilWAD <= _jtYieldShareAtFullUtilWAD
                && _jtYieldShareAtFullUtilWAD <= WAD,
            INVALID_YDM_INITIALIZATION()
        );

        // Initialize the YDM curve for this market
        StaticYieldCurve storage curve = accountantToCurve[msg.sender];
        curve.jtYieldShareAtZeroUtilWAD = uint128(_jtYieldShareAtZeroUtilWAD);
        curve.slopeLtTargetUtilWAD =
            uint128(((_jtYieldShareAtTargetUtilWAD - _jtYieldShareAtZeroUtilWAD).mulDiv(WAD, TARGET_UTILIZATION_WAD, Math.Rounding.Floor)));
        curve.jtYieldShareAtTargetUtilWAD = uint128(_jtYieldShareAtTargetUtilWAD);
        curve.slopeGteTargetUtilWAD =
            uint128(((_jtYieldShareAtFullUtilWAD - _jtYieldShareAtTargetUtilWAD).mulDiv(WAD, (WAD - TARGET_UTILIZATION_WAD), Math.Rounding.Floor)));

        emit StaticCurveYdmInitialized(msg.sender, _jtYieldShareAtZeroUtilWAD, curve.slopeLtTargetUtilWAD, curve.slopeGteTargetUtilWAD);
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
         *   Y(U) = Y_0 + S_lt * U                if U < 0.9  (below target)
         *        = Y_T + S_gte * (U - 0.9)       if U >= 0.9 (at or above target)
         *
         * Y(U)  → Percentage of ST yield paid to the junior tranche
         * U     → Utilization = ((ST_RAW_NAV + (JT_RAW_NAV * BETA_%)) * COV_%) / JT_EFFECTIVE_NAV
         * Y_0   → JT yield share at zero utilization
         * Y_T   → JT yield share at target (90%) utilization
         * S_lt  → Slope below target utilization: (Y_T - Y_0) / 0.9
         * S_gte → Slope at or above target utilization: (Y_full - Y_T) / 0.1
         *
         * Below 90% utilization, JT yield allocation rises from Y_0 based on S_lt.
         * At or above 90% utilization, JT yield allocation rises from Y_T based on S_gte,
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
            return uint256(curve.slopeGteTargetUtilWAD).mulDiv((utilizationWAD - TARGET_UTILIZATION_WAD), WAD, Math.Rounding.Floor)
                + curve.jtYieldShareAtTargetUtilWAD;
        } else {
            // If utilization is below the target (kink), apply the first leg of Y(U)
            return uint256(curve.slopeLtTargetUtilWAD).mulDiv(utilizationWAD, WAD, Math.Rounding.Floor) + curve.jtYieldShareAtZeroUtilWAD;
        }
    }
}
