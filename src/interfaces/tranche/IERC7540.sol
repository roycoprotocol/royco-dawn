// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title IERC7540
 * @notice ERC-7540: Asynchronous ERC-4626 Tokenized Vaults
 * @dev Specification: https://eips.ethereum.org/EIPS/eip-7540
 *
 * Extends ERC-4626 with asynchronous Request flows for deposits and/or redemptions.
 * Implementations MAY choose to support either or both async flows; unsupported flows
 * MUST follow ERC-4626 synchronous behavior. Implementations MUST support ERC-165.
 *
 * Key definitions:
 * - Request: requestDeposit/requestRedeem to enter/exit the vault asynchronously
 * - Pending: Request submitted, not yet claimable
 * - Claimable: Request processed; controller can claim using ERC-4626 claim functions
 * - Claimed: Request finalized via ERC-4626 deposit/mint or redeem/withdraw
 * - controller: owner of the Request; can manage and claim it (or via operator)
 * - operator: account approved to act on behalf of a controller
 */
interface IERC7540 {
    /// @notice Operator approval updated for a controller.
    /// @dev MUST be logged when operator status is set; MAY be logged when unchanged.
    /// @param owner The controller setting an operator.
    /// @param operator The operator being approved/revoked.
    /// @param approved New approval status.
    event OperatorSet(address indexed owner, address indexed operator, bool approved);

    /// @notice Assets locked to request an asynchronous deposit.
    /// @dev MUST be emitted by requestDeposit.
    /// @param controller The controller of the Request.
    /// @param owner The owner whose assets were locked.
    /// @param requestId The identifier for the Request (see Request Ids semantics).
    /// @param sender The caller of requestDeposit (may differ from owner).
    /// @param assets The amount of assets requested.
    event DepositRequest(address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets);

    /// @notice Shares locked (or assumed control of) to request an asynchronous redemption.
    /// @dev MUST be emitted by requestRedeem.
    /// @param controller The controller of the Request (may differ from owner).
    /// @param owner The owner whose shares were locked or assumed.
    /// @param requestId The identifier for the Request (see Request Ids semantics).
    /// @param sender The caller of requestRedeem (may differ from owner).
    /// @param shares The amount of shares requested to redeem.
    event RedeemRequest(address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares);

    /// @notice Transfer assets from owner and submit an async deposit Request.
    /// @dev MUST emit DepositRequest. MUST support ERC20 approve/transferFrom on the asset.
    /// @dev MUST revert if all assets cannot be requested (limits/slippage/approval/etc).
    /// @param _assets Amount of assets to request.
    /// @param _controller Controller of the Request (msg.sender unless operator-approved).
    /// @param _owner Source of the assets; MUST be msg.sender unless operator-approved.
    /// @return requestId Discriminator paired with controller (see Request Ids semantics).
    function requestDeposit(uint256 _assets, address _controller, address _owner) external returns (uint256 requestId);

    /// @notice Amount of requested assets in Pending state for controller/requestId.
    /// @dev MUST NOT include amounts in Claimable; MUST NOT vary by caller.
    /// @param _requestId Request identifier.
    /// @param _controller Controller address.
    /// @return pendingAssets Amount in Pending.
    function pendingDepositRequest(uint256 _requestId, address _controller) external view returns (uint256 pendingAssets);

    /// @notice Amount of requested assets in Claimable state for controller/requestId.
    /// @dev MUST NOT include amounts in Pending; MUST NOT vary by caller.
    /// @param _requestId Request identifier.
    /// @param _controller Controller address.
    /// @return claimableAssets Amount in Claimable.
    function claimableDepositRequest(uint256 _requestId, address _controller) external view returns (uint256 claimableAssets);

    /// @notice Claim an async deposit by calling ERC-4626 deposit.
    /// @dev Overload per ERC-7540. MUST revert unless msg.sender == controller or operator.
    /// @param _assets Assets to claim.
    /// @param _receiver Recipient of shares.
    /// @param _controller Controller discriminating the claim when sender is operator.
    /// @return shares Shares minted.
    function deposit(uint256 _assets, address _receiver, address _controller) external returns (uint256 shares);

    /// @notice Claim an async deposit by calling ERC-4626 mint.
    /// @dev Overload per ERC-7540. MUST revert unless msg.sender == controller or operator.
    /// @param _shares Shares to mint to receiver.
    /// @param _receiver Recipient of shares.
    /// @param _controller Controller discriminating the claim when sender is operator.
    /// @return assets Assets consumed.
    function mint(uint256 _shares, address _receiver, address _controller) external returns (uint256 assets);

    /// @notice Assume control of shares from owner and submit an async redeem Request.
    /// @dev MUST emit RedeemRequest. MUST revert if all shares cannot be requested.
    /// @param _shares Amount of shares to request redemption for.
    /// @param _controller Controller of the Request (msg.sender unless operator-approved).
    /// @param _owner Owner of the shares; MUST be msg.sender unless operator-approved.
    /// @return requestId Discriminator paired with controller (see Request Ids semantics).
    function requestRedeem(uint256 _shares, address _controller, address _owner) external returns (uint256 requestId);

    /// @notice Amount of requested shares in Pending state for controller/requestId.
    /// @dev MUST NOT include amounts in Claimable; MUST NOT vary by caller.
    /// @param _requestId Request identifier.
    /// @param _controller Controller address.
    /// @return pendingShares Amount in Pending.
    function pendingRedeemRequest(uint256 _requestId, address _controller) external view returns (uint256 pendingShares);

    /// @notice Amount of requested shares in Claimable state for controller/requestId.
    /// @dev MUST NOT include amounts in Pending; MUST NOT vary by caller.
    /// @param _requestId Request identifier.
    /// @param _controller Controller address.
    /// @return claimableShares Amount in Claimable.
    function claimableRedeemRequest(uint256 _requestId, address _controller) external view returns (uint256 claimableShares);

    /// @notice Claim an async redemption by calling ERC-4626 redeem.
    /// @dev Overload per ERC-7540. MUST revert unless msg.sender == controller or operator.
    /// @param _shares Shares to redeem.
    /// @param _receiver Recipient of assets.
    /// @param _controller Controller discriminating the claim when sender is operator.
    /// @return assets Assets returned.
    function redeem(uint256 _shares, address _receiver, address _controller) external returns (uint256 assets);

    /// @notice Claim an async redemption by calling ERC-4626 withdraw.
    /// @dev Overload per ERC-7540. MUST revert unless msg.sender == controller or operator.
    /// @param _assets Assets to withdraw.
    /// @param _receiver Recipient of assets.
    /// @param _controller Controller discriminating the claim when sender is operator.
    /// @return shares Shares burned.
    function withdraw(uint256 _assets, address _receiver, address _controller) external returns (uint256 shares);

    /// @notice Returns true if operator is approved for controller.
    /// @param _controller Controller address.
    /// @param _operator Operator address.
    /// @return status Operator approval status.
    function isOperator(address _controller, address _operator) external view returns (bool);

    /// @notice Approve or revoke an operator for the msg.sender (controller).
    /// @dev MUST set operator status, emit OperatorSet, and return true.
    /// @param _operator Operator to set.
    /// @param _approved New approval status.
    /// @return success True.
    function setOperator(address _operator, bool _approved) external returns (bool);
}
