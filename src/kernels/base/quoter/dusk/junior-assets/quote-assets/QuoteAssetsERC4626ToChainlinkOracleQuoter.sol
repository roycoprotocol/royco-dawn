// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { QuoteAssetsChainlinkOracleQuoter } from "./base/QuoteAssetsChainlinkOracleQuoter.sol";
import { Math, QuoteAssetsERC4626OracleQuoter, WAD } from "./base/QuoteAssetsERC4626OracleQuoter.sol";
import { QuoteAssetsOracleQuoter } from "./base/QuoteAssetsOracleQuoter.sol";

/**
 * @title QuoteAssetsERC4626ToChainlinkOracleQuoter
 * @dev The quote asset must be an ERC4626 vault share
 * @dev Use case: Convert sNUSD (Quote unit) to NUSD (base assets) using ERC4626's convertToAssets and convert NUSD to USD (NAV unit) using its Redstone fundamental price feed or an admin set rate
 */
abstract contract QuoteAssetsERC4626ToChainlinkOracleQuoter is QuoteAssetsERC4626OracleQuoter, QuoteAssetsChainlinkOracleQuoter {
    using Math for uint256;

    /**
     * @notice Initializes the quote assets ERC4626 chainlink oracle quoter and its inherited contracts
     * @param _initialQuoteAssetConversionRateWAD The initial conversion rate as defined by the oracle, scaled to WAD precision
     * @param _baseAssetToNavAssetOracle The ERC4626 base asset to NAV accounting asset oracle
     * @param _stalenessThresholdSeconds The staleness threshold in seconds
     */
    function __QuoteAssetsERC4626ToChainlinkOracleQuoter_init(
        uint256 _initialQuoteAssetConversionRateWAD,
        address _baseAssetToNavAssetOracle,
        uint48 _stalenessThresholdSeconds
    )
        internal
        onlyInitializing
    {
        __QuoteAssetsOracleQuoter_init_unchained(_initialQuoteAssetConversionRateWAD);
        __QuoteAssetsChainlinkOracleQuoter_init_unchained(_baseAssetToNavAssetOracle, _stalenessThresholdSeconds);
    }

    /**
     * @notice Returns the conversion rate from quote units to NAV units, scaled to WAD precision
     * @dev This function assumes that the quote asset is an ERC4626 compliant vault
     * @dev The conversion rate is calculated as the value of quote asset in base asset * value of base asset in NAV units
     * @return quoteAssetToNAVUnitConversionRateWAD The conversion rate from quote units to NAV units, scaled to WAD precision
     */
    function getQuoteAssetToNAVUnitConversionRateWAD()
        public
        view
        virtual
        override(QuoteAssetsERC4626OracleQuoter, QuoteAssetsChainlinkOracleQuoter)
        returns (uint256 quoteAssetToNAVUnitConversionRateWAD)
    {
        return QuoteAssetsERC4626OracleQuoter.getQuoteAssetToNAVUnitConversionRateWAD();
    }

    /**
     * @notice Returns the conversion rate from the ERC4626 base asset to NAV units, scaled to WAD precision
     * @return baseAssetToNAVUnitConversionRateWAD The conversion rate from the ERC4626 base asset to NAV units, scaled to WAD precision
     */
    function _getQuoteAssetConversionRateFromOracleWAD() internal view override(QuoteAssetsOracleQuoter) returns (uint256 baseAssetToNAVUnitConversionRateWAD) {
        // Fetch the ERC4626 base asset price in NAV accounting assets and its precision
        (uint256 baseAssetPriceInNavAssets, uint256 pricePrecision) = _queryQuoteAssetChainlinkOracle();
        // Convert the price to be in WAD precision
        return baseAssetPriceInNavAssets.mulDiv(WAD, pricePrecision, Math.Rounding.Floor);
    }
}
