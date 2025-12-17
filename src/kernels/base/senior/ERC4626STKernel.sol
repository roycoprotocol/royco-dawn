// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { IERC20, SafeERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { ExecutionModel, IRoycoKernel, RequestRedeemSharesBehavior } from "../../../interfaces/kernel/IRoycoKernel.sol";
import { ZERO_TRANCHE_UNITS } from "../../../libraries/Constants.sol";
import { TrancheAssetClaims } from "../../../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, UnitsMathLib, toTrancheUnits, toUint256 } from "../../../libraries/Units.sol";
import { UtilsLib } from "../../../libraries/UtilsLib.sol";
import { ERC4626STKernelStorageLib } from "../../../libraries/kernels/ERC4626STKernelStorageLib.sol";
import { Operation, RoycoKernel, TrancheType } from "../RoycoKernel.sol";

abstract contract ERC4626STKernel is RoycoKernel {
    using SafeERC20 for IERC20;
    using UnitsMathLib for TRANCHE_UNIT;

    /// @inheritdoc IRoycoKernel
    ExecutionModel public constant ST_INCREASE_NAV_EXECUTION_MODEL = ExecutionModel.SYNC;

    /// @inheritdoc IRoycoKernel
    ExecutionModel public constant ST_DECREASE_NAV_EXECUTION_MODEL = ExecutionModel.SYNC;

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
        ERC4626STKernelStorageLib.__ERC4626STKernel_init(_vault);
    }

    /// @inheritdoc IRoycoKernel
    function stPreviewDeposit(TRANCHE_UNIT _assets) external view override onlySeniorTranche returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintAt) {
        IERC4626 vault = IERC4626(ERC4626STKernelStorageLib._getERC4626STKernelStorage().vault);

        // Simulate the deposit of the assets into the underlying investment vault
        uint256 underlyingVaultSharesAllocated = vault.previewDeposit(toUint256(_assets));

        // Convert the underlying vault shares to tranche units. This value may differ from _assets if a fee is applied to the deposit.
        TRANCHE_UNIT allocatedInTrancheUnits = toTrancheUnits(vault.convertToAssets(underlyingVaultSharesAllocated));

        valueAllocated = _stConvertTrancheUnitsToNAVUnits(allocatedInTrancheUnits);
        navToMintAt = (_accountant().previewSyncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV())).stEffectiveNAV;
    }

    /// @inheritdoc IRoycoKernel
    function stDeposit(
        TRANCHE_UNIT _assets,
        address,
        address
    )
        external
        override(IRoycoKernel)
        onlySeniorTranche
        whenNotPaused
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintAt)
    {
        // Execute a pre-op sync on accounting
        navToMintAt = (_preOpSyncTrancheAccounting()).stEffectiveNAV;

        // Deposit the assets into the underlying investment vault
        IERC4626(ERC4626STKernelStorageLib._getERC4626STKernelStorage().vault).deposit(toUint256(_assets), address(this));

        // Execute a post-op sync on accounting and enforce the market's coverage requirement
        NAV_UNIT postDepositNAV = (_postOpSyncTrancheAccountingAndEnforceCoverage(Operation.ST_INCREASE_NAV)).stEffectiveNAV;
        valueAllocated = postDepositNAV - navToMintAt;
    }

    /// @inheritdoc IRoycoKernel
    function stPreviewRedeem(uint256 _shares) external view override onlySeniorTranche returns (TrancheAssetClaims memory userClaim) {
        // Get the total claim of ST on the ST and JT assets, and scale it to the number of shares being redeemed
        (, TrancheAssetClaims memory totalClaims, uint256 totalTrancheShares) = previewSyncTrancheAccounting(TrancheType.SENIOR);
        TrancheAssetClaims memory scaledClaims = UtilsLib.scaleTrancheAssetsClaim(totalClaims, _shares, totalTrancheShares);

        // Preview the amount of ST assets that would be redeemed for the given amount of shares
        userClaim.stAssets = _previewWithdrawSTAssets(scaledClaims.stAssets);
        userClaim.jtAssets = _previewWithdrawJTAssets(scaledClaims.jtAssets);
        userClaim.effectiveNAV = _stConvertTrancheUnitsToNAVUnits(userClaim.stAssets) + _jtConvertTrancheUnitsToNAVUnits(userClaim.jtAssets);
    }

    /// @inheritdoc IRoycoKernel
    function stRedeem(
        uint256 _shares,
        address,
        address _receiver
    )
        external
        override(IRoycoKernel)
        onlySeniorTranche
        whenNotPaused
        returns (TrancheAssetClaims memory claims)
    {
        // Execute a pre-op sync on accounting
        uint256 totalTrancheShares;
        (, claims, totalTrancheShares) = _preOpSyncTrancheAccounting(TrancheType.SENIOR);
        claims = UtilsLib.scaleTrancheAssetsClaim(claims, _shares, totalTrancheShares);

        // Withdraw the JT assets if non zero
        if (claims.jtAssets != ZERO_TRANCHE_UNITS) _withdrawJTAssets(claims.jtAssets, _receiver);

        // Withdraw the ST assets if non zero
        if (claims.stAssets != ZERO_TRANCHE_UNITS) _withdrawSTAssets(claims.stAssets, _receiver);

        // Execute a post-op sync on accounting
        _postOpSyncTrancheAccounting(Operation.ST_DECREASE_NAV);
    }

    /// @inheritdoc RoycoKernel
    function _getSeniorTrancheRawNAV() internal view override(RoycoKernel) returns (NAV_UNIT) {
        // Must use preview redeem for the tranche owned shares
        // Max withdraw will mistake illiquidity for NAV losses
        address vault = ERC4626STKernelStorageLib._getERC4626STKernelStorage().vault;
        uint256 trancheSharesBalance = IERC4626(vault).balanceOf(address(this));
        return _stConvertTrancheUnitsToNAVUnits(toTrancheUnits(IERC4626(vault).previewRedeem(trancheSharesBalance)));
    }

    /// @inheritdoc RoycoKernel
    function _maxSTDepositGlobally(address) internal view override(RoycoKernel) returns (TRANCHE_UNIT) {
        // Max deposit takes global withdrawal limits into account
        return toTrancheUnits(IERC4626(ERC4626STKernelStorageLib._getERC4626STKernelStorage().vault).maxDeposit(address(this)));
    }

    /// @inheritdoc RoycoKernel
    function _maxSTWithdrawalGlobally(address) internal view override(RoycoKernel) returns (TRANCHE_UNIT) {
        // Max withdraw takes global withdrawal limits into account
        return toTrancheUnits(IERC4626(ERC4626STKernelStorageLib._getERC4626STKernelStorage().vault).maxWithdraw(address(this)));
    }

    /// @inheritdoc RoycoKernel
    function _withdrawSTAssets(TRANCHE_UNIT _stAssets, address _receiver) internal override(RoycoKernel) {
        IERC4626(ERC4626STKernelStorageLib._getERC4626STKernelStorage().vault).withdraw(toUint256(_stAssets), _receiver, address(this));
    }

    /// @inheritdoc RoycoKernel
    function _previewWithdrawSTAssets(TRANCHE_UNIT _stAssets) internal view override(RoycoKernel) returns (TRANCHE_UNIT redeemedSTAssets) {
        IERC4626 vault = IERC4626(ERC4626STKernelStorageLib._getERC4626STKernelStorage().vault);

        // Convert the ST assets to underlying shares
        uint256 underlyingShares = vault.convertToShares(toUint256(_stAssets));

        // Preview the amount of ST assets that would be redeemed for the given amount of underlying shares
        redeemedSTAssets = toTrancheUnits(vault.previewRedeem(underlyingShares));
    }
}
