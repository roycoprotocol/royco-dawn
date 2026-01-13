// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoBase } from "../../base/RoycoBase.sol";
import { ExecutionModel, IRoycoKernel, SharesRedemptionModel } from "../../interfaces/kernel/IRoycoKernel.sol";
import { IRoycoVaultTranche } from "../../interfaces/tranche/IRoycoVaultTranche.sol";
import { ERC_7540_CONTROLLER_DISCRIMINATED_REQUEST_ID, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../../libraries/Constants.sol";
import { RedemptionRequest, RoycoKernelInitParams, RoycoKernelState, RoycoKernelStorageLib } from "../../libraries/RoycoKernelStorageLib.sol";
import { ActionMetadataFormat, AssetClaims, SyncedAccountingState, TrancheType } from "../../libraries/Types.sol";
import { Math, NAV_UNIT, TRANCHE_UNIT, UnitsMathLib } from "../../libraries/Units.sol";
import { UtilsLib } from "../../libraries/UtilsLib.sol";
import { IRoycoAccountant, Operation } from "./../../interfaces/IRoycoAccountant.sol";

/**
 * @title RoycoKernel
 * @notice Abstract contract for Royco kernel implementations
 * @dev Provides the foundational logic for kernel contracts including pre and post operation NAV reconciliation, coverage enforcement logic,
 *      and base wiring for tranche synchronization. All concrete kernel implementations should inherit from the Royco Kernel.
 */
abstract contract RoycoKernel is IRoycoKernel, RoycoBase {
    using UnitsMathLib for NAV_UNIT;
    using UnitsMathLib for TRANCHE_UNIT;
    using UtilsLib for bytes;

    /// @inheritdoc IRoycoKernel
    /// @dev There is always a redemption delay on the junior tranche
    ExecutionModel public constant JT_REDEEM_EXECUTION_MODEL = ExecutionModel.ASYNC;

    /// @inheritdoc IRoycoKernel
    SharesRedemptionModel public constant JT_REQUEST_REDEEM_SHARES_BEHAVIOR = SharesRedemptionModel.BURN_ON_CLAIM_REDEEM;

    /// @dev Permissions the function to only the market's senior tranche
    /// @dev Should be placed on all ST deposit and withdraw functions
    modifier onlySeniorTranche() {
        require(msg.sender == RoycoKernelStorageLib._getRoycoKernelStorage().seniorTranche, ONLY_SENIOR_TRANCHE());
        _;
    }

    /// @dev Permissions the function to only the market's junior tranche
    /// @dev Should be placed on all JT deposit and withdraw functions
    modifier onlyJuniorTranche() {
        require(msg.sender == RoycoKernelStorageLib._getRoycoKernelStorage().juniorTranche, ONLY_JUNIOR_TRANCHE());
        _;
    }

    /// @notice Modifer to check that the provided JT redemption request ID is valid for the given controller
    /// @param _controller The controller to check the redemption request ID for
    /// @param _requestId The JT redemption request ID to validate
    modifier checkJTRedemptionRequestId(address _controller, uint256 _requestId) {
        RoycoKernelState storage $ = RoycoKernelStorageLib._getRoycoKernelStorage();
        require($.jtControllerToIdToRedemptionRequest[_controller][_requestId].totalJTSharesToRedeem != 0, INVALID_REQUEST_ID(_requestId));
        _;
    }

    // =============================
    // Initializer and State Accessor Functions
    // =============================

    /**
     * @notice Initializes the base kernel state
     * @dev Initializes any parent contracts and the base kernel state
     * @param _params The standard initialization parameters for the Royco kernel
     * @param _stAsset The address of the asset that ST is denominated in: constitutes the ST's tranche units (type and precision)
     * @param _jtAsset The address of the asset that JT is denominated in: constitutes the JT's tranche units (type and precision)
     */
    function __RoycoKernel_init(RoycoKernelInitParams memory _params, address _stAsset, address _jtAsset) internal onlyInitializing {
        // Initialize the Royco base state
        __RoycoBase_init(_params.initialAuthority);
        // Initialize the Royco kernel state
        __RoycoKernel_init_unchained(_params, _stAsset, _jtAsset);
    }

    /**
     * @notice Initializes the base kernel state
     * @param _params The initialization parameters for the base kernel
     * @param _stAsset The address of the asset that ST is denominated in: constitutes the ST's tranche units (type and precision)
     * @param _jtAsset The address of the asset that JT is denominated in: constitutes the JT's tranche units (type and precision)
     */
    function __RoycoKernel_init_unchained(RoycoKernelInitParams memory _params, address _stAsset, address _jtAsset) internal onlyInitializing {
        // Ensure that the tranche addresses, accountant, and protocol fee recipient are not null
        require(
            _params.seniorTranche != address(0) && _params.juniorTranche != address(0) && _params.accountant != address(0)
                && _params.protocolFeeRecipient != address(0),
            NULL_ADDRESS()
        );
        // Initialize the base kernel state
        RoycoKernelStorageLib.__RoycoKernel_init(_params, _stAsset, _jtAsset);
    }

    /// @inheritdoc IRoycoKernel
    function getState()
        external
        view
        override(IRoycoKernel)
        returns (
            address seniorTranche,
            address stAsset,
            address juniorTranche,
            address jtAsset,
            address protocolFeeRecipient,
            address accountant,
            uint24 jtRedemptionDelayInSeconds
        )
    {
        RoycoKernelState storage $ = RoycoKernelStorageLib._getRoycoKernelStorage();
        return ($.seniorTranche, $.stAsset, $.juniorTranche, $.jtAsset, $.protocolFeeRecipient, $.accountant, $.jtRedemptionDelayInSeconds);
    }

    // =============================
    // Quoter Functions
    // =============================

    /// @inheritdoc IRoycoKernel
    function stConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _stAssets) public view virtual override(IRoycoKernel) returns (NAV_UNIT);

    /// @inheritdoc IRoycoKernel
    function jtConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _jtAssets) public view virtual override(IRoycoKernel) returns (NAV_UNIT);

    /// @inheritdoc IRoycoKernel
    function stConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) public view virtual override(IRoycoKernel) returns (TRANCHE_UNIT);

    /// @inheritdoc IRoycoKernel
    function jtConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) public view virtual override(IRoycoKernel) returns (TRANCHE_UNIT);

    // =============================
    // Senior and Junior Tranche Max Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoKernel
    function stMaxDeposit(address _receiver) public view virtual override(IRoycoKernel) returns (TRANCHE_UNIT) {
        NAV_UNIT stMaxDepositableNAV = _accountant().maxSTDepositGivenCoverage(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV());
        return UnitsMathLib.min(_stMaxDepositGlobally(_receiver), stConvertNAVUnitsToTrancheUnits(stMaxDepositableNAV));
    }

    /// @inheritdoc IRoycoKernel
    function stMaxWithdrawable(address _owner)
        public
        view
        virtual
        override(IRoycoKernel)
        returns (NAV_UNIT claimOnStNAV, NAV_UNIT claimOnJtNAV, NAV_UNIT stMaxWithdrawableNAV, NAV_UNIT jtMaxWithdrawableNAV)
    {
        // Get the total claims the senior tranche has on each tranche's assets
        (, AssetClaims memory stNotionalClaims,) = previewSyncTrancheAccounting(TrancheType.SENIOR);
        claimOnStNAV = stConvertTrancheUnitsToNAVUnits(stNotionalClaims.stAssets);
        claimOnJtNAV = jtConvertTrancheUnitsToNAVUnits(stNotionalClaims.jtAssets);

        // Bound the claims by the max withdrawable assets globally for each tranche and compute the cumulative NAV
        stMaxWithdrawableNAV = stConvertTrancheUnitsToNAVUnits(_stMaxWithdrawableGlobally(_owner));
        jtMaxWithdrawableNAV = jtConvertTrancheUnitsToNAVUnits(_jtMaxWithdrawableGlobally(_owner));
    }

    /// @inheritdoc IRoycoKernel
    function jtMaxDeposit(address _receiver) public view virtual override(IRoycoKernel) returns (TRANCHE_UNIT) {
        return _jtMaxDepositGlobally(_receiver);
    }

    /// @inheritdoc IRoycoKernel
    function jtMaxWithdrawable(address _owner)
        public
        view
        virtual
        override(IRoycoKernel)
        returns (NAV_UNIT claimOnStNAV, NAV_UNIT claimOnJtNAV, NAV_UNIT stMaxWithdrawableNAV, NAV_UNIT jtMaxWithdrawableNAV)
    {
        // Get the total claims the junior tranche has on each tranche's assets
        (SyncedAccountingState memory state, AssetClaims memory jtNotionalClaims,) = previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Get the max withdrawable ST and JT assets in NAV units from the accountant consider coverage requirement
        (, NAV_UNIT stClaimableGivenCoverage, NAV_UNIT jtClaimableGivenCoverage) = _accountant()
            .maxJTWithdrawalGivenCoverage(
                state.stRawNAV,
                state.jtRawNAV,
                stConvertTrancheUnitsToNAVUnits(jtNotionalClaims.stAssets),
                jtConvertTrancheUnitsToNAVUnits(jtNotionalClaims.jtAssets)
            );

        claimOnStNAV = stConvertTrancheUnitsToNAVUnits(jtNotionalClaims.stAssets);
        claimOnJtNAV = jtConvertTrancheUnitsToNAVUnits(jtNotionalClaims.jtAssets);

        // Bound the claims by the max withdrawable assets globally for each tranche and compute the cumulative NAV
        stMaxWithdrawableNAV = UnitsMathLib.min(stConvertTrancheUnitsToNAVUnits(_stMaxWithdrawableGlobally(_owner)), stClaimableGivenCoverage);
        jtMaxWithdrawableNAV = UnitsMathLib.min(jtConvertTrancheUnitsToNAVUnits(_jtMaxWithdrawableGlobally(_owner)), jtClaimableGivenCoverage);
    }

    // =============================
    // External Tranche Accounting Synchronization Functions
    // =============================

    /// @inheritdoc IRoycoKernel
    function syncTrancheAccounting() public virtual override(IRoycoKernel) whenNotPaused returns (SyncedAccountingState memory state) {
        // Execute a pre-op accounting sync via the accountant
        return _preOpSyncTrancheAccounting();
    }

    /// @inheritdoc IRoycoKernel
    function previewSyncTrancheAccounting(TrancheType _trancheType)
        public
        view
        virtual
        override(IRoycoKernel)
        returns (SyncedAccountingState memory state, AssetClaims memory claims, uint256 totalTrancheShares)
    {
        // Preview an accounting sync via the accountant
        state = _previewSyncTrancheAccounting();

        // Decompose effective NAVs into self-backed NAV claims and cross-tranche NAV claims
        (NAV_UNIT stNAVClaimOnSelf, NAV_UNIT stNAVClaimOnJT, NAV_UNIT jtNAVClaimOnSelf, NAV_UNIT jtNAVClaimOnST) = _decomposeNAVClaims(state);

        // Marshal the tranche claims for this tranche given the decomposed claims
        claims =
            _marshalAssetClaims(_trancheType, state.stEffectiveNAV, state.jtEffectiveNAV, stNAVClaimOnSelf, stNAVClaimOnJT, jtNAVClaimOnSelf, jtNAVClaimOnST);

        // Preview the total tranche shares after minting any protocol fee shares post-sync
        RoycoKernelState storage $ = RoycoKernelStorageLib._getRoycoKernelStorage();
        if (_trancheType == TrancheType.SENIOR) {
            (, totalTrancheShares) = IRoycoVaultTranche($.seniorTranche).previewMintProtocolFeeShares(state.stProtocolFeeAccrued, state.stEffectiveNAV);
        } else {
            (, totalTrancheShares) = IRoycoVaultTranche($.juniorTranche).previewMintProtocolFeeShares(state.jtProtocolFeeAccrued, state.jtEffectiveNAV);
        }
    }

    // =============================
    // Senior Tranche Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoKernel
    function stDeposit(
        TRANCHE_UNIT _assets,
        address,
        address,
        uint256
    )
        public
        virtual
        override(IRoycoKernel)
        whenNotPaused
        onlySeniorTranche
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintAt, bytes memory)
    {
        // Execute a pre-op sync on accounting
        navToMintAt = (_preOpSyncTrancheAccounting()).stEffectiveNAV;

        // Deposit the assets into the underlying ST investment
        _stDepositAssets(_assets);

        // Execute a post-op sync on accounting and enforce the market's coverage requirement
        NAV_UNIT stPostDepositNAV = (_postOpSyncTrancheAccountingAndEnforceCoverage(Operation.ST_INCREASE_NAV)).stEffectiveNAV;
        // The value allocated after any fees/slippage incurred on deposit
        valueAllocated = stPostDepositNAV - navToMintAt;
    }

    /// @inheritdoc IRoycoKernel
    function stRedeem(
        uint256 _shares,
        address,
        address _receiver,
        uint256
    )
        public
        virtual
        override(IRoycoKernel)
        whenNotPaused
        onlySeniorTranche
        returns (AssetClaims memory userAssetClaims, bytes memory)
    {
        // Execute a pre-op sync on accounting
        uint256 totalTrancheShares;
        (, userAssetClaims, totalTrancheShares) = _preOpSyncTrancheAccounting(TrancheType.SENIOR);

        // Scale total tranche asset claims by the ratio of shares this user owns of the tranche vault
        // Protocol fee shares were minted in the pre-op sync, so the total tranche shares are up to date
        userAssetClaims = UtilsLib.scaleAssetClaims(userAssetClaims, _shares, totalTrancheShares);

        // Withdraw the asset claims from each tranche and transfer them to the receiver
        _withdrawAssets(userAssetClaims, _receiver);

        // Execute a post-op sync on accounting
        _postOpSyncTrancheAccounting(Operation.ST_DECREASE_NAV);
    }

    // =============================
    // Junior Tranche Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoKernel
    function jtDeposit(
        TRANCHE_UNIT _assets,
        address,
        address,
        uint256
    )
        public
        virtual
        override(IRoycoKernel)
        whenNotPaused
        onlyJuniorTranche
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintAt, bytes memory)
    {
        // Execute a pre-op sync on accounting
        navToMintAt = (_preOpSyncTrancheAccounting()).jtEffectiveNAV;

        // Deposit the assets into the underlying ST investment
        _jtDepositAssets(_assets);

        // Execute a post-op sync on accounting and enforce the market's coverage requirement
        NAV_UNIT jtPostDepositNAV = (_postOpSyncTrancheAccounting(Operation.JT_INCREASE_NAV)).jtEffectiveNAV;
        // The value allocated after any fees/slippage incurred on deposit
        valueAllocated = jtPostDepositNAV - navToMintAt;
    }

    /// @inheritdoc IRoycoKernel
    function jtPreviewRedeem(uint256) public pure override returns (AssetClaims memory) {
        revert PREVIEW_REDEEM_DISABLED_FOR_ASYNC_REDEMPTION();
    }

    /// @inheritdoc IRoycoKernel
    function jtRequestRedeem(
        address,
        uint256 _shares,
        address _controller
    )
        public
        virtual
        override(IRoycoKernel)
        whenNotPaused
        onlyJuniorTranche
        returns (uint256 requestId, bytes memory metadata)
    {
        // Execute a pre-op sync on accounting
        (SyncedAccountingState memory state,, uint256 totalTrancheShares) = _preOpSyncTrancheAccounting(TrancheType.JUNIOR);

        /// @dev JT LPs are not entitled to any JT upside during the redemption delay, but they are liable for providing coverage to ST LPs during the redemption delay
        // Compute the current NAV of the shares being requested to be redeemed
        NAV_UNIT redemptionValueAtRequestTime = state.jtEffectiveNAV.mulDiv(_shares, totalTrancheShares, Math.Rounding.Floor);

        // Create a new redemption request for the controller
        RoycoKernelState storage $ = RoycoKernelStorageLib._getRoycoKernelStorage();
        requestId = $.nextJTRedemptionRequestId++;
        RedemptionRequest storage request = $.jtControllerToIdToRedemptionRequest[_controller][requestId];

        // Add the shares to the total shares to redeem in the controller's current redemption request
        // If an existing redemption request exists, it's redemption delay is refreshed based on the current time
        request.totalJTSharesToRedeem = _shares;
        request.redemptionValueAtRequestTime = redemptionValueAtRequestTime;
        uint256 claimableAtTimestamp = request.claimableAtTimestamp = uint32(block.timestamp + $.jtRedemptionDelayInSeconds);

        // Format the metadata for the redemption request
        metadata = abi.encode(claimableAtTimestamp).format(ActionMetadataFormat.REDEMPTION_CLAIMABLE_AT_TIMESTAMP);
    }

    /// @inheritdoc IRoycoKernel
    function jtPendingRedeemRequest(uint256 _requestId, address _controller) public view virtual override(IRoycoKernel) returns (uint256 pendingShares) {
        RedemptionRequest storage request = RoycoKernelStorageLib._getRoycoKernelStorage().jtControllerToIdToRedemptionRequest[_controller][_requestId];
        // If the redemption is canceled or the request is claimable, no shares are still in a pending state
        if (request.isCanceled || request.claimableAtTimestamp <= block.timestamp) return 0;
        // The shares in the controller's redemption request are still pending
        pendingShares = request.totalJTSharesToRedeem;
    }

    /// @inheritdoc IRoycoKernel
    function jtClaimableRedeemRequest(uint256 _requestId, address _controller) public view virtual override(IRoycoKernel) returns (uint256 claimableShares) {
        // Get how many shares from the request are now in a redeemable (claimable) state
        RedemptionRequest storage request = RoycoKernelStorageLib._getRoycoKernelStorage().jtControllerToIdToRedemptionRequest[_controller][_requestId];
        claimableShares = _getRedeemableSharesForRequest(request);
    }

    /// @inheritdoc IRoycoKernel
    function jtCancelRedeemRequest(
        uint256 _requestId,
        address _controller
    )
        public
        virtual
        override(IRoycoKernel)
        whenNotPaused
        onlyJuniorTranche
        checkJTRedemptionRequestId(_controller, _requestId)
    {
        RedemptionRequest storage request = RoycoKernelStorageLib._getRoycoKernelStorage().jtControllerToIdToRedemptionRequest[_controller][_requestId];
        // Cannot cancel an already canceled request
        require(!request.isCanceled, REDEMPTION_REQUEST_CANCELED());
        // Cannot cancel a non-existant redemption request
        require(request.totalJTSharesToRedeem != 0, NONEXISTANT_REQUEST_TO_CANCEL());
        // Mark this request as canceled
        request.isCanceled = true;
    }

    /// @inheritdoc IRoycoKernel
    function jtPendingCancelRedeemRequest(uint256, address) public pure virtual override(IRoycoKernel) returns (bool isPending) {
        // Cancellation requests are always processed instantly, so there can never be a pending cancellation
        isPending = false;
    }

    /// @inheritdoc IRoycoKernel
    function jtClaimableCancelRedeemRequest(uint256 _requestId, address _controller) public view virtual override(IRoycoKernel) returns (uint256 shares) {
        RedemptionRequest storage request = RoycoKernelStorageLib._getRoycoKernelStorage().jtControllerToIdToRedemptionRequest[_controller][_requestId];
        // If the redemption is not canceled, there are no shares to claim
        if (!request.isCanceled) return 0;
        // Return the shares for the redemption request that has been requested to be canceled
        shares = request.totalJTSharesToRedeem;
    }

    /// @inheritdoc IRoycoKernel
    function jtClaimCancelRedeemRequest(
        uint256 _requestId,
        address _controller
    )
        public
        virtual
        override(IRoycoKernel)
        whenNotPaused
        onlyJuniorTranche
        checkJTRedemptionRequestId(_controller, _requestId)
        returns (uint256 shares)
    {
        RoycoKernelState storage $ = RoycoKernelStorageLib._getRoycoKernelStorage();
        RedemptionRequest storage request = $.jtControllerToIdToRedemptionRequest[_controller][_requestId];
        // Cannot claim back shares from a request that hasn't been cancelled
        require(request.isCanceled, REDEMPTION_REQUEST_NOT_CANCELED());
        // Return the number of shares that need to be claimed after request cancellation
        shares = request.totalJTSharesToRedeem;
        // Clear all redemption state since cancellation has been processed
        delete $.jtControllerToIdToRedemptionRequest[_controller][_requestId];
    }

    /// @inheritdoc IRoycoKernel
    function jtRedeem(
        uint256 _shares,
        address _controller,
        address _receiver,
        uint256 _redemptionRequestId
    )
        public
        virtual
        override(IRoycoKernel)
        whenNotPaused
        onlyJuniorTranche
        checkJTRedemptionRequestId(_controller, _redemptionRequestId)
        returns (AssetClaims memory userAssetClaims, bytes memory)
    {
        // Execute a pre-op sync on accounting
        SyncedAccountingState memory state;
        uint256 totalTrancheShares;
        (state, userAssetClaims, totalTrancheShares) = _preOpSyncTrancheAccounting(TrancheType.JUNIOR);

        RoycoKernelState storage $ = RoycoKernelStorageLib._getRoycoKernelStorage();
        RedemptionRequest storage request = $.jtControllerToIdToRedemptionRequest[_controller][_redemptionRequestId];

        // Ensure that the the shares that need to be redeemed are allowed to be redeemed for this controller
        uint256 redeemableShares = _getRedeemableSharesForRequest(request);
        require(_shares <= redeemableShares, INSUFFICIENT_REDEEMABLE_SHARES(_shares, redeemableShares));

        // Compute the current NAV and the NAV at request time of the shares being redeemed
        NAV_UNIT redemptionValueAtCurrentTime = state.jtEffectiveNAV.mulDiv(_shares, totalTrancheShares, Math.Rounding.Floor);
        NAV_UNIT redemptionValueAtRequestTime = request.redemptionValueAtRequestTime.mulDiv(_shares, request.totalJTSharesToRedeem, Math.Rounding.Floor);

        /// @dev JT LPs are not entitled to any JT upside during the redemption delay, but they are liable for providing coverage to ST LPs during the redemption delay
        NAV_UNIT navOfSharesToRedeem = UnitsMathLib.min(redemptionValueAtCurrentTime, redemptionValueAtRequestTime);

        // Update the request accounting based on the shares being redeemed
        uint256 sharesRemaining = request.totalJTSharesToRedeem - _shares;
        // If there are no remaining shares, delete the controller's redemption
        if (sharesRemaining == 0) {
            delete $.jtControllerToIdToRedemptionRequest[_controller][_redemptionRequestId];
        } else {
            // Update the redemption value at request for the remaining shares by the amount that
            request.redemptionValueAtRequestTime = request.redemptionValueAtRequestTime - redemptionValueAtRequestTime;
            request.totalJTSharesToRedeem = sharesRemaining;
        }

        // Scale the claims based on the NAV to liquidate for the user relative to the total JT controlled NAV
        userAssetClaims = UtilsLib.scaleAssetClaims(userAssetClaims, navOfSharesToRedeem, state.jtEffectiveNAV);

        // Withdraw the asset claims from each tranche and transfer them to the receiver
        _withdrawAssets(userAssetClaims, _receiver);

        // Execute a post-op sync on accounting and enforce the market's coverage requirement
        _postOpSyncTrancheAccountingAndEnforceCoverage(Operation.JT_DECREASE_NAV);

        return (userAssetClaims, "");
    }

    // =============================
    // Admin Functions
    // =============================

    /// @inheritdoc IRoycoKernel
    function setProtocolFeeRecipient(address _protocolFeeRecipient) external override(IRoycoKernel) restricted {
        require(_protocolFeeRecipient != address(0), NULL_ADDRESS());
        RoycoKernelStorageLib._getRoycoKernelStorage().protocolFeeRecipient = _protocolFeeRecipient;
        emit ProtocolFeeRecipientUpdated(_protocolFeeRecipient);
    }

    /// @inheritdoc IRoycoKernel
    function setJuniorTrancheRedemptionDelay(uint24 _jtRedemptionDelayInSeconds) external override(IRoycoKernel) restricted {
        RoycoKernelStorageLib._getRoycoKernelStorage().jtRedemptionDelayInSeconds = _jtRedemptionDelayInSeconds;
        emit JuniorTrancheRedemptionDelayUpdated(_jtRedemptionDelayInSeconds);
    }

    // =============================
    // Internal Tranche Accounting Synchronization Functions
    // =============================

    /**
     * @notice Previews an accounting sync via the accountant
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark to market accounting data
     */
    function _previewSyncTrancheAccounting() internal view virtual returns (SyncedAccountingState memory state) {
        // Preview an accounting sync via the accountant
        state = _accountant().previewSyncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV());
    }

    /**
     * @notice Invokes the accountant to do a pre-operation (deposit and withdrawal) NAV sync and mints any protocol fee shares accrued
     * @notice Also returns the asset claims and total tranche shares after minting any fees
     * @dev Should be called on every NAV mutating user operation
     * @param _trancheType An enum indicating which tranche to return claims and total tranche shares for
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark to market accounting data
     * @return claims The claims on ST and JT assets that the specified tranche has denominated in tranche-native units
     * @return totalTrancheShares The total shares outstanding in the specified tranche after minting any protocol fee shares
     */
    function _preOpSyncTrancheAccounting(TrancheType _trancheType)
        internal
        virtual
        returns (SyncedAccountingState memory state, AssetClaims memory claims, uint256 totalTrancheShares)
    {
        // Execute the pre-op sync via the accountant
        state = _accountant().preOpSyncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV());

        // Collect any protocol fees accrued from the sync to the fee recipient
        RoycoKernelState storage $ = RoycoKernelStorageLib._getRoycoKernelStorage();
        address protocolFeeRecipient = $.protocolFeeRecipient;
        uint256 stTotalTrancheSharesAfterMintingFees;
        uint256 jtTotalTrancheSharesAfterMintingFees;
        // If ST fees were accrued or we need to get total shares for ST, mint ST protocol fee shares to the protocol fee recipient
        if (state.stProtocolFeeAccrued != ZERO_NAV_UNITS || _trancheType == TrancheType.SENIOR) {
            (, stTotalTrancheSharesAfterMintingFees) =
                IRoycoVaultTranche($.seniorTranche).mintProtocolFeeShares(state.stProtocolFeeAccrued, state.stEffectiveNAV, protocolFeeRecipient);
        }
        // If JT fees were accrued or we need to get total shares for JT, mint JT protocol fee shares to the protocol fee recipient
        if (state.jtProtocolFeeAccrued != ZERO_NAV_UNITS || _trancheType == TrancheType.JUNIOR) {
            (, jtTotalTrancheSharesAfterMintingFees) =
                IRoycoVaultTranche($.juniorTranche).mintProtocolFeeShares(state.jtProtocolFeeAccrued, state.jtEffectiveNAV, protocolFeeRecipient);
        }

        // Set the total tranche shares to the specified tranche's shares after minting fees
        totalTrancheShares = (_trancheType == TrancheType.SENIOR) ? stTotalTrancheSharesAfterMintingFees : jtTotalTrancheSharesAfterMintingFees;

        // Decompose effective NAVs into self-backed NAV claims and cross-tranche NAV claims
        (NAV_UNIT stNAVClaimOnSelf, NAV_UNIT stNAVClaimOnJT, NAV_UNIT jtNAVClaimOnSelf, NAV_UNIT jtNAVClaimOnST) = _decomposeNAVClaims(state);

        // Marshal the tranche claims for this tranche given the decomposed claims
        claims =
            _marshalAssetClaims(_trancheType, state.stEffectiveNAV, state.jtEffectiveNAV, stNAVClaimOnSelf, stNAVClaimOnJT, jtNAVClaimOnSelf, jtNAVClaimOnST);
    }

    /**
     * @notice Invokes the accountant to do a pre-operation (deposit and withdrawal) NAV sync and mints any protocol fee shares accrued
     * @dev Should be called on every NAV mutating user operation
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark to market accounting data
     */
    function _preOpSyncTrancheAccounting() internal virtual returns (SyncedAccountingState memory state) {
        // Execute the pre-op sync via the accountant
        state = _accountant().preOpSyncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV());

        // Collect any protocol fees accrued from the sync to the fee recipient
        RoycoKernelState storage $ = RoycoKernelStorageLib._getRoycoKernelStorage();
        if (state.stProtocolFeeAccrued != ZERO_NAV_UNITS || state.jtProtocolFeeAccrued != ZERO_NAV_UNITS) {
            address protocolFeeRecipient = $.protocolFeeRecipient;
            // If ST fees were accrued or we need to get total shares for ST, mint ST protocol fee shares to the protocol fee recipient
            if (state.stProtocolFeeAccrued != ZERO_NAV_UNITS) {
                IRoycoVaultTranche($.seniorTranche).mintProtocolFeeShares(state.stProtocolFeeAccrued, state.stEffectiveNAV, protocolFeeRecipient);
            }
            // If JT fees were accrued or we need to get total shares for JT, mint JT protocol fee shares to the protocol fee recipient
            if (state.jtProtocolFeeAccrued != ZERO_NAV_UNITS) {
                IRoycoVaultTranche($.juniorTranche).mintProtocolFeeShares(state.jtProtocolFeeAccrued, state.jtEffectiveNAV, protocolFeeRecipient);
            }
        }
    }

    /**
     * @notice Invokes the accountant to do a post-operation (deposit and withdrawal) NAV sync
     * @dev Should be called on every NAV mutating user operation that doesn't require a coverage check
     * @param _op The operation being executed in between the pre and post synchronizations
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark to market accounting data
     */
    function _postOpSyncTrancheAccounting(Operation _op) internal virtual returns (SyncedAccountingState memory state) {
        // Execute the post-op sync on the accountant
        state = _accountant().postOpSyncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV(), _op);
    }

    /**
     * @notice Invokes the accountant to do a post-operation (deposit and withdrawal) NAV sync and checks the market's coverage requirement is satisfied
     * @dev Should be called on every NAV mutating user operation that requires a coverage check: ST deposit and JT withdrawal
     * @param _op The operation being executed in between the pre and post synchronizations
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark to market accounting data
     */
    function _postOpSyncTrancheAccountingAndEnforceCoverage(Operation _op) internal virtual returns (SyncedAccountingState memory state) {
        // Execute the post-op sync on the accountant
        return _accountant().postOpSyncTrancheAccountingAndEnforceCoverage(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV(), _op);
    }

    /**
     * @notice Decomposes effective NAVs into self-backed NAV claims and cross-tranche NAV claims
     * @param _state The synced NAV, impermanent loss, and fee accounting containing all mark to market accounting data
     * @return stNAVClaimOnSelf The portion of ST's effective NAV that must be funded by ST’s raw NAV
     * @return stNAVClaimOnJT The portion of ST's effective NAV that must be funded by JT’s raw NAV
     * @return jtNAVClaimOnSelf The portion of JT's effective NAV that must be funded by JT’s raw NAV
     * @return jtNAVClaimOnST The portion of JT's effective NAV that must be funded by ST’s raw NAV
     */
    function _decomposeNAVClaims(SyncedAccountingState memory _state)
        internal
        pure
        virtual
        returns (NAV_UNIT stNAVClaimOnSelf, NAV_UNIT stNAVClaimOnJT, NAV_UNIT jtNAVClaimOnSelf, NAV_UNIT jtNAVClaimOnST)
    {
        // Cross-tranche claims (only one direction should be non-zero under conservation)
        stNAVClaimOnJT = UnitsMathLib.saturatingSub(_state.stEffectiveNAV, _state.stRawNAV);
        jtNAVClaimOnST = UnitsMathLib.saturatingSub(_state.jtEffectiveNAV, _state.jtRawNAV);

        // Self-backed portions (the remainder of each tranche’s effective NAV)
        stNAVClaimOnSelf = UnitsMathLib.saturatingSub(_state.stRawNAV, jtNAVClaimOnST);
        jtNAVClaimOnSelf = UnitsMathLib.saturatingSub(_state.jtRawNAV, stNAVClaimOnJT);
    }

    /**
     * @notice Converts NAV denominated claim components into concrete claimable tranche units
     * @param _trancheType An enum indicating which tranche to construct the claim for
     * @param _stEffectiveNAV The effective NAV of the senior tranche
     * @param _jtEffectiveNAV The effective NAV of the junior tranche
     * @param _stNAVClaimOnSelf The portion of ST's effective NAV that must be funded by ST’s raw NAV
     * @param _stNAVClaimOnJT The portion of ST's effective NAV that must be funded by JT’s raw NAV
     * @param _jtNAVClaimOnSelf The portion of JT's effective NAV that must be funded by JT’s raw NAV
     * @param _jtNAVClaimOnST The portion of JT's effective NAV that must be funded by ST’s raw NAV
     * @return claims The claims on ST and JT assets that the specified tranche has denominated in tranche-native units
     */
    function _marshalAssetClaims(
        TrancheType _trancheType,
        NAV_UNIT _stEffectiveNAV,
        NAV_UNIT _jtEffectiveNAV,
        NAV_UNIT _stNAVClaimOnSelf,
        NAV_UNIT _stNAVClaimOnJT,
        NAV_UNIT _jtNAVClaimOnSelf,
        NAV_UNIT _jtNAVClaimOnST
    )
        internal
        view
        virtual
        returns (AssetClaims memory claims)
    {
        if (_trancheType == TrancheType.SENIOR) {
            if (_stNAVClaimOnSelf != ZERO_NAV_UNITS) claims.stAssets = stConvertNAVUnitsToTrancheUnits(_stNAVClaimOnSelf);
            if (_stNAVClaimOnJT != ZERO_NAV_UNITS) claims.jtAssets = jtConvertNAVUnitsToTrancheUnits(_stNAVClaimOnJT);
            claims.nav = _stEffectiveNAV;
        } else {
            if (_jtNAVClaimOnST != ZERO_NAV_UNITS) claims.stAssets = stConvertNAVUnitsToTrancheUnits(_jtNAVClaimOnST);
            if (_jtNAVClaimOnSelf != ZERO_NAV_UNITS) claims.jtAssets = jtConvertNAVUnitsToTrancheUnits(_jtNAVClaimOnSelf);
            claims.nav = _jtEffectiveNAV;
        }
    }

    // =============================
    // Internal Utility Functions
    // =============================

    /**
     * @notice Withdraws any specified assets from each tranche and transfer them to the receiver
     * @param _claims The ST and JT assets to withdraw and transfer to the specified receiver
     * @param _receiver The receiver of the tranche asset claims
     */
    function _withdrawAssets(AssetClaims memory _claims, address _receiver) internal virtual {
        TRANCHE_UNIT stAssetsToClaim = _claims.stAssets;
        TRANCHE_UNIT jtAssetsToClaim = _claims.jtAssets;
        // Withdraw the ST and JT assets if non-zero
        if (stAssetsToClaim != ZERO_TRANCHE_UNITS) _stWithdrawAssets(stAssetsToClaim, _receiver);
        if (jtAssetsToClaim != ZERO_TRANCHE_UNITS) _jtWithdrawAssets(jtAssetsToClaim, _receiver);
    }

    /**
     * @notice Previews the amount of ST and JT assets that would be redeemed for a given number of shares
     * @param _shares The number of shares to redeem
     * @param _trancheType The type of tranche to preview the redemption for
     * @return userClaim The amount of ST and JT assets that would be redeemed for the given number of shares
     */
    function _previewRedeem(uint256 _shares, TrancheType _trancheType) internal view virtual returns (AssetClaims memory userClaim) {
        // Get the total claim of ST on the ST and JT assets, and scale it to the number of shares being redeemed
        (, AssetClaims memory totalClaims, uint256 totalTrancheShares) = previewSyncTrancheAccounting(_trancheType);
        AssetClaims memory scaledClaims = UtilsLib.scaleAssetClaims(totalClaims, _shares, totalTrancheShares);

        // Preview the amount of ST assets that would be redeemed for the given amount of shares
        userClaim.stAssets = _stPreviewWithdraw(scaledClaims.stAssets);
        userClaim.jtAssets = _jtPreviewWithdraw(scaledClaims.jtAssets);
        userClaim.nav = stConvertTrancheUnitsToNAVUnits(userClaim.stAssets) + jtConvertTrancheUnitsToNAVUnits(userClaim.jtAssets);
    }

    /**
     * @notice Returns the amount of JT shares redeemable from a redemption request
     * @param _request The redemption request to get redeemable shares for
     * @return claimableShares The amount of JT shares currently redeemable from the specified redemption request
     */
    function _getRedeemableSharesForRequest(RedemptionRequest storage _request) internal view virtual returns (uint256 claimableShares) {
        // If the request is canceled or not claimable, no shares are claimable
        if (_request.isCanceled || _request.claimableAtTimestamp > block.timestamp) return 0;
        // Return the shares in the request
        claimableShares = _request.totalJTSharesToRedeem;
    }

    /**
     * @notice Returns this kernel's accountant casted to the IRoycoAccountant interface
     * @return accountant The Royco Accountant for this kernel
     */
    function _accountant() internal view returns (IRoycoAccountant accountant) {
        return IRoycoAccountant(RoycoKernelStorageLib._getRoycoKernelStorage().accountant);
    }

    // =============================
    // Internal NAV Retrieval Functions
    // =============================

    /**
     * @notice Returns the raw net asset value of the senior tranche denominated in the NAV units (USD, BTC, etc.) for this kernel
     * @return stRawNAV The pure net asset value of the senior tranche invested assets
     */
    function _getSeniorTrancheRawNAV() internal view virtual returns (NAV_UNIT stRawNAV);

    /**
     * @notice Returns the raw net asset value of the junior tranche denominated in the NAV units (USD, BTC, etc.) for this kernel
     * @return jtRawNAV The pure net asset value of the junior tranche invested assets
     */
    function _getJuniorTrancheRawNAV() internal view virtual returns (NAV_UNIT jtRawNAV);

    // =============================
    // Internal Tranche Specific Helper Functions
    // =============================

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the senior tranche globally
     * @dev Implementation should consider protocol-wide limits and liquidity constraints
     * @param _receiver The receiver of the shares for the assets being deposited (used to enforce white/black lists)
     */
    function _stMaxDepositGlobally(address _receiver) internal view virtual returns (TRANCHE_UNIT);

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the junior tranche globally
     * @dev Implementation should consider protocol-wide limits and liquidity constraints
     * @param _receiver The receiver of the shares for the assets being deposited (used to enforce white/black lists)
     */
    function _jtMaxDepositGlobally(address _receiver) internal view virtual returns (TRANCHE_UNIT);

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn from the senior tranche globally
     * @dev Implementation should consider protocol-wide limits and liquidity constraints
     * @param _owner The owner of the assets being withdrawn (used to enforce white/black lists)
     */
    function _stMaxWithdrawableGlobally(address _owner) internal view virtual returns (TRANCHE_UNIT);

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn from the junior tranche globally
     * @dev Implementation should consider protocol-wide limits and liquidity constraints
     * @param _owner The owner of the assets being withdrawn (used to enforce white/black lists)
     */
    function _jtMaxWithdrawableGlobally(address _owner) internal view virtual returns (TRANCHE_UNIT);

    /**
     * @notice Previews the amount of ST assets that would be redeemed for a given amount of ST assets
     * @param _stAssets The ST assets denominated in its tranche units to redeem
     * @return withdrawnSTAssets The amount of ST assets that would be redeemed for the given amount of ST assets
     */
    function _stPreviewWithdraw(TRANCHE_UNIT _stAssets) internal view virtual returns (TRANCHE_UNIT withdrawnSTAssets);

    /**
     * @notice Previews the amount of JT assets that would be redeemed for a given amount of JT assets
     * @param _jtAssets The JT assets denominated in its tranche units to redeem
     * @return withdrawnJTAssets The amount of JT assets that would be redeemed for the given amount of JT assets
     */
    function _jtPreviewWithdraw(TRANCHE_UNIT _jtAssets) internal view virtual returns (TRANCHE_UNIT withdrawnJTAssets);

    /**
     * @notice Deposits ST assets into its underlying investment opportunity
     * @dev Mandates that the underlying ownership over the deposit (receipt tokens, underlying investment accounting, etc) is retained by the kernel
     * @param _stAssets The ST assets denominated in its tranche units to deposit into its underlying investment opportunity
     */
    function _stDepositAssets(TRANCHE_UNIT _stAssets) internal virtual;

    /**
     * @notice Deposits JT assets into its underlying investment opportunity
     * @dev Mandates that the underlying ownership over the deposit (receipt tokens, underlying investment accounting, etc) is retained by the kernel
     * @param _jtAssets The JT assets denominated in its tranche units to deposit into its underlying investment opportunity
     */
    function _jtDepositAssets(TRANCHE_UNIT _jtAssets) internal virtual;

    /**
     * @notice Withdraws ST assets to the specified receiver
     * @param _stAssets The ST assets denominated in its tranche units to withdraw to the receiver
     * @param _receiver The receiver of the ST assets
     */
    function _stWithdrawAssets(TRANCHE_UNIT _stAssets, address _receiver) internal virtual;

    /**
     * @notice Withdraws JT assets to the specified receiver
     * @param _jtAssets The JT assets denominated in its tranche units to withdraw to the receiver
     * @param _receiver The receiver of the JT assets
     */
    function _jtWithdrawAssets(TRANCHE_UNIT _jtAssets, address _receiver) internal virtual;
}
