// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDuskKernel } from "../../interfaces/IRoycoDuskKernel.sol";
import { ZERO_NAV_UNITS, ZERO_QUOTE_UNITS } from "../../libraries/Constants.sol";
import { AccountingStateCheckpoint, AssetClaims, KernelType, LiquidityPositionClaims, SyncedAccountingState, TrancheType } from "../../libraries/Types.sol";
import { Math, NAV_UNIT, QUOTE_UNIT, TRANCHE_UNIT, UnitsMathLib, toUint256 } from "../../libraries/Units.sol";
import { IRoycoAccountant, IRoycoDawnKernel, IRoycoVaultTranche, RoycoDawnKernel } from "./RoycoDawnKernel.sol";

/**
 * @title RoycoDuskKernel
 */
abstract contract RoycoDuskKernel is IRoycoDuskKernel, RoycoDawnKernel {
    using UnitsMathLib for uint256;
    using UnitsMathLib for NAV_UNIT;
    using UnitsMathLib for TRANCHE_UNIT;

    /// @dev Storage slot for RoycoDuskKernelState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoDuskKernelState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROYCO_DUSK_KERNEL_STORAGE_SLOT = 0xe95dd20a4d0edb62fc02826796060a0e1d8e3ce973dfc64f20cdf50cf478ef00;

    /// @dev The cached tranche unit to NAV unit conversion rate
    uint256 internal transient cachedTrancheUnitToNAVUnitConversionRateWAD;

    // =============================
    // Tranche Asset Quoter Functions
    // =============================

    /// @inheritdoc IRoycoDawnKernel
    function jtConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _jtAssets) public view virtual override(IRoycoDawnKernel, RoycoDawnKernel) returns (NAV_UNIT nav) {
        // Retrieve the liquidity position claims for the specified JT assets
        LiquidityPositionClaims memory lpClaims = jtConvertTrancheUnitsToLPClaims(_jtAssets);
        // Retrieve the NAV of the quote asset claims if non-zero
        if (lpClaims.quoteAssets != ZERO_QUOTE_UNITS) nav = lpConvertQuoteAssetsToNAVUnits(lpClaims.quoteAssets);
        // Preemptively return if the liquidity position has no ST shares to value
        if (lpClaims.stShares == 0) return nav;
        // Get the total supply of senior tranche shares
        uint256 stSharesTotalSupply = IRoycoVaultTranche(SENIOR_TRANCHE).totalSupply();
        // Sum any quote asset NAV with the NAV of the ST yield bearing assets owned by JT
        nav = nav
            + stConvertTrancheUnitsToNAVUnits(
                _getRoycoDawnKernelStorage().stOwnedYieldBearingAssets.mulDiv(lpClaims.stShares, stSharesTotalSupply, Math.Rounding.Floor)
            );
    }

    /// @inheritdoc IRoycoDawnKernel
    function jtConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) public view virtual override(IRoycoDawnKernel, RoycoDawnKernel) returns (TRANCHE_UNIT) { }

    /// @inheritdoc IRoycoDuskKernel
    function jtConvertTrancheUnitsToLPClaims(TRANCHE_UNIT _jtAssets) public view virtual override(IRoycoDuskKernel) returns (LiquidityPositionClaims memory);

    /// @inheritdoc IRoycoDuskKernel
    function lpConvertQuoteAssetsToNAVUnits(QUOTE_UNIT _quoteAssets) public view virtual override(IRoycoDuskKernel) returns (NAV_UNIT);

    // =============================
    // Internal Tranche Accounting Synchronization Functions
    // =============================

    /// @inheritdoc RoycoDawnKernel
    function _previewSyncTrancheAccounting() internal view override(RoycoDawnKernel) whenNotPaused returns (SyncedAccountingState memory state) { }

    /// @inheritdoc RoycoDawnKernel
    function _preOpSyncTrancheAccounting() internal override(RoycoDawnKernel) returns (SyncedAccountingState memory state) {
        return super._preOpSyncTrancheAccounting();
    }

    /// @inheritdoc RoycoDawnKernel
    function _preOpSyncTrancheAccounting(TrancheType _trancheType)
        internal
        override(RoycoDawnKernel)
        returns (SyncedAccountingState memory state, AssetClaims memory claims, uint256 totalTrancheShares)
    {
        return super._preOpSyncTrancheAccounting(_trancheType);
    }

    /**
     * @notice Reconciles the distribution of ST shares in circulation (JT bought/owned and externally owned) and the recomposed tranche NAV checkpoint
     * @return recompositionRequired A boolean indicating whether a NAV checkpoint recomposition is required if the ST share distribution
     * @return newSTSharesEffectiveSupply The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     * @return checkpoint The cumulative asset claims that the specified tranche is entitled to
     */
    function _previewAccountingRecomposition()
        internal
        virtual
        returns (bool recompositionRequired, uint256 newSTSharesEffectiveSupply, AccountingStateCheckpoint memory checkpoint)
    {
        // Retrieve the senior tranche shares currently owned by the junior tranche and on the last accounting synchronization
        uint256 newJTOwnedSTShares = jtConvertTrancheUnitsToLPClaims(_getRoycoDawnKernelStorage().jtOwnedYieldBearingAssets).stShares;
        uint256 cachedJTOwnedSTShares = _getRoycoDuskKernelStorage().jtOwnedSTShares;
        // If the composition of ST owned shares hasn't moved, there is no accounting recomposition required
        if (newJTOwnedSTShares == cachedJTOwnedSTShares) return (false, 0, checkpoint);
        else recompositionRequired = true;

        // Get the total supply of senior tranche shares
        uint256 stSharesTotalSupply = IRoycoVaultTranche(SENIOR_TRANCHE).totalSupply();
        // Compute the current and last checkpointed effective senior tranche share supply (excludes shares owned by the junior tranche)
        newSTSharesEffectiveSupply = stSharesTotalSupply - newJTOwnedSTShares;
        // NOTE: The last ST share effective supply can never resolve to zero
        uint256 lastSTSharesEffectiveSupply = stSharesTotalSupply - cachedJTOwnedSTShares;

        // Retrieve the last accounting state checkpoint and apply the recomposition
        // The recomposition reconciles the distribution of underlying assets held by the senior and junior tranche assuming that swaps happened at par value
        checkpoint = IRoycoAccountant(ACCOUNTANT).getLastAccountingStateCheckpoint();
        // The senior tranche NAVs are scaled to reflect the ST shares that have been bought/sold by the senior tranche since the last accounting synchronization
        checkpoint.lastSTRawNAV = checkpoint.lastSTRawNAV.mulDiv(newSTSharesEffectiveSupply, lastSTSharesEffectiveSupply, Math.Rounding.Floor);
        checkpoint.lastSTEffectiveNAV = checkpoint.lastSTEffectiveNAV.mulDiv(newSTSharesEffectiveSupply, lastSTSharesEffectiveSupply, Math.Rounding.Floor);
        checkpoint.lastSTImpermanentLoss = checkpoint.lastSTImpermanentLoss.mulDiv(newSTSharesEffectiveSupply, lastSTSharesEffectiveSupply, Math.Rounding.Floor);

        // NOTE: The junior tranche raw NAV is left untouched, implying that any swaps occured at par value, allowing the accounting sync to handle any real economic PNL in the underlying asset and/or ST share trade execution
        // The junior tranche effective NAV is computed to preserve NAV conservation, the key accounting invariant
        checkpoint.lastJTEffectiveNAV = (checkpoint.lastSTRawNAV + checkpoint.lastJTRawNAV) - checkpoint.lastSTEffectiveNAV;
        checkpoint.lastJTImpermanentLoss = checkpoint.lastJTImpermanentLoss.mulDiv(newSTSharesEffectiveSupply, lastSTSharesEffectiveSupply, Math.Rounding.Floor);
    }

    // =============================
    // Internal Utility Functions
    // =============================

    /// @inheritdoc RoycoDawnKernel
    /// @dev Reconciles the ST assets owned by the effective supply of ST shares (excluding JT owned ST shares) and converts them to NAV units
    function _getSeniorTrancheRawNAV() internal view override(RoycoDawnKernel) returns (NAV_UNIT stRawNAV) {
        // Retrieve the senior tranche shares currently owned by the junior tranche
        uint256 jtOwnedSTShares = jtConvertTrancheUnitsToLPClaims(_getRoycoDawnKernelStorage().jtOwnedYieldBearingAssets).stShares;
        // Get the total supply of senior tranche shares and preemptively return if none exist
        uint256 stSharesTotalSupply = IRoycoVaultTranche(SENIOR_TRANCHE).totalSupply();
        if (stSharesTotalSupply == 0) return ZERO_NAV_UNITS;
        // Get the ST yield bearing assets owned by the current effective supply of ST shares and convert them to NAV units via the configured quoter
        uint256 stSharesEffectiveSupply = stSharesTotalSupply - jtOwnedSTShares;
        return stConvertTrancheUnitsToNAVUnits(
            _getRoycoDawnKernelStorage().stOwnedYieldBearingAssets.mulDiv(stSharesEffectiveSupply, stSharesTotalSupply, Math.Rounding.Floor)
        );
    }

    /// @inheritdoc RoycoDawnKernel
    /// @dev Reconciles the ST assets owned by JT owned ST shares and quote assets owned by the JT liquidity position and converts them to NAV units
    function _getJuniorTrancheRawNAV() internal view override(RoycoDawnKernel) returns (NAV_UNIT jtRawNAV) {
        return jtConvertTrancheUnitsToNAVUnits(_getRoycoDawnKernelStorage().jtOwnedYieldBearingAssets);
    }

    // =============================
    // Kernel State Accessor Functions
    // =============================

    /// @inheritdoc IRoycoDawnKernel
    function KERNEL_TYPE() external pure override(IRoycoDawnKernel, RoycoDawnKernel) returns (KernelType kernelType) {
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
