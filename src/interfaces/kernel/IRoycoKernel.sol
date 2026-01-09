// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AssetClaims, ExecutionModel, SharesRedemptionModel, SyncedAccountingState } from "../../libraries/Types.sol";
import { TrancheType } from "../../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../../libraries/Units.sol";

/**
 * @title IRoycoKernel
 * @notice Interface for the Royco kernel contract
 * @dev The kernel contract is responsible for defining the execution model and logic of the Senior and Junior tranches of a given Royco market
 */
interface IRoycoKernel {
    /**
     * @notice Emitted when the protocol fee recipient is updated
     * @param protocolFeeRecipient The new protocol fee recipient
     */
    event ProtocolFeeRecipientUpdated(address protocolFeeRecipient);

    /**
     * @notice Emitted when the junior tranche redemption delay is updated
     * @param jtRedemptionDelayInSeconds The new junior tranche redemption delay in seconds
     */
    event JuniorTrancheRedemptionDelayUpdated(uint24 jtRedemptionDelayInSeconds);

    /// @notice Thrown when any of the required initialization params are null
    error NULL_ADDRESS();

    /// @notice Thrown when the caller of a permissioned function isn't the market's senior tranche
    error ONLY_SENIOR_TRANCHE();

    /// @notice Thrown when the caller of a permissioned function isn't the market's junior tranche
    error ONLY_JUNIOR_TRANCHE();

    /// @notice Thrown when the total shares claimable for redemption are less than what the user is trying to redeem
    error INSUFFICIENT_REDEEMABLE_SHARES(uint256 sharesToRedeem, uint256 redeemableShares);

    /// @notice Thrown when the JT redemption request ID is invalid
    error INVALID_REQUEST_ID(uint256 requestId);

    /// @notice Thrown when trying to a cancel a redemption request that doesn't exist
    error NONEXISTANT_REQUEST_TO_CANCEL();

    /// @notice Thrown when trying to claim a cancellation without having an existing cancellation
    error REDEMPTION_REQUEST_NOT_CANCELED();

    /// @notice Thrown when the function is not implemented
    error PREVIEW_REDEEM_DISABLED_FOR_ASYNC_REDEMPTION();

    /// @notice Thrown when trying to cancel a redemption request that has already been canceled
    error REDEMPTION_REQUEST_CANCELED();

    /**
     * @notice Returns the execution model for the senior tranche's increase NAV operation
     * @return The execution model for the senior tranche's increase NAV operation - SYNC or ASYNC
     */
    function ST_DEPOSIT_EXECUTION_MODEL() external pure returns (ExecutionModel);

    /**
     * @notice Returns the execution model for the senior tranche's decrease NAV operation
     * @return The execution model for the senior tranche's decrease NAV operation - SYNC or ASYNC
     */
    function ST_REDEEM_EXECUTION_MODEL() external pure returns (ExecutionModel);

    /**
     * @notice Returns the execution model for the junior tranche's increase NAV operation
     * @return The execution model for the junior tranche's increase NAV operation - SYNC or ASYNC
     */
    function JT_DEPOSIT_EXECUTION_MODEL() external pure returns (ExecutionModel);

    /**
     * @notice Returns the execution model for the junior tranche's decrease NAV operation
     * @return The execution model for the junior tranche's decrease NAV operation - SYNC or ASYNC
     */
    function JT_REDEEM_EXECUTION_MODEL() external pure returns (ExecutionModel);

    /**
     * @notice Returns the request redeem shares behavior for the senior tranche
     * @return The request redeem shares behavior for the senior tranche - BURN_ON_REQUEST_REDEEM or BURN_ON_CLAIM_REDEEM
     */
    function ST_REQUEST_REDEEM_SHARES_BEHAVIOR() external pure returns (SharesRedemptionModel);

    /**
     * @notice Returns the request redeem shares behavior for the junior tranche
     * @return The request redeem shares behavior for the junior tranche - BURN_ON_REQUEST_REDEEM or BURN_ON_CLAIM_REDEEM
     */
    function JT_REQUEST_REDEEM_SHARES_BEHAVIOR() external pure returns (SharesRedemptionModel);

    /**
     * @notice Converts the specified ST assets denominated in its tranche units to the kernel's NAV units
     * @param _stAssets The ST assets denominated in tranche units to convert to the kernel's NAV units
     * @return nav The specified ST assets denominated in its tranche units converted to the kernel's NAV units
     */
    function stConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _stAssets) external view returns (NAV_UNIT nav);

    /**
     * @notice Converts the specified JT assets denominated in its tranche units to the kernel's NAV units
     * @param _jtAssets The JT assets denominated in tranche units to convert to the kernel's NAV units
     * @return nav The specified JT assets denominated in its tranche units converted to the kernel's NAV units
     */
    function jtConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _jtAssets) external view returns (NAV_UNIT nav);

    /**
     * @notice Converts the specified assets denominated in the kernel's NAV units to assets denominated in ST's tranche units
     * @param _navAssets The NAV of the assets denominated in the kernel's NAV units to convert to assets denominated in ST's tranche units
     * @return stAssets The specified NAV of the assets denominated in the kernel's NAV units converted to assets denominated in ST's tranche units
     */
    function stConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) external view returns (TRANCHE_UNIT stAssets);

    /**
     * @notice Converts the specified assets denominated in the kernel's NAV units to assets denominated in JT's tranche units
     * @param _navAssets The NAV of the assets denominated in the kernel's NAV units to convert to assets denominated in JT's tranche units
     * @return jtAssets The specified NAV of the assets denominated in the kernel's NAV units converted to assets denominated in JT's tranche units
     */
    function jtConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) external view returns (TRANCHE_UNIT jtAssets);

    /**
     * @notice Synchronizes and persists the raw and effective NAVs of both tranches
     * @dev Only executes a pre-op sync because there is no operation being executed in the same call as this sync
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark to market accounting data
     */
    function syncTrancheAccounting() external returns (SyncedAccountingState memory state);

    /**
     * @notice Previews a synchronization of the raw and effective NAVs of both tranches
     * @dev Does not mutate any state
     * @param _trancheType An enum indicating which tranche to execute this preview for
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark to market accounting data
     * @return claims The claims on ST and JT assets that the specified tranche has denominated in tranche-native units
     * @return totalTrancheShares The total number of shares that exist in the specified tranche after minting any protocol fee shares post-sync
     */
    function previewSyncTrancheAccounting(TrancheType _trancheType)
        external
        view
        returns (SyncedAccountingState memory state, AssetClaims memory claims, uint256 totalTrancheShares);

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the senior tranche
     * @param _receiver The address that is depositing the assets
     * @return assets The maximum amount of assets that can be deposited into the senior tranche, denominated in the senior tranche's tranche units
     */
    function stMaxDeposit(address _receiver) external view returns (TRANCHE_UNIT assets);

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn from the senior tranche
     * @param _owner The address that is withdrawing the assets
     * @return claimOnStNAV The notional claims on ST assets that the senior tranche has denominated in kernel's NAV units
     * @return claimOnJtNAV The notional claims on JT assets that the senior tranche has denominated in kernel's NAV units
     * @return stMaxWithdrawableNAV The maximum amount of assets that can be withdrawn from the senior tranche, denominated in the kernel's NAV units
     * @return jtMaxWithdrawableNAV The maximum amount of assets that can be withdrawn from the junior tranche, denominated in the kernel's NAV units
     */
    function stMaxWithdrawable(address _owner)
        external
        view
        returns (NAV_UNIT claimOnStNAV, NAV_UNIT claimOnJtNAV, NAV_UNIT stMaxWithdrawableNAV, NAV_UNIT jtMaxWithdrawableNAV);

    /**
     * @notice Previews the deposit of a specified amount of assets into the senior tranche
     * @dev The kernel may decide to simulate the deposit and revert internally with the result
     * @dev Should revert if deposits are asynchronous
     * @param _assets The amount of assets to deposit, denominated in the senior tranche's tranche units
     * @return stateBeforeDeposit The state of the senior tranche before the deposit, after applying the pre-op sync
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units
     */
    function stPreviewDeposit(TRANCHE_UNIT _assets) external view returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated);

    /**
     * @notice Previews the redemption of a specified number of shares from the senior tranche
     * @dev The kernel may decide to simulate the redemption and revert internally with the result
     * @dev Should revert if redemptions are asynchronous
     * @param _shares The number of shares to redeem
     * @return userClaim The distribution of assets that would be transferred to the receiver on redemption, denominated in the respective tranches' tranche units
     */
    function stPreviewRedeem(uint256 _shares) external view returns (AssetClaims memory userClaim);

    /**
     * @notice Processes the deposit of a specified amount of assets into the senior tranche
     * @dev Assumes that the funds are transferred to the kernel before the deposit call is made
     * @param _assets The amount of assets to deposit, denominated in the senior tranche's tranche units
     * @param _caller The address that is depositing the assets
     * @param _receiver The address that is receiving the shares
     * @param _depositRequestId The deposit request identifier if the deposit is asynchronous. Ignore if the deposit is synchronous.
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units
     * @return navToMintAt The NAV at which the shares will be minted, exclusive of valueAllocated
     * @return metadata The format prefixed metadata of the deposit
     */
    function stDeposit(
        TRANCHE_UNIT _assets,
        address _caller,
        address _receiver,
        uint256 _depositRequestId
    )
        external
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintAt, bytes memory metadata);

    /**
     * @notice Processes the redemption of a specified number of shares from the senior tranche
     * @dev The function is expected to transfer the senior and junior assets directly to the receiver, based on the redemption claims
     * @param _shares The number of shares to redeem
     * @param _controller The controller that is allowed to operate the redemption
     * @param _receiver The address that is receiving the assets
     * @param _redemptionRequestId The redemption request identifier if the redemption is asynchronous. Ignore if the redemption is synchronous.
     * @return claims The distribution of assets that were transferred to the receiver on redemption, denominated in the respective tranches' tranche units
     * @return metadata The format prefixed metadata of the redemption
     */
    function stRedeem(
        uint256 _shares,
        address _controller,
        address _receiver,
        uint256 _redemptionRequestId
    )
        external
        returns (AssetClaims memory claims, bytes memory metadata);

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the junior tranche
     * @param _receiver The address that is depositing the assets
     * @return assets The maximum amount of assets that can be deposited into the junior tranche, denominated in the junior tranche's tranche units
     */
    function jtMaxDeposit(address _receiver) external view returns (TRANCHE_UNIT assets);

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn from the junior tranche
     * @param _owner The address that is withdrawing the assets
     * @return claimOnStNAV The notional claims on ST assets that the junior tranche has denominated in kernel's NAV units
     * @return claimOnJtNAV The notional claims on JT assets that the junior tranche has denominated in kernel's NAV units
     * @return stMaxWithdrawableNAV The maximum amount of assets that can be withdrawn from the senior tranche, denominated in the kernel's NAV units
     * @return jtMaxWithdrawableNAV The maximum amount of assets that can be withdrawn from the junior tranche, denominated in the kernel's NAV units
     */
    function jtMaxWithdrawable(address _owner)
        external
        view
        returns (NAV_UNIT claimOnStNAV, NAV_UNIT claimOnJtNAV, NAV_UNIT stMaxWithdrawableNAV, NAV_UNIT jtMaxWithdrawableNAV);

    /**
     * @notice Previews the deposit of a specified amount of assets into the junior tranche
     * @dev The kernel may decide to simulate the deposit and revert internally with the result
     * @dev Should revert if deposits are asynchronous
     * @param _assets The amount of assets to deposit, denominated in the junior tranche's tranche units
     * @return stateBeforeDeposit The state of the junior tranche before the deposit, after applying the pre-op sync
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units
     */
    function jtPreviewDeposit(TRANCHE_UNIT _assets) external view returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated);

    /**
     * @notice Previews the redemption of a specified number of shares from the junior tranche
     * @dev The kernel may decide to simulate the redemption and revert internally with the result
     * @dev Should revert if redemptions are asynchronous
     * @param _shares The number of shares to redeem
     * @return userClaim The distribution of assets that would be transferred to the receiver on redemption, denominated in the respective tranches' tranche units
     */
    function jtPreviewRedeem(uint256 _shares) external view returns (AssetClaims memory userClaim);

    /**
     * @notice Processes the deposit of a specified amount of assets into the junior tranche
     * @dev Assumes that the funds are transferred to the kernel before the deposit call is made
     * @param _assets The amount of assets to deposit, denominated in the junior tranche's tranche units
     * @param _caller The address that is depositing the assets
     * @param _receiver The address that is receiving the shares
     * @param _depositRequestId The deposit request identifier if the deposit is asynchronous. Ignore if the deposit is synchronous.
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units
     * @return navToMintAt The NAV at which the shares will be minted, exclusive of valueAllocated
     * @return metadata The format prefixed metadata of the deposit
     */
    function jtDeposit(
        TRANCHE_UNIT _assets,
        address _caller,
        address _receiver,
        uint256 _depositRequestId
    )
        external
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintAt, bytes memory metadata);

    /**
     * @notice Requests a redemption for a specified amount of shares from the underlying investment opportunity
     * @param _caller The address of the user requesting the withdrawal for the junior tranche
     * @param _shares The amount of shares of the junior tranche being requested to be redeemed
     * @param _controller The controller that is allowed to operate the lifecycle of the request.
     * @return requestId The request ID of this withdrawal request
     * @return metadata The format prefixed metadata of the redemption request or empty bytes if no metadata is shared
     */
    function jtRequestRedeem(address _caller, uint256 _shares, address _controller) external returns (uint256 requestId, bytes memory metadata);

    /**
     * @notice Returns the amount of assets pending redemption for a specific controller
     * @param _requestId The request ID of this withdrawal request
     * @param _controller The controller to query pending redemptions for
     * @return pendingShares The amount of shares pending redemption for the controller
     */
    function jtPendingRedeemRequest(uint256 _requestId, address _controller) external view returns (uint256 pendingShares);

    /**
     * @notice Returns the amount of shares claimable from completed redemption requests for a specific controller
     * @param _requestId The request ID of this withdrawal request
     * @param _controller The controller to query claimable redemptions for
     * @return claimableShares The amount of shares claimable from completed redemption requests
     */
    function jtClaimableRedeemRequest(uint256 _requestId, address _controller) external view returns (uint256 claimableShares);

    /**
     * @notice Cancels a pending redeem request for the specified controller
     * @dev This function is only relevant if the kernel supports redeem cancellation
     * @param _requestId The request ID of this deposit request
     * @param _controller The controller that is allowed to operate the cancellation
     */
    function jtCancelRedeemRequest(uint256 _requestId, address _controller) external;

    /**
     * @notice Returns whether there is a pending redeem cancellation for the specified controller
     * @dev This function is only relevant if the kernel supports redeem cancellation
     * @param _requestId The request ID of this deposit request
     * @param _controller The controller to query for pending cancellation
     * @return isPending True if there is a pending redeem cancellation
     */
    function jtPendingCancelRedeemRequest(uint256 _requestId, address _controller) external view returns (bool isPending);

    /**
     * @notice Returns the amount of assets claimable from a redeem cancellation for the specified controller
     * @dev This function is only relevant if the kernel supports redeem cancellation
     * @param _requestId The request ID of this deposit request
     * @param _controller The controller to query for claimable cancellation assets
     * @return shares The amount of shares claimable from redeem cancellation
     */
    function jtClaimableCancelRedeemRequest(uint256 _requestId, address _controller) external view returns (uint256 shares);

    /**
     * @notice Claims a canceled redeem request for a specified controller
     * @dev This function is only relevant if the kernel supports redeem cancellation
     * @param _requestId The request ID of this deposit request
     * @param _controller The controller corresponding to this request
     * @return shares The amount of shares claimed from the canceled redeem request
     */
    function jtClaimCancelRedeemRequest(uint256 _requestId, address _controller) external returns (uint256 shares);

    /**
     * @notice Processes the redemption of a specified number of shares from the junior tranche
     * @dev The function is expected to transfer the senior and junior assets directly to the receiver, based on the redemption claims
     * @param _shares The number of shares to redeem
     * @param _controller The controller that is allowed to operate the redemption
     * @param _receiver The address that is receiving the assets
     * @param _redemptionRequestId The redemption request identifier if the redemption is asynchronous. Ignore if the redemption is synchronous.
     * @return claims The distribution of assets that were transferred to the receiver on redemption, denominated in the respective tranches' tranche units
     * @return metadata The format prefixed metadata of the redemption or empty bytes if no metadata is shared
     */
    function jtRedeem(
        uint256 _shares,
        address _controller,
        address _receiver,
        uint256 _redemptionRequestId
    )
        external
        returns (AssetClaims memory claims, bytes memory metadata);

    /**
     * @notice Sets the new protocol fee recipient
     * @param _protocolFeeRecipient The address of the new protocol fee recipient
     */
    function setProtocolFeeRecipient(address _protocolFeeRecipient) external;

    /**
     * @notice Sets the new junior tranche redemption delay
     * @param _jtRedemptionDelayInSeconds The new junior tranche redemption delay in seconds
     */
    function setJuniorTrancheRedemptionDelay(uint24 _jtRedemptionDelayInSeconds) external;

    /**
     * @notice Returns the state of the kernel
     * @param seniorTranche The address of the Royco senior tranche associated with this kernel
     * @param stAsset The address of the asset that ST is denominated in: constitutes the ST's tranche units (type and precision)
     * @param juniorTranche The address of the Royco junior tranche associated with this kernel
     * @param jtAsset The address of the asset that JT is denominated in: constitutes the ST's tranche units (type and precision)
     * @param protocolFeeRecipient The market's configured protocol fee recipient
     * @param accountant The address of the Royco accountant used to perform per operation accounting for this kernel
     * @param jtRedemptionDelayInSeconds The redemption delay in seconds that a JT LP has to wait between requesting and executing a redemption
     */
    function getState()
        external
        view
        returns (
            address seniorTranche,
            address stAsset,
            address juniorTranche,
            address jtAsset,
            address protocolFeeRecipient,
            address accountant,
            uint24 jtRedemptionDelayInSeconds
        );
}
