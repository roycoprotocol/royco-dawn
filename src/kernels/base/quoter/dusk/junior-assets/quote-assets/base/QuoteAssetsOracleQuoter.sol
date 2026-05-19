// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../../../../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { ConversionRateCacheKey } from "../../../../../../../libraries/Types.sol";
import { Math, NAV_UNIT, QUOTE_UNIT, UnitsMathLib, toNAVUnits, toUint256 } from "../../../../../../../libraries/Units.sol";
import { IRoycoDuskKernel, RoycoDuskKernel } from "../../../../../RoycoDuskKernel.sol";

/**
 * @title QuoteAssetsOracleQuoter
 * @notice Quoter to convert quote units to NAV units using an oracle
 * @dev NAV units always have WAD precision
 * @dev The quoter reads the conversion rate from the specified oracle in WAD precision.
 *      The kernel admin can optionally override the conversion rate with a fixed value.
 *      Supported use-cases include:
 *      - Stablecoin quote asset: USDC / USDT (Quote unit), USD (NAV unit)
 */
abstract contract QuoteAssetsOracleQuoter is RoycoDuskKernel {
    using UnitsMathLib for QUOTE_UNIT;

    /// @dev Storage slot for QuoteAssetsOracleQuoterState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.QuoteAssetsOracleQuoterState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant QUOTE_ASSETS_ORACLE_QUOTER_STORAGE_SLOT = 0x199b590799bbaf9712bc946337667de355a911efc84a6ef81b2a6b8cd0dafc00;

    /// @dev Value representing the scale factor of the quote unit: 10^(QUOTE_UNIT_DECIMALS)
    uint256 internal immutable QUOTE_UNIT_SCALE_FACTOR;

    /// @dev Storage state for the Royco quote assets overridable oracle quoter
    /// @custom:storage-location erc7201:Royco.storage.QuoteAssetsOracleQuoterState
    struct QuoteAssetsOracleQuoterState {
        uint256 quoteAssetConversionRateWAD;
    }

    /// @notice Emitted when the quote asset to NAV unit conversion rate is updated
    /// @param quoteAssetConversionRateWAD The updated conversion rate as defined by the oracle, scaled to WAD precision
    event QuoteAssetConversionRateUpdated(uint256 quoteAssetConversionRateWAD);

    /// @dev Constructs the quote assets oracle quoter
    constructor() {
        // The quote asset is non-null, guaranteed by the order of construction: RoycoDuskKernel is constructed first
        // Compute and set the quote unit scale factor
        QUOTE_UNIT_SCALE_FACTOR = 10 ** IERC20Metadata(QUOTE_ASSET).decimals();
    }

    /**
     * @notice Initializes the quote assets oracle quoter
     * @param _initialQuoteAssetConversionRateWAD The initial quote asset to NAV unit conversion rate, scaled to WAD precision
     */
    function __QuoteAssetsOracleQuoter_init_unchained(uint256 _initialQuoteAssetConversionRateWAD) internal onlyInitializing {
        // Preemptively return if this quoter is reliant on an oracle instead of an admin set conversion rate
        if (_initialQuoteAssetConversionRateWAD == SENTINEL_CONVERSION_RATE) return;
        _getQuoteAssetsOracleQuoterStorage().quoteAssetConversionRateWAD = _initialQuoteAssetConversionRateWAD;
        emit QuoteAssetConversionRateUpdated(_initialQuoteAssetConversionRateWAD);
    }

    /// @inheritdoc RoycoDuskKernel
    /// @dev Converts quote units to NAV units, scaled to WAD precision
    function lpConvertQuoteAssetsToNAVUnits(QUOTE_UNIT _quoteAssets) public view override(RoycoDuskKernel) returns (NAV_UNIT) {
        return toNAVUnits(toUint256(_quoteAssets.mulDiv(_getCachedQuoteAssetToNAVUnitConversionRateWAD(), QUOTE_UNIT_SCALE_FACTOR, Math.Rounding.Floor)));
    }

    /**
     * @notice Sets the quote asset to NAV unit conversion rate
     * @dev Once this is set, the quoter will rely solely on this value instead of the overridden oracle query
     * @dev Executes an accounting sync before and after setting the new conversion rate
     * @dev Only callable by a designated admin
     * @param _quoteAssetConversionRateWAD The new quote asset to NAV unit conversion rate, scaled to WAD precision
     * @param _syncBeforeUpdate Whether to sync the tranche accounting before updating the conversion rate
     */
    function setQuoteAssetConversionRate(uint256 _quoteAssetConversionRateWAD, bool _syncBeforeUpdate) public virtual restricted {
        // If specified, sync the tranche accounting to reflect the PNL up to this point in time
        if (_syncBeforeUpdate) _preOpSyncTrancheAccounting();
        // Set the new conversion rate
        _getQuoteAssetsOracleQuoterStorage().quoteAssetConversionRateWAD = _quoteAssetConversionRateWAD;
        emit QuoteAssetConversionRateUpdated(_quoteAssetConversionRateWAD);
        // Sync the tranche accounting to reflect the PNL from the updated conversion rate
        _preOpSyncTrancheAccounting();
    }

    /**
     * @notice Returns the value of 1 Quote Unit in NAV Units, scaled to WAD precision
     * @dev If the admin oracle is set, it will return the override value, otherwise it will return the value queried from the oracle
     * @return quoteAssetToNAVUnitConversionRateWAD The quote asset to NAV unit conversion rate
     */
    function getQuoteAssetToNAVUnitConversionRateWAD() public view virtual returns (uint256 quoteAssetToNAVUnitConversionRateWAD) {
        // If there is an admin set conversion rate, use that, else query the oracle for the rate
        quoteAssetToNAVUnitConversionRateWAD = getStoredQuoteAssetConversionRateWAD();
        if (quoteAssetToNAVUnitConversionRateWAD != SENTINEL_CONVERSION_RATE) return quoteAssetToNAVUnitConversionRateWAD;
        return _getQuoteAssetConversionRateFromOracleWAD();
    }

    /// @notice Returns the stored quote asset conversion rate, scaled to WAD precision
    /// @return quoteAssetConversionRateWAD The stored quote asset conversion rate, scaled to WAD precision
    function getStoredQuoteAssetConversionRateWAD() public view returns (uint256 quoteAssetConversionRateWAD) {
        return _getQuoteAssetsOracleQuoterStorage().quoteAssetConversionRateWAD;
    }

    /// @inheritdoc RoycoDuskKernel
    /// @dev Caches the quote asset to NAV unit conversion rate
    function _initializeQuoterCache() internal virtual override(RoycoDuskKernel) {
        // Chain to the parent quoter cache
        super._initializeQuoterCache();
        // Get the quote asset to NAV unit conversion rate and set the cached flag
        cachedQuoteAssetToNAVUnitConversionRateWAD = getQuoteAssetToNAVUnitConversionRateWAD() | CACHED_CONVERSION_RATE_MASK;
    }

    /// @inheritdoc RoycoDuskKernel
    /// @dev Clears the cached quote asset to NAV unit conversion rate
    function _clearQuoterCache() internal virtual override(RoycoDuskKernel) {
        // Chain to the parent quoter cache
        super._clearQuoterCache();
        cachedQuoteAssetToNAVUnitConversionRateWAD = 0;
    }

    /// @notice Returns the quote asset → NAV unit conversion rate, preferring the transient cache and falling back to the live oracle query on miss
    /// @return The quote asset → NAV unit conversion rate, scaled to WAD precision
    function _getCachedQuoteAssetToNAVUnitConversionRateWAD() internal view returns (uint256) {
        (bool cacheHit, uint256 conversionRateWAD) = _lookupCachedConversionRate(ConversionRateCacheKey.QUOTE_UNIT);
        if (cacheHit) return conversionRateWAD;
        return getQuoteAssetToNAVUnitConversionRateWAD();
    }

    /**
     * @notice Returns a quote asset conversion rate, scaled to WAD precision
     * @dev Depending on the concrete implementation, this may return the value of 1 quote unit or an intermediate reference asset in NAV Units
     * @dev This function should be overridden if the conversion rate needs to be fetched from an oracle
     * @return quoteAssetConversionRateWAD The quote asset conversion rate, scaled to WAD precision
     */
    function _getQuoteAssetConversionRateFromOracleWAD() internal view virtual returns (uint256 quoteAssetConversionRateWAD);

    /**
     * @notice Returns a storage pointer to the QuoteAssetsOracleQuoterState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer
     */
    function _getQuoteAssetsOracleQuoterStorage() private pure returns (QuoteAssetsOracleQuoterState storage $) {
        assembly ("memory-safe") {
            $.slot := QUOTE_ASSETS_ORACLE_QUOTER_STORAGE_SLOT
        }
    }
}
