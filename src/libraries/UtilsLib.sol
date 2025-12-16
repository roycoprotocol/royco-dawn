// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { ConstantsLib } from "./ConstantsLib.sol";

library UtilsLib {
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
        uint256 _stRawNAV,
        uint256 _jtRawNAV,
        uint256 _betaWAD,
        uint256 _coverageWAD,
        uint256 _jtEffectiveNAV
    )
        internal
        pure
        returns (uint256 utilization)
    {
        // If there is no remaining JT loss-absorption buffer, utilization is effectively infinite
        if (_jtEffectiveNAV == 0) return type(uint256).max;
        // Round in favor of ensuring senior tranche protection
        utilization = (_stRawNAV + _jtRawNAV.mulDiv(_betaWAD, ConstantsLib.WAD, Math.Rounding.Ceil)).mulDiv(_coverageWAD, _jtEffectiveNAV, Math.Rounding.Ceil);
    }
}
