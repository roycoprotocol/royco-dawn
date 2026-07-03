// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { WAD, ZERO_NAV_UNITS } from "./Constants.sol";
import { AssetClaims } from "./Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, UnitsMathLib } from "./Units.sol";

/**
 * @title UtilsLib
 * @author Waymont
 * @notice A library providing utility functions for the Royco protocol
 */
library UtilsLib {
    using UnitsMathLib for NAV_UNIT;
    using UnitsMathLib for TRANCHE_UNIT;
    using UnitsMathLib for uint256;

    /**
     * @notice Computes the utilization of the Royco market given the market's state
     * @dev Informally: (total coverage required for exposure) / (loss absorption buffer)
     * @dev Formally: Utilization = ((ST_RAW_NAV + (JT_RAW_NAV * β)) * COV) / JT_EFFECTIVE_NAV
     * @dev Rounding favors ensuring senior tranche protection
     * @param _stRawNAV The raw net asset value of the senior tranche invested assets
     * @param _jtRawNAV The raw net asset value of the junior tranche invested assets
     * @param _betaWAD The JT's sensitivity to the same downside stress that affects ST, scaled to WAD precision
     *                 For example, beta is 0 when JT is in the RFR and 1 when JT is in the same opportunity as senior
     * @param _coverageWAD The ratio of current total exposure that is expected to be protected by the market's junior capital, scaled to WAD precision
     * @param _jtEffectiveNAV The junior tranche net asset value after absorbing JT losses, providing coverage to ST, and accruing JT yield and ST yield share (risk premium)
     * @return utilization The utilization of the Royco market, scaled to WAD precision
     */
    function computeUtilization(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        uint256 _betaWAD,
        uint256 _coverageWAD,
        NAV_UNIT _jtEffectiveNAV
    )
        internal
        pure
        returns (uint256 utilization)
    {
        // Compute the total exposure that the junior tranche is obligated to protect against a coverage sized drawdown
        NAV_UNIT totalCoveredExposure = _stRawNAV + _jtRawNAV.mulDiv(_betaWAD, WAD, Math.Rounding.Ceil);
        // If there is no covered exposure, there is nothing the junior buffer needs to protect, so utilization is 0
        if (totalCoveredExposure == ZERO_NAV_UNITS) return 0;
        // If there is no remaining JT loss-absorption buffer but covered exposure exists, utilization is effectively infinite
        if (_jtEffectiveNAV == ZERO_NAV_UNITS) return type(uint256).max;
        // Return the computed utilization
        utilization = _coverageWAD.mulDiv(totalCoveredExposure, _jtEffectiveNAV, Math.Rounding.Ceil);
    }

    /**
     * @notice Scales the claims on ST and JT assets of a tranche by a given shares assuming total shares in a vault
     * @param _claims The claims on ST and JT assets of the tranche
     * @param _shares The number of shares to scale the claims by
     * @param _totalTrancheShares The total number of shares that exist in the tranche
     * @return scaledClaims The scaled claims on ST and JT assets of the tranche
     */
    function scaleAssetClaims(AssetClaims memory _claims, uint256 _shares, uint256 _totalTrancheShares)
        internal
        pure
        returns (AssetClaims memory scaledClaims)
    {
        scaledClaims.nav = _claims.nav.mulDiv(_shares, _totalTrancheShares, Math.Rounding.Floor);
        scaledClaims.stAssets = _claims.stAssets.mulDiv(_shares, _totalTrancheShares, Math.Rounding.Floor);
        scaledClaims.jtAssets = _claims.jtAssets.mulDiv(_shares, _totalTrancheShares, Math.Rounding.Floor);
    }

    /**
     * @notice Scales the claims on ST and JT assets of a tranche by a given NAV ratio
     * @param _claims The claims on ST and JT assets of the tranche
     * @param _navNumerator The NAV to use for the numerator
     * @param _navDenominator The NAV to use for the denominator
     * @return scaledClaims The scaled claims on ST and JT assets of the tranche
     */
    function scaleAssetClaims(
        AssetClaims memory _claims,
        NAV_UNIT _navNumerator,
        NAV_UNIT _navDenominator
    )
        internal
        pure
        returns (AssetClaims memory scaledClaims)
    {
        scaledClaims.nav = _claims.nav.mulDiv(_navNumerator, _navDenominator, Math.Rounding.Floor);
        scaledClaims.stAssets = _claims.stAssets.mulDiv(_navNumerator, _navDenominator, Math.Rounding.Floor);
        scaledClaims.jtAssets = _claims.jtAssets.mulDiv(_navNumerator, _navDenominator, Math.Rounding.Floor);
    }
}
