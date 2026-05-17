// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { Math, NAV_UNIT, TRANCHE_UNIT, UnitsMathLib, toNAVUnits, toTrancheUnits, toUint256 } from "../../../../../libraries/Units.sol";
import { RoycoDawnKernel } from "../../../RoycoDawnKernel.sol";

/**
 * @title IdenticalAssetsOracleQuoter
 * @notice Quoter to convert tranche units to/from NAV units using an oracle for markets where both tranches use the same tranche units
 * @dev NAV units always have WAD precision
 * @dev The quoter reads the conversion rate from the specified oracle in WAD precision.
 *      The kernel admin can optionally override the conversion rate with a fixed value.
 *      Supported use-cases include:
 *      - Identical Yield Bearing ERC20 for ST And JT: Yield Bearing ERC20 and Tranche Unit (FalconXUSDC, reUSD, etc.), NAV Unit (USD)
 */
abstract contract IdenticalAssetsOracleQuoter is RoycoDawnKernel {
    using UnitsMathLib for NAV_UNIT;
    using UnitsMathLib for TRANCHE_UNIT;

    /// @dev Storage slot for IdenticalAssetsOracleQuoterState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.IdenticalAssetsOracleQuoterState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant IDENTICAL_ASSETS_ORACLE_QUOTER_STORAGE_SLOT = 0xca94f7ca84d231255275e1b9f26a7020d13b86fcd22e881d1138f23eeb47cf00;

    /// @dev Value representing the scale factor of the tranche unit: 10^(TRANCHE_UNIT_DECIMALS)
    uint256 internal immutable TRANCHE_UNIT_SCALE_FACTOR;

    /// @dev The cached tranche unit to NAV unit conversion rate
    uint256 internal transient cachedTrancheUnitToNAVUnitConversionRateWAD;

    /// @dev Storage state for the Royco identical assets overridable oracle quoter
    /// @custom:storage-location erc7201:Royco.storage.IdenticalAssetsOracleQuoterState
    struct IdenticalAssetsOracleQuoterState {
        uint256 conversionRateWAD;
    }

    /// @notice Emitted when the tranche unit to NAV unit conversion rate is updated
    /// @param conversionRateWAD The updated conversion rate as defined by the oracle, scaled to WAD precision
    event ConversionRateUpdated(uint256 conversionRateWAD);

    /// @notice Thrown when the senior and junior tranche assets are not identical
    error TRANCHE_ASSETS_MUST_BE_IDENTICAL();

    /// @dev Constructs the identical assets oracle quoter
    constructor() {
        // The tranche assets must be non-null (guaranteed by order of construction: kernel is constructed first)
        // The tranche assets must be identical since there is a single conversion rate used for both tranches
        require(ST_ASSET == JT_ASSET, TRANCHE_ASSETS_MUST_BE_IDENTICAL());
        // Compute and set the tranche unit scale factor
        TRANCHE_UNIT_SCALE_FACTOR = 10 ** IERC20Metadata(ST_ASSET).decimals();
    }

    /**
     * @notice Initializes the identical assets oracle quoter
     * @param _initialConversionRateWAD The initial conversion rate as defined by the oracle, scaled to WAD precision
     */
    function __IdenticalAssetsOracleQuoter_init_unchained(uint256 _initialConversionRateWAD) internal onlyInitializing {
        // Preemptively return if this quoter is reliant on an oracle instead of an admin set conversion rate
        if (_initialConversionRateWAD == SENTINEL_CONVERSION_RATE) return;
        _getIdenticalAssetsOracleQuoterStorage().conversionRateWAD = _initialConversionRateWAD;
        emit ConversionRateUpdated(_initialConversionRateWAD);
    }

    /// @inheritdoc RoycoDawnKernel
    function stConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _stAssets) public view override(RoycoDawnKernel) returns (NAV_UNIT nav) {
        return _convertTrancheUnitsToNAVUnits(_stAssets);
    }

    /// @inheritdoc RoycoDawnKernel
    function jtConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _jtAssets) public view override(RoycoDawnKernel) returns (NAV_UNIT nav) {
        return _convertTrancheUnitsToNAVUnits(_jtAssets);
    }

    /// @inheritdoc RoycoDawnKernel
    function stConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) public view override(RoycoDawnKernel) returns (TRANCHE_UNIT stAssets) {
        return _convertNAVUnitsToTrancheUnits(_navAssets);
    }

    /// @inheritdoc RoycoDawnKernel
    function jtConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) public view override(RoycoDawnKernel) returns (TRANCHE_UNIT jtAssets) {
        return _convertNAVUnitsToTrancheUnits(_navAssets);
    }

    /**
     * @notice Sets the tranche unit to NAV unit conversion rate
     * @dev Once this is set, the quoter will rely solely on this value instead of the overridden oracle query
     * @dev Executes an accounting sync before and after setting the new conversion rate
     * @dev Only callable by a designated admin
     * @param _conversionRateWAD The conversion rate as defined by the oracle, scaled to WAD precision
     * @param _syncBeforeUpdate Whether to sync the tranche accounting before updating the conversion rate
     */
    function setConversionRate(uint256 _conversionRateWAD, bool _syncBeforeUpdate) public virtual restricted {
        // If specified, sync the tranche accounting to reflect the PNL up to this point in time
        if (_syncBeforeUpdate) _preOpSyncTrancheAccounting();
        // Set the new conversion rate
        _getIdenticalAssetsOracleQuoterStorage().conversionRateWAD = _conversionRateWAD;
        emit ConversionRateUpdated(_conversionRateWAD);
        // Sync the tranche accounting to reflect the PNL from the updated conversion rate
        _preOpSyncTrancheAccounting();
    }

    /**
     * @notice Returns the value of 1 Tranche Unit in NAV Units, scaled to WAD precision
     * @dev If the admin oracle is set, it will return the override value, otherwise it will return the value queried from the oracle
     * @return trancheToNAVUnitConversionRateWAD The tranche unit to NAV unit conversion rate
     */
    function getTrancheUnitToNAVUnitConversionRateWAD() public view virtual returns (uint256 trancheToNAVUnitConversionRateWAD) {
        // If there is an admin set conversion rate, use that, else query the oracle for the rate
        trancheToNAVUnitConversionRateWAD = getStoredConversionRateWAD();
        if (trancheToNAVUnitConversionRateWAD != SENTINEL_CONVERSION_RATE) return trancheToNAVUnitConversionRateWAD;
        return _getConversionRateFromOracleWAD();
    }

    /// @notice Returns the stored conversion rate, scaled to WAD precision
    /// @return conversionRateWAD The stored conversion rate, scaled to WAD precision
    function getStoredConversionRateWAD() public view returns (uint256) {
        return _getIdenticalAssetsOracleQuoterStorage().conversionRateWAD;
    }

    /// @inheritdoc RoycoDawnKernel
    /// @dev Caches the tranche unit to NAV unit conversion rate
    function _initializeQuoterCache() internal virtual override(RoycoDawnKernel) {
        // Get the tranche unit to NAV unit conversion rate and set the cached flag
        cachedTrancheUnitToNAVUnitConversionRateWAD = getTrancheUnitToNAVUnitConversionRateWAD() | CACHED_CONVERSION_RATE_MASK;
    }

    /// @inheritdoc RoycoDawnKernel
    /// @dev Clears the cached tranche unit to NAV unit conversion rate
    function _clearQuoterCache() internal virtual override(RoycoDawnKernel) {
        cachedTrancheUnitToNAVUnitConversionRateWAD = 0;
    }

    /**
     * @notice Returns the cached tranche unit to NAV unit conversion rate
     * @dev On a cache hit, returns the cached value.
     *      Otherwise falls back to getTrancheUnitToNAVUnitConversionRateWAD() for view function compatibility.
     * @return The tranche unit to NAV unit conversion rate
     */
    function _getCachedTrancheUnitToNAVUnitConversionRateWAD() internal view returns (uint256) {
        // Look up the transient cache slot
        (bool cacheHit, uint256 conversionRateWAD) = _lookupCachedConversionRate(cachedTrancheUnitToNAVUnitConversionRateWAD);
        if (cacheHit) return conversionRateWAD;
        // Otherwise fall back to querying the rate directly (for view functions)
        return getTrancheUnitToNAVUnitConversionRateWAD();
    }

    /// @dev Converts tranche units to NAV units for both tranches since they use identical assets, scaled to WAD precision
    function _convertTrancheUnitsToNAVUnits(TRANCHE_UNIT _assets) internal view returns (NAV_UNIT) {
        return toNAVUnits(toUint256(_assets.mulDiv(_getCachedTrancheUnitToNAVUnitConversionRateWAD(), TRANCHE_UNIT_SCALE_FACTOR, Math.Rounding.Floor)));
    }

    /// @dev Converts NAV units to tranche units for both tranches since they use identical assets, scaled to TRANCHE_UNIT precision
    function _convertNAVUnitsToTrancheUnits(NAV_UNIT _nav) internal view returns (TRANCHE_UNIT) {
        return toTrancheUnits(toUint256(_nav.mulDiv(TRANCHE_UNIT_SCALE_FACTOR, _getCachedTrancheUnitToNAVUnitConversionRateWAD(), Math.Rounding.Floor)));
    }

    /**
     * @notice Returns a conversion rate, scaled to WAD precision
     * @dev Depending on the concrete implementation, this may return the value of 1 tranche unit or an intermediate reference asset in NAV Units
     * @dev This function should be overridden if the conversion rate needs to be fetched from an oracle
     * @return conversionRateWAD The conversion rate, scaled to WAD precision
     */
    function _getConversionRateFromOracleWAD() internal view virtual returns (uint256 conversionRateWAD);

    /**
     * @notice Returns a storage pointer to the IdenticalAssetsOracleQuoterState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer
     */
    function _getIdenticalAssetsOracleQuoterStorage() private pure returns (IdenticalAssetsOracleQuoterState storage $) {
        assembly ("memory-safe") {
            $.slot := IDENTICAL_ASSETS_ORACLE_QUOTER_STORAGE_SLOT
        }
    }
}
