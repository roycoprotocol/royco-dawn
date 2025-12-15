// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { RoycoAuth } from "../../../auth/RoycoAuth.sol";
import { RoycoRoles } from "../../../auth/RoycoRoles.sol";
import { IAsyncJTWithdrawalKernel } from "../../../interfaces/kernel/IAsyncJTWithdrawalKernel.sol";
import { IRoycoKernel } from "../../../interfaces/kernel/IRoycoKernel.sol";
import { ConstantsLib } from "../../../libraries/ConstantsLib.sol";
import { RequestRedeemSharesBehavior } from "../../../libraries/Types.sol";
import { Operation, RoycoKernel, SyncedNAVsPacket } from "../RoycoKernel.sol";

/// @title BaseAsyncJTRedemptionDelayKernel
/// @notice Abstract base contract for the junior tranche redemption delay kernel
abstract contract BaseAsyncJTRedemptionDelayKernel is IAsyncJTWithdrawalKernel, IRoycoKernel, RoycoAuth, RoycoKernel {
    using Math for uint256;

    // keccak256(abi.encode(uint256(keccak256("Royco.storage.BaseAsyncJTRedemptionDelayKernel")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BASE_ASYNC_JT_REDEMPTION_DELAY_KERNEL_STORAGE_SLOT = 0xb5c6c83047900617b0d8e0a777db642d7504e41a6e0a65096bced63526c1bf00;

    RequestRedeemSharesBehavior public constant JT_REQUEST_REDEEM_SHARES_BEHAVIOR = RequestRedeemSharesBehavior.BURN_ON_REDEEM;

    /// @dev Emitted when the redemption delay is updated
    event RedemptionDelayUpdated(uint256 redemptionDelaySeconds);

    /// @notice Thrown when the redemption delay is zero
    error INVALID_WITHDRAWAL_DELAY_SECONDS(uint256 redemptionDelaySeconds);
    /// @notice Thrown when the total shares to withdraw is less than the shares to redeem
    error INSUFFICIENT_SHARES(uint256 sharesToRedeem, uint256 totalSharesToRedeem);
    /// @notice Thrown when the redemption is not allowed
    error WITHDRAWAL_NOT_ALLOWED(uint256 redemptionAllowedAtTimestamp);
    /// @notice Thrown when the request ID is invalid
    error INVALID_REQUEST_ID(uint256 requestId);
    /// @notice Thrown when the redemption is cancelled and the controller is trying to claim before requesting again
    error WITHDRAWAL_CANCELLED__CLAIM_BEFORE_REQUESTING_AGAIN();
    /// @notice Thrown when the redemption is already canceled
    error WITHDRAWAL_ALREADY_CANCELED();
    /// @notice Thrown when the shares to claim are zero
    error MUST_CLAIM_NON_ZERO_SHARES();

    /// @custom:storage-location erc7201:Royco.storage.BaseAsyncJTRedemptionDelayKernelState
    /// forge-lint: disable-next-item(pascal-case-struct)
    struct BaseAsyncJTRedemptionDelayKernelState {
        uint256 redemptionDelaySeconds;
        mapping(address controller => Redemption redemption) redemptions;
    }

    struct Redemption {
        bool isCanceled;
        uint256 totalJTSharesToRedeem;
        uint256 redemptionValueAtRequest;
        uint256 redemptionAllowedAtTimestamp;
    }

    function __BaseAsyncJTRedemptionDelayKernel_init(uint256 _redemptionDelaySeconds) internal onlyInitializing {
        __BaseAsyncJTRedemptionDelayKernel_init_unchained(_redemptionDelaySeconds);
    }

    function __BaseAsyncJTRedemptionDelayKernel_init_unchained(uint256 _redemptionDelaySeconds) internal onlyInitializing {
        require(_redemptionDelaySeconds > 0, INVALID_WITHDRAWAL_DELAY_SECONDS(_redemptionDelaySeconds));
        __BaseAsyncJTRedemptionDelayKernel_init(_redemptionDelaySeconds);
    }

    // =============================
    // ERC7540 Asynchronous flow functions
    // =============================

    /// @inheritdoc IAsyncJTWithdrawalKernel
    function jtRequestRedeem(
        address,
        uint256 _shares,
        uint256 _totalShares,
        address _controller
    )
        external
        onlyJuniorTranche
        whenNotPaused
        returns (uint256 requestId)
    {
        uint256 jtEffectiveNAV = _preOpSyncTrancheNAVs().jtEffectiveNAV;
        BaseAsyncJTRedemptionDelayKernelState storage $ = _getBaseAsyncJTRedemptionDelayKernelState();

        Redemption storage redemption = $.redemptions[_controller];
        require(!redemption.isCanceled, WITHDRAWAL_CANCELLED__CLAIM_BEFORE_REQUESTING_AGAIN());

        // Redeem Requests are purely controller-discriminated, so the request ID is 0
        requestId = ConstantsLib.ERC_7540_CONTROLLER_DISCRIMINATED_REQUEST_ID;

        // Compute the redemption value at request
        uint256 redemptionValueAtRequest = _redemptionValue(jtEffectiveNAV, _shares, _totalShares);

        // Add the shares to the total shares to withdraw
        // If an existing redemption request exists, it's redemption delay is extended by the new redemption delay
        redemption.totalJTSharesToRedeem += _shares;
        redemption.redemptionValueAtRequest += redemptionValueAtRequest;
        redemption.redemptionAllowedAtTimestamp = block.timestamp + $.redemptionDelaySeconds;
    }

    /// @inheritdoc IAsyncJTWithdrawalKernel
    function jtPendingRedeemRequest(uint256 _requestId, address _controller) external view onlyJuniorTranche returns (uint256 pendingShares) {
        require(_requestId == ConstantsLib.ERC_7540_CONTROLLER_DISCRIMINATED_REQUEST_ID, INVALID_REQUEST_ID(_requestId));
        BaseAsyncJTRedemptionDelayKernelState storage $ = _getBaseAsyncJTRedemptionDelayKernelState();
        Redemption storage redemption = $.redemptions[_controller];

        // If the redemption is canceled, return 0
        if (redemption.isCanceled) {
            return 0;
        }

        // If the redemption is not allowed yet, return 0
        if (redemption.redemptionAllowedAtTimestamp >= block.timestamp) {
            return 0;
        }

        pendingShares = redemption.totalJTSharesToRedeem;
    }

    /// @inheritdoc IAsyncJTWithdrawalKernel
    function jtClaimableRedeemRequest(uint256 _requestId, address _controller) external view onlyJuniorTranche returns (uint256 claimableShares) {
        require(_requestId == ConstantsLib.ERC_7540_CONTROLLER_DISCRIMINATED_REQUEST_ID, INVALID_REQUEST_ID(_requestId));

        claimableShares = _jtClaimableRedeemRequest(_controller);
    }

    function _jtClaimableRedeemRequest(address _controller) internal view returns (uint256 claimableShares) {
        BaseAsyncJTRedemptionDelayKernelState storage $ = _getBaseAsyncJTRedemptionDelayKernelState();
        Redemption storage redemption = $.redemptions[_controller];

        // If the redemption is canceled, return 0
        if (redemption.isCanceled) {
            return 0;
        }

        // If the redemption is not allowed yet, return 0
        if (redemption.redemptionAllowedAtTimestamp < block.timestamp) {
            return 0;
        }

        claimableShares = redemption.totalJTSharesToRedeem;
    }

    // =============================
    // ERC7887 Cancelation functions
    // =============================

    /// @inheritdoc IAsyncJTWithdrawalKernel
    function jtCancelRedeemRequest(uint256 _requestId, address _controller) external onlyJuniorTranche whenNotPaused {
        require(_requestId == ConstantsLib.ERC_7540_CONTROLLER_DISCRIMINATED_REQUEST_ID, INVALID_REQUEST_ID(_requestId));
        BaseAsyncJTRedemptionDelayKernelState storage $ = _getBaseAsyncJTRedemptionDelayKernelState();
        Redemption storage redemption = $.redemptions[_controller];

        require(!redemption.isCanceled, WITHDRAWAL_ALREADY_CANCELED());
        redemption.isCanceled = true;
    }

    /// @inheritdoc IAsyncJTWithdrawalKernel
    function jtClaimCancelRedeemRequest(uint256 _requestId, address, address _controller) external onlyJuniorTranche whenNotPaused returns (uint256 shares) {
        require(_requestId == ConstantsLib.ERC_7540_CONTROLLER_DISCRIMINATED_REQUEST_ID, INVALID_REQUEST_ID(_requestId));
        BaseAsyncJTRedemptionDelayKernelState storage $ = _getBaseAsyncJTRedemptionDelayKernelState();
        Redemption memory redemption = $.redemptions[_controller];

        require(!redemption.isCanceled, WITHDRAWAL_ALREADY_CANCELED());
        shares = redemption.totalJTSharesToRedeem;
        require(shares != 0, MUST_CLAIM_NON_ZERO_SHARES());

        delete $.redemptions[_controller];
    }

    /// @inheritdoc IAsyncJTWithdrawalKernel
    function jtClaimableCancelRedeemRequest(uint256 _requestId, address _controller) external view onlyJuniorTranche returns (uint256 shares) {
        require(_requestId == ConstantsLib.ERC_7540_CONTROLLER_DISCRIMINATED_REQUEST_ID, INVALID_REQUEST_ID(_requestId));
        BaseAsyncJTRedemptionDelayKernelState storage $ = _getBaseAsyncJTRedemptionDelayKernelState();

        // If the redemption is not canceled, return 0
        if (!$.redemptions[_controller].isCanceled) {
            return 0;
        }

        shares = $.redemptions[_controller].totalJTSharesToRedeem;
    }

    /// @inheritdoc IAsyncJTWithdrawalKernel
    function jtPendingCancelRedeemRequest(uint256, address) external view onlyJuniorTranche returns (bool isPending) {
        // Cancelation requests are always processed instantly, so there is no pending cancelation
        isPending = false;
    }

    /// @notice Sets the redemption delay
    /// @param _redemptionDelaySeconds The new redemption delay in seconds
    function setRedemptionDelay(uint256 _redemptionDelaySeconds) external onlyRole(RoycoRoles.KERNEL_ADMIN_ROLE) {
        _getBaseAsyncJTRedemptionDelayKernelState().redemptionDelaySeconds = _redemptionDelaySeconds;
        emit RedemptionDelayUpdated(_redemptionDelaySeconds);
    }

    /// @notice Returns the redemption delay
    /// @return redemptionDelaySeconds The redemption delay in seconds
    function redemptionDelay() external view returns (uint256) {
        return _getBaseAsyncJTRedemptionDelayKernelState().redemptionDelaySeconds;
    }

    /// @notice Accounts for the total JT shares claimed from a claimable redemption request
    /// @param _controller The controller that is allowed to operate the claim
    /// @param _currentJTEffectiveNAV The current effective NAV of JT
    /// @param _sharesToRedeem The amount of JT shares to redeem
    /// @param _totalShares The total number of JT shares to withdraw
    /// @return valueClaimed The value of the shares claimed from the redemption request
    function _processClaimableRedeemRequest(
        address _controller,
        uint256 _currentJTEffectiveNAV,
        uint256 _sharesToRedeem,
        uint256 _totalShares
    )
        internal
        returns (uint256 valueClaimed)
    {
        BaseAsyncJTRedemptionDelayKernelState storage $ = _getBaseAsyncJTRedemptionDelayKernelState();
        Redemption storage redemption = $.redemptions[_controller];

        // JT LPs are not entitled to any of the upside during the redemption delay
        // They are however, liable for providing coverage to ST LPs during the redemption delay
        uint256 redemptionValueAtCurrentNAV = _redemptionValue(_currentJTEffectiveNAV, _sharesToRedeem, _totalShares);
        uint256 redemptionValueAtRequest = redemption.redemptionValueAtRequest.mulDiv(_sharesToRedeem, redemption.totalJTSharesToRedeem);
        valueClaimed = Math.min(redemptionValueAtCurrentNAV, redemptionValueAtRequest);

        uint256 sharesRemaining = redemption.totalJTSharesToRedeem - _sharesToRedeem;
        if (sharesRemaining != 0) {
            // Update the redemption value at request for the remaining shares
            redemption.redemptionValueAtRequest -= redemptionValueAtRequest;
            redemption.totalJTSharesToRedeem = sharesRemaining;
        } else {
            // If there are no remaining shares, delete the controller's redemption
            delete $.redemptions[_controller];
        }
    }

    /// @notice Computes the value of a redemption request
    /// @param _currentJTEffectiveNAV The current effective NAV of JT
    /// @param _shares The amount of JT shares to redeem
    /// @param _totalShares The total number of JT shares to withdraw
    /// @return value The value of the redemption request
    function _redemptionValue(uint256 _currentJTEffectiveNAV, uint256 _shares, uint256 _totalShares) internal pure returns (uint256 value) {
        return _shares.mulDiv(_currentJTEffectiveNAV, _totalShares, Math.Rounding.Floor);
    }

    function _getBaseAsyncJTRedemptionDelayKernelState() private pure returns (BaseAsyncJTRedemptionDelayKernelState storage $) {
        assembly ("memory-safe") {
            $.slot := BASE_ASYNC_JT_REDEMPTION_DELAY_KERNEL_STORAGE_SLOT
        }
    }
}
