// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { RoycoAuth } from "../../../auth/RoycoAuth.sol";
import { IAsyncJTWithdrawalKernel } from "../../../interfaces/kernel/IAsyncJTWithdrawalKernel.sol";
import { IRoycoKernel } from "../../../interfaces/kernel/IRoycoKernel.sol";
import { ERC_7540_CONTROLLER_DISCRIMINATED_REQUEST_ID } from "../../../libraries/Constants.sol";
import { TrancheAssetClaims } from "../../../libraries/Types.sol";
import { Operation, RequestRedeemSharesBehavior, SyncedAccountingState, TrancheType } from "../../../libraries/Types.sol";
import { NAV_UNIT, UnitsMathLib, toNAVUnits, toUint256 } from "../../../libraries/Units.sol";
import { RoycoKernel } from "../RoycoKernel.sol";

/// @title BaseAsyncJTRedemptionDelayKernel
/// @notice Abstract base contract for the junior tranche redemption delay kernel
abstract contract BaseAsyncJTRedemptionDelayKernel is IAsyncJTWithdrawalKernel, IRoycoKernel, RoycoAuth, RoycoKernel {
    using Math for uint256;
    using UnitsMathLib for NAV_UNIT;

    // keccak256(abi.encode(uint256(keccak256("Royco.storage.BaseAsyncJTRedemptionDelayKernel")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BASE_ASYNC_JT_REDEMPTION_DELAY_KERNEL_STORAGE_SLOT = 0xded0c80c14aecd5426bd643f18df17d9cea228e72fcaefe1b139ffca90913500;

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
    /// @notice Thrown when the function is not implemented
    error PREVIEW_REDEEM_DISABLED_FOR_ASYNC_REDEMPTION();

    /// @custom:storage-location erc7201:Royco.storage.BaseAsyncJTRedemptionDelayKernelState
    /// forge-lint: disable-next-item(pascal-case-struct)
    struct BaseAsyncJTRedemptionDelayKernelState {
        uint256 redemptionDelaySeconds;
        mapping(address controller => Redemption redemption) redemptions;
    }

    /// @dev Storage state for a redemption request
    /// @custom:field isCanceled Whether the redemption request has been canceled
    /// @custom:field totalJTSharesToRedeem The total number of JT shares to redeem
    /// @custom:field redemptionValueAtRequest The value of the redemption request at the time it was requested, denominated in the kernel's NAV units
    /// @custom:field redemptionAllowedAtTimestamp The timestamp at which the redemption request is allowed to be claimed
    struct Redemption {
        bool isCanceled;
        uint256 totalJTSharesToRedeem;
        NAV_UNIT redemptionValueAtRequest;
        uint256 redemptionAllowedAtTimestamp;
    }

    function __BaseAsyncJTRedemptionDelayKernel_init(uint256 _redemptionDelaySeconds) internal onlyInitializing {
        __BaseAsyncJTRedemptionDelayKernel_init_unchained(_redemptionDelaySeconds);
    }

    function __BaseAsyncJTRedemptionDelayKernel_init_unchained(uint256 _redemptionDelaySeconds) internal onlyInitializing {
        require(_redemptionDelaySeconds > 0, INVALID_WITHDRAWAL_DELAY_SECONDS(_redemptionDelaySeconds));
        __BaseAsyncJTRedemptionDelayKernel_init(_redemptionDelaySeconds);
    }

    /// @inheritdoc IRoycoKernel
    function jtPreviewRedeem(uint256) external view virtual override onlyJuniorTranche returns (TrancheAssetClaims memory) {
        revert PREVIEW_REDEEM_DISABLED_FOR_ASYNC_REDEMPTION();
    }

    // =============================
    // ERC7540 Asynchronous flow functions
    // =============================

    /// @inheritdoc IAsyncJTWithdrawalKernel
    function jtRequestRedeem(address, uint256 _shares, address _controller) external onlyJuniorTranche whenNotPaused returns (uint256 requestId) {
        BaseAsyncJTRedemptionDelayKernelState storage $ = _getBaseAsyncJTRedemptionDelayKernelState();

        // Execute a pre-op sync on accounting
        (SyncedAccountingState memory state,, uint256 totalTrancheShares) = _preOpSyncTrancheAccounting(TrancheType.JUNIOR);

        Redemption storage redemption = $.redemptions[_controller];
        require(!redemption.isCanceled, WITHDRAWAL_CANCELLED__CLAIM_BEFORE_REQUESTING_AGAIN());

        // Redeem Requests are purely controller-discriminated, so the request ID is 0
        requestId = ERC_7540_CONTROLLER_DISCRIMINATED_REQUEST_ID;

        // Compute the redemption value at request
        NAV_UNIT redemptionValueAtRequest = _redemptionValue(state.jtEffectiveNAV, _shares, totalTrancheShares);

        // Add the shares to the total shares to withdraw
        // If an existing redemption request exists, it's redemption delay is extended by the new redemption delay
        redemption.totalJTSharesToRedeem += _shares;
        redemption.redemptionValueAtRequest = redemption.redemptionValueAtRequest + redemptionValueAtRequest;
        redemption.redemptionAllowedAtTimestamp = block.timestamp + $.redemptionDelaySeconds;

        // Execute a post-op sync on accounting
        _postOpSyncTrancheAccounting(Operation.JT_REQUEST_REDEEM);
    }

    /// @inheritdoc IAsyncJTWithdrawalKernel
    function jtPendingRedeemRequest(uint256 _requestId, address _controller) external view onlyJuniorTranche returns (uint256 pendingShares) {
        require(_requestId == ERC_7540_CONTROLLER_DISCRIMINATED_REQUEST_ID, INVALID_REQUEST_ID(_requestId));
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
        require(_requestId == ERC_7540_CONTROLLER_DISCRIMINATED_REQUEST_ID, INVALID_REQUEST_ID(_requestId));

        claimableShares = _jtClaimableRedeemRequest(_controller);
    }

    /// @notice Returns the amount of JT shares claimable from a redemption request
    /// @param _controller The controller that is allowed to operate the claim
    /// @return claimableShares The amount of JT shares claimable from the redemption request
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
        require(_requestId == ERC_7540_CONTROLLER_DISCRIMINATED_REQUEST_ID, INVALID_REQUEST_ID(_requestId));
        BaseAsyncJTRedemptionDelayKernelState storage $ = _getBaseAsyncJTRedemptionDelayKernelState();
        Redemption storage redemption = $.redemptions[_controller];

        require(!redemption.isCanceled, WITHDRAWAL_ALREADY_CANCELED());
        redemption.isCanceled = true;
    }

    /// @inheritdoc IAsyncJTWithdrawalKernel
    function jtClaimCancelRedeemRequest(uint256 _requestId, address, address _controller) external onlyJuniorTranche whenNotPaused returns (uint256 shares) {
        require(_requestId == ERC_7540_CONTROLLER_DISCRIMINATED_REQUEST_ID, INVALID_REQUEST_ID(_requestId));
        BaseAsyncJTRedemptionDelayKernelState storage $ = _getBaseAsyncJTRedemptionDelayKernelState();
        Redemption memory redemption = $.redemptions[_controller];

        require(!redemption.isCanceled, WITHDRAWAL_ALREADY_CANCELED());
        shares = redemption.totalJTSharesToRedeem;
        require(shares != 0, MUST_CLAIM_NON_ZERO_SHARES());

        delete $.redemptions[_controller];
    }

    /// @inheritdoc IAsyncJTWithdrawalKernel
    function jtClaimableCancelRedeemRequest(uint256 _requestId, address _controller) external view onlyJuniorTranche returns (uint256 shares) {
        require(_requestId == ERC_7540_CONTROLLER_DISCRIMINATED_REQUEST_ID, INVALID_REQUEST_ID(_requestId));
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
    function setRedemptionDelay(uint256 _redemptionDelaySeconds) external restricted {
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
        NAV_UNIT _currentJTEffectiveNAV,
        uint256 _sharesToRedeem,
        uint256 _totalShares
    )
        internal
        returns (NAV_UNIT valueClaimed)
    {
        BaseAsyncJTRedemptionDelayKernelState storage $ = _getBaseAsyncJTRedemptionDelayKernelState();
        Redemption storage redemption = $.redemptions[_controller];

        // JT LPs are not entitled to any of the upside during the redemption delay
        // They are however, liable for providing coverage to ST LPs during the redemption delay
        NAV_UNIT redemptionValueAtCurrentNAV = _redemptionValue(_currentJTEffectiveNAV, _sharesToRedeem, _totalShares);
        NAV_UNIT redemptionValueAtRequest = redemption.redemptionValueAtRequest.mulDiv(_sharesToRedeem, redemption.totalJTSharesToRedeem, Math.Rounding.Floor);
        valueClaimed = UnitsMathLib.min(redemptionValueAtCurrentNAV, redemptionValueAtRequest);

        uint256 sharesRemaining = redemption.totalJTSharesToRedeem - _sharesToRedeem;
        if (sharesRemaining != 0) {
            // Update the redemption value at request for the remaining shares
            redemption.redemptionValueAtRequest = redemption.redemptionValueAtRequest - redemptionValueAtRequest;
            redemption.totalJTSharesToRedeem = sharesRemaining;
        } else {
            // If there are no remaining shares, delete the controller's redemption
            delete $.redemptions[_controller];
        }
    }

    /// @notice Computes the value of a redemption request
    /// @param _currentJTEffectiveNAV The current effective NAV of JT
    /// @param _shares The amount of JT shares to redeem
    /// @param _totalShares The total number of JT shares in the tranche, including the virtual shares
    /// @return value The value of the redemption request
    function _redemptionValue(NAV_UNIT _currentJTEffectiveNAV, uint256 _shares, uint256 _totalShares) internal pure returns (NAV_UNIT value) {
        return toNAVUnits(_shares.mulDiv(toUint256(_currentJTEffectiveNAV), _totalShares, Math.Rounding.Floor));
    }

    function _getBaseAsyncJTRedemptionDelayKernelState() private pure returns (BaseAsyncJTRedemptionDelayKernelState storage $) {
        assembly ("memory-safe") {
            $.slot := BASE_ASYNC_JT_REDEMPTION_DELAY_KERNEL_STORAGE_SLOT
        }
    }
}
