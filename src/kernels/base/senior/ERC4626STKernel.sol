// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { IERC20, SafeERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { ExecutionModel, IRoycoKernel } from "../../../interfaces/kernel/IRoycoKernel.sol";
import { RoycoKernelState, RoycoKernelStorageLib } from "../../../libraries/RoycoKernelStorageLib.sol";
import { RequestRedeemSharesBehavior } from "../../../libraries/Types.sol";
import { ERC4626STKernelStorageLib } from "../../../libraries/kernels/ERC4626STKernelStorageLib.sol";
import { Operation, RoycoKernel, SyncedNAVsPacket } from "../RoycoKernel.sol";

abstract contract ERC4626STKernel is RoycoKernel {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @inheritdoc IRoycoKernel
    ExecutionModel public constant ST_DEPOSIT_EXECUTION_MODEL = ExecutionModel.SYNC;

    /// @inheritdoc IRoycoKernel
    ExecutionModel public constant ST_WITHDRAWAL_EXECUTION_MODEL = ExecutionModel.SYNC;

    /// @inheritdoc IRoycoKernel
    RequestRedeemSharesBehavior public constant ST_REQUEST_REDEEM_SHARES_BEHAVIOR = RequestRedeemSharesBehavior.BURN_ON_REDEEM;

    /// @notice Thrown when the ST base asset is different the the ERC4626 vault's base asset
    error TRANCHE_AND_VAULT_ASSET_MISMATCH();

    /**
     * @notice Initializes a kernel where the senior tranche is deployed into an ERC4626 vault
     * @dev Mandates that the base kernel state is already initialized
     * @param _vault The address of the ERC4626 compliant vault
     * @param _stAsset The address of the base asset of the senior tranche
     */
    function __ERC4626STKernel_init_unchained(address _vault, address _stAsset) internal onlyInitializing {
        // Ensure that the ST base asset is identical to the ERC4626 vault's base asset
        require(IERC4626(_vault).asset() == _stAsset, TRANCHE_AND_VAULT_ASSET_MISMATCH());

        // Extend a one time max approval to the ERC4626 vault for the ST's base asset
        IERC20(_stAsset).forceApprove(address(_vault), type(uint256).max);

        // Initialize the ERC4626 ST kernel storage
        ERC4626STKernelStorageLib.__ERC4626STKernel_init(_vault, _stAsset);
    }

    /// @inheritdoc IRoycoKernel
    function getSTTotalEffectiveAssets() external view override(IRoycoKernel) returns (uint256) {
        return previewSyncTrancheNAVs().stEffectiveNAV;
    }

    /// @inheritdoc IRoycoKernel
    function stDeposit(
        address,
        uint256 _assets,
        address,
        address
    )
        external
        override(IRoycoKernel)
        onlySeniorTranche
        whenNotPaused
        returns (uint256 valueAllocated, uint256 effectiveNAVToMintAt)
    {
        // The effective NAV to mint at is the effective NAV of the tranche before the deposit is made, ie. the NAV at which the shares will be minted
        // This is the NAV returned by the pre-op sync
        effectiveNAVToMintAt = (_preOpSyncTrancheNAVs()).stEffectiveNAV;

        // Deposit the assets into the underlying investment vault
        IERC4626(ERC4626STKernelStorageLib._getERC4626STKernelStorage().vault).deposit(_assets, address(this));

        // The value of the assets deposited is the value of the assets in the asset that the tranche's NAV is denominated in
        valueAllocated = _convertAssetsToValue(_assets);

        // Execute a post-op sync on NAV accounting and enforce the market's coverage requirement
        _postOpSyncTrancheNAVsAndEnforceCoverage(Operation.ST_DEPOSIT);
    }

    /// @inheritdoc IRoycoKernel
    function stRedeem(
        address _asset,
        uint256 _shares,
        uint256 _totalShares,
        address,
        address _receiver
    )
        external
        override(IRoycoKernel)
        onlySeniorTranche
        whenNotPaused
        returns (uint256 assetsWithdrawn)
    {
        // Execute a pre-op sync on NAV accounting
        SyncedNAVsPacket memory packet = _preOpSyncTrancheNAVs();

        // Compute the assets expected to be received on withdrawal based on the ST's effective NAV
        assetsWithdrawn = _shares.mulDiv(packet.stEffectiveNAV, _totalShares, Math.Rounding.Floor);

        // ST's coverage debt post-sync is the total applied coverage by JT to ST
        uint256 totalAppliedCoverage = packet.stCoverageDebt;
        // Compute and claim the assets that need to pulled from JT for this withdrawal, rounding in favor of ST
        uint256 jtAssetsToWithdraw = Math.min(_shares.mulDiv(totalAppliedCoverage, _totalShares, Math.Rounding.Ceil), totalAppliedCoverage);
        if (jtAssetsToWithdraw != 0) _claimSeniorAssetsFromJunior(_asset, jtAssetsToWithdraw, _receiver);

        // Facilitate the remainder of the withdrawal from ST exposure
        // TODO: Should we use redeem flow instead since some vaults disable withdrawal flows?
        IERC4626(ERC4626STKernelStorageLib._getERC4626STKernelStorage().vault).withdraw((assetsWithdrawn - jtAssetsToWithdraw), _receiver, address(this));

        // Execute a post-op sync on NAV accounting
        _postOpSyncTrancheNAVs(Operation.ST_WITHDRAW);
    }

    /**
     * @notice Converts the amount of assets to the value of the assets in the asset that the tranche's NAV is denominated in
     * @dev This implementation assumes that the NAV is denominated in the same asset as the assets being deposited
     * @param _assets The amount of assets to convert
     * @return value The value of the assets in the asset that the tranche's NAV is denominated in
     */
    function _convertAssetsToValue(uint256 _assets) internal view virtual returns (uint256 value) {
        return _assets;
    }

    /// @inheritdoc RoycoKernel
    function _claimJuniorAssetsFromSenior(address, uint256 _assets, address _receiver) internal override(RoycoKernel) {
        IERC4626(ERC4626STKernelStorageLib._getERC4626STKernelStorage().vault).withdraw(_assets, _receiver, address(this));
    }

    /// @inheritdoc RoycoKernel
    function _getSeniorTrancheRawNAV() internal view override(RoycoKernel) returns (uint256) {
        // Must use preview redeem for the tranche owned shares
        // Max withdraw will mistake illiquidity for NAV losses
        address vault = ERC4626STKernelStorageLib._getERC4626STKernelStorage().vault;
        uint256 trancheSharesBalance = IERC4626(vault).balanceOf(address(this));
        return IERC4626(vault).previewRedeem(trancheSharesBalance);
    }

    /// @inheritdoc RoycoKernel
    function _maxSTDepositGlobally(address) internal view override(RoycoKernel) returns (uint256) {
        // Max deposit takes global withdrawal limits into account
        return IERC4626(ERC4626STKernelStorageLib._getERC4626STKernelStorage().vault).maxDeposit(address(this));
    }

    /// @inheritdoc RoycoKernel
    function _maxSTWithdrawalGlobally(address) internal view override(RoycoKernel) returns (uint256) {
        // Max withdraw takes global withdrawal limits into account
        return IERC4626(ERC4626STKernelStorageLib._getERC4626STKernelStorage().vault).maxWithdraw(address(this));
    }
}
