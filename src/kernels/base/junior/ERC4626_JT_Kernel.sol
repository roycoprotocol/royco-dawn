// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { IERC20, SafeERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { ExecutionModel, IRoycoKernel } from "../../../interfaces/kernel/IRoycoKernel.sol";
import { SyncedAccountingState } from "../../../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, UnitsMathLib, toTrancheUnits, toUint256 } from "../../../libraries/Units.sol";
import { ERC4626KernelState, ERC4626KernelStorageLib } from "../../../libraries/kernels/ERC4626KernelStorageLib.sol";
import { RoycoKernel } from "../RoycoKernel.sol";

abstract contract ERC4626_JT_Kernel is RoycoKernel {
    using SafeERC20 for IERC20;
    using UnitsMathLib for TRANCHE_UNIT;

    /// @inheritdoc IRoycoKernel
    ExecutionModel public constant JT_DEPOSIT_EXECUTION_MODEL = ExecutionModel.SYNC;

    /// @notice Thrown when the JT base asset is different the the ERC4626 vault's base asset
    error JUNIOR_TRANCHE_AND_VAULT_ASSET_MISMATCH();

    /**
     * @notice Initializes a kernel where the junior tranche is deployed into an ERC4626 vault
     * @param _jtVault The address of the ERC4626 compliant vault the junior tranche will deploy into
     * @param _jtAsset The address of the base asset of the junior tranche
     */
    function __ERC4626_JT_Kernel_init_unchained(address _jtVault, address _jtAsset) internal onlyInitializing {
        // Ensure that the ST base asset is identical to the ERC4626 vault's base asset
        require(IERC4626(_jtVault).asset() == _jtAsset, JUNIOR_TRANCHE_AND_VAULT_ASSET_MISMATCH());

        // Extend a one time max approval to the ERC4626 vault for the JT's base asset
        IERC20(_jtAsset).forceApprove(address(_jtVault), type(uint256).max);

        // Initialize the ERC4626 JT kernel storage
        ERC4626KernelStorageLib._getERC4626KernelStorage().jtVault = _jtVault;
    }

    /// @inheritdoc IRoycoKernel
    function jtPreviewDeposit(TRANCHE_UNIT _assets) external view override returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated) {
        IERC4626 jtVault = IERC4626(ERC4626KernelStorageLib._getERC4626KernelStorage().jtVault);

        // Simulate the deposit of the assets into the underlying investment vault
        uint256 jtVaultSharesMinted = jtVault.previewDeposit(toUint256(_assets));

        // Convert the underlying vault shares to tranche units. This value may differ from _assets if a fee or slippage is incurred to the deposit.
        TRANCHE_UNIT jtAssetsAllocated = toTrancheUnits(jtVault.convertToAssets(jtVaultSharesMinted));

        // Convert the assets allocated to NAV units and preview a sync to get the current NAV to mint shares at for the junior tranche
        valueAllocated = jtConvertTrancheUnitsToNAVUnits(jtAssetsAllocated);
        stateBeforeDeposit = _previewSyncTrancheAccounting();
    }

    /// @inheritdoc RoycoKernel
    function _getJuniorTrancheRawNAV() internal view override(RoycoKernel) returns (NAV_UNIT) {
        ERC4626KernelState storage $ = ERC4626KernelStorageLib._getERC4626KernelStorage();
        // Must use convert to assets for the tranche owned shares in order to be exclusive of any fixed fees on withdrawal
        // Cannot use max withdraw since it will treat illiquidity as a NAV loss
        TRANCHE_UNIT jtOwnedAssets = toTrancheUnits(IERC4626($.jtVault).convertToAssets($.jtOwnedShares));
        return jtConvertTrancheUnitsToNAVUnits(jtOwnedAssets);
    }

    /// @inheritdoc RoycoKernel
    function _jtMaxDepositGlobally(address) internal view override(RoycoKernel) returns (TRANCHE_UNIT) {
        // Max deposit takes global withdrawal limits into account
        return toTrancheUnits(IERC4626(ERC4626KernelStorageLib._getERC4626KernelStorage().jtVault).maxDeposit(address(this)));
    }

    /// @inheritdoc RoycoKernel
    function _jtMaxWithdrawableGlobally(address) internal view override(RoycoKernel) returns (TRANCHE_UNIT) {
        // Max withdraw takes global withdrawal limits into account
        return toTrancheUnits(IERC4626(ERC4626KernelStorageLib._getERC4626KernelStorage().jtVault).maxWithdraw(address(this)));
    }

    /// @inheritdoc RoycoKernel
    function _jtPreviewWithdraw(TRANCHE_UNIT _jtAssets) internal view override(RoycoKernel) returns (TRANCHE_UNIT withdrawnJTAssets) {
        IERC4626 jtVault = IERC4626(ERC4626KernelStorageLib._getERC4626KernelStorage().jtVault);
        // Convert the ST assets to underlying shares
        uint256 jtVaultShares = jtVault.convertToShares(toUint256(_jtAssets));
        // Preview the amount of ST assets that would be redeemed for the given amount of underlying shares
        withdrawnJTAssets = toTrancheUnits(jtVault.previewRedeem(jtVaultShares));
    }

    /// @inheritdoc RoycoKernel
    function _jtDepositAssets(TRANCHE_UNIT _jtAssets) internal override(RoycoKernel) {
        // Deposit the assets into the underlying investment vault and add to the number of ST controlled shares for this vault
        ERC4626KernelState storage $ = ERC4626KernelStorageLib._getERC4626KernelStorage();
        $.jtOwnedShares += IERC4626($.jtVault).deposit(toUint256(_jtAssets), address(this));
    }

    /// @inheritdoc RoycoKernel
    function _jtWithdrawAssets(TRANCHE_UNIT _jtAssets, address _receiver) internal override(RoycoKernel) {
        ERC4626KernelState storage $ = ERC4626KernelStorageLib._getERC4626KernelStorage();
        IERC4626 jtVault = IERC4626($.jtVault);
        // Get the currently withdrawable liquidity from the vault
        TRANCHE_UNIT maxWithdrawableAssets = toTrancheUnits(jtVault.maxWithdraw(address(this)));
        // If the vault has sufficient liquidity to withdraw the specified assets, do so
        if (maxWithdrawableAssets >= _jtAssets) {
            $.jtOwnedShares -= jtVault.withdraw(toUint256(_jtAssets), _receiver, address(this));
            // If the vault has insufficient liquidity to withdraw the specified assets, transfer the equivalent number of shares to the receiver
        } else {
            // Transfer the assets equivalent of shares to the receiver
            uint256 sharesEquivalentToWithdraw = jtVault.convertToShares(toUint256(_jtAssets));
            $.jtOwnedShares -= sharesEquivalentToWithdraw;
            IERC20(address(jtVault)).safeTransfer(_receiver, sharesEquivalentToWithdraw);
        }
    }
}
