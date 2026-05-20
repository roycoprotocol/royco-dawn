// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../../../../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { Math } from "../../../../../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { AggregatorV3Interface } from "../../../../../../../interfaces/external/chainlink/AggregatorV3Interface.sol";
import { WAD } from "../../../../../../../libraries/Constants.sol";
import { ConversionRateCacheKey } from "../../../../../../../libraries/Types.sol";
import { NAV_UNIT, QUOTE_UNIT, UnitsMathLib, toNAVUnits, toUint256 } from "../../../../../../../libraries/Units.sol";
import { RoycoDuskKernel } from "../../../../../RoycoDuskKernel.sol";

/**
 * @title QuoteAssetsChainlinkOracleQuoter
 * @notice Quoter that prices the quote asset in NAV units via a single Chainlink (compatible) oracle
 * @dev Use case: Convert USDC (Quote unit) to USD (NAV unit) using a Chainlink (compatible) oracle that prices the asset directly in NAV terms
 */
abstract contract QuoteAssetsChainlinkOracleQuoter is RoycoDuskKernel {
    using UnitsMathLib for QUOTE_UNIT;
    using Math for uint256;

    /// @dev Storage slot for QuoteAssetsChainlinkOracleQuoterState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.QuoteAssetsChainlinkOracleQuoterState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant QUOTE_ASSETS_CHAINLINK_ORACLE_QUOTER_STORAGE_SLOT = 0x698af3a7ae9a080c35dfbceb442b0e5fe89fcbd66ffcb403c016b981099b8900;

    /// @dev Scale factor of the quote unit: 10^(QUOTE_UNIT_DECIMALS)
    uint256 internal immutable QUOTE_UNIT_SCALE_FACTOR;

    /// @dev Storage state for the Royco quote assets chainlink oracle quoter
    /// @custom:storage-location erc7201:Royco.storage.QuoteAssetsChainlinkOracleQuoterState
    struct QuoteAssetsChainlinkOracleQuoterState {
        address quoteAssetOracle;
        uint48 quoteAssetStalenessThresholdSeconds;
    }

    /// @notice Emitted when the quote assets chainlink oracle is updated
    event QuoteAssetChainlinkOracleUpdated(address indexed quoteAssetOracle, uint48 quoteAssetStalenessThresholdSeconds);

    /// @notice Thrown when the staleness threshold seconds is zero
    error INVALID_QUOTE_ASSET_STALENESS_THRESHOLD_SECONDS();

    /// @notice Thrown when the price is stale
    error STALE_QUOTE_ASSET_PRICE();

    /// @notice Thrown when the price is invalid
    error INVALID_QUOTE_ASSET_PRICE();

    /// @notice Thrown when the price is incomplete
    error INCOMPLETE_QUOTE_ASSET_PRICE();

    /// @dev Constructs the quote assets chainlink oracle quoter
    constructor() {
        // The quote asset is non-null, guaranteed by the order of construction: RoycoDuskKernel is constructed first
        QUOTE_UNIT_SCALE_FACTOR = 10 ** IERC20Metadata(QUOTE_ASSET).decimals();
    }

    /**
     * @notice Initializes the quote assets chainlink oracle quoter
     * @param _quoteAssetOracle The Chainlink (compatible) oracle pricing the quote asset in NAV units
     * @param _quoteAssetStalenessThresholdSeconds The staleness threshold in seconds
     */
    function __QuoteAssetsChainlinkOracleQuoter_init_unchained(
        address _quoteAssetOracle,
        uint48 _quoteAssetStalenessThresholdSeconds
    )
        internal
        onlyInitializing
    {
        _setQuoteAssetChainlinkOracle(_quoteAssetOracle, _quoteAssetStalenessThresholdSeconds);
    }

    /// @inheritdoc RoycoDuskKernel
    /// @dev Converts quote units to NAV units, scaled to WAD precision
    function lpConvertQuoteAssetsToNAVUnits(QUOTE_UNIT _quoteAssets) public view override(RoycoDuskKernel) returns (NAV_UNIT) {
        return toNAVUnits(toUint256(_quoteAssets.mulDiv(_getCachedQuoteAssetToNAVUnitConversionRateWAD(), QUOTE_UNIT_SCALE_FACTOR, Math.Rounding.Floor)));
    }

    /**
     * @notice Returns the value of 1 quote unit in NAV units, scaled to WAD precision, queried live from the chainlink oracle
     * @return quoteAssetToNAVUnitConversionRateWAD The quote asset → NAV unit conversion rate
     */
    function getQuoteAssetToNAVUnitConversionRateWAD() public view virtual returns (uint256 quoteAssetToNAVUnitConversionRateWAD) {
        (uint256 price, uint256 pricePrecision) = _queryQuoteAssetChainlinkOracle();
        // Convert the oracle's native-precision price into a WAD-precision NAV-per-asset rate
        quoteAssetToNAVUnitConversionRateWAD = price.mulDiv(WAD, pricePrecision, Math.Rounding.Floor);
    }

    /**
     * @notice Sets the chainlink oracle for pricing the quote asset
     * @dev Executes an accounting sync before and after setting the new oracle
     * @dev Only callable by a designated admin
     * @param _quoteAssetOracle The new Chainlink (compatible) oracle for pricing the quote asset
     * @param _quoteAssetStalenessThresholdSeconds The new staleness threshold seconds
     * @param _syncBeforeUpdate Whether to sync the tranche accounting before updating the oracle
     */
    function setQuoteAssetChainlinkOracle(address _quoteAssetOracle, uint48 _quoteAssetStalenessThresholdSeconds, bool _syncBeforeUpdate) external restricted {
        if (_syncBeforeUpdate) _preOpSyncTrancheAccounting();
        _setQuoteAssetChainlinkOracle(_quoteAssetOracle, _quoteAssetStalenessThresholdSeconds);
        _preOpSyncTrancheAccounting();
    }

    /// @dev Returns the chainlink oracle configuration for this quoter
    function getQuoteAssetChainlinkOracleConfiguration() external pure returns (QuoteAssetsChainlinkOracleQuoterState memory) {
        return _getQuoteAssetsChainlinkOracleQuoterStorage();
    }

    /// @inheritdoc RoycoDuskKernel
    /// @dev Caches the quote asset to NAV unit conversion rate
    function _initializeQuoterCache() internal virtual override(RoycoDuskKernel) {
        super._initializeQuoterCache();
        cachedQuoteAssetToNAVUnitConversionRateWAD = getQuoteAssetToNAVUnitConversionRateWAD() | CACHED_CONVERSION_RATE_MASK;
    }

    /// @inheritdoc RoycoDuskKernel
    /// @dev Clears the cached quote asset to NAV unit conversion rate
    function _clearQuoterCache() internal virtual override(RoycoDuskKernel) {
        super._clearQuoterCache();
        cachedQuoteAssetToNAVUnitConversionRateWAD = 0;
    }

    /// @notice Returns the quote asset → NAV unit conversion rate, preferring the transient cache and falling back to the live chainlink query on miss
    /// @return The quote asset → NAV unit conversion rate, scaled to WAD precision
    function _getCachedQuoteAssetToNAVUnitConversionRateWAD() internal view returns (uint256) {
        (bool cacheHit, uint256 conversionRateWAD) = _lookupCachedConversionRate(ConversionRateCacheKey.QUOTE_UNIT);
        if (cacheHit) return conversionRateWAD;
        return getQuoteAssetToNAVUnitConversionRateWAD();
    }

    /**
     * @notice Queries the quote asset chainlink oracle for the price
     * @return price The price from the latest round
     * @return precision The precision of the price (10^oracle.decimals())
     */
    function _queryQuoteAssetChainlinkOracle() internal view returns (uint256 price, uint256 precision) {
        QuoteAssetsChainlinkOracleQuoterState storage $ = _getQuoteAssetsChainlinkOracleQuoterStorage();
        AggregatorV3Interface quoteAssetOracle = AggregatorV3Interface($.quoteAssetOracle);
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = quoteAssetOracle.latestRoundData();

        // Conduct sanity checks
        require(updatedAt + $.quoteAssetStalenessThresholdSeconds >= block.timestamp, STALE_QUOTE_ASSET_PRICE());
        require(answer > 0, INVALID_QUOTE_ASSET_PRICE());
        require(answeredInRound >= roundId, INCOMPLETE_QUOTE_ASSET_PRICE());

        price = uint256(answer);
        precision = 10 ** uint256(quoteAssetOracle.decimals());
    }

    /**
     * @notice Sets the new chainlink oracle
     * @param _quoteAssetOracle The new quote asset oracle (prices the asset in NAV units)
     * @param _quoteAssetStalenessThresholdSeconds The new staleness threshold seconds
     */
    function _setQuoteAssetChainlinkOracle(address _quoteAssetOracle, uint48 _quoteAssetStalenessThresholdSeconds) internal {
        require(_quoteAssetOracle != address(0), NULL_ADDRESS());
        require(_quoteAssetStalenessThresholdSeconds > 0, INVALID_QUOTE_ASSET_STALENESS_THRESHOLD_SECONDS());

        QuoteAssetsChainlinkOracleQuoterState storage $ = _getQuoteAssetsChainlinkOracleQuoterStorage();
        $.quoteAssetOracle = _quoteAssetOracle;
        $.quoteAssetStalenessThresholdSeconds = _quoteAssetStalenessThresholdSeconds;

        emit QuoteAssetChainlinkOracleUpdated(_quoteAssetOracle, _quoteAssetStalenessThresholdSeconds);
    }

    /// @dev Returns a storage pointer to the QuoteAssetsChainlinkOracleQuoterState storage
    function _getQuoteAssetsChainlinkOracleQuoterStorage() private pure returns (QuoteAssetsChainlinkOracleQuoterState storage $) {
        assembly ("memory-safe") {
            $.slot := QUOTE_ASSETS_CHAINLINK_ORACLE_QUOTER_STORAGE_SLOT
        }
    }
}
