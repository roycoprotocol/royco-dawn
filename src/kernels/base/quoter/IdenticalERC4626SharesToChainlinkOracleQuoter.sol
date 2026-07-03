// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IdenticalAssetsChainlinkOracleQuoter } from "./base/IdenticalAssetsChainlinkOracleQuoter.sol";
import { IdenticalAssetsOracleQuoter } from "./base/IdenticalAssetsOracleQuoter.sol";
import { IdenticalERC4626SharesOracleQuoter, Math, WAD } from "./base/IdenticalERC4626SharesOracleQuoter.sol";

/**
 * @title IdenticalERC4626SharesToChainlinkOracleQuoter
 * @dev The senior and junior tranches must have the same ERC4626 vault share as its tranche unit
 * @dev Use case: Convert sNUSD (Tranche unit) to NUSD (base assets) using ERC4626's convertToAssets and convert NUSD to USD (NAV unit) using its Redstone fundamental price feed or an admin set rate
 */
abstract contract IdenticalERC4626SharesToChainlinkOracleQuoter is IdenticalERC4626SharesOracleQuoter, IdenticalAssetsChainlinkOracleQuoter {
    using Math for uint256;

    /**
     * @notice Initializes the identical ERC4626 shares chainlink oracle quoter and its inherited contracts
     * @param _initialConversionRateWAD The initial conversion rate as defined by the oracle, scaled to WAD precision
     * @param _baseAssetToNavAssetOracle The ERC4626 base asset to NAV accounting asset oracle
     * @param _stalenessThresholdSeconds The staleness threshold in seconds
     */
    function __IdenticalERC4626SharesToChainlinkOracleQuoter_init(
        uint256 _initialConversionRateWAD,
        address _baseAssetToNavAssetOracle,
        uint48 _stalenessThresholdSeconds
    )
        internal
        onlyInitializing
    {
        __IdenticalAssetsOracleQuoter_init_unchained(_initialConversionRateWAD);
        __IdenticalAssetsChainlinkOracleQuoter_init_unchained(_baseAssetToNavAssetOracle, _stalenessThresholdSeconds);
    }

    /**
     * @notice Returns the conversion rate from tranche units to NAV units, scaled to WAD precision
     * @dev This function assumes that the tranche token is an ERC4626 compliant vault
     * @dev The conversion rate is calculated as the value of tranche asset in base asset * value of base asset in NAV units
     * @return trancheToNAVUnitConversionRateWAD The conversion rate from tranche token units to NAV units, scaled to WAD precision
     */
    function getTrancheUnitToNAVUnitConversionRateWAD()
        public
        view
        virtual
        override(IdenticalERC4626SharesOracleQuoter, IdenticalAssetsChainlinkOracleQuoter)
        returns (uint256 trancheToNAVUnitConversionRateWAD)
    {
        return IdenticalERC4626SharesOracleQuoter.getTrancheUnitToNAVUnitConversionRateWAD();
    }

    /**
     * @notice Returns the conversion rate from the ERC4626 base asset to NAV units, scaled to WAD precision
     * @return baseAssetToNAVUnitConversionRateWAD The conversion rate from the ERC4626 base asset to NAV units, scaled to WAD precision
     */
    function _getConversionRateFromOracleWAD() internal view override(IdenticalAssetsOracleQuoter) returns (uint256 baseAssetToNAVUnitConversionRateWAD) {
        // Fetch the ERC4626 base asset price in NAV accounting assets and its precision
        (uint256 baseAssetPriceInNavAssets, uint256 pricePrecision) = _queryChainlinkOracle();
        // Convert the price to be in WAD precision
        return baseAssetPriceInNavAssets.mulDiv(WAD, pricePrecision, Math.Rounding.Floor);
    }
}
