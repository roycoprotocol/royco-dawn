// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { AggregatorV3Interface } from "../../../../../../interfaces/external/chainlink/AggregatorV3Interface.sol";
import { SeniorAssetsOracleQuoter } from "./SeniorAssetsOracleQuoter.sol";

/**
 * @title SeniorAssetsChainlinkOracleQuoter
 * @notice Quoter to convert senior tranche units to/from NAV units using a Chainlink (compatible) oracle to convert senior tranche units to reference assets which uses an admin or oracle set rate to convert to NAV units
 * @dev Use case: Convert PT-USDE (Senior tranche unit) to USDE (Reference asset) using a Chainlink (compatible) oracle and convert USDE to USD (NAV unit) using an admin or oracle set rate
 */
abstract contract SeniorAssetsChainlinkOracleQuoter is SeniorAssetsOracleQuoter {
    using Math for uint256;

    /// @dev Storage slot for SeniorAssetsChainlinkOracleQuoterState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.SeniorAssetsChainlinkOracleQuoterState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SENIOR_ASSETS_CHAINLINK_ORACLE_QUOTER_STORAGE_SLOT = 0x41d6356829bd16e314a46051477dace63a63b4bf6b7c59e3fe79fac589f65b00;

    /// @dev Storage state for the Royco senior assets chainlink oracle quoter
    /// @custom:storage-location erc7201:Royco.storage.SeniorAssetsChainlinkOracleQuoterState
    struct SeniorAssetsChainlinkOracleQuoterState {
        address oracle;
        uint48 stalenessThresholdSeconds;
    }

    /// @notice Emitted when the senior assets chainlink oracle is updated
    event SeniorAssetChainlinkOracleUpdated(address indexed oracle, uint48 stalenessThresholdSeconds);

    /// @notice Thrown when the staleness threshold seconds is zero
    error INVALID_STALENESS_THRESHOLD_SECONDS();

    /// @notice Thrown when the price is stale
    error STALE_PRICE();

    /// @notice Thrown when the price is invalid
    error INVALID_PRICE();

    /// @notice Thrown when the price is incomplete
    error INCOMPLETE_PRICE();

    /**
     * @notice Initializes the senior assets chainlink oracle quoter
     * @param _oracle The chainlink (compatible) oracle used to price the senior asset
     * @param _stalenessThresholdSeconds The staleness threshold in seconds
     */
    function __SeniorAssetsChainlinkOracleQuoter_init_unchained(address _oracle, uint48 _stalenessThresholdSeconds) internal onlyInitializing {
        _setSeniorAssetChainlinkOracle(_oracle, _stalenessThresholdSeconds);
    }

    /**
     * @notice Returns the conversion rate from senior tranche units to NAV units, scaled to WAD precision
     * @dev The conversion rate is calculated as Senior Tranche Asset Price in Reference Asset * Reference Asset Price in NAV units
     * @return seniorTrancheToNAVUnitConversionRateWAD The conversion rate from senior tranche token units to NAV units, scaled to WAD precision
     */
    function getSeniorTrancheUnitToNAVUnitConversionRateWAD()
        public
        view
        virtual
        override(SeniorAssetsOracleQuoter)
        returns (uint256 seniorTrancheToNAVUnitConversionRateWAD)
    {
        // Fetch the senior tranche asset price in reference assets and its precision
        (uint256 seniorAssetPriceInReferenceAsset, uint256 pricePrecision) = _querySeniorAssetChainlinkOracle();

        // Resolve the reference asset to NAV unit conversion rate, scaled to WAD precision
        uint256 referenceAssetToNAVUnitConversionRateWAD = getStoredSeniorAssetConversionRateWAD();
        // If the stored conversion rate is the sentinel value, query the oracle for the rate
        if (referenceAssetToNAVUnitConversionRateWAD == SENTINEL_CONVERSION_RATE) referenceAssetToNAVUnitConversionRateWAD = _getSeniorAssetConversionRateFromOracleWAD();

        // Calculate the conversion rate from senior tranche to NAV units, scaled to WAD precision
        seniorTrancheToNAVUnitConversionRateWAD =
            seniorAssetPriceInReferenceAsset.mulDiv(referenceAssetToNAVUnitConversionRateWAD, pricePrecision, Math.Rounding.Floor);
    }

    /**
     * @notice Sets the chainlink oracle for pricing the senior asset
     * @param _oracle The new chainlink (compatible) oracle for pricing the senior asset
     * @param _stalenessThresholdSeconds The new staleness threshold seconds
     * @param _syncBeforeUpdate Whether to sync the tranche accounting before updating the chainlink oracle
     */
    function setSeniorAssetChainlinkOracle(address _oracle, uint48 _stalenessThresholdSeconds, bool _syncBeforeUpdate) external restricted {
        // If specified, sync the tranche accounting before updating the chainlink oracle
        if (_syncBeforeUpdate) _preOpSyncTrancheAccounting();
        // Update the chainlink oracle
        _setSeniorAssetChainlinkOracle(_oracle, _stalenessThresholdSeconds);
        // Sync the tranche accounting after updating the chainlink oracle
        _preOpSyncTrancheAccounting();
    }

    /// @dev Returns the chainlink oracle configuration for this quoter
    function getSeniorAssetChainlinkOracleConfiguration() external pure returns (SeniorAssetsChainlinkOracleQuoterState memory) {
        return _getSeniorAssetsChainlinkOracleQuoterStorage();
    }

    /**
     * @notice Queries the senior asset chainlink oracle for the price
     * @dev The price is returned as the answer from the latest round
     * @return price The price from the latest round
     * @return precision The precision of the price
     */
    function _querySeniorAssetChainlinkOracle() internal view returns (uint256 price, uint256 precision) {
        // Fetch the price of the senior asset
        SeniorAssetsChainlinkOracleQuoterState storage $ = _getSeniorAssetsChainlinkOracleQuoterStorage();
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
     * @notice Sets the new chainlink oracle for the senior asset
     * @param _oracle The new senior asset to reference asset oracle
     * @param _stalenessThresholdSeconds The new staleness threshold seconds
     */
    function _setSeniorAssetChainlinkOracle(address _oracle, uint48 _stalenessThresholdSeconds) internal {
        require(_oracle != address(0), NULL_ADDRESS());
        require(_stalenessThresholdSeconds > 0, INVALID_STALENESS_THRESHOLD_SECONDS());

        SeniorAssetsChainlinkOracleQuoterState storage $ = _getSeniorAssetsChainlinkOracleQuoterStorage();
        $.oracle = _oracle;
        $.stalenessThresholdSeconds = _stalenessThresholdSeconds;

        emit SeniorAssetChainlinkOracleUpdated(_oracle, _stalenessThresholdSeconds);
    }

    /**
     * @notice Returns a storage pointer to the SeniorAssetsChainlinkOracleQuoterState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer
     */
    function _getSeniorAssetsChainlinkOracleQuoterStorage() private pure returns (SeniorAssetsChainlinkOracleQuoterState storage $) {
        assembly ("memory-safe") {
            $.slot := SENIOR_ASSETS_CHAINLINK_ORACLE_QUOTER_STORAGE_SLOT
        }
    }
}
