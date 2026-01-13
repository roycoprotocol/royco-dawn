// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoVaultTranche } from "../interfaces/tranche/IRoycoVaultTranche.sol";
import { RoycoKernelInitParams } from "../libraries/RoycoKernelStorageLib.sol";
import { Math, NAV_UNIT, TRANCHE_UNIT, UnitsMathLib } from "../libraries/Units.sol";
import { ERC4626KernelState, ERC4626KernelStorageLib } from "../libraries/kernels/ERC4626KernelStorageLib.sol";
import { AssetClaims, IRoycoKernel, RoycoKernel, SyncedAccountingState, TrancheType, ZERO_NAV_UNITS } from "./base/RoycoKernel.sol";
import { ERC4626_JT_Kernel } from "./base/junior/ERC4626_JT_Kernel.sol";
import { InKindAssetsQuoter } from "./base/quoter/InKindAssetsQuoter.sol";
import { ERC4626_ST_Kernel } from "./base/senior/ERC4626_ST_Kernel.sol";

/**
 * @title ERC4626_ST_ERC4626_JT_InKindAssets_Kernel
 * @notice The senior and junior tranches are deployed into a ERC4626 compliant vault
 * @notice The two tranches can be deployed into the same ERC4626 compliant vault
 * @notice The tranche assets are identical in value and can have differing precisions (eg. USDC and USDS, USDT and USDE, etc.)
 * @notice NAV units are always expressed in tranche units scaled to WAD (18 decimals) precision
 */
contract ERC4626_ST_ERC4626_JT_InKindAssets_Kernel is ERC4626_ST_Kernel, ERC4626_JT_Kernel, InKindAssetsQuoter {
    using UnitsMathLib for TRANCHE_UNIT;

    /**
     * @notice Initializes the Royco Kernel
     * @param _stVault The ERC4626 compliant vault that the senior tranche will deploy into
     * @param _jtVault The ERC4626 compliant vault that the junior tranche will deploy into
     */
    function initialize(RoycoKernelInitParams calldata _params, address _stVault, address _jtVault) external initializer {
        // Get the base assets for both tranches and ensure that they are identical
        address stAsset = IRoycoVaultTranche(_params.seniorTranche).asset();
        address jtAsset = IRoycoVaultTranche(_params.juniorTranche).asset();

        // Initialize the base kernel state
        __RoycoKernel_init(_params, stAsset, jtAsset);
        // Initialize the ERC4626 senior tranche state
        __ERC4626_ST_Kernel_init_unchained(_stVault, stAsset);
        // Initialize the ERC4626 junior tranche state
        __ERC4626_JT_Kernel_init_unchained(_jtVault, jtAsset);
        // Initialize the in kind assets quoter
        __InKindAssetsQuoter_init_unchained(stAsset, jtAsset);
    }

    /// @inheritdoc IRoycoKernel
    /// @dev Override this function to prevent double counting of max withdrawable assets when both tranches deploy into the same ERC4626 vault
    function stMaxWithdrawable(address _owner)
        public
        view
        override(RoycoKernel)
        returns (NAV_UNIT claimOnStNAV, NAV_UNIT claimOnJtNAV, NAV_UNIT stMaxWithdrawableNAV, NAV_UNIT jtMaxWithdrawableNAV)
    {
        ERC4626KernelState storage $ = ERC4626KernelStorageLib._getERC4626KernelStorage();
        // If both tranches are in different ERC4626 vaults, double counting is not possible
        if ($.stVault != $.jtVault) return super.stMaxWithdrawable(_owner);

        // Get the total claims the senior tranche has on each tranche's assets
        (, AssetClaims memory stNotionalClaims,) = previewSyncTrancheAccounting(TrancheType.SENIOR);
        NAV_UNIT stTotalClaimsNAV = stNotionalClaims.nav;
        if (stTotalClaimsNAV == ZERO_NAV_UNITS) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS);
        claimOnStNAV = stConvertTrancheUnitsToNAVUnits(stNotionalClaims.stAssets);
        claimOnJtNAV = jtConvertTrancheUnitsToNAVUnits(stNotionalClaims.jtAssets);

        // Get the maximum withdrawable assets for both tranches combined
        // Scale the max withdrawable assets by the percentage claims ST has on each tranche
        TRANCHE_UNIT totalMaxWithdrawableAssets = _stMaxWithdrawableGlobally(_owner);
        stMaxWithdrawableNAV = stConvertTrancheUnitsToNAVUnits(totalMaxWithdrawableAssets.mulDiv(claimOnStNAV, stTotalClaimsNAV, Math.Rounding.Floor));
        jtMaxWithdrawableNAV = jtConvertTrancheUnitsToNAVUnits(totalMaxWithdrawableAssets.mulDiv(claimOnJtNAV, stTotalClaimsNAV, Math.Rounding.Floor));
    }

    /// @inheritdoc IRoycoKernel
    /// @dev Override this function to prevent double counting of max withdrawable assets when both tranches deploy into the same ERC4626 vault
    function jtMaxWithdrawable(address _owner)
        public
        view
        virtual
        override(RoycoKernel)
        returns (NAV_UNIT claimOnStNAV, NAV_UNIT claimOnJtNAV, NAV_UNIT stMaxWithdrawableNAV, NAV_UNIT jtMaxWithdrawableNAV)
    {
        ERC4626KernelState storage $ = ERC4626KernelStorageLib._getERC4626KernelStorage();
        // If both tranches are in different ERC4626 vaults, double counting is not possible
        if ($.stVault != $.jtVault) return super.jtMaxWithdrawable(_owner);

        // Get the total claims the junior tranche has on each tranche's assets
        (SyncedAccountingState memory state, AssetClaims memory jtNotionalClaims,) = previewSyncTrancheAccounting(TrancheType.JUNIOR);
        NAV_UNIT jtTotalClaimsNAV = jtNotionalClaims.nav;
        if (jtTotalClaimsNAV == ZERO_NAV_UNITS) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS);

        // Get the max withdrawable ST and JT assets in NAV units from the accountant consider coverage requirement
        (, NAV_UNIT stClaimableGivenCoverage, NAV_UNIT jtClaimableGivenCoverage) = _accountant()
            .maxJTWithdrawalGivenCoverage(
                state.stRawNAV,
                state.jtRawNAV,
                stConvertTrancheUnitsToNAVUnits(jtNotionalClaims.stAssets),
                jtConvertTrancheUnitsToNAVUnits(jtNotionalClaims.jtAssets)
            );

        claimOnStNAV = stConvertTrancheUnitsToNAVUnits(jtNotionalClaims.stAssets);
        claimOnJtNAV = jtConvertTrancheUnitsToNAVUnits(jtNotionalClaims.jtAssets);

        // Get the maximum withdrawable assets for both tranches combined
        // Scale the max withdrawable assets by the percentage claims JT has on each tranche
        TRANCHE_UNIT totalMaxWithdrawableAssets = _jtMaxWithdrawableGlobally(_owner);
        stMaxWithdrawableNAV = UnitsMathLib.min(
            stConvertTrancheUnitsToNAVUnits(totalMaxWithdrawableAssets.mulDiv(claimOnStNAV, jtTotalClaimsNAV, Math.Rounding.Floor)), stClaimableGivenCoverage
        );
        jtMaxWithdrawableNAV = UnitsMathLib.min(
            jtConvertTrancheUnitsToNAVUnits(totalMaxWithdrawableAssets.mulDiv(claimOnJtNAV, jtTotalClaimsNAV, Math.Rounding.Floor)), jtClaimableGivenCoverage
        );
    }
}
