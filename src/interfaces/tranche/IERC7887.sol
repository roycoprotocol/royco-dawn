// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title ERC-7887: Cancelation for ERC-7540 Tokenized Vaults (Draft)
/// @notice Interface extending ERC-7540 asynchronous vaults with cancelation flows.
/// @dev Contracts implementing this interface MUST also implement ERC-165.
interface IERC7887 {
    // =============================
    // Events
    // =============================

    /// @notice Emitted when a controller requests cancelation of a deposit Request.
    /// @param controller The controller of the Request (may equal msg.sender or its approved operator).
    /// @param requestId The identifier of the deposit Request being canceled.
    /// @param sender The caller of the cancelDepositRequest.
    event CancelDepositRequest(address indexed controller, uint256 indexed requestId, address sender);

    /// @notice Emitted when a controller claims a deposit cancelation.
    /// @param controller The controller of the canceled Request.
    /// @param receiver The recipient of the returned assets.
    /// @param requestId The identifier of the canceled Request.
    /// @param sender The caller of the claimCancelDepositRequest.
    /// @param assets The amount of assets claimed.
    event CancelDepositClaim(address indexed controller, address indexed receiver, uint256 indexed requestId, address sender, uint256 assets);

    /// @notice Emitted when a controller requests cancelation of a redeem Request.
    /// @param controller The controller of the Request (may equal msg.sender or its approved operator).
    /// @param requestId The identifier of the redeem Request being canceled.
    /// @param sender The caller of the cancelRedeemRequest.
    event CancelRedeemRequest(address indexed controller, uint256 indexed requestId, address sender);

    /// @notice Emitted when a controller claims a redeem cancelation.
    /// @param controller The controller of the canceled Request.
    /// @param receiver The recipient of the returned shares.
    /// @param requestId The identifier of the canceled Request.
    /// @param sender The caller of the claimCancelRedeemRequest.
    /// @param shares The amount of shares claimed.
    event CancelRedeemClaim(address indexed controller, address indexed receiver, uint256 indexed requestId, address sender, uint256 shares);

    // =============================
    // Deposit Cancelation
    // =============================

    /// @notice Submit an asynchronous deposit cancelation Request.
    /// @dev MUST emit {CancelDepositRequest}.
    /// @param _requestId The identifier of the original deposit Request.
    /// @param _controller The controller of the Request (must equal msg.sender unless operator-approved).
    function cancelDepositRequest(uint256 _requestId, address _controller) external;

    /// @notice Returns whether a deposit cancelation Request is pending for the given controller.
    /// @dev MUST NOT vary by caller. MUST NOT revert except for unreasonable input overflow.
    /// @param _requestId The identifier of the original deposit Request.
    /// @param _controller The controller address.
    /// @return isPending True if the cancelation is pending.
    function pendingCancelDepositRequest(uint256 _requestId, address _controller) external view returns (bool isPending);

    /// @notice Returns the amount of assets claimable for a deposit cancelation Request for the controller.
    /// @dev MUST NOT vary by caller. MUST NOT revert except for unreasonable input overflow.
    /// @param _requestId The identifier of the original deposit Request.
    /// @param _controller The controller address.
    /// @return assets The amount of assets claimable.
    function claimableCancelDepositRequest(uint256 _requestId, address _controller) external view returns (uint256 assets);

    /// @notice Claim a deposit cancelation Request, transferring assets to the receiver.
    /// @dev MUST emit {CancelDepositClaim}.
    /// @param _requestId The identifier of the canceled deposit Request.
    /// @param _receiver The recipient of assets.
    /// @param _controller The controller of the Request (must equal msg.sender unless operator-approved).
    function claimCancelDepositRequest(uint256 _requestId, address _receiver, address _controller) external;

    // =============================
    // Redeem Cancelation
    // =============================

    /// @notice Submit an asynchronous redeem cancelation Request.
    /// @dev MUST emit {CancelRedeemRequest}.
    /// @param _requestId The identifier of the original redeem Request.
    /// @param _controller The controller of the Request (must equal msg.sender unless operator-approved).
    function cancelRedeemRequest(uint256 _requestId, address _controller) external;

    /// @notice Returns whether a redeem cancelation Request is pending for the given controller.
    /// @dev MUST NOT vary by caller. MUST NOT revert except for unreasonable input overflow.
    /// @param _requestId The identifier of the original redeem Request.
    /// @param _controller The controller address.
    /// @return isPending True if the cancelation is pending.
    function pendingCancelRedeemRequest(uint256 _requestId, address _controller) external view returns (bool isPending);

    /// @notice Returns the amount of shares claimable for a redeem cancelation Request for the controller.
    /// @dev MUST NOT vary by caller. MUST NOT revert except for unreasonable input overflow.
    /// @param _requestId The identifier of the original redeem Request.
    /// @param _controller The controller address.
    /// @return shares The amount of shares claimable.
    function claimableCancelRedeemRequest(uint256 _requestId, address _controller) external view returns (uint256 shares);

    /// @notice Claim a redeem cancelation Request, transferring shares to the receiver.
    /// @dev MUST emit {CancelRedeemClaim}.
    /// @param _requestId The identifier of the canceled redeem Request.
    /// @param _receiver The recipient of shares.
    /// @param _owner The owner for whom the shares are claimed (per draft spec).
    function claimCancelRedeemRequest(uint256 _requestId, address _receiver, address _owner) external;
}
