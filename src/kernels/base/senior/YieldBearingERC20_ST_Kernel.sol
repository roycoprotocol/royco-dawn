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

abstract contract YieldBearingERC20_ST_Kernel is RoycoKernel {
    using SafeERC20 for IERC20;

    /// @inheritdoc IRoycoKernel
    ExecutionModel public constant ST_DEPOSIT_EXECUTION_MODEL = ExecutionModel.SYNC;

    /// @inheritdoc IRoycoKernel
    ExecutionModel public constant ST_REDEEM_EXECUTION_MODEL = ExecutionModel.SYNC;

    /// @inheritdoc IRoycoKernel
    SharesRedemptionModel public constant ST_REQUEST_REDEEM_SHARES_BEHAVIOR = SharesRedemptionModel.BURN_ON_CLAIM_REDEEM;

    /// @notice Initializes a kernel where the senior tranche vault's deposit asset is a yield bearing ERC20 asset
    /// @dev The yield bearing asset must be rebasing in terms of price, not quantity
    function __YieldBearingERC20_ST_Kernel_init_unchained() internal onlyInitializing { }

    /// @inheritdoc IRoycoKernel
    function stPreviewDeposit(TRANCHE_UNIT _assets) external view override returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated) {
        // Convert the yield bearing assets deposited to NAV units and preview a sync to get the current NAV to mint shares at for the senior tranche
        valueAllocated = stConvertTrancheUnitsToNAVUnits(_assets);
        stateBeforeDeposit = _previewSyncTrancheAccounting();
    }

    /// @inheritdoc IRoycoKernel
    function stPreviewRedeem(uint256 _shares) external view override returns (AssetClaims memory userClaim) {
        userClaim = _previewRedeem(_shares, TrancheType.SENIOR);
    }

    /// @inheritdoc RoycoKernel
    function _getSeniorTrancheRawNAV() internal view override(RoycoKernel) returns (NAV_UNIT) {
        // Get the yield bearing assets owned by ST and convert them to NAV units via the configured quoter
        return stConvertTrancheUnitsToNAVUnits(YieldBearingERC20KernelStorageLib._getYieldBearingERC20KernelStorage().stOwnedYieldBearingAssets);
    }

    /// @inheritdoc RoycoKernel
    function _stMaxDepositGlobally(address) internal view override(RoycoKernel) returns (TRANCHE_UNIT) {
        // No limit to how many yield bearing assets can be deposited into this kernel
        return MAX_TRANCHE_UNITS;
    }

    /// @inheritdoc RoycoKernel
    function _stMaxWithdrawableGlobally(address) internal view override(RoycoKernel) returns (TRANCHE_UNIT) {
        // The max yield bearing assets that can be withdrawn is the number of assets owned by ST
        return YieldBearingERC20KernelStorageLib._getYieldBearingERC20KernelStorage().stOwnedYieldBearingAssets;
    }

    /// @inheritdoc RoycoKernel
    function _stPreviewWithdraw(TRANCHE_UNIT _stAssets) internal view override(RoycoKernel) returns (TRANCHE_UNIT withdrawnSTAssets) {
        // No conversion between the assets being withdrawn and what will be withdrawn: the kernel simply transfers them out
        return _stAssets;
    }

    /// @inheritdoc RoycoKernel
    function _stDepositAssets(TRANCHE_UNIT _stAssets) internal override(RoycoKernel) {
        // The tranche vault has already transfered the assets to the kernel, so simply credit those assets to the senior tranche
        YieldBearingERC20KernelState storage $ = YieldBearingERC20KernelStorageLib._getYieldBearingERC20KernelStorage();
        $.stOwnedYieldBearingAssets = $.stOwnedYieldBearingAssets + _stAssets;
    }

    /// @inheritdoc RoycoKernel
    function _stWithdrawAssets(TRANCHE_UNIT _stAssets, address _receiver) internal override(RoycoKernel) {
        // Debit the yield bearing assets being withdrawn from the senior tranche
        YieldBearingERC20KernelState storage $ = YieldBearingERC20KernelStorageLib._getYieldBearingERC20KernelStorage();
        $.stOwnedYieldBearingAssets = $.stOwnedYieldBearingAssets - _stAssets;

        // Transfer the yield bearing assets being withdrawn to the receiver
        address stYieldBearingAsset = RoycoKernelStorageLib._getRoycoKernelStorage().stAsset;
        IERC20(stYieldBearingAsset).safeTransfer(_receiver, toUint256(_stAssets));
    }
}
