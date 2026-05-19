// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { IRoycoDuskKernel } from "../../interfaces/IRoycoDuskKernel.sol";
import { ZERO_NAV_UNITS, ZERO_QUOTE_UNITS, ZERO_TRANCHE_UNITS } from "../../libraries/Constants.sol";
import { AccountingStateCheckpoint, AssetClaims, ConversionRateCacheKey, KernelType, LiquidityPositionClaims, SyncedAccountingState, TrancheType } from "../../libraries/Types.sol";
import { Math, NAV_UNIT, QUOTE_UNIT, TRANCHE_UNIT, UnitsMathLib, toTrancheUnits, toUint256 } from "../../libraries/Units.sol";
import { IERC20, IRoycoAccountant, IRoycoDawnKernel, IRoycoVaultTranche, RoycoDawnKernel, SafeERC20 } from "./RoycoDawnKernel.sol";

/**
 * @title RoycoDuskKernel
 */
abstract contract RoycoDuskKernel is IRoycoDuskKernel, RoycoDawnKernel {
    using SafeERC20 for IERC20;
    using UnitsMathLib for uint256;
    using UnitsMathLib for NAV_UNIT;
    using UnitsMathLib for TRANCHE_UNIT;

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

    // =============================
    // Tranche Asset Quoter Functions
    // =============================

    /// @inheritdoc IRoycoDawnKernel
    /// @dev Retrieves the ST shares and quote assets owned by the JT liquidity position and converts them to NAV units
    function jtConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _jtAssets) public view virtual override(IRoycoDawnKernel, RoycoDawnKernel) returns (NAV_UNIT nav) {
        // Retrieve the liquidity position claims for the specified JT assets
        LiquidityPositionClaims memory lpClaims = jtConvertTrancheUnitsToLPClaims(_jtAssets);
        // Retrieve the NAV of the quote asset claims if non-zero
        if (lpClaims.quoteAssets != ZERO_QUOTE_UNITS) nav = lpConvertQuoteAssetsToNAVUnits(lpClaims.quoteAssets);
        // Preemptively return if the liquidity position has no ST shares to value
        if (lpClaims.stShares == 0) return nav;
        // Sum any quote asset NAV with the NAV of the ST yield bearing assets owned by JT
        nav = nav + stConvertTrancheUnitsToNAVUnits(convertInternalSTSharesToSTAssets(lpClaims.stShares));
    }

    /// @inheritdoc IRoycoDawnKernel
    function jtConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) public view virtual override(IRoycoDawnKernel, RoycoDawnKernel) returns (TRANCHE_UNIT) {
        return toTrancheUnits(
            toUint256(_navAssets.mulDiv(JUNIOR_TRANCHE_UNIT_SCALE_FACTOR, _getCachedJuniorTrancheUnitToNAVUnitConversionRateWAD(), Math.Rounding.Floor))
        );
    }

    /// @inheritdoc IRoycoDuskKernel
    function convertInternalSTSharesToSTAssets(uint256 _internalSTShares) public view override(IRoycoDuskKernel) returns (TRANCHE_UNIT stAssets) {
        return
            _getRoycoDawnKernelStorage().stOwnedYieldBearingAssets
                .mulDiv(_internalSTShares, IRoycoVaultTranche(SENIOR_TRANCHE).totalSupply(), Math.Rounding.Floor);
    }

    /// @inheritdoc IRoycoDuskKernel
    function jtConvertTrancheUnitsToLPClaims(TRANCHE_UNIT _jtAssets) public view virtual override(IRoycoDuskKernel) returns (LiquidityPositionClaims memory);

    /// @inheritdoc IRoycoDuskKernel
    function lpConvertQuoteAssetsToNAVUnits(QUOTE_UNIT _quoteAssets) public view virtual override(IRoycoDuskKernel) returns (NAV_UNIT);

    // =============================
    // Internal Tranche Accounting Synchronization Functions
    // =============================

    /**
     * @notice Synchronizes tranche accounting after an external operation on the JT's underlying position (e.g. swap, add or remove liquidity, etc.)
     * @dev Designed to run after a pre-operation PNL sync has already captured any oracle drift on the senior side, so the recomposed ST raw NAV is reused
     *      as the live value, yielding a zero ST delta by construction
     * @dev The junior tranche raw NAV is read live to capture the operation's JT-side residual: trade fees, slippage, and any coverage premium paid or received
     * @return state The synchronized accounting state after the recomposition and accountant waterfall have been applied
     */
    function _postLiquidityPositionOpSyncTrancheAccounting() internal virtual returns (SyncedAccountingState memory state) {
        // Retrieve the recomposed accounting checkpoint to apply the PNL sync to after reconciling new external and interal ST shares
        (uint256 currentJTOwnedSTShares, AccountingStateCheckpoint memory checkpoint) = _getRecomposedAccountingCheckpoint();
        // Update the new internal (JT owned) ST share supply if needed
        _getRoycoDuskKernelStorage().lastJTOwnedSTShares = currentJTOwnedSTShares;
        // Execute the pre-op sync via the accountant using the recomposed accounting checkpoint to handle any
        // NOTE: The ST PNL post-swap should be zero since we synced PNL pre-swap. The JT PNL is a combination of coverage bought/sold, swap fees, and slippage
        state = IRoycoAccountant(ACCOUNTANT).preOpSyncTrancheAccounting(checkpoint, checkpoint.lastSTRawNAV, _getJuniorTrancheRawNAV());
    }

    /**
     * @notice Reconciles the distribution of ST shares in circulation (internally and externally owned) into a recomposed tranche NAVs checkpoint
     * @return currentJTOwnedSTShares The current ST shares owned by the junior tranche via their liqudity position claims
     * @return checkpoint The current NAV accounting checkpoint after applying the recomposition of externally and internally owned ST shares
     */
    function _getRecomposedAccountingCheckpoint() internal view virtual returns (uint256 currentJTOwnedSTShares, AccountingStateCheckpoint memory checkpoint) {
        // Retrieve the senior tranche shares currently owned by the junior tranche and on the last accounting synchronization
        currentJTOwnedSTShares = jtConvertTrancheUnitsToLPClaims(_getRoycoDawnKernelStorage().jtOwnedYieldBearingAssets).stShares;
        uint256 lastJTOwnedSTShares = _getRoycoDuskKernelStorage().lastJTOwnedSTShares;
        checkpoint = super._getLastAccountingCheckpoint();
        // If the composition of ST owned shares hasn't moved, there is no accounting recomposition required
        if (currentJTOwnedSTShares == lastJTOwnedSTShares) return (currentJTOwnedSTShares, checkpoint);

        // Get the total supply of senior tranche shares
        uint256 stSharesTotalSupply = IRoycoVaultTranche(SENIOR_TRANCHE).totalSupply();
        // Compute the current and last checkpointed effective senior tranche share supply (excludes shares owned by the junior tranche)
        // NOTE: This can never underflow since the total supply of ST shares must be greater than or equal to those owned by JT
        uint256 currentSTSharesEffectiveSupply = stSharesTotalSupply - currentJTOwnedSTShares;
        uint256 lastSTSharesEffectiveSupply = stSharesTotalSupply - lastJTOwnedSTShares;

        // Apply the recomposition to the accounting state checkpoint
        // The recomposition reconciles the distribution of underlying assets held by the senior and junior tranche assuming that swaps happened at par value
        // If there were no external ST shares on the last sync, but there are now
        if (lastSTSharesEffectiveSupply == 0) {
            // The senior tranche raw NAV and effective NAVs are identical: the current raw NAV based on the distribution of shares (internal vs external)
            // NOTE: If there were no external senior holder on the last sync, all self and coverage related impermanent losses must have been zeroed out
            checkpoint.lastSTRawNAV = _getSeniorTrancheRawNAV();
            checkpoint.lastSTEffectiveNAV = checkpoint.lastSTRawNAV;
        } else {
            // The senior tranche NAVs are scaled to reflect the ST shares that have been bought/sold by the junior tranche's LP position since the last accounting synchronization
            checkpoint.lastSTRawNAV = checkpoint.lastSTRawNAV.mulDiv(currentSTSharesEffectiveSupply, lastSTSharesEffectiveSupply, Math.Rounding.Floor);
            checkpoint.lastSTEffectiveNAV =
                checkpoint.lastSTEffectiveNAV.mulDiv(currentSTSharesEffectiveSupply, lastSTSharesEffectiveSupply, Math.Rounding.Floor);
            checkpoint.lastSTImpermanentLoss =
                checkpoint.lastSTImpermanentLoss.mulDiv(currentSTSharesEffectiveSupply, lastSTSharesEffectiveSupply, Math.Rounding.Ceil);
            checkpoint.lastJTImpermanentLoss =
                checkpoint.lastJTImpermanentLoss.mulDiv(currentSTSharesEffectiveSupply, lastSTSharesEffectiveSupply, Math.Rounding.Floor);
        }

        // NOTE: The junior tranche raw NAV is always left untouched, implying that any JT buys/sells of ST shares occurred at par value
        // This enables the following accounting sync to reconcile any real economic PNL in the ST share trade execution
        // The junior tranche effective NAV is computed to preserve NAV conservation, the key accounting invariant
        checkpoint.lastJTEffectiveNAV = (checkpoint.lastSTRawNAV + checkpoint.lastJTRawNAV).saturatingSub(checkpoint.lastSTEffectiveNAV);
    }

    // =============================
    // Internal Utility Functions
    // =============================

    /// @inheritdoc RoycoDawnKernel
    /// @dev Reconciles the ST assets owned by the effective supply of ST shares (excluding JT owned ST shares) and converts them to NAV units
    function _getSeniorTrancheRawNAV() internal view virtual override(RoycoDawnKernel) returns (NAV_UNIT stRawNAV) {
        RoycoDawnKernelState storage $ = _getRoycoDawnKernelStorage();
        // Retrieve the senior tranche shares currently owned by the junior tranche
        uint256 jtOwnedSTShares = jtConvertTrancheUnitsToLPClaims($.jtOwnedYieldBearingAssets).stShares;
        // Get the total supply of senior tranche shares
        uint256 stSharesTotalSupply = IRoycoVaultTranche(SENIOR_TRANCHE).totalSupply();
        // Compute the effective supply of senior tranche shares (excludes JT owned ST shares)
        uint256 stSharesEffectiveSupply = stSharesTotalSupply - jtOwnedSTShares;
        if (stSharesEffectiveSupply == 0) return ZERO_NAV_UNITS;
        // Convert the yield bearing assets owned by the effective senior tranche shares supply to NAV units via the configured quoter
        return stConvertTrancheUnitsToNAVUnits($.stOwnedYieldBearingAssets.mulDiv(stSharesEffectiveSupply, stSharesTotalSupply, Math.Rounding.Floor));
    }

    /// @inheritdoc RoycoDawnKernel
    function _getJuniorTrancheRawNAV() internal view virtual override(RoycoDawnKernel) returns (NAV_UNIT jtRawNAV) {
        return jtConvertTrancheUnitsToNAVUnits(_getRoycoDawnKernelStorage().jtOwnedYieldBearingAssets);
    }

    /// @inheritdoc RoycoDawnKernel
    /// @dev Unwraps the liquidity position tied to the specified JT assets (LP tokens) and remits the internal ST shares withdrawn to this kernel and quote assets withdrawn to the receiver
    /// @dev Burns any internal ST shares withdrawn and remits their proportional claim on ST assets to the specified receiver
    function _jtWithdrawAssets(TRANCHE_UNIT _jtAssets, address _receiver) internal virtual override(RoycoDawnKernel) {
        // Unwrap the liquidity position: the internal ST shares withdrawn must be in the kernel and the quote assets withdrawn must have been remitted to the specified receiver
        uint256 internalSTSharesWithdrawn = _jtUnwrapLiquidityPosition(_jtAssets, _receiver);
        // Preemptively return if their were no internal ST shares withdrawn
        if (internalSTSharesWithdrawn == 0) return;
        // Convert the internal ST shares withdrawn to their claims on ST assets
        TRANCHE_UNIT internalSTAssetsToWithdraw = convertInternalSTSharesToSTAssets(internalSTSharesWithdrawn);
        // Debit the ST assets being withdrawn
        RoycoDawnKernelState storage $ = _getRoycoDawnKernelStorage();
        $.stOwnedYieldBearingAssets = $.stOwnedYieldBearingAssets - internalSTAssetsToWithdraw;
        // Burn the internal ST shares this kernel received
        IRoycoVaultTranche(SENIOR_TRANCHE).burn(internalSTSharesWithdrawn);
        // Remit the ST assets directly to the specified receiver
        IERC20(ST_ASSET).safeTransfer(_receiver, toUint256(internalSTAssetsToWithdraw));
    }

    /**
     * @notice Unwraps the specified amount of junior tranche assets out of the junior tranche's underlying liquidity position
     * @dev The inheriting junior tranche liquidity position quoter must implement this function
     * @dev The quote asset portion of the unwrap must be remitted directly to the receiver, the internal senior tranche shares released must be credited back to this kernel so that `_jtWithdrawAssets` can burn them against the senior tranche and remit the underlying senior assets to the receiver
     * @param _jtAssets The junior tranche assets (units of the underlying liquidity position) to unwrap
     * @param _receiver The recipient of the quote asset portion of the unwrap
     * @return internalSTSharesWithdrawn The senior tranche shares withdrawn back to this kernel by the unwrap: they are burnt and remitted as the underlying senior asset to the receiver by `_jtWithdrawAssets`
     */
    function _jtUnwrapLiquidityPosition(TRANCHE_UNIT _jtAssets, address _receiver) internal virtual returns (uint256 internalSTSharesWithdrawn);

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
        if (_cacheKey == ConversionRateCacheKey.QUOTE_UNIT) return _decodeCachedConversionRate(cachedQuoteAssetToNAVUnitConversionRateWAD);
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
