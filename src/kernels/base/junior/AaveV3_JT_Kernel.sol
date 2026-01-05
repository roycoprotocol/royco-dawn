// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { IPool } from "../../../interfaces/aave/IPool.sol";
import { IPoolAddressesProvider } from "../../../interfaces/aave/IPoolAddressesProvider.sol";
import { IPoolDataProvider } from "../../../interfaces/aave/IPoolDataProvider.sol";
import { ExecutionModel, IRoycoKernel } from "../../../interfaces/kernel/IRoycoKernel.sol";
import { MAX_TRANCHE_UNITS, ZERO_TRANCHE_UNITS } from "../../../libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, UnitsMathLib, toTrancheUnits, toUint256 } from "../../../libraries/Units.sol";
import { RoycoKernel, RoycoKernelStorageLib, SyncedAccountingState } from "../RoycoKernel.sol";

abstract contract AaveV3_JT_Kernel is RoycoKernel {
    using SafeERC20 for IERC20;
    using UnitsMathLib for TRANCHE_UNIT;

    /// @dev Storage slot for AaveV3_JT_KernelState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.AaveV3_JT_KernelState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant AAVE_V3_JT_KERNEL_STORAGE_SLOT = 0xbd2cea01170a8a3a63be09b675f1b67e378a959a79f759c2a857613313f76400;

    /// @inheritdoc IRoycoKernel
    ExecutionModel public constant JT_DEPOSIT_EXECUTION_MODEL = ExecutionModel.SYNC;

    /**
     * @notice Storage state for the Royco Aave V3 Kernel
     * @custom:storage-location erc7201:Royco.storage.AaveV3_JT_KernelState
     * @custom:field pool - The address of the Aave V3 pool
     * @custom:field poolAddressesProvider - The address of the Aave V3 pool addresses provider
     * @custom:field jtAssetAToken - The address of the junior tranche base asset's A Token
     */
    struct AaveV3_JT_KernelState {
        address pool;
        address poolAddressesProvider;
        address jtAssetAToken;
    }

    /// @notice Thrown when the JT base asset is not a supported reserve token in the Aave V3 Pool
    error UNSUPPORTED_RESERVE_TOKEN();

    /// @notice Thrown when a low-level call fails
    error FAILED_CALL();

    /**
     * @notice Initializes a kernel where the junior tranche is deployed into Aave V3 with a redemption delay
     * @param _aaveV3Pool The address of the Aave V3 Pool
     * @param _jtAsset The address of the base asset of the junior tranche
     */
    function __AaveV3_JT_Kernel_init_unchained(address _aaveV3Pool, address _jtAsset) internal onlyInitializing {
        // Initialize the Aave V3 junior tranche kernel state
        // Ensure that the JT base asset is a supported reserve token in the Aave V3 Pool
        address jtAssetAToken = IPool(_aaveV3Pool).getReserveAToken(_jtAsset);
        require(jtAssetAToken != address(0), UNSUPPORTED_RESERVE_TOKEN());

        // Extend a one time max approval to the Aave V3 pool for the JT's base asset
        IERC20(_jtAsset).forceApprove(_aaveV3Pool, type(uint256).max);

        // Set the initial state of the Aave V3 kernel
        AaveV3_JT_KernelState storage $ = _getAaveV3JTKernelStorage();
        $.pool = _aaveV3Pool;
        $.poolAddressesProvider = address(IPool(_aaveV3Pool).ADDRESSES_PROVIDER());
        $.jtAssetAToken = jtAssetAToken;
    }

    /// @inheritdoc IRoycoKernel
    function jtPreviewDeposit(TRANCHE_UNIT _assets)
        external
        view
        override
        onlyJuniorTranche
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated)
    {
        // Preview the deposit by converting the assets to NAV units and returning the NAV at which the shares will be minted
        valueAllocated = jtConvertTrancheUnitsToNAVUnits(_assets);
        stateBeforeDeposit = _previewSyncTrancheAccounting();
    }

    /// @inheritdoc RoycoKernel
    function _getJuniorTrancheRawNAV() internal view override(RoycoKernel) returns (NAV_UNIT) {
        // The tranche's balance of the AToken is the total assets it is owed from the Aave pool
        /// @dev This does not treat illiquidity in the Aave pool as a loss: we assume that total lent will be withdrawable at some point
        return jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(IERC20(_getAaveV3JTKernelStorage().jtAssetAToken).balanceOf(address(this))));
    }

    /// @inheritdoc RoycoKernel
    function _jtMaxDepositGlobally(address) internal view override(RoycoKernel) returns (TRANCHE_UNIT) {
        // Retrieve the Pool's data provider and asset
        IPoolDataProvider poolDataProvider = IPoolDataProvider(IPoolAddressesProvider(_getAaveV3JTKernelStorage().poolAddressesProvider).getPoolDataProvider());
        address asset = RoycoKernelStorageLib._getRoycoKernelStorage().jtAsset;

        // If the reserve asset is inactive, frozen, or paused, supplies are forbidden
        (uint256 decimals,,,,,,,, bool isActive, bool isFrozen) = poolDataProvider.getReserveConfigurationData(asset);
        if (!isActive || isFrozen || poolDataProvider.getPaused(asset)) return ZERO_TRANCHE_UNITS;

        // Get the supply cap for the reserve asset. If unset, the suppliable amount is unbounded
        (, uint256 supplyCap) = poolDataProvider.getReserveCaps(asset);
        if (supplyCap == 0) return MAX_TRANCHE_UNITS;

        // Compute the total reserve assets supplied and accrued to the treasury
        (uint256 totalAccruedToTreasury, uint256 totalLent) = _getTotalAccruedToTreasuryAndLent(poolDataProvider, asset);
        uint256 currentlySupplied = totalLent + totalAccruedToTreasury;
        // Supply cap was returned as whole tokens, so we must scale by underlying decimals
        supplyCap = supplyCap * (10 ** decimals);

        // If supply cap hit, no incremental supplies are permitted. Else, return the max suppliable amount within the cap.
        return toTrancheUnits((currentlySupplied >= supplyCap) ? 0 : (supplyCap - currentlySupplied));
    }

    /**
     * @notice Helper function to get the total accrued to treasury and total lent from the pool data provider
     * @dev IPoolDataProvider.getReserveData returns a tuple of 11 words which saturates the stack
     * @dev Uses a low-level static call to the pool data provider to avoid stack too deep errors
     * @param _poolDataProvider The Aave V3 pool data provider
     * @param _asset The asset to get the total lent data for
     * @return totalAccruedToTreasury The total assets accrued to the Aave treasury that exist in the lending pool
     * @return totalLent The total assets lent and owned by lenders of the pool
     */
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
    function _jtMaxWithdrawableGlobally(address) internal view override(RoycoKernel) returns (TRANCHE_UNIT) {
        // Retrieve the Pool's data provider and asset
        AaveV3_JT_KernelState storage $ = _getAaveV3JTKernelStorage();
        IPoolDataProvider poolDataProvider = IPoolDataProvider(IPoolAddressesProvider($.poolAddressesProvider).getPoolDataProvider());
        address asset = RoycoKernelStorageLib._getRoycoKernelStorage().jtAsset;

        // If the reserve asset is inactive or paused, withdrawals are forbidden
        (,,,,,,,, bool isActive,) = poolDataProvider.getReserveConfigurationData(asset);
        if (!isActive || poolDataProvider.getPaused(asset)) return ZERO_TRANCHE_UNITS;

        // Return the unborrowed/reserve assets of the pool
        return toTrancheUnits(IERC20(asset).balanceOf($.jtAssetAToken));
    }

    /// @inheritdoc RoycoKernel
    function _jtPreviewWithdraw(TRANCHE_UNIT _jtAssets) internal pure override(RoycoKernel) returns (TRANCHE_UNIT withdrawnJTAssets) {
        return _jtAssets;
    }

    /// @inheritdoc RoycoKernel
    function _jtDepositAssets(TRANCHE_UNIT _jtAssets) internal override(RoycoKernel) {
        // Supply the specified assets to the pool
        // Max approval already given to the pool on initialization
        IPool(_getAaveV3JTKernelStorage().pool).supply(RoycoKernelStorageLib._getRoycoKernelStorage().jtAsset, toUint256(_jtAssets), address(this), 0);
    }

    /// @inheritdoc RoycoKernel
    function _jtWithdrawAssets(TRANCHE_UNIT _jtAssets, address _receiver) internal override(RoycoKernel) {
        // Try and withdraw the requested assets from the Aave pool
        AaveV3_JT_KernelState storage $ = _getAaveV3JTKernelStorage();
        (bool withdrawalSucceeded,) =
            $.pool.call(abi.encodeCall(IPool.withdraw, (RoycoKernelStorageLib._getRoycoKernelStorage().jtAsset, toUint256(_jtAssets), _receiver)));
        if (withdrawalSucceeded) return;

        // The Pool lacks the liquidity to withdraw the requested assets, transfer A Tokens instead
        IERC20($.jtAssetAToken).safeTransfer(_receiver, toUint256(_jtAssets));
    }

    /**
     * @notice Returns a storage pointer to the AaveV3_JT_KernelState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer to the Aave V3 JT kernel state
     */
    function _getAaveV3JTKernelStorage() internal pure returns (AaveV3_JT_KernelState storage $) {
        assembly ("memory-safe") {
            $.slot := AAVE_V3_JT_KERNEL_STORAGE_SLOT
        }
    }
}
