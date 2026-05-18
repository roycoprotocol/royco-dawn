// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../../../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { Math, NAV_UNIT, TRANCHE_UNIT, UnitsMathLib, toNAVUnits, toTrancheUnits, toUint256 } from "../../../../../../libraries/Units.sol";
import { RoycoDawnKernel } from "../../../../RoycoDawnKernel.sol";

/**
 * @title SeniorAssetsOracleQuoter
 * @notice Quoter to convert senior tranche units to/from NAV units using an oracle for markets where the senior tranche asset is priced independently of the junior tranche asset
 * @dev NAV units always have WAD precision
 * @dev The quoter reads the conversion rate from the specified oracle in WAD precision.
 *      The kernel admin can optionally override the conversion rate with a fixed value.
 *      Supported use-cases include:
 *      - Dusk markets where the junior tranche unit is a liquidity position and the senior tranche unit is a yield bearing ERC20 (sUSDE, FalconXUSDC, etc.), NAV Unit (USD)
 */
abstract contract SeniorAssetsOracleQuoter is RoycoDawnKernel {
    using UnitsMathLib for NAV_UNIT;
    using UnitsMathLib for TRANCHE_UNIT;

    /// @dev Storage slot for SeniorAssetsOracleQuoterState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.SeniorAssetsOracleQuoterState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SENIOR_ASSETS_ORACLE_QUOTER_STORAGE_SLOT = 0x36881d05adc0f8c11ad97bd9be5df9c0e7351bbb3c7eb868c30a17e60546bd00;

    /// @dev Value representing the scale factor of the senior tranche unit: 10^(ST_ASSET_DECIMALS)
    uint256 internal immutable SENIOR_TRANCHE_UNIT_SCALE_FACTOR;

    /// @dev The cached senior tranche unit to NAV unit conversion rate
    uint256 internal transient cachedSeniorTrancheUnitToNAVUnitConversionRateWAD;

    /// @dev Storage state for the Royco senior assets overridable oracle quoter
    /// @custom:storage-location erc7201:Royco.storage.SeniorAssetsOracleQuoterState
    struct SeniorAssetsOracleQuoterState {
        uint256 seniorAssetConversionRateWAD;
    }

    /// @notice Emitted when the senior asset to NAV unit conversion rate is updated
    /// @param seniorAssetConversionRateWAD The updated conversion rate as defined by the oracle, scaled to WAD precision
    event SeniorAssetConversionRateUpdated(uint256 seniorAssetConversionRateWAD);

    /// @dev Constructs the senior assets oracle quoter
    constructor() {
        // The senior tranche asset is non-null, guaranteed by the order of construction: kernel is constructed first
        // Compute and set the senior tranche unit scale factor
        SENIOR_TRANCHE_UNIT_SCALE_FACTOR = 10 ** IERC20Metadata(ST_ASSET).decimals();
    }

    /**
     * @notice Initializes the senior assets oracle quoter
     * @param _initialSeniorAssetConversionRateWAD The initial conversion rate as defined by the oracle, scaled to WAD precision
     */
    function __SeniorAssetsOracleQuoter_init_unchained(uint256 _initialSeniorAssetConversionRateWAD) internal onlyInitializing {
        // Preemptively return if this quoter is reliant on an oracle instead of an admin set conversion rate
        if (_initialSeniorAssetConversionRateWAD == SENTINEL_CONVERSION_RATE) return;
        _getSeniorAssetsOracleQuoterStorage().seniorAssetConversionRateWAD = _initialSeniorAssetConversionRateWAD;
        emit SeniorAssetConversionRateUpdated(_initialSeniorAssetConversionRateWAD);
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
     * @notice Sets the senior asset to NAV unit conversion rate
     * @dev Once this is set, the quoter will rely solely on this value instead of the overridden oracle query
     * @dev Executes an accounting sync before and after setting the new conversion rate
     * @dev Only callable by a designated admin
     * @param _seniorAssetConversionRateWAD The conversion rate as defined by the oracle, scaled to WAD precision
     * @param _syncBeforeUpdate Whether to sync the tranche accounting before updating the conversion rate
     */
    function setSeniorAssetConversionRate(uint256 _seniorAssetConversionRateWAD, bool _syncBeforeUpdate) public virtual restricted {
        // If specified, sync the tranche accounting to reflect the PNL up to this point in time
        if (_syncBeforeUpdate) _preOpSyncTrancheAccounting();
        // Set the new conversion rate
        _getSeniorAssetsOracleQuoterStorage().seniorAssetConversionRateWAD = _seniorAssetConversionRateWAD;
        emit SeniorAssetConversionRateUpdated(_seniorAssetConversionRateWAD);
        // Sync the tranche accounting to reflect the PNL from the updated conversion rate
        _preOpSyncTrancheAccounting();
    }

    /**
     * @notice Returns the value of 1 Senior Tranche Unit in NAV Units, scaled to WAD precision
     * @dev If the admin oracle is set, it will return the override value, otherwise it will return the value queried from the oracle
     * @return seniorTrancheToNAVUnitConversionRateWAD The senior tranche unit to NAV unit conversion rate
     */
    function getSeniorTrancheUnitToNAVUnitConversionRateWAD() public view virtual returns (uint256 seniorTrancheToNAVUnitConversionRateWAD) {
        // If there is an admin set conversion rate, use that, else query the oracle for the rate
        seniorTrancheToNAVUnitConversionRateWAD = getStoredSeniorAssetConversionRateWAD();
        if (seniorTrancheToNAVUnitConversionRateWAD != SENTINEL_CONVERSION_RATE) return seniorTrancheToNAVUnitConversionRateWAD;
        return _getSeniorAssetConversionRateFromOracleWAD();
    }

    /// @notice Returns the stored senior asset conversion rate, scaled to WAD precision
    /// @return The stored senior asset conversion rate, scaled to WAD precision
    function getStoredSeniorAssetConversionRateWAD() public view returns (uint256) {
        return _getSeniorAssetsOracleQuoterStorage().seniorAssetConversionRateWAD;
    }

    /// @inheritdoc RoycoDawnKernel
    /// @dev Caches the senior tranche unit to NAV unit conversion rate
    function _initializeQuoterCache() internal virtual override(RoycoDawnKernel) {
        // Get the senior tranche unit to NAV unit conversion rate and set the cached flag
        cachedSeniorTrancheUnitToNAVUnitConversionRateWAD = getSeniorTrancheUnitToNAVUnitConversionRateWAD() | CACHED_CONVERSION_RATE_MASK;
    }

    /// @inheritdoc RoycoDawnKernel
    /// @dev Clears the cached senior tranche unit to NAV unit conversion rate
    function _clearQuoterCache() internal virtual override(RoycoDawnKernel) {
        cachedSeniorTrancheUnitToNAVUnitConversionRateWAD = 0;
    }

    /**
     * @notice Returns the cached senior tranche unit to NAV unit conversion rate
     * @dev On a cache hit, returns the cached value.
     *      Otherwise falls back to getSeniorTrancheUnitToNAVUnitConversionRateWAD() for view function compatibility.
     * @return The senior tranche unit to NAV unit conversion rate
     */
    function _getCachedSeniorTrancheUnitToNAVUnitConversionRateWAD() internal view returns (uint256) {
        // Look up the transient cache slot
        (bool cacheHit, uint256 conversionRateWAD) = _lookupCachedConversionRate(cachedSeniorTrancheUnitToNAVUnitConversionRateWAD);
        if (cacheHit) return conversionRateWAD;
        // Otherwise fall back to querying the rate directly (for view functions)
        return getSeniorTrancheUnitToNAVUnitConversionRateWAD();
    }

    /**
     * @notice Returns a senior asset conversion rate, scaled to WAD precision
     * @dev Depending on the concrete implementation, this may return the value of 1 senior tranche unit or an intermediate reference asset in NAV Units
     * @dev This function should be overridden if the conversion rate needs to be fetched from an oracle
     * @return seniorAssetConversionRateWAD The senior asset conversion rate, scaled to WAD precision
     */
    function _getSeniorAssetConversionRateFromOracleWAD() internal view virtual returns (uint256 seniorAssetConversionRateWAD);

    /**
     * @notice Returns a storage pointer to the SeniorAssetsOracleQuoterState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer
     */
    function _getSeniorAssetsOracleQuoterStorage() private pure returns (SeniorAssetsOracleQuoterState storage $) {
        assembly ("memory-safe") {
            $.slot := SENIOR_ASSETS_ORACLE_QUOTER_STORAGE_SLOT
        }
    }
}
