// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IYDM } from "../interfaces/IYDM.sol";

import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { WAD } from "../libraries/Constants.sol";
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
     * @dev Constant for the target utilization (kink) of the junior tranche's (90%) loss capital
     * @dev Utilization = ((ST_RAW_NAV + (JT_RAW_NAV * BETA_%)) * COV_%) / JT_EFFECTIVE_NAV
     * @dev If Utilization <= 1, the senior tranche exposure is collateralized as per the market's configured coverage requirement
     *      If Utilization > 1, the senior tranche exposure is undercollateralized as per the market's configured coverage requirement
     */
    uint256 public constant TARGET_UTILIZATION = 0.9e18;

    /// @dev The slope when the market's utilization is less than the target utilization (scaled to WAD precision)
    uint256 public constant SLOPE_LT_TARGET_UTIL = 0.25e18;

    /// @dev The slope when the market's utilization is greater than or equal to the target utilization (scaled to WAD precision)
    uint256 public constant SLOPE_GTE_TARGET_UTIL = 7.75e18;

    /// @dev The base rate paid to the junior tranche when the utilization is exactly at the target (scaled to WAD precision)
    uint256 public constant BASE_RATE_GTE_TARGET_UTIL = 0.225e18;

    /// @inheritdoc IYDM
    function previewJTYieldShare(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        uint256 _betaWAD,
        uint256 _coverageWAD,
        NAV_UNIT _jtEffectiveNAV
    )
        external
        pure
        returns (uint256)
    {
        return _computeJTYieldShare(_stRawNAV, _jtRawNAV, _betaWAD, _coverageWAD, _jtEffectiveNAV);
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
        pure
        returns (uint256)
    {
        return _computeJTYieldShare(_stRawNAV, _jtRawNAV, _betaWAD, _coverageWAD, _jtEffectiveNAV);
    }

    /// @dev Pure helper to compute the instantaneous JT yield share based on the defined static curve
    function _computeJTYieldShare(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        uint256 _betaWAD,
        uint256 _coverageWAD,
        NAV_UNIT _jtEffectiveNAV
    )
        internal
        pure
        returns (uint256)
    {
        /**
         * Yield Distribution Model (piecewise curve):
         *
         *   R(U) = 0.25 * U                   if 0.9 > U >= 0
         *        = 7.75 * (U - 0.9) + 0.225   if 1 > U >= 0.9
         *        = 1                          if U >= 1
         *
         * U    → Utilization = ((ST_RAW_NAV + (JT_RAW_NAV * BETA_%)) * COV_%) / JT_EFFECTIVE_NAV
         * R(U) → Percentage of ST yield paid to the junior tranche
         *
         * Below 90% utilization, JT yield allocation rises slowly (0.25 slope).
         * At and above 90% utilization, JT yield allocation rises sharply (7.75 slope), penalizing high utilization and incentivizing marginal junior deposits or senior withdrawals
         * At and above 100% utilization, JT yield allocation is set to 100% of ST yield, as the market is exactly or undercollateralized
         */
        // Compute the utilization of the market
        uint256 utilization = UtilsLib.computeUtilization(_stRawNAV, _jtRawNAV, _betaWAD, _coverageWAD, _jtEffectiveNAV);

        // Compute R(U), rounding in favor the senior tranche
        if (utilization >= WAD) {
            // If utilization is greater than or equal to 1, apply the third leg of R(U)
            return WAD;
        } else if (utilization >= TARGET_UTILIZATION) {
            // If utilization is at or above the kink (target) but less than 1, apply the second leg of R(U)
            return SLOPE_GTE_TARGET_UTIL.mulDiv((utilization - TARGET_UTILIZATION), WAD, Math.Rounding.Floor) + BASE_RATE_GTE_TARGET_UTIL;
        } else {
            // If utilization is below the kink (target), apply the first leg of R(U)
            return SLOPE_LT_TARGET_UTIL.mulDiv(utilization, WAD, Math.Rounding.Floor);
        }
    }
}
