// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../../../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { AggregatorV3Interface } from "../../../../../../../interfaces/external/chainlink/AggregatorV3Interface.sol";
import { QuoteAssetsOracleQuoter } from "./QuoteAssetsOracleQuoter.sol";

/**
 * @title QuoteAssetsChainlinkOracleQuoter
 * @notice Quoter to convert quote units to NAV units using a Chainlink (compatible) oracle to convert quote units to reference assets which uses an admin or oracle set rate to convert to NAV units
 * @dev Use case: Convert aUSDC (Quote unit) to USDC (Reference asset) using a Chainlink (compatible) oracle and convert USDC to USD (NAV unit) using an admin or oracle set rate
 */
abstract contract QuoteAssetsChainlinkOracleQuoter is QuoteAssetsOracleQuoter {
    using Math for uint256;

    /// @dev Storage slot for QuoteAssetsChainlinkOracleQuoterState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.QuoteAssetsChainlinkOracleQuoterState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant QUOTE_ASSETS_CHAINLINK_ORACLE_QUOTER_STORAGE_SLOT = 0x698af3a7ae9a080c35dfbceb442b0e5fe89fcbd66ffcb403c016b981099b8900;

    /// @dev Storage state for the Royco quote assets chainlink oracle quoter
    /// @custom:storage-location erc7201:Royco.storage.QuoteAssetsChainlinkOracleQuoterState
    struct QuoteAssetsChainlinkOracleQuoterState {
        address oracle;
        uint48 stalenessThresholdSeconds;
    }

    /// @notice Emitted when the quote assets chainlink oracle is updated
    event QuoteAssetChainlinkOracleUpdated(address indexed oracle, uint48 stalenessThresholdSeconds);

    /// @notice Thrown when the staleness threshold seconds is zero
    error INVALID_QUOTE_ASSET_STALENESS_THRESHOLD_SECONDS();

    /// @notice Thrown when the price is stale
    error STALE_QUOTE_ASSET_PRICE();

    /// @notice Thrown when the price is invalid
    error INVALID_QUOTE_ASSET_PRICE();

    /// @notice Thrown when the price is incomplete
    error INCOMPLETE_QUOTE_ASSET_PRICE();

    /**
     * @notice Initializes the quote assets chainlink oracle quoter
     * @param _oracle The chainlink (compatible) oracle used to price the quote asset
     * @param _stalenessThresholdSeconds The staleness threshold in seconds
     */
    function __QuoteAssetsChainlinkOracleQuoter_init_unchained(address _oracle, uint48 _stalenessThresholdSeconds) internal onlyInitializing {
        _setQuoteAssetChainlinkOracle(_oracle, _stalenessThresholdSeconds);
    }

    /**
     * @notice Returns the conversion rate from quote units to NAV units, scaled to WAD precision
     * @dev The conversion rate is calculated as Quote Asset Price in Reference Asset * Reference Asset Price in NAV units
     * @return quoteAssetToNAVUnitConversionRateWAD The conversion rate from quote units to NAV units, scaled to WAD precision
     */
    function getQuoteAssetToNAVUnitConversionRateWAD()
        public
        view
        virtual
        override(QuoteAssetsOracleQuoter)
        returns (uint256 quoteAssetToNAVUnitConversionRateWAD)
    {
        // Fetch the quote asset price in reference assets and its precision
        (uint256 quoteAssetPriceInReferenceAsset, uint256 pricePrecision) = _queryQuoteAssetChainlinkOracle();

        // Resolve the reference asset to NAV unit conversion rate, scaled to WAD precision
        uint256 referenceAssetToNAVUnitConversionRateWAD = getStoredQuoteAssetConversionRateWAD();
        // If the stored conversion rate is the sentinel value, query the oracle for the rate
        if (referenceAssetToNAVUnitConversionRateWAD == SENTINEL_CONVERSION_RATE) {
            referenceAssetToNAVUnitConversionRateWAD = _getQuoteAssetConversionRateFromOracleWAD();
        }

        // Calculate the conversion rate from quote to NAV units, scaled to WAD precision
        quoteAssetToNAVUnitConversionRateWAD =
            quoteAssetPriceInReferenceAsset.mulDiv(referenceAssetToNAVUnitConversionRateWAD, pricePrecision, Math.Rounding.Floor);
    }

    /**
     * @notice Sets the chainlink oracle for pricing the quote asset
     * @param _oracle The new chainlink (compatible) oracle for pricing the quote asset
     * @param _stalenessThresholdSeconds The new staleness threshold seconds
     * @param _syncBeforeUpdate Whether to sync the tranche accounting before updating the chainlink oracle
     */
    function setQuoteAssetChainlinkOracle(address _oracle, uint48 _stalenessThresholdSeconds, bool _syncBeforeUpdate) external restricted {
        // If specified, sync the tranche accounting before updating the chainlink oracle
        if (_syncBeforeUpdate) _preOpSyncTrancheAccounting();
        // Update the chainlink oracle
        _setQuoteAssetChainlinkOracle(_oracle, _stalenessThresholdSeconds);
        // Sync the tranche accounting after updating the chainlink oracle
        _preOpSyncTrancheAccounting();
    }

    /// @dev Returns the chainlink oracle configuration for this quoter
    function getQuoteAssetChainlinkOracleConfiguration() external pure returns (QuoteAssetsChainlinkOracleQuoterState memory) {
        return _getQuoteAssetsChainlinkOracleQuoterStorage();
    }

    /**
     * @notice Queries the chainlink oracle for the price
     * @dev The price is returned as the answer from the latest round
     * @return price The price from the latest round
     * @return precision The precision of the price
     */
    function _queryQuoteAssetChainlinkOracle() internal view returns (uint256 price, uint256 precision) {
        // Fetch the price of the quote asset
        QuoteAssetsChainlinkOracleQuoterState storage $ = _getQuoteAssetsChainlinkOracleQuoterStorage();
        AggregatorV3Interface oracle = AggregatorV3Interface($.oracle);
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = oracle.latestRoundData();

        // Conduct sanity checks
        require(updatedAt + $.stalenessThresholdSeconds >= block.timestamp, STALE_QUOTE_ASSET_PRICE());
        require(answer > 0, INVALID_QUOTE_ASSET_PRICE());
        require(answeredInRound >= roundId, INCOMPLETE_QUOTE_ASSET_PRICE());

        // Return the price and the scaled precision
        price = uint256(answer);
        precision = 10 ** uint256(oracle.decimals());
    }

    /**
     * @notice Sets the new chainlink oracle
     * @param _oracle The new quote asset to reference asset oracle
     * @param _stalenessThresholdSeconds The new staleness threshold seconds
     */
    function _setQuoteAssetChainlinkOracle(address _oracle, uint48 _stalenessThresholdSeconds) internal {
        require(_oracle != address(0), NULL_ADDRESS());
        require(_stalenessThresholdSeconds > 0, INVALID_QUOTE_ASSET_STALENESS_THRESHOLD_SECONDS());

        QuoteAssetsChainlinkOracleQuoterState storage $ = _getQuoteAssetsChainlinkOracleQuoterStorage();
        $.oracle = _oracle;
        $.stalenessThresholdSeconds = _stalenessThresholdSeconds;

        emit QuoteAssetChainlinkOracleUpdated(_oracle, _stalenessThresholdSeconds);
    }

    /**
     * @notice Returns a storage pointer to the QuoteAssetsChainlinkOracleQuoterState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer
     */
    function _getQuoteAssetsChainlinkOracleQuoterStorage() private pure returns (QuoteAssetsChainlinkOracleQuoterState storage $) {
        assembly ("memory-safe") {
            $.slot := QUOTE_ASSETS_CHAINLINK_ORACLE_QUOTER_STORAGE_SLOT
        }
    }
}
