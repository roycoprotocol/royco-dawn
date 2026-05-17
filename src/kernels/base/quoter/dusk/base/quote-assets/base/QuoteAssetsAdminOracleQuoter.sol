// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { QuoteAssetsOracleQuoter } from "./QuoteAssetsOracleQuoter.sol";

/**
 * @title QuoteAssetsAdminOracleQuoter
 * @notice Quoter to convert quote units to NAV units using an admin controlled oracle
 * @dev The quote asset conversion rate is set purely by an admin
 */
abstract contract QuoteAssetsAdminOracleQuoter is QuoteAssetsOracleQuoter {
    /// @notice Thrown when trying to call the oracle querying helper
    error QUOTE_ASSET_MUST_USE_ADMIN_ORACLE_INPUT();

    /// @notice Thrown when trying to set the quote asset conversion rate to the sentinel value (0)
    error INVALID_QUOTE_ASSET_CONVERSION_RATE();

    /**
     * @notice Initializes the quote assets admin oracle quoter
     * @dev The conversion rate cannot be set to the sentinel value (0)
     * @param _initialQuoteAssetConversionRateWAD The initial quote asset to NAV unit conversion rate, scaled to WAD precision
     */
    function __QuoteAssetsAdminOracleQuoter_init(uint256 _initialQuoteAssetConversionRateWAD) internal onlyInitializing {
        // Validate the conversion rate
        require(_initialQuoteAssetConversionRateWAD != SENTINEL_CONVERSION_RATE, INVALID_QUOTE_ASSET_CONVERSION_RATE());
        // Initialize the quote assets oracle quoter with the initial admin set rate
        __QuoteAssetsOracleQuoter_init_unchained(_initialQuoteAssetConversionRateWAD);
    }

    /// @inheritdoc QuoteAssetsOracleQuoter
    /// @dev The conversion rate cannot be set to the sentinel value (0)
    function setQuoteAssetConversionRate(
        uint256 _quoteAssetConversionRateWAD,
        bool _syncBeforeUpdate
    )
        public
        virtual
        override(QuoteAssetsOracleQuoter)
        restricted
    {
        // Validate the conversion rate
        require(_quoteAssetConversionRateWAD != SENTINEL_CONVERSION_RATE, INVALID_QUOTE_ASSET_CONVERSION_RATE());
        // Update the quote assets oracle quoter with the new admin set rate
        QuoteAssetsOracleQuoter.setQuoteAssetConversionRate(_quoteAssetConversionRateWAD, _syncBeforeUpdate);
    }

    /// @inheritdoc QuoteAssetsOracleQuoter
    function _getQuoteAssetConversionRateFromOracleWAD() internal pure override(QuoteAssetsOracleQuoter) returns (uint256) {
        revert QUOTE_ASSET_MUST_USE_ADMIN_ORACLE_INPUT();
    }
}
