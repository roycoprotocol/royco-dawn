// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TRANCHE_UNIT } from "../../libraries/Types.sol";

/**
 * @title IAsyncSTDepositKernel
 * @notice Interface for Royco kernels that employ an asynchronous deposit flow for the senior tranche
 * @dev We mandate that kernels implement the cancellation functions because of the market's utilization changing between request and claim
 *      if the underlying investment opportunity supports it
 */
interface IAsyncSTDepositKernel {
    /**
     * @notice Requests a deposit of a specified amount of an asset into the underlying investment opportunity
     * @dev Assumes that the funds are transferred to the kernel before the deposit call is made
     * @param _caller The address of the user requesting the deposit for the senior tranche
     * @param _assets The amount of the asset to deposit into the underlying investment opportunity
     * @param _controller The controller that is allowed to operate the lifecycle of this deposit request
     * @return requestId The request ID of this deposit request
     * @return metadata The format prefixed metadata of the deposit request or empty bytes if no metadata is shared
     */
    function stRequestDeposit(address _caller, TRANCHE_UNIT _assets, address _controller) external returns (uint256 requestId, bytes memory metadata);

    /**
     * @notice Returns the amount of assets pending deposit for a specified controller
     * @param _requestId The request ID of this deposit request
     * @param _controller The controller corresponding to this request
     * @return pendingAssets The amount of assets pending deposit for the controller
     */
    function stPendingDepositRequest(uint256 _requestId, address _controller) external view returns (TRANCHE_UNIT pendingAssets);

    /**
     * @notice Claims a canceled deposit request for a specified controller
     * @dev It is expected that this function transfers the assets to the receiver directly after the cancellation is processed
     * @param _requestId The request ID of this deposit request
     * @param _receiver The receiver of the canceled deposit assets
     * @param _controller The controller corresponding to this request
     * @return assets The amount of assets claimed from the canceled deposit request denominated in the tranche's base asset
     */
    function stClaimCancelDepositRequest(uint256 _requestId, address _receiver, address _controller) external returns (TRANCHE_UNIT assets);

    /**
     * @notice Returns the amount of assets claimable from a processed deposit request for a specified controller
     * @param _requestId The request ID of this deposit request
     * @param _controller The controller corresponding to this request
     * @return claimableAssets The amount of assets claimable from processed deposit request denominated in the tranche's base asset
     */
    function stClaimableDepositRequest(uint256 _requestId, address _controller) external view returns (TRANCHE_UNIT claimableAssets);

    /**
     * @notice Cancels a pending deposit request for the specified controller
     * @dev The tranche calling this function must have a pending deposit request with this requestId and/or controller
     * @param _caller The address of the user requesting the cancellation of a deposit request for the senior tranche
     * @param _requestId The request ID of this deposit request
     * @param _controller The controller that is allowed to operate the lifecycle of this cancellation request
     */
    function stCancelDepositRequest(address _caller, uint256 _requestId, address _controller) external;

    /**
     * @notice Returns whether there is a pending deposit cancellation for the specified controller
     * @dev This function is only relevant if the kernel supports deposit cancellation for the senior tranche
     * @param _requestId The request ID of this deposit request
     * @param _controller The controller to query for pending cancellation
     * @return isPending True if there is a pending deposit cancellation
     */
    function stPendingCancelDepositRequest(uint256 _requestId, address _controller) external view returns (bool isPending);

    /**
     * @notice Returns the amount of assets claimable from a deposit cancellation for the specified controller
     * @dev This function is only relevant if the kernel supports deposit cancellation for the senior tranche
     * @param _requestId The request ID of this deposit request
     * @param _controller The controller to query for claimable cancellation assets
     * @return assets The amount of assets claimable from deposit cancellation denominated in the tranche's base asset
     */
    function stClaimableCancelDepositRequest(uint256 _requestId, address _controller) external view returns (TRANCHE_UNIT assets);
}
