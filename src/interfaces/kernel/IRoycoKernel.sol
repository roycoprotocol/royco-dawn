// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoKernelState } from "../../libraries/RoycoKernelStorageLib.sol";
import { ExecutionModel, RequestRedeemSharesBehavior, SyncedAccountingState, TrancheAssetClaims } from "../../libraries/Types.sol";
import { TrancheType } from "../../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../../libraries/Units.sol";
import { IRoycoQuoter } from "./IRoycoQuoter.sol";

/**
 * @title IRoycoKernel
 * @notice Interface for the Royco kernel contract
 * @dev The kernel contract is responsible for defining the execution model and logic of the Senior and Junior tranches of a given Royco market
 */
interface IRoycoKernel is IRoycoQuoter {
    /// @notice Thrown when any of the required initialization params are null
    error NULL_ADDRESS();

    /// @notice Thrown when the caller of a permissioned function isn't the market's senior tranche
    error ONLY_SENIOR_TRANCHE();

    /// @notice Thrown when the caller of a permissioned function isn't the market's junior tranche
    error ONLY_JUNIOR_TRANCHE();

    /**
     * @notice Returns the request redeem shares behavior for the senior tranche
     * @return The request redeem shares behavior for the senior tranche - BURN_ON_REQUEST or BURN_ON_REDEEM
     */
    function ST_REQUEST_REDEEM_SHARES_BEHAVIOR() external pure returns (RequestRedeemSharesBehavior);

    /**
     * @notice Returns the request redeem shares behavior for the junior tranche
     * @return The request redeem shares behavior for the junior tranche - BURN_ON_REQUEST or BURN_ON_REDEEM
     */
    function JT_REQUEST_REDEEM_SHARES_BEHAVIOR() external pure returns (RequestRedeemSharesBehavior);

    /**
     * @notice Returns the execution model for the senior tranche's increase NAV operation
     * @return The execution model for the senior tranche's increase NAV operation - SYNC or ASYNC
     */
    function ST_INCREASE_NAV_EXECUTION_MODEL() external pure returns (ExecutionModel);

    /**
     * @notice Returns the execution model for the senior tranche's decrease NAV operation
     * @return The execution model for the senior tranche's decrease NAV operation - SYNC or ASYNC
     */
    function ST_DECREASE_NAV_EXECUTION_MODEL() external pure returns (ExecutionModel);

    /**
     * @notice Returns the execution model for the junior tranche's increase NAV operation
     * @return The execution model for the junior tranche's increase NAV operation - SYNC or ASYNC
     */
    function JT_INCREASE_NAV_EXECUTION_MODEL() external pure returns (ExecutionModel);

    /**
     * @notice Returns the execution model for the junior tranche's decrease NAV operation
     * @return The execution model for the junior tranche's decrease NAV operation - SYNC or ASYNC
     */
    function JT_DECREASE_NAV_EXECUTION_MODEL() external pure returns (ExecutionModel);

    /**
     * @notice Returns the raw NAV of the senior tranche.
     * @dev The raw NAV represents the value of the senior tranche's invested assets, denominated in the kernel's NAV units
     * @return nav The raw NAV of the senior tranche, denominated in the kernel's NAV units
     */
    function getSTRawNAV() external view returns (NAV_UNIT nav);

    /**
     * @notice Returns the raw NAV of the junior tranche
     * @dev The raw NAV represents the value of the junior tranche's invested assets, denominated in the kernel's NAV units
     * @return nav The raw NAV of the junior tranche, denominated in the kernel's NAV units
     */
    function getJTRawNAV() external view returns (NAV_UNIT nav);

    /**
     * @notice Returns the distribution the senior's claim of assets across the senior and junior tranches
     * @return claims The distribution of the senior tranche's claim of assets across the senior and junior tranches, denominated in the respective tranches' tranche units
     */
    function getSTAssetClaims() external view returns (TrancheAssetClaims memory claims);

    /**
     * @notice Returns the distribution the junior's claim of assets across the senior and junior tranches
     * @return claims The distribution of the junior tranche's claim of assets across the senior and junior tranches, denominated in the respective tranches' tranche units
     */
    function getJTAssetClaims() external view returns (TrancheAssetClaims memory claims);

    /**
     * @notice Synchronizes and persists the raw and effective NAVs of both tranches
     * @dev Only executes a pre-op sync because there is no operation being executed in the same call as this sync
     * @return state The synced NAV, debt, and fee accounting containing all mark to market accounting data
     */
    function syncTrancheAccounting() external returns (SyncedAccountingState memory state);

    /**
     * @notice Previews a synchronization of the raw and effective NAVs of both tranches
     * @dev Does not mutate any state
     * @param _trancheType An enum indicating which tranche to execute this preview for
     * @return state The synced NAV, debt, and fee accounting containing all mark to market accounting data
     * @return claims The claims on ST and JT assets that the specified tranche has denominated in tranche-native units
     * @return totalTrancheShares The total number of shares that exist in the specified tranche after minting any protocol fee shares post-sync
     */
    function previewSyncTrancheAccounting(TrancheType _trancheType)
        external
        view
        returns (SyncedAccountingState memory state, TrancheAssetClaims memory claims, uint256 totalTrancheShares);

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the senior tranche
     * @param _receiver The address that is depositing the assets
     * @return assets The maximum amount of assets that can be deposited into the senior tranche, denominated in the senior tranche's tranche units
     */
    function stMaxAssetsDeposit(address _receiver) external view returns (TRANCHE_UNIT assets);

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn from the senior tranche
     * @param _owner The address that is withdrawing the assets
     * @return maxWithdrawableNAV The maximum amount of assets that can be withdrawn from the senior tranche, denominated in the senior tranche's NAV units
     */
    function stMaxWithdrawableNAV(address _owner) external view returns (NAV_UNIT maxWithdrawableNAV);

    /**
     * @notice Previews the deposit of a specified amount of assets into the senior tranche
     * @dev Intentionally defined as a non-view function to allow for the kernel to simulate the deposit without actually depositing the assets
     * @dev The kernel may decide to simulate the deposit and revert internally with the result
     * @dev Should revert if deposits are asynchronous
     * @param _assets The amount of assets to deposit, denominated in the senior tranche's tranche units
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units
     * @return navToMintAt The NAV at which the shares will be minted, exclusive of valueAllocated
     */
    function stPreviewDeposit(TRANCHE_UNIT _assets) external returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintAt);

    /**
     * @notice Processes the deposit of a specified amount of assets into the senior tranche
     * @dev Assumes that the funds are transferred to the kernel before the deposit call is made
     * @param _assets The amount of assets to deposit, denominated in the senior tranche's tranche units
     * @param _caller The address that is depositing the assets
     * @param _receiver The address that is receiving the shares
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units
     * @return navToMintAt The NAV at which the shares will be minted, exclusive of valueAllocated
     */
    function stDeposit(TRANCHE_UNIT _assets, address _caller, address _receiver) external returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintAt);

    /**
     * @notice Previews the redemption of a specified number of shares from the senior tranche
     * @dev Intentionally defined as a non-view function to allow for the kernel to simulate the redemption without actually redeeming the shares
     * @dev The kernel may decide to simulate the redemption and revert internally with the result
     * @dev Should revert if redemptions are asynchronous
     * @param _shares The number of shares to redeem
     * @return claims The distribution of assets that would be transferred to the receiver on redemption, denominated in the respective tranches' tranche units
     * @return totalTrancheShares The total number of shares that exist in the senior tranche after minting any protocol fee shares post-sync
     */
    function stPreviewRedeem(uint256 _shares) external returns (TrancheAssetClaims memory claims, uint256 totalTrancheShares);

    /**
     * @notice Processes the redemption of a specified number of shares from the senior tranche
     * @dev The function is expected to transfer the senior and junior assets directly to the receiver, based on the redemption claims
     * @param _shares The number of shares to redeem
     * @param _controller The controller that is allowed to operate the redemption
     * @param _receiver The address that is receiving the assets
     * @return claims The distribution of assets that were transferred to the receiver on redemption, denominated in the respective tranches' tranche units
     */
    function stRedeem(uint256 _shares, address _controller, address _receiver) external returns (TrancheAssetClaims memory claims);

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the junior tranche
     * @param _receiver The address that is depositing the assets
     * @return assets The maximum amount of assets that can be deposited into the junior tranche, denominated in the junior tranche's tranche units
     */
    function jtMaxAssetsDeposit(address _receiver) external view returns (TRANCHE_UNIT assets);

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn from the junior tranche
     * @param _owner The address that is withdrawing the assets
     * @return maxWithdrawableNAV The maximum amount of assets that can be withdrawn from the junior tranche, denominated in the junior tranche's NAV units
     */
    function jtMaxWithdrawableNAV(address _owner) external view returns (NAV_UNIT maxWithdrawableNAV);

    /**
     * @notice Previews the deposit of a specified amount of assets into the junior tranche
     * @dev Intentionally defined as a non-view function to allow for the kernel to simulate the deposit without actually depositing the assets
     * @dev The kernel may decide to simulate the deposit and revert internally with the result
     * @dev Should revert if deposits are asynchronous
     * @param _assets The amount of assets to deposit, denominated in the junior tranche's tranche units
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units
     * @return navToMintAt The NAV at which the shares will be minted, exclusive of valueAllocated
     */
    function jtPreviewDeposit(TRANCHE_UNIT _assets) external returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintAt);

    /**
     * @notice Previews the redemption of a specified number of shares from the junior tranche
     * @dev Intentionally defined as a non-view function to allow for the kernel to simulate the redemption without actually redeeming the shares
     * @dev The kernel may decide to simulate the redemption and revert internally with the result
     * @dev Should revert if redemptions are asynchronous
     * @param _shares The number of shares to redeem
     * @return claims The distribution of assets that would be transferred to the receiver on redemption, denominated in the respective tranches' tranche units
     * @return totalTrancheShares The total number of shares that exist in the junior tranche after minting any protocol fee shares post-sync
     */
    function jtPreviewRedeem(uint256 _shares) external returns (TrancheAssetClaims memory claims, uint256 totalTrancheShares);

    /**
     * @notice Processes the deposit of a specified amount of assets into the junior tranche
     * @dev Assumes that the funds are transferred to the kernel before the deposit call is made
     * @param _assets The amount of assets to deposit, denominated in the junior tranche's tranche units
     * @param _caller The address that is depositing the assets
     * @param _receiver The address that is receiving the shares
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units
     * @return navToMintAt The NAV at which the shares will be minted, exclusive of valueAllocated
     */
    function jtDeposit(TRANCHE_UNIT _assets, address _caller, address _receiver) external returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintAt);

    /**
     * @notice Processes the redemption of a specified number of shares from the junior tranche
     * @dev The function is expected to transfer the senior and junior assets directly to the receiver, based on the redemption claims
     * @param _shares The number of shares to redeem
     * @param _controller The controller that is allowed to operate the redemption
     * @param _receiver The address that is receiving the assets
     * @return claims The distribution of assets that were transferred to the receiver on redemption, denominated in the respective tranches' tranche units
     */
    function jtRedeem(uint256 _shares, address _controller, address _receiver) external returns (TrancheAssetClaims memory claims);

    /**
     * @notice Returns the state of the kernel
     * @return The state of the kernel
     */
    function getState() external view returns (RoycoKernelState memory);
}
