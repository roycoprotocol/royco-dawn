// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { SeniorAssetsChainlinkOracleQuoter } from "./base/SeniorAssetsChainlinkOracleQuoter.sol";
import { SeniorERC4626SharesOracleQuoter, Math, WAD } from "./base/SeniorERC4626SharesOracleQuoter.sol";
import { SeniorAssetsOracleQuoter } from "./base/SeniorAssetsOracleQuoter.sol";

/**
 * @title SeniorERC4626SharesToChainlinkOracleQuoter
 * @dev The senior tranche unit must be an ERC4626 vault share
 * @dev Use case: Convert sNUSD (Senior tranche unit) to NUSD (base assets) using ERC4626's convertToAssets and convert NUSD to USD (NAV unit) using its Redstone fundamental price feed or an admin set rate
 */
abstract contract SeniorERC4626SharesToChainlinkOracleQuoter is SeniorERC4626SharesOracleQuoter, SeniorAssetsChainlinkOracleQuoter {
    using Math for uint256;

    /**
     * @notice Initializes the senior assets ERC4626 shares chainlink oracle quoter and its inherited contracts
     * @param _initialSeniorAssetConversionRateWAD The initial conversion rate as defined by the oracle, scaled to WAD precision
     * @param _baseAssetToNavAssetOracle The ERC4626 base asset to NAV accounting asset oracle
     * @param _stalenessThresholdSeconds The staleness threshold in seconds
     */
    function __SeniorERC4626SharesToChainlinkOracleQuoter_init(
        uint256 _initialSeniorAssetConversionRateWAD,
        address _baseAssetToNavAssetOracle,
        uint48 _stalenessThresholdSeconds
    )
        internal
        onlyInitializing
    {
        __SeniorAssetsOracleQuoter_init_unchained(_initialSeniorAssetConversionRateWAD);
        __SeniorAssetsChainlinkOracleQuoter_init_unchained(_baseAssetToNavAssetOracle, _stalenessThresholdSeconds);
    }

    /**
     * @notice Returns the conversion rate from senior tranche units to NAV units, scaled to WAD precision
     * @dev This function assumes that the senior tranche token is an ERC4626 compliant vault
     * @dev The conversion rate is calculated as the value of the senior asset in base asset * value of base asset in NAV units
     * @return seniorTrancheToNAVUnitConversionRateWAD The conversion rate from senior tranche token units to NAV units, scaled to WAD precision
     */
    function getSeniorTrancheUnitToNAVUnitConversionRateWAD()
        public
        view
        virtual
        override(SeniorERC4626SharesOracleQuoter, SeniorAssetsChainlinkOracleQuoter)
        returns (uint256 seniorTrancheToNAVUnitConversionRateWAD)
    {
        return SeniorERC4626SharesOracleQuoter.getSeniorTrancheUnitToNAVUnitConversionRateWAD();
    }

    /**
     * @notice Returns the conversion rate from the ERC4626 base asset to NAV units, scaled to WAD precision
     * @return baseAssetToNAVUnitConversionRateWAD The conversion rate from the ERC4626 base asset to NAV units, scaled to WAD precision
     */
    function _getSeniorAssetConversionRateFromOracleWAD() internal view override(SeniorAssetsOracleQuoter) returns (uint256 baseAssetToNAVUnitConversionRateWAD) {
        // Fetch the ERC4626 base asset price in NAV accounting assets and its precision
        (uint256 baseAssetPriceInNavAssets, uint256 pricePrecision) = _querySeniorAssetChainlinkOracle();
        // Convert the price to be in WAD precision
        return baseAssetPriceInNavAssets.mulDiv(WAD, pricePrecision, Math.Rounding.Floor);
    }
}
