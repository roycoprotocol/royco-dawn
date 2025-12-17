// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IPool } from "../../../interfaces/aave/IPool.sol";
import { IPoolAddressesProvider } from "../../../interfaces/aave/IPoolAddressesProvider.sol";
import { IPoolDataProvider } from "../../../interfaces/aave/IPoolDataProvider.sol";
import { ExecutionModel, IRoycoKernel } from "../../../interfaces/kernel/IRoycoKernel.sol";
import { ZERO_TRANCHE_UNITS } from "../../../libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, UnitsMathLib, toTrancheUnits, toUint256 } from "../../../libraries/Units.sol";
import { AaveV3KernelState, AaveV3KernelStorageLib } from "../../../libraries/kernels/AaveV3KernelStorageLib.sol";
import { Operation, RoycoKernel, RoycoKernelStorageLib, SyncedAccountingState, TrancheAssetClaims, TrancheType } from "../RoycoKernel.sol";
import { BaseAsyncJTRedemptionDelayKernel } from "./BaseAsyncJTRedemptionDelayKernel.sol";

abstract contract AaveV3JTKernel is RoycoKernel, BaseAsyncJTRedemptionDelayKernel {
    using SafeERC20 for IERC20;
    using UnitsMathLib for TRANCHE_UNIT;
    using Math for uint256;

    /// @inheritdoc IRoycoKernel
    ExecutionModel public constant JT_INCREASE_NAV_EXECUTION_MODEL = ExecutionModel.SYNC;

    /// @inheritdoc IRoycoKernel
    ExecutionModel public constant JT_DECREASE_NAV_EXECUTION_MODEL = ExecutionModel.ASYNC;

    /// @notice Thrown when the JT base asset is not a supported reserve token in the Aave V3 Pool
    error UNSUPPORTED_RESERVE_TOKEN();

    /// @notice Thrown when the shares to redeem are greater than the claimable shares
    error INSUFFICIENT_CLAIMABLE_SHARES(uint256 sharesToRedeem, uint256 claimableShares);

    /// @notice Thrown when a low-level call fails
    error FAILED_CALL();

    /**
     * @notice Initializes a kernel where the junior tranche is deployed into Aave V3
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
        AaveV3KernelStorageLib.__AaveV3Kernel_init(_aaveV3Pool, address(IPool(_aaveV3Pool).ADDRESSES_PROVIDER()), jtAssetAToken);
    }

    /// @inheritdoc IRoycoKernel
    function jtPreviewDeposit(TRANCHE_UNIT _assets) external view override onlyJuniorTranche returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintAt) {
        // Preview the deposit by converting the assets to NAV units and returning the NAV at which the shares will be minted
        valueAllocated = _jtConvertTrancheUnitsToNAVUnits(_assets);
        navToMintAt = (_accountant().previewSyncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV())).jtEffectiveNAV;
    }

    /// @inheritdoc IRoycoKernel
    function jtDeposit(
        TRANCHE_UNIT _assets,
        address,
        address
    )
        external
        override(IRoycoKernel)
        onlyJuniorTranche
        whenNotPaused
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintAt)
    {
        // Execute a pre-op sync on accounting
        valueAllocated = _jtConvertTrancheUnitsToNAVUnits(_assets);
        navToMintAt = (_preOpSyncTrancheAccounting()).jtEffectiveNAV;

        // Max approval already given to the pool on initialization
        IPool(AaveV3KernelStorageLib._getAaveV3KernelStorage().pool)
            .supply(RoycoKernelStorageLib._getRoycoKernelStorage().jtAsset, toUint256(_assets), address(this), 0);

        // Execute a post-op sync on accounting
        _postOpSyncTrancheAccounting(Operation.JT_INCREASE_NAV);
    }

    /// @inheritdoc IRoycoKernel
    function jtRedeem(
        uint256 _shares,
        address _controller,
        address _receiver
    )
        external
        override(IRoycoKernel)
        onlyJuniorTranche
        returns (TrancheAssetClaims memory claims)
    {
        // Execute a pre-op sync on accounting
        SyncedAccountingState memory state;
        uint256 totalTrancheShares;
        (state, claims, totalTrancheShares) = _preOpSyncTrancheAccounting(TrancheType.JUNIOR);

        // Ensure that the shares to redeem are actually claimable right now
        require(_shares <= _jtClaimableRedeemRequest(_controller), INSUFFICIENT_CLAIMABLE_SHARES(_shares, _jtClaimableRedeemRequest(_controller)));

        // Get the total NAV to withdraw on this redemption
        NAV_UNIT navToWithdraw = _processClaimableRedeemRequest(_controller, state.jtEffectiveNAV, _shares, totalTrancheShares);

        // Compute the ST assets to claim and withdraw them
        claims.stAssets = claims.stAssets.mulDiv(navToWithdraw, state.jtEffectiveNAV, Math.Rounding.Floor);
        if (claims.stAssets != ZERO_TRANCHE_UNITS) _withdrawSTAssets(claims.stAssets, _receiver);

        // Compute the JT assets to claim and withdraw them
        claims.jtAssets = claims.jtAssets.mulDiv(navToWithdraw, state.jtEffectiveNAV, Math.Rounding.Floor);
        if (claims.jtAssets != ZERO_TRANCHE_UNITS) _withdrawJTAssets(claims.jtAssets, _receiver);

        // Execute a post-op sync on accounting and enforce the market's coverage requirement
        _postOpSyncTrancheAccountingAndEnforceCoverage(Operation.JT_DECREASE_NAV);
    }

    /// @inheritdoc RoycoKernel
    function _getJuniorTrancheRawNAV() internal view override(RoycoKernel) returns (NAV_UNIT) {
        // The tranche's balance of the AToken is the total assets it is owed from the Aave pool
        /// @dev This does not treat illiquidity in the Aave pool as a loss: we assume that total lent will be withdrawable at some point
        return _jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(IERC20(AaveV3KernelStorageLib._getAaveV3KernelStorage().aToken).balanceOf(address(this))));
    }

    /// @inheritdoc RoycoKernel
    function _jtMaxAssetDepositGlobally(address) internal view override(RoycoKernel) returns (TRANCHE_UNIT) {
        // Retrieve the Pool's data provider and asset
        IPoolDataProvider poolDataProvider =
            IPoolDataProvider(IPoolAddressesProvider(AaveV3KernelStorageLib._getAaveV3KernelStorage().poolAddressesProvider).getPoolDataProvider());
        address asset = RoycoKernelStorageLib._getRoycoKernelStorage().jtAsset;

        // If the reserve asset is inactive, frozen, or paused, supplies are forbidden
        (uint256 decimals,,,,,,,, bool isActive, bool isFrozen) = poolDataProvider.getReserveConfigurationData(asset);
        if (!isActive || isFrozen || poolDataProvider.getPaused(asset)) return ZERO_TRANCHE_UNITS;

        // Get the supply cap for the reserve asset. If unset, the suppliable amount is unbounded
        (, uint256 supplyCap) = poolDataProvider.getReserveCaps(asset);
        if (supplyCap == 0) return toTrancheUnits(type(uint256).max);

        // Compute the total reserve assets supplied and accrued to the treasury
        (uint256 totalAccruedToTreasury, uint256 totalLent) = _getTotalAccruedToTreasuryAndLent(poolDataProvider, asset);
        uint256 currentlySupplied = totalLent + totalAccruedToTreasury;
        // Supply cap was returned as whole tokens, so we must scale by underlying decimals
        supplyCap = supplyCap * (10 ** decimals);

        // If supply cap hit, no incremental supplies are permitted. Else, return the max suppliable amount within the cap.
        return toTrancheUnits((currentlySupplied >= supplyCap) ? 0 : (supplyCap - currentlySupplied));
    }

    /// @notice Helper function to get the total accrued to treasury and total lent from the pool data provider
    /// @dev IPoolDataProvider.getReserveData returns a tuple of 11 words which saturates the stack
    /// @dev Uses a low-level static call to the pool data provider to avoid stack too deep errors
    function _getTotalAccruedToTreasuryAndLent(
        IPoolDataProvider _poolDataProvider,
        address _asset
    )
        internal
        view
        returns (uint256 totalAccruedToTreasury, uint256 totalLent)
    {
        bytes memory data = abi.encodeCall(IPoolDataProvider.getReserveData, (_asset));
        bool success;
        assembly ("memory-safe") {
            // Load the free memory pointer, and allocate 0x60 bytes for the return data
            let ptr := mload(0x40)
            mstore(0x40, add(ptr, 0x60))

            // Make the static call to the pool data provider
            success := staticcall(gas(), _poolDataProvider, add(data, 0x20), mload(data), ptr, 0x60)

            // Load the total accrued to treasury and total lent from the return data
            // Refer IPoolDataProvider.getReserveData for the return data layout
            totalAccruedToTreasury := mload(add(ptr, 0x20))
            totalLent := mload(add(ptr, 0x40))
        }
        require(success, FAILED_CALL());
    }

    /// @inheritdoc RoycoKernel
    function _maxJTWithdrawalGlobally(address) internal view override(RoycoKernel) returns (TRANCHE_UNIT) {
        // Retrieve the Pool's data provider and asset
        AaveV3KernelState storage $ = AaveV3KernelStorageLib._getAaveV3KernelStorage();
        IPoolDataProvider poolDataProvider = IPoolDataProvider(IPoolAddressesProvider($.poolAddressesProvider).getPoolDataProvider());
        address asset = RoycoKernelStorageLib._getRoycoKernelStorage().jtAsset;

        // If the reserve asset is inactive or paused, withdrawals are forbidden
        (,,,,,,,, bool isActive,) = poolDataProvider.getReserveConfigurationData(asset);
        if (!isActive || poolDataProvider.getPaused(asset)) return ZERO_TRANCHE_UNITS;

        // Return the minimum of the assets lent by the JT and the total idle/unborrowed reserve assets (currently withdrawable from the pool)
        return toTrancheUnits(IERC20(asset).balanceOf($.aToken));
    }

    /// @inheritdoc RoycoKernel
    function _withdrawJTAssets(TRANCHE_UNIT _jtAssets, address _receiver) internal override(RoycoKernel) {
        IPool(AaveV3KernelStorageLib._getAaveV3KernelStorage().pool)
            .withdraw(RoycoKernelStorageLib._getRoycoKernelStorage().jtAsset, toUint256(_jtAssets), _receiver);
    }

    /// @inheritdoc RoycoKernel
    function _previewWithdrawJTAssets(TRANCHE_UNIT _jtAssets) internal view override(RoycoKernel) returns (TRANCHE_UNIT redeemedJTAssets) {
        return _jtAssets;
    }
}
