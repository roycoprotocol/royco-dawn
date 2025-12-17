// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ERC20Upgradeable, IERC20, IERC20Metadata } from "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import { ERC20PausableUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import { ERC20PermitUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { IAccessControlEnumerable } from "../../lib/openzeppelin-contracts/contracts/access/extensions/IAccessControlEnumerable.sol";
import { SafeERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { RoycoBase } from "../base/RoycoBase.sol";
import { IAsyncJTDepositKernel } from "../interfaces/kernel/IAsyncJTDepositKernel.sol";
import { IAsyncJTWithdrawalKernel } from "../interfaces/kernel/IAsyncJTWithdrawalKernel.sol";
import { IAsyncSTDepositKernel } from "../interfaces/kernel/IAsyncSTDepositKernel.sol";
import { IAsyncSTWithdrawalKernel } from "../interfaces/kernel/IAsyncSTWithdrawalKernel.sol";
import { ExecutionModel, IRoycoKernel, RequestRedeemSharesBehavior } from "../interfaces/kernel/IRoycoKernel.sol";
import { IERC165, IRoycoAsyncCancellableVault, IRoycoAsyncVault, IRoycoVaultTranche } from "../interfaces/tranche/IRoycoVaultTranche.sol";
import { ZERO_NAV_UNITS } from "../libraries/Constants.sol";
import { RoycoTrancheStorageLib } from "../libraries/RoycoTrancheStorageLib.sol";
import { TrancheAssetClaims, TrancheType } from "../libraries/Types.sol";
import { Action, SyncedAccountingState, TrancheDeploymentParams } from "../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../libraries/Units.sol";
import { UtilsLib } from "../libraries/UtilsLib.sol";

/**
 * @title RoycoVaultTranche
 * @notice Abstract base contract implementing core functionality for Royco tranches
 */
abstract contract RoycoVaultTranche is IRoycoVaultTranche, RoycoBase, ERC20PausableUpgradeable, ERC20PermitUpgradeable {
    using Math for uint256;
    using SafeERC20 for IERC20;

    /// @notice Thrown when the specified action is disabled
    error DISABLED();

    /// @notice Thrown when the caller is not the expected account or an approved operator
    error ONLY_CALLER_OR_OPERATOR();

    /// @notice Thrown when the redeem amount is zero
    error MUST_REQUEST_NON_ZERO_SHARES();

    /// @notice Thrown when the deposit amount is zero
    error MUST_INCREASE_NAV_NON_ZERO_ASSETS();

    /// @notice Thrown when the redeem amount is zero
    error MUST_CLAIM_NON_ZERO_SHARES();

    /// @notice Thrown when the caller isn't the kernel
    error ONLY_KERNEL();

    /// @notice Thrown when the value allocated is zero
    error INVALID_VALUE_ALLOCATED();

    /**
     * @notice Modifier to ensure the specified action uses a synchronous execution model
     * @param _action The action to check (DEPOSIT or WITHDRAW)
     * @dev Reverts if the execution model for the action is asynchronous
     */
    /// forge-lint: disable-next-item(unwrapped-modifier-logic)
    modifier executionIsSync(Action _action) {
        require(_isSync(_action), DISABLED());
        _;
    }

    /**
     * @notice Modifier to ensure the specified action uses an asynchronous execution model
     * @param _action The action to check (DEPOSIT or WITHDRAW)
     * @dev Reverts if the execution model for the action is synchronous
     */
    /// forge-lint: disable-next-item(unwrapped-modifier-logic)
    modifier executionIsAsync(Action _action) {
        require(!_isSync(_action), DISABLED());
        _;
    }

    /**
     * @notice Modifier to ensure caller is either the specified address or an approved operator
     * @param _account The address that the caller should match or have operator approval for
     * @dev Reverts if caller is neither the address nor an approved operator
     */
    modifier onlyCallerOrOperator(address _account) {
        _onlyCallerOrOperator(_account);
        _;
    }

    /**
     * @notice Checks if the caller is either the specified address or an approved operator
     * @param _account The address to check
     * @dev Reverts if the caller is neither the address nor an approved operator
     */
    function _onlyCallerOrOperator(address _account) internal view {
        require(msg.sender == _account || RoycoTrancheStorageLib._getRoycoTrancheStorage().isOperator[_account][msg.sender], ONLY_CALLER_OR_OPERATOR());
    }

    /**
     * @notice Initializes the Royco tranche
     * @dev This function initializes parent contracts and the tranche-specific state
     * @param _trancheParams Deployment parameters including name, symbol, kernel, and kernel initialization data
     * @param _asset The underlying asset for the tranche
     * @param _initialAuthority The initial authority for the tranche
     * @param _marketId The identifier of the Royco market this tranche is linked to
     */
    function __RoycoTranche_init(
        TrancheDeploymentParams calldata _trancheParams,
        address _asset,
        address _initialAuthority,
        bytes32 _marketId
    )
        internal
        onlyInitializing
    {
        // Initialize the parent contracts
        __ERC20_init_unchained(_trancheParams.name, _trancheParams.symbol);
        __ERC20Pausable_init();
        __ERC20Permit_init(_trancheParams.name);
        __RoycoBase_init(_initialAuthority);

        // Initialize the Royco Tranche state
        __RoycoTranche_init_unchained(_asset, _trancheParams.kernel, _marketId);
    }

    /**
     * @notice Internal initialization function for Royco tranche-specific state
     * @dev This function sets up the tranche storage and initializes the kernel
     * @param _asset The underlying asset for the tranche
     * @param _kernelAddress The address of the kernel that handles strategy logic
     * @param _marketId The identifier of the Royco market this tranche is linked to
     */
    function __RoycoTranche_init_unchained(address _asset, address _kernelAddress, bytes32 _marketId) internal onlyInitializing {
        // Calculate the vault's decimal offset (curb inflation attacks)
        uint8 underlyingAssetDecimals = IERC20Metadata(_asset).decimals();
        uint8 decimalsOffset = underlyingAssetDecimals >= 18 ? 0 : (18 - underlyingAssetDecimals);

        // Initialize the tranche's state
        RoycoTrancheStorageLib.__RoycoTranche_init(_kernelAddress, _asset, _marketId, underlyingAssetDecimals, decimalsOffset, TRANCHE_TYPE());
    }

    /// @inheritdoc IRoycoVaultTranche
    function kernel() public view virtual override(IRoycoVaultTranche) returns (address) {
        return RoycoTrancheStorageLib._getRoycoTrancheStorage().kernel;
    }

    /// @inheritdoc IRoycoVaultTranche
    function marketId() external view virtual override(IRoycoVaultTranche) returns (bytes32) {
        return RoycoTrancheStorageLib._getRoycoTrancheStorage().marketId;
    }

    /// @inheritdoc IRoycoVaultTranche
    function totalAssets() external view virtual override(IRoycoVaultTranche) returns (TrancheAssetClaims memory claims) {
        return (TRANCHE_TYPE() == TrancheType.SENIOR ? IRoycoKernel(kernel()).getSTAssetClaims() : IRoycoKernel(kernel()).getJTAssetClaims());
    }

    /// @inheritdoc IRoycoVaultTranche
    function getRawNAV() external view virtual override(IRoycoVaultTranche) returns (NAV_UNIT nav) {
        nav = (TRANCHE_TYPE() == TrancheType.SENIOR ? IRoycoKernel(kernel()).getSTRawNAV() : IRoycoKernel(kernel()).getJTRawNAV());
    }

    /// @inheritdoc IRoycoVaultTranche
    function maxDeposit(address _receiver) external view virtual override(IRoycoVaultTranche) returns (TRANCHE_UNIT assets) {
        assets =
        (TRANCHE_TYPE() == TrancheType.SENIOR ? IRoycoKernel(kernel()).stMaxAssetsDeposit(_receiver) : IRoycoKernel(kernel()).jtMaxAssetsDeposit(_receiver));
    }

    /// @inheritdoc IRoycoVaultTranche
    function maxRedeem(address _owner) external view virtual override(IRoycoVaultTranche) returns (uint256 shares) {
        NAV_UNIT maxWithdrawableNAV =
        (TRANCHE_TYPE() == TrancheType.SENIOR ? IRoycoKernel(kernel()).stMaxWithdrawableNAV(_owner) : IRoycoKernel(kernel()).jtMaxWithdrawableNAV(_owner));
        if (maxWithdrawableNAV == ZERO_NAV_UNITS) return 0;

        // Get the post-sync tranche state: applying NAV reconciliation and fee share minting
        (TrancheAssetClaims memory trancheClaims, uint256 trancheTotalShares) = _previewPostSyncTrancheState();

        // Compute the max withdrawable shares based on max withdrawable assets
        uint256 maxRedeemableShares = _convertToShares(maxWithdrawableNAV, trancheTotalShares, trancheClaims.effectiveNAV, Math.Rounding.Floor);

        // Return the minimum of the max redeemable shares and the balance of the owner
        shares = Math.min(maxRedeemableShares, balanceOf(_owner));
    }

    /// @inheritdoc IRoycoVaultTranche
    function previewDeposit(TRANCHE_UNIT _assets) external view virtual override(IRoycoVaultTranche) executionIsSync(Action.DEPOSIT) returns (uint256 shares) {
        (NAV_UNIT navAssets, NAV_UNIT effectiveNAVToMintAt) =
            (TRANCHE_TYPE() == TrancheType.SENIOR ? IRoycoKernel(kernel()).stPreviewDeposit(_assets) : IRoycoKernel(kernel()).jtPreviewDeposit(_assets));
        shares = _convertToShares(navAssets, totalSupply(), effectiveNAVToMintAt, Math.Rounding.Floor);
    }

    /// @inheritdoc IRoycoVaultTranche
    function convertToShares(TRANCHE_UNIT _assets) public view virtual override(IRoycoVaultTranche) returns (uint256 shares) {
        // Get the post-sync tranche state: applying NAV reconciliation.
        NAV_UNIT navAssets =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IRoycoKernel(kernel()).stConvertTrancheUnitsToNAVUnits(_assets)
                : IRoycoKernel(kernel()).jtConvertTrancheUnitsToNAVUnits(_assets));
        (TrancheAssetClaims memory trancheClaims, uint256 trancheTotalShares) = _previewPostSyncTrancheState();
        shares = _convertToShares(navAssets, trancheTotalShares, trancheClaims.effectiveNAV, Math.Rounding.Floor);
    }

    /// @inheritdoc IRoycoVaultTranche
    function previewRedeem(uint256 _shares)
        external
        view
        virtual
        override(IRoycoVaultTranche)
        executionIsSync(Action.WITHDRAW)
        returns (TrancheAssetClaims memory claims)
    {
        claims = (TRANCHE_TYPE() == TrancheType.SENIOR ? IRoycoKernel(kernel()).stPreviewRedeem(_shares) : IRoycoKernel(kernel()).jtPreviewRedeem(_shares));
    }

    /// @inheritdoc IRoycoVaultTranche
    function convertToAssets(uint256 _shares) public view virtual override(IRoycoVaultTranche) returns (TrancheAssetClaims memory claims) {
        // Get the post-sync tranche state: applying NAV reconciliation.
        (TrancheAssetClaims memory trancheClaims, uint256 trancheTotalShares) = _previewPostSyncTrancheState();
        return UtilsLib.scaleTrancheAssetsClaim(trancheClaims, _shares, trancheTotalShares);
    }

    /// @inheritdoc IRoycoAsyncVault
    function deposit(
        TRANCHE_UNIT _assets,
        address _receiver,
        address _controller
    )
        external
        virtual
        override
        restricted
        whenNotPaused
        onlyCallerOrOperator(_controller)
        returns (uint256 shares)
    {
        require(_assets != toTrancheUnits(0), MUST_INCREASE_NAV_NON_ZERO_ASSETS());

        IRoycoKernel kernel_ = IRoycoKernel(kernel());

        // Transfer the assets from the receiver to the kernel, if the deposit is synchronous
        // If the deposit is asynchronous, the assets were transferred in during requestDeposit
        if (_isSync(Action.DEPOSIT)) {
            IERC20(asset()).safeTransferFrom(_receiver, address(kernel_), toUint256(_assets));
        }

        // Deposit the assets into the underlying investment opportunity and get the fraction of total assets allocated
        (NAV_UNIT valueAllocated, NAV_UNIT effectiveNAVToMintAt) =
            (TRANCHE_TYPE() == TrancheType.SENIOR ? kernel_.stDeposit(_assets, _controller, _receiver) : kernel_.jtDeposit(_assets, _controller, _receiver));

        // effectiveNAVToMint at can be zero initially when the tranche is deployed
        require(valueAllocated != ZERO_NAV_UNITS, INVALID_VALUE_ALLOCATED());

        // valueAllocated represents the value of the assets deposited in the asset that the tranche's NAV is denominated in
        // shares are minted to the user at the effective NAV of the tranche
        // effectiveNAVToMintAt is the effective NAV of the tranche before the deposit is made, ie. the NAV at which the shares will be minted
        shares = _convertToShares(valueAllocated, totalSupply(), effectiveNAVToMintAt, Math.Rounding.Floor);

        // Mint the shares to the receiver
        _mint(_receiver, shares);

        emit Deposit(msg.sender, _receiver, _assets, shares);
    }

    /// @inheritdoc IRoycoAsyncVault
    function redeem(
        uint256 _shares,
        address _receiver,
        address _controller
    )
        external
        virtual
        override
        restricted
        onlyCallerOrOperator(_controller)
        whenNotPaused
        returns (TrancheAssetClaims memory claims)
    {
        require(_shares != 0, MUST_REQUEST_NON_ZERO_SHARES());

        // Process the withdrawal from the underlying investment opportunity
        // It is expected that the kernel transfers the assets directly to the receiver
        claims =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IRoycoKernel(kernel()).stRedeem(_shares, _controller, _receiver)
                : IRoycoKernel(kernel()).jtRedeem(_shares, _controller, _receiver));

        // Account for the withdrawal
        _withdraw(msg.sender, _controller, _shares);
    }

    // =============================
    // ERC7540 Asynchronous flow functions
    // =============================

    /// @inheritdoc IRoycoAsyncVault
    function isOperator(address _controller, address _operator) external view virtual override(IRoycoAsyncVault) returns (bool) {
        return RoycoTrancheStorageLib._getRoycoTrancheStorage().isOperator[_controller][_operator];
    }

    /// @inheritdoc IRoycoAsyncVault
    function setOperator(address _operator, bool _approved) external virtual override(IRoycoAsyncVault) whenNotPaused returns (bool) {
        // Set the operator's approval status for the caller
        RoycoTrancheStorageLib._getRoycoTrancheStorage().isOperator[msg.sender][_operator] = _approved;
        emit OperatorSet(msg.sender, _operator, _approved);

        // Must return true as per ERC7540
        return true;
    }

    /**
     * @inheritdoc IRoycoAsyncVault
     * @dev Will revert if this tranche does not employ an asynchronous deposit flow
     */
    function requestDeposit(
        TRANCHE_UNIT _assets,
        address _controller,
        address _owner
    )
        external
        virtual
        override(IRoycoAsyncVault)
        restricted
        whenNotPaused
        onlyCallerOrOperator(_owner)
        executionIsAsync(Action.DEPOSIT)
        returns (uint256 requestId)
    {
        address kernel_ = kernel();

        // Transfer the assets from the owner to the kernel
        IERC20(asset()).safeTransferFrom(_owner, kernel_, toUint256(_assets));

        // Queue the deposit request and get the request ID from the kernel
        requestId =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTDepositKernel(kernel_).stRequestDeposit(msg.sender, _assets, _controller)
                : IAsyncJTDepositKernel(kernel_).jtRequestDeposit(msg.sender, _assets, _controller));

        emit DepositRequest(_controller, _owner, requestId, msg.sender, _assets);
    }

    /**
     * @inheritdoc IRoycoAsyncVault
     * @dev Will revert if this tranche does not employ an asynchronous deposit flow
     */
    function pendingDepositRequest(
        uint256 _requestId,
        address _controller
    )
        external
        view
        virtual
        override(IRoycoAsyncVault)
        executionIsAsync(Action.DEPOSIT)
        returns (TRANCHE_UNIT pendingAssets)
    {
        pendingAssets =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTDepositKernel(kernel()).stPendingDepositRequest(_requestId, _controller)
                : IAsyncJTDepositKernel(kernel()).jtPendingDepositRequest(_requestId, _controller));
    }

    /**
     * @inheritdoc IRoycoAsyncVault
     * @dev Will revert if this tranche does not employ an asynchronous deposit flow
     */
    function claimableDepositRequest(
        uint256 _requestId,
        address _controller
    )
        external
        view
        virtual
        override(IRoycoAsyncVault)
        executionIsAsync(Action.DEPOSIT)
        returns (TRANCHE_UNIT claimableAssets)
    {
        claimableAssets =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTDepositKernel(kernel()).stClaimableDepositRequest(_requestId, _controller)
                : IAsyncJTDepositKernel(kernel()).jtClaimableDepositRequest(_requestId, _controller));
    }

    /**
     * @inheritdoc IRoycoAsyncVault
     * @dev Will revert if this tranche does not employ an asynchronous withdrawal flow
     */
    function requestRedeem(
        uint256 _shares,
        address _controller,
        address _owner
    )
        external
        virtual
        override(IRoycoAsyncVault)
        restricted
        whenNotPaused
        executionIsAsync(Action.WITHDRAW)
        returns (uint256 requestId)
    {
        require(_shares != 0, MUST_REQUEST_NON_ZERO_SHARES());

        // Spend the caller's share allowance if the caller isn't the owner or an approved operator
        if (msg.sender != _owner && !RoycoTrancheStorageLib._getRoycoTrancheStorage().isOperator[_owner][msg.sender]) {
            _spendAllowance(_owner, msg.sender, _shares);
        }

        // Queue the redemption request and get the request ID from the kernel
        requestId =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTWithdrawalKernel(kernel()).stRequestRedeem(msg.sender, _shares, _controller)
                : IAsyncJTWithdrawalKernel(kernel()).jtRequestRedeem(msg.sender, _shares, _controller));

        // Handle the shares being redeemed from the owner
        if (_requestRedeemSharesBehavior() == RequestRedeemSharesBehavior.BURN_ON_REDEEM) {
            // Transfer and lock the requested shares being redeemed from the owner to the tranche
            _transfer(_owner, address(this), _shares);
        } else {
            // Burn the shares being redeemed from the owner immediately after the request is made
            _burn(_owner, _shares);
        }

        emit RedeemRequest(_controller, _owner, requestId, msg.sender, _shares);
    }

    /**
     * @inheritdoc IRoycoAsyncVault
     * @dev Will revert if this tranche does not employ an asynchronous withdrawal flow
     */
    function pendingRedeemRequest(
        uint256 _requestId,
        address _controller
    )
        external
        view
        virtual
        override(IRoycoAsyncVault)
        executionIsAsync(Action.WITHDRAW)
        returns (uint256 pendingShares)
    {
        pendingShares =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTWithdrawalKernel(kernel()).stPendingRedeemRequest(_requestId, _controller)
                : IAsyncJTWithdrawalKernel(kernel()).jtPendingRedeemRequest(_requestId, _controller));
    }

    /**
     * @inheritdoc IRoycoAsyncVault
     * @dev Will revert if this tranche does not employ an asynchronous withdrawal flow
     */
    function claimableRedeemRequest(
        uint256 _requestId,
        address _controller
    )
        external
        view
        virtual
        override(IRoycoAsyncVault)
        executionIsAsync(Action.WITHDRAW)
        returns (uint256 claimableShares)
    {
        claimableShares =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTWithdrawalKernel(kernel()).stClaimableRedeemRequest(_requestId, _controller)
                : IAsyncJTWithdrawalKernel(kernel()).jtClaimableRedeemRequest(_requestId, _controller));
    }

    // =============================
    // ERC-7887 Cancelation Functions
    // =============================

    /**
     * @inheritdoc IRoycoAsyncCancellableVault
     * @dev Will revert if this tranche does not employ an asynchronous deposit flow
     */
    function cancelDepositRequest(
        uint256 _requestId,
        address _controller
    )
        external
        virtual
        override(IRoycoAsyncCancellableVault)
        restricted
        whenNotPaused
        onlyCallerOrOperator(_controller)
        executionIsAsync(Action.DEPOSIT)
    {
        if (TRANCHE_TYPE() == TrancheType.SENIOR) {
            IAsyncSTDepositKernel(kernel()).stCancelDepositRequest(msg.sender, _requestId, _controller);
        } else {
            IAsyncJTDepositKernel(kernel()).jtCancelDepositRequest(msg.sender, _requestId, _controller);
        }

        emit CancelDepositRequest(_controller, _requestId, msg.sender);
    }

    /**
     * @inheritdoc IRoycoAsyncCancellableVault
     * @dev Will revert if this tranche does not employ an asynchronous deposit flow
     */
    function pendingCancelDepositRequest(
        uint256 _requestId,
        address _controller
    )
        external
        view
        virtual
        override(IRoycoAsyncCancellableVault)
        executionIsAsync(Action.DEPOSIT)
        returns (bool isPending)
    {
        return (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTDepositKernel(kernel()).stPendingCancelDepositRequest(_requestId, _controller)
                : IAsyncJTDepositKernel(kernel()).jtPendingCancelDepositRequest(_requestId, _controller));
    }

    /**
     * @inheritdoc IRoycoAsyncCancellableVault
     * @dev Will revert if this tranche does not employ an asynchronous deposit flow
     */
    function claimableCancelDepositRequest(
        uint256 _requestId,
        address _controller
    )
        external
        view
        virtual
        override(IRoycoAsyncCancellableVault)
        executionIsAsync(Action.DEPOSIT)
        returns (TRANCHE_UNIT assets)
    {
        assets =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTDepositKernel(kernel()).stClaimableCancelDepositRequest(_requestId, _controller)
                : IAsyncJTDepositKernel(kernel()).jtClaimableCancelDepositRequest(_requestId, _controller));
    }

    /**
     * @inheritdoc IRoycoAsyncCancellableVault
     * @dev Will revert if this tranche does not employ an asynchronous deposit flow
     */
    function claimCancelDepositRequest(
        uint256 _requestId,
        address _receiver,
        address _controller
    )
        external
        virtual
        override(IRoycoAsyncCancellableVault)
        restricted
        whenNotPaused
        onlyCallerOrOperator(_controller)
        executionIsAsync(Action.DEPOSIT)
    {
        // Expect the kernel to transfer the assets to the receiver directly after the cancellation is processed
        TRANCHE_UNIT claimedAssets =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTDepositKernel(kernel()).stClaimCancelDepositRequest(_requestId, _receiver, _controller)
                : IAsyncJTDepositKernel(kernel()).jtClaimCancelDepositRequest(_requestId, _receiver, _controller));
        emit CancelDepositClaim(_controller, _receiver, _requestId, msg.sender, claimedAssets);
    }

    /**
     * @inheritdoc IRoycoAsyncCancellableVault
     * @dev Will revert if this tranche does not employ an asynchronous withdrawal flow
     */
    function cancelRedeemRequest(
        uint256 _requestId,
        address _controller
    )
        external
        virtual
        override(IRoycoAsyncCancellableVault)
        restricted
        whenNotPaused
        onlyCallerOrOperator(_controller)
        executionIsAsync(Action.WITHDRAW)
    {
        if (TRANCHE_TYPE() == TrancheType.SENIOR) {
            IAsyncSTWithdrawalKernel(kernel()).stCancelRedeemRequest(_requestId, _controller);
        } else {
            IAsyncJTWithdrawalKernel(kernel()).jtCancelRedeemRequest(_requestId, _controller);
        }

        emit CancelRedeemRequest(_controller, _requestId, msg.sender);
    }

    /**
     * @inheritdoc IRoycoAsyncCancellableVault
     * @dev Will revert if this tranche does not employ an asynchronous withdrawal flow
     */
    function pendingCancelRedeemRequest(
        uint256 _requestId,
        address _controller
    )
        external
        view
        virtual
        override(IRoycoAsyncCancellableVault)
        executionIsAsync(Action.WITHDRAW)
        returns (bool isPending)
    {
        isPending =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTWithdrawalKernel(kernel()).stPendingCancelRedeemRequest(_requestId, _controller)
                : IAsyncJTWithdrawalKernel(kernel()).jtPendingCancelRedeemRequest(_requestId, _controller));
    }

    /**
     * @inheritdoc IRoycoAsyncCancellableVault
     * @dev Will revert if this tranche does not employ an asynchronous withdrawal flow
     */
    function claimableCancelRedeemRequest(
        uint256 _requestId,
        address _controller
    )
        external
        view
        virtual
        override(IRoycoAsyncCancellableVault)
        executionIsAsync(Action.WITHDRAW)
        returns (uint256 shares)
    {
        shares =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTWithdrawalKernel(kernel()).stClaimableCancelRedeemRequest(_requestId, _controller)
                : IAsyncJTWithdrawalKernel(kernel()).jtClaimableCancelRedeemRequest(_requestId, _controller));
    }

    /**
     * @inheritdoc IRoycoAsyncCancellableVault
     * @dev Will revert if this tranche does not employ an asynchronous withdrawal flow
     */
    function claimCancelRedeemRequest(
        uint256 _requestId,
        address _receiver,
        address _owner
    )
        external
        virtual
        override(IRoycoAsyncCancellableVault)
        restricted
        whenNotPaused
        onlyCallerOrOperator(_owner)
        executionIsAsync(Action.WITHDRAW)
    {
        uint256 shares =
            (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTWithdrawalKernel(kernel()).stClaimCancelRedeemRequest(_requestId, _receiver, _owner)
                : IAsyncJTWithdrawalKernel(kernel()).jtClaimCancelRedeemRequest(_requestId, _receiver, _owner));

        require(shares != 0, MUST_CLAIM_NON_ZERO_SHARES());

        // Return the shares to the receiver based on the redeem shares behavior
        if (_requestRedeemSharesBehavior() == RequestRedeemSharesBehavior.BURN_ON_REQUEST) {
            // Mint the burnt shares to the receiver
            _mint(_receiver, shares);
        } else {
            // Transfer the previously locked shares (on request) to the receiver
            _transfer(address(this), _receiver, shares);
        }

        emit CancelRedeemClaim(_owner, _receiver, _requestId, msg.sender, shares);
    }

    /// @inheritdoc IRoycoVaultTranche
    function previewMintProtocolFeeShares(
        NAV_UNIT _protocolFeeAssets,
        NAV_UNIT _trancheTotalAssets
    )
        public
        view
        virtual
        override(IRoycoVaultTranche)
        returns (uint256 mintedProtocolFeeShares, uint256 totalTrancheShares)
    {
        // Compute the shares to be minted to the protocol fee recipient to satisfy the ratio of total assets that the fee represents
        // Subtract fee assets from total tranche assets because fees are included in total tranche assets
        // Round in favor of the tranche
        uint256 totalShares = totalSupply();
        mintedProtocolFeeShares = _convertToShares(_protocolFeeAssets, totalShares, (_trancheTotalAssets - _protocolFeeAssets), Math.Rounding.Floor);

        // The total tranche shares include the protocol fee shares and virtual shares
        totalTrancheShares = _withVirtualShares(totalShares + mintedProtocolFeeShares);
    }

    /// @inheritdoc IRoycoVaultTranche
    function mintProtocolFeeShares(
        NAV_UNIT _protocolFeeAssets,
        NAV_UNIT _trancheTotalAssets,
        address _protocolFeeRecipient
    )
        external
        virtual
        override(IRoycoVaultTranche)
        returns (uint256 mintedProtocolFeeShares, uint256 totalTrancheShares)
    {
        require(msg.sender == kernel(), ONLY_KERNEL());

        (mintedProtocolFeeShares, totalTrancheShares) = previewMintProtocolFeeShares(_protocolFeeAssets, _trancheTotalAssets);
        if (mintedProtocolFeeShares != 0) {
            _mint(_protocolFeeRecipient, mintedProtocolFeeShares);
        }
    }

    /// @inheritdoc IERC20Metadata
    function decimals() public view virtual override(ERC20Upgradeable) returns (uint8) {
        return RoycoTrancheStorageLib._getRoycoTrancheStorage().underlyingAssetDecimals + _decimalsOffset();
    }

    /// @inheritdoc IRoycoVaultTranche
    function asset() public view virtual override(IRoycoVaultTranche) returns (address) {
        return RoycoTrancheStorageLib._getRoycoTrancheStorage().asset;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 _interfaceId) public pure virtual override(IERC165) returns (bool) {
        return _interfaceId == type(IERC165).interfaceId || _interfaceId == type(IRoycoAsyncVault).interfaceId
            || _interfaceId == type(IRoycoAsyncCancellableVault).interfaceId || _interfaceId == type(IRoycoVaultTranche).interfaceId
            || _interfaceId == type(IAccessControlEnumerable).interfaceId;
    }

    /// @dev Returns the type of the tranche
    function TRANCHE_TYPE() public pure virtual returns (TrancheType);

    /// @dev Doesn't transfer assets to the receiver. This is the responsibility of the kernel.
    function _withdraw(address _caller, address _owner, uint256 _shares) internal virtual {
        // If withdrawals are synchronous, burn the shares from the owner
        if (_isSync(Action.WITHDRAW)) {
            // Spend the caller's share allowance if the caller isn't the owner
            if (_caller != _owner) _spendAllowance(_owner, _caller, _shares);
            // Burn the shares being redeemed from the owner
            _burn(_owner, _shares);
        } else if (_requestRedeemSharesBehavior() == RequestRedeemSharesBehavior.BURN_ON_REDEEM) {
            // No need to spend allowance, that was already done during requestRedeem
            _burn(address(this), _shares);
        }
    }

    /**
     * @notice Returns the total tranche assets and shares after previewing a NAV synchronization in the kernel
     * @return trancheClaims The breakdown of total tranche's total controlled assets
     * @return trancheTotalShares The total supply of tranche shares (including marginally minted fee shares)
     */
    function _previewPostSyncTrancheState() internal view returns (TrancheAssetClaims memory trancheClaims, uint256 trancheTotalShares) {
        // Get the post-sync state of the kernel for the tranche
        IRoycoKernel kernel_ = IRoycoKernel(kernel());
        SyncedAccountingState memory state;
        (state, trancheClaims, trancheTotalShares) = kernel_.previewSyncTrancheAccounting(TRANCHE_TYPE());
    }

    /**
     * @dev Returns the amount of shares that have a claim on the specified amount of tranche controlled assets
     * @param _assets The amount of assets to convert
     * @param _totalSupply The total supply of tranche shares (including marginally minted fee shares)
     * @param _totalAssets The total tranche controlled assets
     * @param _rounding The rounding mode to use
     * @return shares The number of shares that have a claim on the specified amount of tranche controlled assets
     */
    function _convertToShares(NAV_UNIT _assets, uint256 _totalSupply, NAV_UNIT _totalAssets, Math.Rounding _rounding) internal view returns (uint256 shares) {
        return toUint256(_assets).mulDiv(_withVirtualShares(_totalSupply), toUint256(_withVirtualAssets(_totalAssets)), _rounding);
    }

    /// @dev Returns if the specified action employs a synchronous execution model
    function _isSync(Action _action) internal view returns (bool) {
        return (_action == Action.DEPOSIT
                    ? RoycoTrancheStorageLib._getRoycoTrancheStorage().DEPOSIT_EXECUTION_MODEL
                    : RoycoTrancheStorageLib._getRoycoTrancheStorage().WITHDRAW_EXECUTION_MODEL) == ExecutionModel.SYNC;
    }

    function _decimalsOffset() internal view virtual returns (uint8) {
        return RoycoTrancheStorageLib._getRoycoTrancheStorage().decimalsOffset;
    }

    function _requestRedeemSharesBehavior() internal view virtual returns (RequestRedeemSharesBehavior) {
        return (TRANCHE_TYPE() == TrancheType.SENIOR
                ? RoycoTrancheStorageLib._getRoycoTrancheStorage().REQUEST_REDEEM_SHARES_ST_BEHAVIOR
                : RoycoTrancheStorageLib._getRoycoTrancheStorage().REQUEST_REDEEM_SHARES_JT_BEHAVIOR);
    }

    function _withVirtualShares(uint256 _shares) internal view returns (uint256) {
        return _shares + 10 ** _decimalsOffset();
    }

    function _withVirtualAssets(NAV_UNIT _assets) internal pure returns (NAV_UNIT) {
        return _assets + toNAVUnits(uint256(1));
    }

    /// @inheritdoc ERC20PausableUpgradeable
    function _update(address _from, address _to, uint256 _value) internal override(ERC20PausableUpgradeable, ERC20Upgradeable) whenNotPaused {
        super._update(_from, _to, _value);
    }
}
