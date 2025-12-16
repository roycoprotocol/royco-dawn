// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title IRDM - Reward Distribution Model Interface
 * @notice Interface for reward distribution models that determine how ST yield is distributed between tranches in Royco markets
 */
interface IRDM {
    /**
     * @notice Previews and returns a Royco market's percentage of ST yield that should be allocated to its JT
     * @dev Does not mutate any state
     * @param _stRawNAV The raw net asset value of the senior tranche invested assets
     * @param _jtRawNAV The raw net asset value of the junior tranche invested assets
     * @param _betaWAD The JT's sensitivity to the same downside stress that affects ST scaled to WAD precision
     *                 For example, beta is 0 when JT is in the RFR and 1 when JT is in the same opportunity as senior
     * @param _coverageWAD The ratio of current exposure that is expected to be covered by the junior capital scaled to WAD precision
     * @param _jtEffectiveNAV JT's net asset value after applying provided coverage, JT yield, ST yield distribution, and JT losses
     *                        Equivalent to its remaining loss-absorption buffer to cover ST's and its own drawdowns
     * @return jtYieldShareWAD The percentage of the ST's yield allocated to its JT, scaled to WAD precision
     *                         It is implied that (WAD - jtRewardPercentageWAD) will be the percentage allocated to ST, excluding any protocol fees
     */
    function previewJTYieldShare(
        uint256 _stRawNAV,
        uint256 _jtRawNAV,
        uint256 _betaWAD,
        uint256 _coverageWAD,
        uint256 _jtEffectiveNAV
    )
        external
        view
        returns (uint256 jtYieldShareWAD);

    /**
     * @notice Returns a Royco market's percentage of ST yield that should be allocated to its JT
     * @dev Can mutate state
     * @param _stRawNAV The raw net asset value of the senior tranche invested assets
     * @param _jtRawNAV The raw net asset value of the junior tranche invested assets
     * @param _betaWAD The JT's sensitivity to the same downside stress that affects ST scaled to WAD precision
     *                 For example, beta is 0 when JT is in the RFR and 1 when JT is in the same opportunity as senior
     * @param _coverageWAD The ratio of current exposure that is expected to be covered by the junior capital scaled to WAD precision
     * @param _jtEffectiveNAV JT's net asset value after applying provided coverage, JT yield, ST yield distribution, and JT losses
     *                        Equivalent to its remaining loss-absorption buffer to cover ST's and its own drawdowns
     * @return jtYieldShareWAD The percentage of the ST's yield allocated to its JT, scaled to WAD precision
     *                         It is implied that (WAD - jtRewardPercentageWAD) will be the percentage allocated to ST, excluding any protocol fees
     */
    function jtYieldShare(
        uint256 _stRawNAV,
        uint256 _jtRawNAV,
        uint256 _betaWAD,
        uint256 _coverageWAD,
        uint256 _jtEffectiveNAV
    )
        external
        returns (uint256 jtYieldShareWAD);
}
