// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { ConstantsLib } from "./ConstantsLib.sol";

library UtilsLib {
    using Math for uint256;

    /**
     * @notice Computes the utilization of the Royco market given the market's state
     * @dev Informally: total covered exposure / junior loss absorbtion buffer
     * @dev Formally: Utilization = ((ST_RAW_NAV + (JT_RAW_NAV * BETA_%)) * COV_%) / JT_EFFECTIVE_NAV
     * @param _stRawNavRAY The raw net asset value of the senior tranche invested assets, scaled to RAY precision
     * @param _jtRawNavRAY The raw net asset value of the junior tranche invested assets, scaled to RAY precision
     * @param _betaWAD The JT's sensitivity to the same downside stress that affects ST scaled to WAD precision
     *                 For example, beta is 0 when JT is in the RFR and 1 when JT is in the same opportunity as senior
     * @param _coverageWAD The ratio of current total exposure that is expected to be covered by the junior capital scaled to WAD precision
     * @param _jtEffectiveNavRAY The junior tranche net asset value after applying provided coverage, JT yield, ST yield distribution, and JT losses, scaled to RAY precision
     * @return utilizationWAD The utilization of the Royco market, scaled to WAD precision
     */
    function computeUtilization(
        uint256 _stRawNavRAY,
        uint256 _jtRawNavRAY,
        uint256 _betaWAD,
        uint256 _coverageWAD,
        uint256 _jtEffectiveNavRAY
    )
        internal
        pure
        returns (uint256 utilizationWAD)
    {
        // If there is no remaining JT loss-absorption buffer, utilization is effectively infinite
        if (_jtEffectiveNavRAY == 0) return type(uint256).max;
        // Round in favor of ensuring senior tranche protection
        utilizationWAD =
            (_stRawNavRAY + _jtRawNavRAY.mulDiv(_betaWAD, ConstantsLib.WAD, Math.Rounding.Ceil)).mulDiv(_coverageWAD, _jtEffectiveNavRAY, Math.Rounding.Ceil);
    }

    /**
     * @notice Scales a quantity to RAY precision
     * @param _amount The amount to scale to RAY precision
     * @param _scaleFactorToRAY The scaling factor applied to scale the amount to RAY precision (10 ^ (27 - _amount precision))
     * @return _amountRAY The amount scaled to RAY precision
     */
    function scaleToRAY(uint256 _amount, uint96 _scaleFactorToRAY) internal pure returns (uint256 _amountRAY) {
        _amountRAY = _amount * _scaleFactorToRAY;
    }

    /**
     * @notice Scales a quantity from RAY precision to its original precision
     * @dev Uses integer division, rounding down
     * @param _amountRAY The amount to scale from RAY precision back to its original precision
     * @param _scaleFactorToRAY The scaling factor applied to scale the amount to RAY precision (10 ^ (27 - _amount precision))
     * @return _amount The amount scaled from RAY precision back to its original precision
     */
    function scaleFromRAY(uint256 _amountRAY, uint96 _scaleFactorToRAY) internal pure returns (uint256 _amount) {
        _amount = _amountRAY / _scaleFactorToRAY;
    }
}
