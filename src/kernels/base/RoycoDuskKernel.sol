// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { IRoycoDuskKernel } from "../../interfaces/IRoycoDuskKernel.sol";
import { ZERO_NAV_UNITS, ZERO_QUOTE_UNITS, ZERO_TRANCHE_UNITS } from "../../libraries/Constants.sol";
import { AssetClaims, ConversionRateCacheKey, KernelType, SyncedAccountingState } from "../../libraries/Types.sol";
import { Math, NAV_UNIT, QUOTE_UNIT, TRANCHE_UNIT, UnitsMathLib, toTrancheUnits, toUint256 } from "../../libraries/Units.sol";
import { IERC20, IRoycoDawnKernel, IRoycoVaultTranche, RoycoDawnKernel, SafeERC20 } from "./RoycoDawnKernel.sol";

/**
 * @title RoycoDuskKernel
 */
abstract contract RoycoDuskKernel is IRoycoDuskKernel, RoycoDawnKernel {
    using SafeERC20 for IERC20;
    using UnitsMathLib for uint256;
    using UnitsMathLib for NAV_UNIT;
    using UnitsMathLib for TRANCHE_UNIT;

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
    function jtConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) public view virtual override(IRoycoDawnKernel, RoycoDawnKernel) returns (TRANCHE_UNIT) {
        return toTrancheUnits(
            toUint256(_navAssets.mulDiv(JUNIOR_TRANCHE_UNIT_SCALE_FACTOR, _getCachedJuniorTrancheUnitToNAVUnitConversionRateWAD(), Math.Rounding.Floor))
        );
    }

    /// @inheritdoc IRoycoDuskKernel
    function lpConvertQuoteAssetsToNAVUnits(QUOTE_UNIT _quoteAssets) public view virtual override(IRoycoDuskKernel) returns (NAV_UNIT);

    /// @notice Unwraps the specified junior tranche assets (BPT) out of the junior tranche's underlying liquidity position
    /// @dev Implemented by the junior tranche liquidity-position quoter: the quote asset portion is remitted to the receiver and any internal ST shares are credited back to this kernel
    /// @param _jtAssets The junior tranche assets (BPT) to unwrap
    /// @param _receiver The recipient of the quote asset portion of the unwrap
    /// @return internalSTSharesWithdrawn The senior tranche shares withdrawn back to this kernel by the unwrap
    function _jtUnwrapLiquidityPosition(TRANCHE_UNIT _jtAssets, address _receiver) internal virtual returns (uint256 internalSTSharesWithdrawn);

    // =============================
    // Internal Utility Functions
    // =============================

    /**
     * @inheritdoc RoycoDawnKernel
     * @dev Remits any ST yield bearing assets in the claims directly to the receiver
     * @dev Unwraps the liquidity position tied to the specified JT assets (LP tokens) and remits the internal ST shares withdrawn to this kernel and quote assets withdrawn to the receiver
     * @dev Burns any internal ST shares withdrawn and remits their proportional claim on ST assets to the specified receiver
     */
    function _withdrawAssets(AssetClaims memory _claims, address _receiver) internal virtual override(RoycoDawnKernel) {
        // // Cache the individual claims
        // TRANCHE_UNIT stAssetsToClaim = _claims.stAssets;
        // TRANCHE_UNIT jtAssetsToClaim = _claims.jtAssets;

        // // Credit the assets being withdrawn to the receiver
        // // Do one batch withdrawal if they are the same asset, else do two separate transfers
        // if (jtAssetsToClaim != ZERO_TRANCHE_UNITS) {
        //     // Unwrap the liquidity position: the internal ST shares withdrawn must be in the kernel and the quote assets withdrawn must have been remitted to the specified receiver
        //     uint256 internalSTSharesWithdrawn = _jtUnwrapLiquidityPosition(jtAssetsToClaim, _receiver);
        //     // If their were no internal ST shares withdrawn, the JT assets claims have been withdrawn
        //     if (internalSTSharesWithdrawn != 0) {
        //         // Convert the internal ST shares withdrawn to their claims on ST assets
        //         TRANCHE_UNIT internalSTAssetsToWithdraw = convertInternalSTSharesToSTAssets(internalSTSharesWithdrawn);
        //         // Burn the internal ST shares this kernel received
        //         IRoycoVaultTranche(SENIOR_TRANCHE).burn(internalSTSharesWithdrawn);
        //         // Credit the ST assets being withdrawn
        //         stAssetsToClaim = stAssetsToClaim + internalSTAssetsToWithdraw;
        //     }
        // }

        // // Debit the ST and JT assets being withdrawn from each tranche if non-zero
        // RoycoDawnKernelState storage $ = _getRoycoDawnKernelStorage();
        // if (stAssetsToClaim != ZERO_TRANCHE_UNITS) $.stOwnedYieldBearingAssets = $.stOwnedYieldBearingAssets - stAssetsToClaim;
        // if (jtAssetsToClaim != ZERO_TRANCHE_UNITS) $.jtOwnedYieldBearingAssets = $.jtOwnedYieldBearingAssets - jtAssetsToClaim;

        // // Remit the ST assets directly to the specified receiver
        // IERC20(ST_ASSET).safeTransfer(_receiver, toUint256(stAssetsToClaim));
    }

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
}
