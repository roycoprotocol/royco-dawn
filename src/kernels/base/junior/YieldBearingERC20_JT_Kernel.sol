// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { ExecutionModel, IRoycoKernel, SharesRedemptionModel } from "../../../interfaces/kernel/IRoycoKernel.sol";
import { MAX_TRANCHE_UNITS } from "../../../libraries/Constants.sol";
import { RoycoKernelState, RoycoKernelStorageLib } from "../../../libraries/RoycoKernelStorageLib.sol";
import { AssetClaims, SyncedAccountingState } from "../../../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toUint256 } from "../../../libraries/Units.sol";
import { YieldBearingERC20KernelState, YieldBearingERC20KernelStorageLib } from "../../../libraries/kernels/YieldBearingERC20KernelStorageLib.sol";
import { RoycoKernel, TrancheType } from "../RoycoKernel.sol";

abstract contract YieldBearingERC20_JT_Kernel is RoycoKernel {
    using SafeERC20 for IERC20;

    /// @inheritdoc IRoycoKernel
    ExecutionModel public constant JT_DEPOSIT_EXECUTION_MODEL = ExecutionModel.SYNC;

    /// @notice Initializes a kernel where the junior tranche vault's deposit asset is a yield bearing ERC20 asset
    /// @dev The yield bearing asset must be rebasing in terms of price, not quantity
    function __YieldBearingERC20_JT_Kernel_init_unchained() internal onlyInitializing { }

    /// @inheritdoc IRoycoKernel
    function jtPreviewDeposit(TRANCHE_UNIT _assets) external view override returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated) {
        // Convert the yield bearing assets deposited to NAV units and preview a sync to get the current NAV to mint shares at for the junior tranche
        valueAllocated = jtConvertTrancheUnitsToNAVUnits(_assets);
        stateBeforeDeposit = _previewSyncTrancheAccounting();
    }

    /// @inheritdoc RoycoKernel
    function _getJuniorTrancheRawNAV() internal view override(RoycoKernel) returns (NAV_UNIT) {
        // Get the yield bearing assets owned by JT and convert them to NAV units via the configured quoter
        return jtConvertTrancheUnitsToNAVUnits(YieldBearingERC20KernelStorageLib._getYieldBearingERC20KernelStorage().jtOwnedYieldBearingAssets);
    }

    /// @inheritdoc RoycoKernel
    function _jtMaxDepositGlobally(address) internal view override(RoycoKernel) returns (TRANCHE_UNIT) {
        // No limit to how many yield bearing assets can be deposited into this kernel
        return MAX_TRANCHE_UNITS;
    }

    /// @inheritdoc RoycoKernel
    function _jtMaxWithdrawableGlobally(address) internal view override(RoycoKernel) returns (TRANCHE_UNIT) {
        // The max yield bearing assets that can be withdrawn is the number of assets owned by JT
        return YieldBearingERC20KernelStorageLib._getYieldBearingERC20KernelStorage().jtOwnedYieldBearingAssets;
    }

    /// @inheritdoc RoycoKernel
    function _jtPreviewWithdraw(TRANCHE_UNIT _jtAssets) internal view override(RoycoKernel) returns (TRANCHE_UNIT withdrawnSTAssets) {
        // No conversion between the assets being withdrawn and what will be withdrawn: the kernel simply transfers them out
        return _jtAssets;
    }

    /// @inheritdoc RoycoKernel
    function _jtDepositAssets(TRANCHE_UNIT _jtAssets) internal override(RoycoKernel) {
        // The tranche vault has already transfered the assets to the kernel, so simply credit those assets to the junior tranche
        YieldBearingERC20KernelState storage $ = YieldBearingERC20KernelStorageLib._getYieldBearingERC20KernelStorage();
        $.jtOwnedYieldBearingAssets = $.jtOwnedYieldBearingAssets + _jtAssets;
    }

    /// @inheritdoc RoycoKernel
    function _jtWithdrawAssets(TRANCHE_UNIT _jtAssets, address _receiver) internal override(RoycoKernel) {
        // Debit the yield bearing assets being withdrawn from the junior tranche
        YieldBearingERC20KernelState storage $ = YieldBearingERC20KernelStorageLib._getYieldBearingERC20KernelStorage();
        $.jtOwnedYieldBearingAssets = $.jtOwnedYieldBearingAssets - _jtAssets;

        // Transfer the yield bearing assets being withdrawn to the receiver
        address jtYieldBearingAsset = RoycoKernelStorageLib._getRoycoKernelStorage().jtAsset;
        IERC20(jtYieldBearingAsset).safeTransfer(_receiver, toUint256(_jtAssets));
    }
}
