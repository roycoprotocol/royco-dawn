// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../../../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { Math } from "../../../../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { AggregatorV3Interface } from "../../../../../../interfaces/external/chainlink/AggregatorV3Interface.sol";
import { WAD } from "../../../../../../libraries/Constants.sol";
import { ConversionRateCacheKey } from "../../../../../../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, UnitsMathLib, toNAVUnits, toTrancheUnits, toUint256 } from "../../../../../../libraries/Units.sol";
import { RoycoDawnKernel } from "../../../../RoycoDawnKernel.sol";

/**
 * @title SeniorAssetsChainlinkOracleQuoter
 * @notice Quoter that prices the senior tranche unit in NAV units via a single Chainlink (compatible) oracle
 * @dev Use case: Convert sUSDe (Senior tranche unit) to USD (NAV unit) using a Chainlink (compatible) oracle that prices the asset directly in NAV terms
 */
abstract contract SeniorAssetsChainlinkOracleQuoter is RoycoDawnKernel {
    using UnitsMathLib for NAV_UNIT;
    using UnitsMathLib for TRANCHE_UNIT;
    using Math for uint256;

    /// @dev Storage slot for SeniorAssetsChainlinkOracleQuoterState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.SeniorAssetsChainlinkOracleQuoterState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SENIOR_ASSETS_CHAINLINK_ORACLE_QUOTER_STORAGE_SLOT = 0x41d6356829bd16e314a46051477dace63a63b4bf6b7c59e3fe79fac589f65b00;

    /// @dev Scale factor of the senior tranche unit: 10^(ST_ASSET_DECIMALS)
    uint256 internal immutable SENIOR_TRANCHE_UNIT_SCALE_FACTOR;

    /// @dev Storage state for the Royco senior assets chainlink oracle quoter
    /// @custom:storage-location erc7201:Royco.storage.SeniorAssetsChainlinkOracleQuoterState
    struct SeniorAssetsChainlinkOracleQuoterState {
        address seniorAssetOracle;
        uint48 seniorAssetStalenessThresholdSeconds;
    }

    /// @notice Emitted when the senior assets chainlink oracle is updated
    event SeniorAssetChainlinkOracleUpdated(address indexed seniorAssetOracle, uint48 seniorAssetStalenessThresholdSeconds);

    /// @notice Thrown when the staleness threshold seconds is zero
    error INVALID_SENIOR_ASSET_STALENESS_THRESHOLD_SECONDS();

    /// @notice Thrown when the price is stale
    error STALE_SENIOR_ASSET_PRICE();

    /// @notice Thrown when the price is invalid
    error INVALID_SENIOR_ASSET_PRICE();

    /// @notice Thrown when the price is incomplete
    error INCOMPLETE_SENIOR_ASSET_PRICE();

    /// @dev Constructs the senior assets chainlink oracle quoter
    constructor() {
        // The senior tranche asset is non-null, guaranteed by the order of construction: kernel is constructed first
        SENIOR_TRANCHE_UNIT_SCALE_FACTOR = 10 ** IERC20Metadata(ST_ASSET).decimals();
    }

    /**
     * @notice Initializes the senior assets chainlink oracle quoter
     * @param _seniorAssetOracle The Chainlink (compatible) oracle pricing the senior tranche asset in NAV units
     * @param _seniorAssetStalenessThresholdSeconds The staleness threshold in seconds
     */
    function __SeniorAssetsChainlinkOracleQuoter_init_unchained(address _seniorAssetOracle, uint48 _seniorAssetStalenessThresholdSeconds)
        internal
        onlyInitializing
    {
        _setSeniorAssetChainlinkOracle(_seniorAssetOracle, _seniorAssetStalenessThresholdSeconds);
    }

    /// @inheritdoc RoycoDawnKernel
    function stConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _stAssets) public view virtual override(RoycoDawnKernel) returns (NAV_UNIT nav) {
        return toNAVUnits(
            toUint256(_stAssets.mulDiv(_getCachedSeniorTrancheUnitToNAVUnitConversionRateWAD(), SENIOR_TRANCHE_UNIT_SCALE_FACTOR, Math.Rounding.Floor))
        );
    }

    /// @inheritdoc RoycoDawnKernel
    function stConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) public view virtual override(RoycoDawnKernel) returns (TRANCHE_UNIT stAssets) {
        return toTrancheUnits(
            toUint256(_navAssets.mulDiv(SENIOR_TRANCHE_UNIT_SCALE_FACTOR, _getCachedSeniorTrancheUnitToNAVUnitConversionRateWAD(), Math.Rounding.Floor))
        );
    }

    /**
     * @notice Returns the value of 1 senior tranche unit in NAV units, scaled to WAD precision, queried live from the chainlink oracle
     * @return seniorTrancheToNAVUnitConversionRateWAD The senior tranche unit → NAV unit conversion rate
     */
    function getSeniorTrancheUnitToNAVUnitConversionRateWAD() public view virtual returns (uint256 seniorTrancheToNAVUnitConversionRateWAD) {
        (uint256 price, uint256 pricePrecision) = _querySeniorAssetChainlinkOracle();
        // Convert the oracle's native-precision price into a WAD-precision NAV-per-asset rate
        seniorTrancheToNAVUnitConversionRateWAD = price.mulDiv(WAD, pricePrecision, Math.Rounding.Floor);
    }

    /**
     * @notice Sets the chainlink oracle for pricing the senior asset
     * @dev Executes an accounting sync before and after setting the new oracle
     * @dev Only callable by a designated admin
     * @param _seniorAssetOracle The new Chainlink (compatible) oracle for pricing the senior asset
     * @param _seniorAssetStalenessThresholdSeconds The new staleness threshold seconds
     * @param _syncBeforeUpdate Whether to sync the tranche accounting before updating the oracle
     */
    function setSeniorAssetChainlinkOracle(address _seniorAssetOracle, uint48 _seniorAssetStalenessThresholdSeconds, bool _syncBeforeUpdate)
        external
        restricted
    {
        if (_syncBeforeUpdate) _preOpSyncTrancheAccounting();
        _setSeniorAssetChainlinkOracle(_seniorAssetOracle, _seniorAssetStalenessThresholdSeconds);
        _preOpSyncTrancheAccounting();
    }

    /// @dev Returns the chainlink oracle configuration for this quoter
    function getSeniorAssetChainlinkOracleConfiguration() external pure returns (SeniorAssetsChainlinkOracleQuoterState memory) {
        return _getSeniorAssetsChainlinkOracleQuoterStorage();
    }

    /// @inheritdoc RoycoDawnKernel
    /// @dev Caches the senior tranche unit to NAV unit conversion rate
    function _initializeQuoterCache() internal virtual override(RoycoDawnKernel) {
        cachedSeniorTrancheUnitToNAVUnitConversionRateWAD = getSeniorTrancheUnitToNAVUnitConversionRateWAD() | CACHED_CONVERSION_RATE_MASK;
    }

    /// @inheritdoc RoycoDawnKernel
    /// @dev Clears the cached senior tranche unit to NAV unit conversion rate
    function _clearQuoterCache() internal virtual override(RoycoDawnKernel) {
        cachedSeniorTrancheUnitToNAVUnitConversionRateWAD = 0;
    }

    /// @notice Returns the senior tranche unit → NAV unit conversion rate, preferring the transient cache and falling back to the live chainlink query on miss
    /// @return The senior tranche unit → NAV unit conversion rate, scaled to WAD precision
    function _getCachedSeniorTrancheUnitToNAVUnitConversionRateWAD() internal view returns (uint256) {
        (bool cacheHit, uint256 conversionRateWAD) = _lookupCachedConversionRate(ConversionRateCacheKey.SENIOR_TRANCHE_UNIT);
        if (cacheHit) return conversionRateWAD;
        return getSeniorTrancheUnitToNAVUnitConversionRateWAD();
    }

    /**
     * @notice Queries the senior asset chainlink oracle for the price
     * @return price The price from the latest round
     * @return precision The precision of the price (10^oracle.decimals())
     */
    function _querySeniorAssetChainlinkOracle() internal view returns (uint256 price, uint256 precision) {
        SeniorAssetsChainlinkOracleQuoterState storage $ = _getSeniorAssetsChainlinkOracleQuoterStorage();
        AggregatorV3Interface seniorAssetOracle = AggregatorV3Interface($.seniorAssetOracle);
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = seniorAssetOracle.latestRoundData();

        // Conduct sanity checks
        require(updatedAt + $.seniorAssetStalenessThresholdSeconds >= block.timestamp, STALE_SENIOR_ASSET_PRICE());
        require(answer > 0, INVALID_SENIOR_ASSET_PRICE());
        require(answeredInRound >= roundId, INCOMPLETE_SENIOR_ASSET_PRICE());

        price = uint256(answer);
        precision = 10 ** uint256(seniorAssetOracle.decimals());
    }

    /**
     * @notice Sets the new chainlink oracle for the senior asset
     * @param _seniorAssetOracle The new senior asset oracle (prices the asset in NAV units)
     * @param _seniorAssetStalenessThresholdSeconds The new staleness threshold seconds
     */
    function _setSeniorAssetChainlinkOracle(address _seniorAssetOracle, uint48 _seniorAssetStalenessThresholdSeconds) internal {
        require(_seniorAssetOracle != address(0), NULL_ADDRESS());
        require(_seniorAssetStalenessThresholdSeconds > 0, INVALID_SENIOR_ASSET_STALENESS_THRESHOLD_SECONDS());

        SeniorAssetsChainlinkOracleQuoterState storage $ = _getSeniorAssetsChainlinkOracleQuoterStorage();
        $.seniorAssetOracle = _seniorAssetOracle;
        $.seniorAssetStalenessThresholdSeconds = _seniorAssetStalenessThresholdSeconds;

        emit SeniorAssetChainlinkOracleUpdated(_seniorAssetOracle, _seniorAssetStalenessThresholdSeconds);
    }

    /// @dev Returns a storage pointer to the SeniorAssetsChainlinkOracleQuoterState storage
    function _getSeniorAssetsChainlinkOracleQuoterStorage() private pure returns (SeniorAssetsChainlinkOracleQuoterState storage $) {
        assembly ("memory-safe") {
            $.slot := SENIOR_ASSETS_CHAINLINK_ORACLE_QUOTER_STORAGE_SLOT
        }
    }
}
