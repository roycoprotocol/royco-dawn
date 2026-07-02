// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { AggregatorV3Interface } from "../../../../interfaces/external/chainlink/AggregatorV3Interface.sol";
import { IdenticalAssetsOracleQuoter } from "./IdenticalAssetsOracleQuoter.sol";

/**
 * @title IdenticalAssetsChainlinkOracleQuoter
 * @notice Quoter to convert tranche units to/from NAV units using a Chainlink (compatible) oracle to convert tranche units to reference assets which uses an admin or oracle set rate to convert to NAV units
 * @dev Use case: Convert PT-USDE (Tranche unit) to USDE (Reference asset) using a Chainlink (compatible) oracle and convert USDE to USD (NAV unit) using an admin or oracle set rate
 */
abstract contract IdenticalAssetsChainlinkOracleQuoter is IdenticalAssetsOracleQuoter {
    using Math for uint256;

    /// @dev Storage slot for IdenticalAssetsChainlinkOracleQuoterState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.IdenticalAssetsChainlinkOracleQuoterState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant IDENTICAL_ASSETS_CHAINLINK_ORACLE_QUOTER_STORAGE_SLOT = 0x36321e8ea9ef16a1b272d9cece1e9b80ed6532a47572ae703d9c65a3a5fa1800;

    /// @dev Storage state for the Royco identical assets chainlink oracle quoter
    /// @custom:storage-location erc7201:Royco.storage.IdenticalAssetsChainlinkOracleQuoterState
    struct IdenticalAssetsChainlinkOracleQuoterState {
        address oracle;
        uint48 stalenessThresholdSeconds;
        address sequencerUptimeFeed;
        uint48 gracePeriodSeconds;
    }

    /// @notice Emitted when the identical assets chainlink oracle is updated
    event ChainlinkOracleUpdated(address indexed oracle, uint48 stalenessThresholdSeconds);

    /// @notice Emitted when the L2 sequencer uptime feed is updated
    event SequencerUptimeFeedUpdated(address indexed sequencerUptimeFeed, uint48 gracePeriodSeconds);

    /// @notice Thrown when the staleness threshold seconds is zero
    error INVALID_STALENESS_THRESHOLD_SECONDS();

    /// @notice Thrown when the grace period seconds is zero while an L2 sequencer uptime feed is set
    error INVALID_GRACE_PERIOD_SECONDS();

    /// @notice Thrown when the price is stale
    error STALE_PRICE();

    /// @notice Thrown when the price is invalid
    error INVALID_PRICE();

    /// @notice Thrown when the price is incomplete
    error INCOMPLETE_PRICE();

    /// @notice Thrown when the L2 sequencer is down
    error SEQUENCER_DOWN();

    /// @notice Thrown when the L2 sequencer's grace period has not elapsed since it was last restored
    error GRACE_PERIOD_NOT_OVER();

    /**
     * @notice Initializes the identical assets chainlink oracle quoter
     * @param _oracle The chainlink (compatible) oracle used to price an asset
     * @param _stalenessThresholdSeconds The staleness threshold in seconds
     * @param _sequencerUptimeFeed The L2 sequencer uptime feed to check before trusting the price (set to the null address to disable the check)
     * @param _gracePeriodSeconds The grace period in seconds that must elapse after the L2 sequencer is restored before trusting the price
     */
    function __IdenticalAssetsChainlinkOracleQuoter_init_unchained(
        address _oracle,
        uint48 _stalenessThresholdSeconds,
        address _sequencerUptimeFeed,
        uint48 _gracePeriodSeconds
    )
        internal
        onlyInitializing
    {
        _setChainlinkOracle(_oracle, _stalenessThresholdSeconds);
        _setSequencerUptimeFeed(_sequencerUptimeFeed, _gracePeriodSeconds);
    }

    /**
     * @notice Returns the conversion rate from tranche units to NAV units, scaled to WAD precision
     * @dev The conversion rate is calculated as Tranche Asset Price in Reference Asset * Reference Asset Price in NAV units
     * @return trancheToNAVUnitConversionRateWAD The conversion rate from tranche token units to NAV units, scaled to WAD precision
     */
    function getTrancheUnitToNAVUnitConversionRateWAD()
        public
        view
        virtual
        override(IdenticalAssetsOracleQuoter)
        returns (uint256 trancheToNAVUnitConversionRateWAD)
    {
        // Fetch the tranche asset price in reference assets and its precision
        (uint256 trancheAssetPriceInReferenceAsset, uint256 pricePrecision) = _queryChainlinkOracle();

        // Resolve the reference asset to NAV unit conversion rate, scaled to WAD precision
        uint256 referenceAssetToNAVUnitConversionRateWAD = getStoredConversionRateWAD();
        // If the stored conversion rate is the sentinel value, query the oracle for the rate
        if (referenceAssetToNAVUnitConversionRateWAD == SENTINEL_CONVERSION_RATE) referenceAssetToNAVUnitConversionRateWAD = _getConversionRateFromOracleWAD();

        // Calculate the conversion rate from tranche to NAV units, scaled to WAD precision
        trancheToNAVUnitConversionRateWAD =
            trancheAssetPriceInReferenceAsset.mulDiv(referenceAssetToNAVUnitConversionRateWAD, pricePrecision, Math.Rounding.Floor);
    }

    /**
     * @notice Sets the chainlink oracle for pricing an asset
     * @param _oracle The new chainlink (compatible) oracle for pricing an asset
     * @param _stalenessThresholdSeconds The new staleness threshold seconds
     * @param _syncBeforeUpdate Whether to sync the tranche accounting before updating the chainlink oracle
     */
    function setChainlinkOracle(address _oracle, uint48 _stalenessThresholdSeconds, bool _syncBeforeUpdate) external restricted {
        // If specified, sync the tranche accounting before updating the chainlink oracle
        if (_syncBeforeUpdate) _preOpSyncTrancheAccounting();
        // Update the chainlink oracle
        _setChainlinkOracle(_oracle, _stalenessThresholdSeconds);
        // Sync the tranche accounting after updating the chainlink oracle
        _preOpSyncTrancheAccounting();
    }

    /**
     * @notice Sets the L2 sequencer uptime feed and grace period used to gate price queries
     * @dev The sequencer uptime feed and grace period do not affect the conversion rate, so no accounting sync is performed
     * @param _sequencerUptimeFeed The new L2 sequencer uptime feed (set to the null address to disable the check)
     * @param _gracePeriodSeconds The new grace period in seconds that must elapse after the L2 sequencer is restored before trusting the price
     */
    function setSequencerUptimeFeed(address _sequencerUptimeFeed, uint48 _gracePeriodSeconds) external restricted {
        _setSequencerUptimeFeed(_sequencerUptimeFeed, _gracePeriodSeconds);
    }

    /// @dev Returns the chainlink oracle configuration for this quoter
    function getChainlinkOracleConfiguration() external pure returns (IdenticalAssetsChainlinkOracleQuoterState memory) {
        return _getIdenticalAssetsChainlinkOracleQuoterStorage();
    }

    /**
     * @notice Queries the chainlink oracle for the price
     * @dev The price is returned as the answer from the latest round
     * @return price The price from the latest round
     * @return precision The precision of the price
     */
    function _queryChainlinkOracle() internal view returns (uint256 price, uint256 precision) {
        IdenticalAssetsChainlinkOracleQuoterState storage $ = _getIdenticalAssetsChainlinkOracleQuoterStorage();

        // If a sequencer uptime feed is set, ensure the L2 sequencer is up and its grace period has elapsed before trusting the price
        address sequencerUptimeFeed = $.sequencerUptimeFeed;
        if (sequencerUptimeFeed != address(0)) {
            (, int256 sequencerStatus, uint256 sequencerStartedAt,,) = AggregatorV3Interface(sequencerUptimeFeed).latestRoundData();
            // A sequencer status of 0 indicates that the sequencer is up, and 1 indicates that it is down
            require(sequencerStatus == 0, SEQUENCER_DOWN());
            // Ensure the round is initialized (startedAt is 0 only for an uninitialized uptime feed) and that the grace
            // period has fully elapsed since the sequencer was last restored
            require(sequencerStartedAt != 0 && (block.timestamp - sequencerStartedAt) > $.gracePeriodSeconds, GRACE_PERIOD_NOT_OVER());
        }

        // Fetch the price of the asset
        AggregatorV3Interface oracle = AggregatorV3Interface($.oracle);
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = oracle.latestRoundData();

        // Conduct sanity checks
        require(updatedAt + $.stalenessThresholdSeconds >= block.timestamp, STALE_PRICE());
        require(answer > 0, INVALID_PRICE());
        require(answeredInRound >= roundId, INCOMPLETE_PRICE());

        // Return the price and the scaled precision
        price = uint256(answer);
        precision = 10 ** uint256(oracle.decimals());
    }

    /**
     * @notice Sets the new chainlink oracle
     * @param _oracle The new tranche asset to reference asset oracle
     * @param _stalenessThresholdSeconds The new staleness threshold seconds
     */
    function _setChainlinkOracle(address _oracle, uint48 _stalenessThresholdSeconds) internal {
        require(_oracle != address(0), NULL_ADDRESS());
        require(_stalenessThresholdSeconds > 0, INVALID_STALENESS_THRESHOLD_SECONDS());

        IdenticalAssetsChainlinkOracleQuoterState storage $ = _getIdenticalAssetsChainlinkOracleQuoterStorage();
        $.oracle = _oracle;
        $.stalenessThresholdSeconds = _stalenessThresholdSeconds;

        emit ChainlinkOracleUpdated(_oracle, _stalenessThresholdSeconds);
    }

    /**
     * @notice Sets the new L2 sequencer uptime feed and grace period
     * @dev A null sequencer uptime feed disables the L2 sequencer check; when a feed is set, the grace period must be a positive
     *      duration (mirroring the treatment of the staleness threshold for the price feed)
     * @param _sequencerUptimeFeed The new L2 sequencer uptime feed (set to the null address to disable the check)
     * @param _gracePeriodSeconds The new grace period seconds
     */
    function _setSequencerUptimeFeed(address _sequencerUptimeFeed, uint48 _gracePeriodSeconds) internal {
        require(_sequencerUptimeFeed == address(0) || _gracePeriodSeconds > 0, INVALID_GRACE_PERIOD_SECONDS());

        IdenticalAssetsChainlinkOracleQuoterState storage $ = _getIdenticalAssetsChainlinkOracleQuoterStorage();
        $.sequencerUptimeFeed = _sequencerUptimeFeed;
        $.gracePeriodSeconds = _gracePeriodSeconds;

        emit SequencerUptimeFeedUpdated(_sequencerUptimeFeed, _gracePeriodSeconds);
    }

    /**
     * @notice Returns a storage pointer to the IdenticalAssetsChainlinkOracleQuoterState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer
     */
    function _getIdenticalAssetsChainlinkOracleQuoterStorage() private pure returns (IdenticalAssetsChainlinkOracleQuoterState storage $) {
        assembly ("memory-safe") {
            $.slot := IDENTICAL_ASSETS_CHAINLINK_ORACLE_QUOTER_STORAGE_SLOT
        }
    }
}
