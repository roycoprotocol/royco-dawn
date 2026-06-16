// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { IRoycoDuskKernel } from "../../interfaces/IRoycoDuskKernel.sol";
import { AssetClaims, ConversionRateCacheKey, KernelType } from "../../libraries/Types.sol";
import { Math, NAV_UNIT, QUOTE_UNIT, TRANCHE_UNIT, UnitsMathLib, toTrancheUnits, toUint256 } from "../../libraries/Units.sol";
import { IRoycoDawnKernel, RoycoDawnKernel } from "./RoycoDawnKernel.sol";

/**
 * @title RoycoDuskKernel
 */
abstract contract RoycoDuskKernel is IRoycoDuskKernel, RoycoDawnKernel {
    using UnitsMathLib for NAV_UNIT;

    /// @dev Storage slot for RoycoDuskKernelState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoDuskKernelState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROYCO_DUSK_KERNEL_STORAGE_SLOT = 0xe95dd20a4d0edb62fc02826796060a0e1d8e3ce973dfc64f20cdf50cf478ef00;

    /// @inheritdoc IRoycoDuskKernel
    address public immutable override(IRoycoDuskKernel) QUOTE_ASSET;

    /// @dev Value representing the scale factor of the juniior tranche unit: 10^(JUNIOR_TRANCHE_UNIT_DECIMALS)
    uint256 internal immutable JUNIOR_TRANCHE_UNIT_SCALE_FACTOR;

    /// @dev Cache slot for the quote asset → NAV unit conversion rate; populated and cleared by the quote-side oracle mixin via the cache lifecycle hooks
    uint256 internal transient cachedQuoteAssetToNAVUnitConversionRateWAD;

    /// @notice Constructs the base Royco kernel state
    /// @param _params The standard construction parameters for the Royco Dusk kernel
    constructor(RoycoDuskKernelConstructionParams memory _params) RoycoDawnKernel(_params.dawnKernelParams) {
        // Dusk markets must have non-identical senior and junior assets: ST asset is the tranched asset and JT is a claim on a liquidity position against ST shares
        require(ST_ASSET != JT_ASSET, TRANCHE_ASSETS_MUST_NOT_BE_IDENTICAL());
        // Ensure that the quote asset address is not null
        require(_params.quoteAsset != address(0), NULL_ADDRESS());
        // Ensure that the senior tranche shares are not the quote asset for the liquidity position
        require(_params.quoteAsset != SENIOR_TRANCHE, QUOTE_ASSET_MUST_NOT_BE_SENIOR_TRANCHE_SHARE());

        // Set the kernel's quote asset
        QUOTE_ASSET = _params.quoteAsset;
        JUNIOR_TRANCHE_UNIT_SCALE_FACTOR = 10 ** IERC20Metadata(JT_ASSET).decimals();
    }

    /// @notice Initializes the base Royco Dusk kernel state
    /// @param _params The standard initialization parameters for the Royco Dusk kernel
    function __RoycoDuskKernel_init(RoycoDuskKernelInitParams memory _params) internal onlyInitializing {
        __RoycoDawnKernel_init(_params.dawnKernelInitParams);
    }

    // =============================
    // Tranche Asset Quoter Functions
    // =============================

    /// @inheritdoc IRoycoDawnKernel
    /// @dev TODO: rewire to the conservative BPT valuation (frozen invariant, fair-point value, demand clamp, senior-favoring floor) per the Dusk spec
    function jtConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _jtAssets) public view virtual override(IRoycoDawnKernel, RoycoDawnKernel) returns (NAV_UNIT nav) { }

    /// @inheritdoc IRoycoDawnKernel
    function jtConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) public view virtual override(IRoycoDawnKernel, RoycoDawnKernel) returns (TRANCHE_UNIT) {
        return toTrancheUnits(
            toUint256(_navAssets.mulDiv(JUNIOR_TRANCHE_UNIT_SCALE_FACTOR, _getCachedJuniorTrancheUnitToNAVUnitConversionRateWAD(), Math.Rounding.Floor))
        );
    }

    /// @inheritdoc IRoycoDuskKernel
    function lpConvertQuoteAssetsToNAVUnits(QUOTE_UNIT _quoteAssets) public view virtual override(IRoycoDuskKernel) returns (NAV_UNIT);

    // =============================
    // Internal Utility Functions
    // =============================

    /**
     * @inheritdoc RoycoDawnKernel
     * @dev Remits any ST yield bearing assets in the claims directly to the receiver
     * @dev TODO: rewire the JT leg to unwrap the liquidity position via `_jtUnwrapLiquidityPosition` once the Dusk redemption flow is finalized
     */
    function _withdrawAssets(AssetClaims memory _claims, address _receiver) internal virtual override(RoycoDawnKernel) { }

    /**
     * @notice Unwraps the specified amount of junior tranche assets out of the junior tranche's underlying liquidity position
     * @dev The inheriting junior tranche liquidity position quoter must implement this function
     * @dev The quote asset portion of the unwrap must be remitted directly to the receiver; the senior tranche shares released are credited back to this kernel, and their handling is wired by the Dusk redemption flow
     * @param _jtAssets The junior tranche assets (units of the underlying liquidity position) to unwrap
     * @param _receiver The recipient of the quote asset portion of the unwrap
     * @return stSharesWithdrawn The senior tranche shares withdrawn back to this kernel by the unwrap
     */
    function _jtUnwrapLiquidityPosition(TRANCHE_UNIT _jtAssets, address _receiver) internal virtual returns (uint256 stSharesWithdrawn);

    // =============================
    // Internal Quoter Cache Functions
    // =============================

    /// @inheritdoc RoycoDawnKernel
    /// @dev Caches the junior tranche unit to NAV unit conversion rate
    function _initializeQuoterCache() internal virtual override(RoycoDawnKernel) {
        // Get the junior tranche unit to NAV unit conversion rate and set the cached flag
        cachedJuniorTrancheUnitToNAVUnitConversionRateWAD =
            (toUint256(jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(JUNIOR_TRANCHE_UNIT_SCALE_FACTOR)))) | CACHED_CONVERSION_RATE_MASK;
    }

    /// @inheritdoc RoycoDawnKernel
    /// @dev Clears the cached junior tranche unit to NAV unit conversion rate
    function _clearQuoterCache() internal virtual override(RoycoDawnKernel) {
        cachedJuniorTrancheUnitToNAVUnitConversionRateWAD = 0;
    }

    /// @notice Returns the junior tranche unit → NAV unit conversion rate, preferring the transient cache and falling back to the live query on miss
    /// @return The junior tranche unit → NAV unit conversion rate, scaled to WAD precision
    function _getCachedJuniorTrancheUnitToNAVUnitConversionRateWAD() internal view returns (uint256) {
        (bool cacheHit, uint256 conversionRateWAD) = _lookupCachedConversionRate(ConversionRateCacheKey.JUNIOR_TRANCHE_UNIT);
        if (cacheHit) return conversionRateWAD;
        return toUint256(jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(JUNIOR_TRANCHE_UNIT_SCALE_FACTOR)));
    }

    /// @inheritdoc RoycoDawnKernel
    /// @dev Handles the Dusk-level QUOTE_UNIT cache key; delegates the tranche-unit keys to super
    function _lookupCachedConversionRate(ConversionRateCacheKey _cacheKey)
        internal
        view
        virtual
        override(RoycoDawnKernel)
        returns (bool cacheHit, uint256 conversionRateWAD)
    {
        if (_cacheKey == ConversionRateCacheKey.QUOTE_UNIT) {
            return _decodeCachedConversionRate(cachedQuoteAssetToNAVUnitConversionRateWAD);
        }
        return super._lookupCachedConversionRate(_cacheKey);
    }

    // =============================
    // Kernel State Accessor Functions
    // =============================

    /// @inheritdoc IRoycoDawnKernel
    function KERNEL_TYPE() external pure virtual override(IRoycoDawnKernel, RoycoDawnKernel) returns (KernelType kernelType) {
        return KernelType.DUSK;
    }

    /**
     * @notice Returns a storage pointer to the RoycoDuskKernelState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer to the kernel's state
     */
    function _getRoycoDuskKernelStorage() internal pure returns (RoycoDuskKernelState storage $) {
        assembly ("memory-safe") {
            $.slot := ROYCO_DUSK_KERNEL_STORAGE_SLOT
        }
    }
}
