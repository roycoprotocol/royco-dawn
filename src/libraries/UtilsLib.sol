// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { WAD, ZERO_NAV_UNITS } from "./Constants.sol";
import { TrancheAssetClaims } from "./Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, UnitsMathLib, toUint256 } from "./Units.sol";

library UtilsLib {
    using UnitsMathLib for NAV_UNIT;
    using UnitsMathLib for TRANCHE_UNIT;
    using Math for uint256;

    /// @notice Computes the utilization of the Royco market given the market's state
    /// @dev Informally: total covered exposure / junior loss absorbtion buffer
    /// @dev Formally: Utilization = ((ST_RAW_NAV + (JT_RAW_NAV * BETA_%)) * COV_%) / JT_EFFECTIVE_NAV
    /// @param _stRawNAV The raw net asset value of the senior tranche invested assets
    /// @param _jtRawNAV The raw net asset value of the junior tranche invested assets
    /// @param _betaWAD The JT's sensitivity to the same downside stress that affects ST scaled to WAD precision
    ///                 For example, beta is 0 when JT is in the RFR and 1 when JT is in the same opportunity as senior
    /// @param _coverageWAD The ratio of current total exposure that is expected to be covered by the junior capital scaled to WAD precision
    /// @param _jtEffectiveNAV The junior tranche net asset value after applying provided coverage, JT yield, ST yield distribution, and JT losses
    /// @return utilization The utilization of the Royco market scaled to WAD precision
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
        // If there is no remaining JT loss-absorption buffer, utilization is effectively infinite
        if (_jtEffectiveNAV == ZERO_NAV_UNITS) return type(uint256).max;
        // Round in favor of ensuring senior tranche protection
        utilization = toUint256((_stRawNAV + _jtRawNAV.mulDiv(_betaWAD, WAD, Math.Rounding.Ceil)).mulDiv(_coverageWAD, _jtEffectiveNAV, Math.Rounding.Ceil));
    }

    /// @notice Scales the claims on ST and JT assets of a tranche by a given shares assuming total shares in a vault
    /// @param _claims The claims on ST and JT assets of the tranche
    /// @param _shares The number of shares to scale the claims by
    /// @param _totalTrancheShares The total number of shares that exist in the tranche
    /// @return scaledClaims The scaled claims on ST and JT assets of the tranche
    function scaleTrancheAssetsClaim(
        TrancheAssetClaims memory _claims,
        uint256 _shares,
        uint256 _totalTrancheShares
    )
        internal
        pure
        returns (TrancheAssetClaims memory scaledClaims)
    {
        scaledClaims.effectiveNAV = _claims.effectiveNAV.mulDiv(_shares, _totalTrancheShares, Math.Rounding.Floor);
        scaledClaims.stAssets = _claims.stAssets.mulDiv(_shares, _totalTrancheShares, Math.Rounding.Floor);
        scaledClaims.jtAssets = _claims.jtAssets.mulDiv(_shares, _totalTrancheShares, Math.Rounding.Floor);
    }
}
