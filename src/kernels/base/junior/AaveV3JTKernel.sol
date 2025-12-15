// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IPool } from "../../../interfaces/aave/IPool.sol";
import { IPoolAddressesProvider } from "../../../interfaces/aave/IPoolAddressesProvider.sol";
import { IPoolDataProvider } from "../../../interfaces/aave/IPoolDataProvider.sol";
import { ExecutionModel, IRoycoKernel } from "../../../interfaces/kernel/IRoycoKernel.sol";
import { AaveV3KernelState, AaveV3KernelStorageLib } from "../../../libraries/kernels/AaveV3KernelStorageLib.sol";
import { Operation, RoycoKernel, SyncedNAVsPacket } from "../RoycoKernel.sol";
import { BaseAsyncJTRedemptionDelayKernel } from "./BaseAsyncJTRedemptionDelayKernel.sol";

abstract contract AaveV3JTKernel is RoycoKernel, BaseAsyncJTRedemptionDelayKernel {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @inheritdoc IRoycoKernel
    ExecutionModel public constant JT_DEPOSIT_EXECUTION_MODEL = ExecutionModel.SYNC;

    /// @inheritdoc IRoycoKernel
    ExecutionModel public constant JT_WITHDRAWAL_EXECUTION_MODEL = ExecutionModel.ASYNC;

    /// @notice Thrown when the JT base asset is not a supported reserve token in the Aave V3 Pool
    error UNSUPPORTED_RESERVE_TOKEN();
    /// @notice Thrown when the shares to redeem are greater than the claimable shares
    error INSUFFICIENT_CLAIMABLE_SHARES(uint256 sharesToRedeem, uint256 claimableShares);

    /**
     * @notice Initializes a kernel where the junior tranche is deployed into Aave V3
     * @dev Mandates that the base kernel state is already initialized
     * @param _aaveV3Pool The address of the Aave V3 Pool
     * @param _jtAsset The address of the base asset of the junior tranche
     */
    function __AaveV3JTKernel_init_unchained(address _aaveV3Pool, address _jtAsset) internal onlyInitializing {
        // Ensure that the JT base asset is a supported reserve token in the Aave V3 Pool
        address jtAssetAToken = IPool(_aaveV3Pool).getReserveAToken(_jtAsset);
        require(jtAssetAToken != address(0), UNSUPPORTED_RESERVE_TOKEN());

        // Extend a one time max approval to the Aave V3 pool for the JT's base asset
        IERC20(_jtAsset).forceApprove(_aaveV3Pool, type(uint256).max);

        // Initialize the Aave V3 kernel storage
        AaveV3KernelStorageLib.__AaveV3Kernel_init(_aaveV3Pool, address(IPool(_aaveV3Pool).ADDRESSES_PROVIDER()), _jtAsset, jtAssetAToken);
    }

    /// @inheritdoc IRoycoKernel
    function getJTTotalEffectiveAssets() external view override(IRoycoKernel) returns (uint256) {
        return previewSyncTrancheNAVs().jtEffectiveNAV;
    }

    /// @inheritdoc IRoycoKernel
    function jtDeposit(
        address _asset,
        uint256 _assets,
        address,
        address
    )
        external
        override(IRoycoKernel)
        onlyJuniorTranche
        whenNotPaused
        returns (uint256 valueAllocated, uint256 effectiveNAVToMintAt)
    {
        // Execute a pre-op sync on NAV accounting
        valueAllocated = _assets;
        effectiveNAVToMintAt = (_preOpSyncTrancheNAVs()).stEffectiveNAV;

        // Max approval already given to the pool on initialization
        IPool(AaveV3KernelStorageLib._getAaveV3KernelStorage().pool).supply(_asset, _assets, address(this), 0);

        // Execute a post-op sync on NAV accounting
        _postOpSyncTrancheNAVs(Operation.JT_DEPOSIT);
    }

    /// @inheritdoc IRoycoKernel
    function jtRedeem(
        address _asset,
        uint256 _shares,
        uint256 _totalShares,
        address _controller,
        address _receiver
    )
        external
        override(IRoycoKernel)
        onlyJuniorTranche
        returns (uint256 assetsWithdrawn)
    {
        SyncedNAVsPacket memory packet = _preOpSyncTrancheNAVs();
        require(_shares <= _jtClaimableRedeemRequest(_controller), INSUFFICIENT_CLAIMABLE_SHARES(_shares, _jtClaimableRedeemRequest(_controller)));
        // Calculate the value of the shares to claim and update the controller's redemption request
        assetsWithdrawn = _processClaimableRedeemRequest(_controller, packet.jtEffectiveNAV, _shares, _totalShares);

        // The difference between the JT effective NAV and raw NAV is the amount of assets it is owed from ST raw NAV
        uint256 totalJTClaimOnSTAssets = Math.saturatingSub(packet.jtEffectiveNAV, packet.jtRawNAV);
        // Compute and claim the assets that need to be pulled from ST for this withdrawal, rounding in favor of the senior tranche
        uint256 stAssetsToWithdraw = _shares.mulDiv(totalJTClaimOnSTAssets, _totalShares, Math.Rounding.Floor);
        if (stAssetsToWithdraw != 0) _claimJuniorAssetsFromSenior(_asset, stAssetsToWithdraw, _receiver);

        // Facilitate the remainder of the withdrawal from JT exposure
        IPool(AaveV3KernelStorageLib._getAaveV3KernelStorage().pool).withdraw(_asset, (assetsWithdrawn - stAssetsToWithdraw), _receiver);

        // Execute a post-op sync on NAV accounting and enforce the market's coverage requirement
        _postOpSyncTrancheNAVsAndEnforceCoverage(Operation.JT_WITHDRAW);
    }

    /// @inheritdoc RoycoKernel
    function _claimSeniorAssetsFromJunior(address _asset, uint256 _assets, address _receiver) internal override(RoycoKernel) {
        IPool(AaveV3KernelStorageLib._getAaveV3KernelStorage().pool).withdraw(_asset, _assets, _receiver);
    }

    /// @inheritdoc RoycoKernel
    function _getJuniorTrancheRawNAV() internal view override(RoycoKernel) returns (uint256) {
        // The tranche's balance of the AToken is the total assets it is owed from the Aave pool
        /// @dev This does not treat illiquidity in the Aave pool as a loss: we assume that total lent will be withdrawable at some point
        AaveV3KernelState storage $ = AaveV3KernelStorageLib._getAaveV3KernelStorage();
        return IERC20($.aToken).balanceOf(address(this));
    }

    /// @inheritdoc RoycoKernel
    function _maxJTDepositGlobally(address) internal view override(RoycoKernel) returns (uint256) {
        // Retrieve the Pool's data provider and asset
        AaveV3KernelState storage $ = AaveV3KernelStorageLib._getAaveV3KernelStorage();
        IPoolDataProvider poolDataProvider = IPoolDataProvider(IPoolAddressesProvider($.poolAddressesProvider).getPoolDataProvider());
        address asset = $.asset;

        // If the reserve asset is inactive, frozen, or paused, supplies are forbidden
        (uint256 decimals,,,,,,,, bool isActive, bool isFrozen) = poolDataProvider.getReserveConfigurationData(asset);
        if (!isActive || isFrozen || poolDataProvider.getPaused(asset)) return 0;

        // Get the supply cap for the reserve asset. If unset, the suppliable amount is unbounded
        (, uint256 supplyCap) = poolDataProvider.getReserveCaps(asset);
        if (supplyCap == 0) return type(uint256).max;

        // Compute the total reserve assets supplied and accrued to the treasury
        (, uint256 totalAccruedToTreasury, uint256 totalLent,,,,,,,,,) = poolDataProvider.getReserveData(asset);
        uint256 currentlySupplied = totalLent + totalAccruedToTreasury;
        // Supply cap was returned as whole tokens, so we must scale by underlying decimals
        supplyCap = supplyCap * (10 ** decimals);

        // If supply cap hit, no incremental supplies are permitted. Else, return the max suppliable amount within the cap.
        return (currentlySupplied >= supplyCap) ? 0 : (supplyCap - currentlySupplied);
    }

    /// @inheritdoc RoycoKernel
    function _maxJTWithdrawalGlobally(address) internal view override(RoycoKernel) returns (uint256) {
        // Retrieve the Pool's data provider and asset
        AaveV3KernelState storage $ = AaveV3KernelStorageLib._getAaveV3KernelStorage();
        IPoolDataProvider poolDataProvider = IPoolDataProvider(IPoolAddressesProvider($.poolAddressesProvider).getPoolDataProvider());
        address asset = $.asset;

        // If the reserve asset is inactive or paused, withdrawals are forbidden
        (,,,,,,,, bool isActive,) = poolDataProvider.getReserveConfigurationData(asset);
        if (!isActive || poolDataProvider.getPaused(asset)) return 0;

        // Return the minimum of the assets lent by the JT and the total idle/unborrowed reserve assets (currently withdrawable from the pool)
        return Math.min(_getJuniorTrancheRawNAV(), IERC20(asset).balanceOf($.aToken));
    }
}
