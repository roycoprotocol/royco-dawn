// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {
    ERC4626Upgradeable,
    IERC20,
    IERC20Metadata,
    Math
} from "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { IAccessControlEnumerable } from "../../lib/openzeppelin-contracts/contracts/access/extensions/IAccessControlEnumerable.sol";
import { SafeERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { AccessControlEnumerableUpgradeable, RoycoAuth, RoycoRoles } from "../auth/RoycoAuth.sol";
import { IAsyncJTDepositKernel } from "../interfaces/kernel/IAsyncJTDepositKernel.sol";
import { IAsyncJTWithdrawalKernel } from "../interfaces/kernel/IAsyncJTWithdrawalKernel.sol";
import { IAsyncSTDepositKernel } from "../interfaces/kernel/IAsyncSTDepositKernel.sol";
import { IAsyncSTWithdrawalKernel } from "../interfaces/kernel/IAsyncSTWithdrawalKernel.sol";
import { ExecutionModel, IRoycoKernel, RequestRedeemSharesBehavior } from "../interfaces/kernel/IRoycoKernel.sol";
import { IERC165, IERC7540, IERC7575, IERC7887, IRoycoVaultTranche } from "../interfaces/tranche/IRoycoVaultTranche.sol";
import { RoycoTrancheStorageLib } from "../libraries/RoycoTrancheStorageLib.sol";
import { TrancheType } from "../libraries/Types.sol";
import { Action, SyncedNAVsPacket, TrancheDeploymentParams } from "../libraries/Types.sol";

/// @title RoycoVaultTranche
/// @notice Abstract base contract implementing core functionality for Royco tranches
/// @dev This contract provides common tranche operations including ERC4626 vault functionality,
///      asynchronous deposit/withdrawal support via ERC7540, and request cancellation via ERC7887
///      All asset management and investment operations are delegated to the configured kernel
abstract contract RoycoVaultTranche is IRoycoVaultTranche, RoycoAuth, UUPSUpgradeable, ERC4626Upgradeable {
    using Math for uint256;
    using SafeERC20 for IERC20;

    /// @notice Thrown when attempting to use disabled functionality
    error DISABLED();

    /// @notice Thrown when the caller is not the expected account or an approved operator
    error ONLY_CALLER_OR_OPERATOR();

    /// @notice Thrown when the redeem amount is zero
    error MUST_REQUEST_NON_ZERO_SHARES();

    /// @notice Thrown when the deposit amount is zero
    error MUST_DEPOSIT_NON_ZERO_ASSETS();

    /// @notice Thrown when the redeem amount is zero
    error MUST_CLAIM_NON_ZERO_SHARES();

    /// @notice Modifier to ensure the functionality is disabled
    /// forge-lint: disable-next-item(unwrapped-modifier-logic)
    modifier disabled() {
        revert DISABLED();
        _;
    }

    /// @notice Modifier to ensure the specified action uses a synchronous execution model
    /// @param _action The action to check (DEPOSIT or WITHDRAW)
    /// @dev Reverts if the execution model for the action is asynchronous
    /// forge-lint: disable-next-item(unwrapped-modifier-logic)
    modifier executionIsSync(Action _action) {
        require(_isSync(_action), DISABLED());
        _;
    }

    /// @notice Modifier to ensure the specified action uses an asynchronous execution model
    /// @param _action The action to check (DEPOSIT or WITHDRAW)
    /// @dev Reverts if the execution model for the action is synchronous
    /// forge-lint: disable-next-item(unwrapped-modifier-logic)
    modifier executionIsAsync(Action _action) {
        require(!_isSync(_action), DISABLED());
        _;
    }

    /// @notice Modifier to ensure caller is either the specified address or an approved operator
    /// @param _account The address that the caller should match or have operator approval for
    /// @dev Reverts if caller is neither the address nor an approved operator
    modifier onlyCallerOrOperator(address _account) {
        _onlyCallerOrOperator(_account);
        _;
    }

    /// @notice Checks if the caller is either the specified address or an approved operator
    /// @param _account The address to check
    /// @dev Reverts if the caller is neither the address nor an approved operator
    function _onlyCallerOrOperator(address _account) internal view {
        require(msg.sender == _account || RoycoTrancheStorageLib._getRoycoTrancheStorage().isOperator[_account][msg.sender], ONLY_CALLER_OR_OPERATOR());
    }

    /// @notice Initializes the Royco tranche
    /// @dev This function initializes parent contracts and the tranche-specific state
    /// @param _trancheParams Deployment parameters including name, symbol, kernel, and kernel initialization data
    /// @param _asset The underlying asset for the tranche
    /// @param _owner The initial owner of the tranche
    /// @param _pauser The initial pauser of the tranche
    /// @param _marketId The identifier of the Royco market this tranche is linked to
    function __RoycoTranche_init(
        TrancheDeploymentParams calldata _trancheParams,
        address _asset,
        address _owner,
        address _pauser,
        bytes32 _marketId
    )
        internal
        onlyInitializing
    {
        // Initialize the parent contracts
        __ERC20_init_unchained(_trancheParams.name, _trancheParams.symbol);
        __ERC4626_init_unchained(IERC20(_asset));
        __RoycoAuth_init(_owner, _pauser);

        // Initialize the Royco Tranche state
        __RoycoTranche_init_unchained(_asset, _trancheParams.kernel, _marketId);
    }

    /// @notice Internal initialization function for Royco tranche-specific state
    /// @dev This function sets up the tranche storage and initializes the kernel
    /// @param _asset The underlying asset for the tranche
    /// @param _kernelAddress The address of the kernel that handles strategy logic
    /// @param _marketId The identifier of the Royco market this tranche is linked to
    function __RoycoTranche_init_unchained(address _asset, address _kernelAddress, bytes32 _marketId) internal onlyInitializing {
        // Calculate the vault's decimal offset (curb inflation attacks)
        uint8 underlyingAssetDecimals = IERC20Metadata(_asset).decimals();
        // TODO: Justify
        uint8 decimalsOffset = underlyingAssetDecimals >= 18 ? 0 : (18 - underlyingAssetDecimals);

        // Initialize the tranche's state
        RoycoTrancheStorageLib.__RoycoTranche_init(msg.sender, _kernelAddress, _marketId, decimalsOffset, TRANCHE_TYPE());
    }

    /// @inheritdoc ERC4626Upgradeable
    function totalAssets() public view virtual override(ERC4626Upgradeable) returns (uint256) {
        return
            (TRANCHE_TYPE() == TrancheType.SENIOR ? IRoycoKernel(_kernel()).getSTTotalEffectiveAssets() : IRoycoKernel(_kernel()).getJTTotalEffectiveAssets());
    }

    /// @inheritdoc IRoycoVaultTranche
    function getRawNAV() public view override(IRoycoVaultTranche) returns (uint256) {
        return (TRANCHE_TYPE() == TrancheType.SENIOR ? IRoycoKernel(_kernel()).getSTRawNAV() : IRoycoKernel(_kernel()).getJTRawNAV());
    }

    /// @inheritdoc ERC4626Upgradeable
    function maxDeposit(address _receiver) public view override(ERC4626Upgradeable) returns (uint256) {
        return (
            TRANCHE_TYPE() == TrancheType.SENIOR
                ? IRoycoKernel(_kernel()).stMaxDeposit(asset(), _receiver)
                : IRoycoKernel(_kernel()).jtMaxDeposit(asset(), _receiver)
        );
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev mint* flows are not supported
    function maxMint(address _receiver) public view virtual override(ERC4626Upgradeable) disabled returns (uint256) { }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev withdraw* flows are not supported
    function maxWithdraw(address _owner) public view virtual override(ERC4626Upgradeable) disabled returns (uint256) { }

    /// @inheritdoc ERC4626Upgradeable
    function maxRedeem(address _owner) public view virtual override(ERC4626Upgradeable) returns (uint256) {
        uint256 maxWithdrawableAssets = (
            TRANCHE_TYPE() == TrancheType.SENIOR
                ? IRoycoKernel(_kernel()).stMaxWithdraw(asset(), _owner)
                : IRoycoKernel(_kernel()).jtMaxWithdraw(asset(), _owner)
        );
        if (maxWithdrawableAssets == 0) return 0;

        // Get the post-sync tranche state: applying NAV reconciliation and fee share minting
        (uint256 trancheTotalAssets, uint256 trancheTotalShares) = _previewPostSyncTrancheState();

        // Compute the max withdrawable shares based on max withdrawable assets
        uint256 maxRedeemableShares = _convertToShares(maxWithdrawableAssets, trancheTotalShares, trancheTotalAssets, Math.Rounding.Floor);

        // Return the minimum of the max redeemable shares and the balance of the owner
        return Math.min(maxRedeemableShares, balanceOf(_owner));
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Disabled if deposit execution is asynchronous as per ERC7540
    function previewDeposit(uint256 _assets) public view virtual override(ERC4626Upgradeable) executionIsSync(Action.DEPOSIT) returns (uint256) {
        // Get the post-sync tranche state: applying NAV reconciliation and fee share minting
        (uint256 trancheTotalAssets, uint256 trancheTotalShares) = _previewPostSyncTrancheState();
        return _convertToShares(_assets, trancheTotalShares, trancheTotalAssets, Math.Rounding.Floor);
    }

    /// @inheritdoc ERC4626Upgradeable
    function convertToShares(uint256 _assets) public view virtual override(ERC4626Upgradeable) returns (uint256) {
        // Get the post-sync tranche state: applying NAV reconciliation. Excludes fee shares minted to the protocol fee recipient
        (uint256 trancheTotalAssets,) = _previewPostSyncTrancheState();
        return _convertToShares(_assets, totalSupply(), trancheTotalAssets, Math.Rounding.Floor);
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev mint* flows are not supported
    function previewMint(uint256 _shares) public view virtual override(ERC4626Upgradeable) disabled returns (uint256) { }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev withdraw* flows are not supported
    function previewWithdraw(uint256 _assets) public view virtual override(ERC4626Upgradeable) disabled returns (uint256) { }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Disabled if withdrawal execution is asynchronous as per ERC7540
    function previewRedeem(uint256 _shares) public view virtual override(ERC4626Upgradeable) executionIsSync(Action.WITHDRAW) returns (uint256) {
        // Get the post-sync tranche state: applying NAV reconciliation and fee share minting
        (uint256 trancheTotalAssets, uint256 trancheTotalShares) = _previewPostSyncTrancheState();
        return _convertToAssets(_shares, trancheTotalShares, trancheTotalAssets, Math.Rounding.Floor);
    }

    /// @inheritdoc ERC4626Upgradeable
    function convertToAssets(uint256 _shares) public view virtual override(ERC4626Upgradeable) returns (uint256) {
        // Get the post-sync tranche state: applying NAV reconciliation. Excludes fee shares minted to the protocol fee recipient
        (uint256 trancheTotalAssets,) = _previewPostSyncTrancheState();
        return _convertToAssets(_shares, totalSupply(), trancheTotalAssets, Math.Rounding.Floor);
    }

    /// @inheritdoc ERC4626Upgradeable
    function deposit(uint256 _assets, address _receiver) public virtual override(ERC4626Upgradeable) returns (uint256) {
        return deposit(_assets, _receiver, msg.sender);
    }

    /// @inheritdoc IERC7540
    function deposit(
        uint256 _assets,
        address _receiver,
        address _controller
    )
        public
        virtual
        override(IERC7540)
        checkRoleAndDelayIfGated(RoycoRoles.DEPOSIT_ROLE)
        whenNotPaused
        onlyCallerOrOperator(_controller)
        returns (uint256 shares)
    {
        require(_assets != 0, MUST_DEPOSIT_NON_ZERO_ASSETS());

        IRoycoKernel kernel = IRoycoKernel(_kernel());
        IERC20 asset = IERC20(asset());

        // Transfer the assets from the receiver to the kernel, if the deposit is synchronous
        // If the deposit is asynchronous, the assets were transferred in during requestDeposit
        if (_isSync(Action.DEPOSIT)) {
            asset.safeTransferFrom(_receiver, address(kernel), _assets);
        }

        // Deposit the assets into the underlying investment opportunity and get the fraction of total assets allocated
        (uint256 valueAllocated, uint256 effectiveNAVToMintAt) = (
            TRANCHE_TYPE() == TrancheType.SENIOR
                ? kernel.stDeposit(address(asset), _assets, _controller, _receiver)
                : kernel.jtDeposit(address(asset), _assets, _controller, _receiver)
        );

        // valueAllocated represents the value of the assets deposited in the asset that the tranche's NAV is denominated in
        // shares are minted to the user at the effective NAV of the tranche
        // effectiveNAVToMintAt is the effective NAV of the tranche before the deposit is made, ie. the NAV at which the shares will be minted
        shares = _convertToShares(valueAllocated, totalSupply(), effectiveNAVToMintAt, Math.Rounding.Floor);

        // Mint the shares to the receiver
        _mint(_receiver, shares);

        emit Deposit(msg.sender, _receiver, _assets, shares);
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev mint* flows are not supported
    function mint(uint256 _shares, address _receiver) public virtual override(ERC4626Upgradeable) disabled returns (uint256) { }

    /// @inheritdoc IERC7540
    /// @dev mint* flows are not supported
    function mint(uint256 _shares, address _receiver, address _controller) public virtual override(IERC7540) disabled returns (uint256 assets) { }

    /// @inheritdoc IERC7540
    /// @dev withdraw* flows are not supported
    function withdraw(
        uint256 _assets,
        address _receiver,
        address _controller
    )
        public
        virtual
        override(ERC4626Upgradeable, IERC7540)
        disabled
        returns (uint256 shares)
    { }

    /// @inheritdoc IERC7540
    function redeem(
        uint256 _shares,
        address _receiver,
        address _controller
    )
        public
        virtual
        override(ERC4626Upgradeable, IERC7540)
        onlyCallerOrOperator(_controller)
        checkRoleAndDelayIfGated(RoycoRoles.REDEEM_ROLE)
        whenNotPaused
        returns (uint256 assets)
    {
        require(_shares != 0, MUST_REQUEST_NON_ZERO_SHARES());

        // Process the withdrawal from the underlying investment opportunity
        // It is expected that the kernel transfers the assets directly to the receiver
        uint256 assetsWithdrawn = (
            TRANCHE_TYPE() == TrancheType.SENIOR
                ? IRoycoKernel(_kernel()).stRedeem(asset(), _shares, _withVirtualShares(totalSupply()), _controller, _receiver)
                : IRoycoKernel(_kernel()).jtRedeem(asset(), _shares, _withVirtualShares(totalSupply()), _controller, _receiver)
        );
        assets = assetsWithdrawn;

        // Account for the withdrawal
        _withdraw(msg.sender, _receiver, _controller, assets, _shares);
    }

    // =============================
    // ERC7540 Asynchronous flow functions
    // =============================

    /// @inheritdoc IERC7540
    function isOperator(address _controller, address _operator) external view virtual override(IERC7540) returns (bool) {
        return RoycoTrancheStorageLib._getRoycoTrancheStorage().isOperator[_controller][_operator];
    }

    /// @inheritdoc IERC7540
    function setOperator(address _operator, bool _approved) external virtual override(IERC7540) whenNotPaused returns (bool) {
        // Set the operator's approval status for the caller
        RoycoTrancheStorageLib._getRoycoTrancheStorage().isOperator[msg.sender][_operator] = _approved;
        emit OperatorSet(msg.sender, _operator, _approved);

        // Must return true as per ERC7540
        return true;
    }

    /// @inheritdoc IERC7540
    /// @dev Will revert if this tranche does not employ an asynchronous deposit flow
    function requestDeposit(
        uint256 _assets,
        address _controller,
        address _owner
    )
        external
        virtual
        override(IERC7540)
        checkRoleAndDelayIfGated(RoycoRoles.DEPOSIT_ROLE)
        whenNotPaused
        onlyCallerOrOperator(_owner)
        executionIsAsync(Action.DEPOSIT)
        returns (uint256 requestId)
    {
        address kernel = _kernel();

        // Transfer the assets from the owner to the kernel
        IERC20(asset()).safeTransferFrom(_owner, kernel, _assets);

        // Queue the deposit request and get the request ID from the kernel
        requestId = (
            TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTDepositKernel(kernel).stRequestDeposit(msg.sender, _assets, _controller)
                : IAsyncJTDepositKernel(kernel).jtRequestDeposit(msg.sender, _assets, _controller)
        );

        emit DepositRequest(_controller, _owner, requestId, msg.sender, _assets);
    }

    /// @inheritdoc IERC7540
    /// @dev Will revert if this tranche does not employ an asynchronous deposit flow
    function pendingDepositRequest(
        uint256 _requestId,
        address _controller
    )
        external
        view
        virtual
        override(IERC7540)
        executionIsAsync(Action.DEPOSIT)
        returns (uint256 pendingAssets)
    {
        pendingAssets = (
            TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTDepositKernel(_kernel()).stPendingDepositRequest(_requestId, _controller)
                : IAsyncJTDepositKernel(_kernel()).jtPendingDepositRequest(_requestId, _controller)
        );
    }

    /// @inheritdoc IERC7540
    /// @dev Will revert if this tranche does not employ an asynchronous deposit flow
    function claimableDepositRequest(
        uint256 _requestId,
        address _controller
    )
        external
        view
        virtual
        override(IERC7540)
        executionIsAsync(Action.DEPOSIT)
        returns (uint256)
    {
        return (
            TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTDepositKernel(_kernel()).stClaimableDepositRequest(_requestId, _controller)
                : IAsyncJTDepositKernel(_kernel()).jtClaimableDepositRequest(_requestId, _controller)
        );
    }

    /// @inheritdoc IERC7540
    /// @dev Will revert if this tranche does not employ an asynchronous withdrawal flow
    function requestRedeem(
        uint256 _shares,
        address _controller,
        address _owner
    )
        external
        virtual
        override(IERC7540)
        checkRoleAndDelayIfGated(RoycoRoles.REDEEM_ROLE)
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
        requestId = (
            TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTWithdrawalKernel(_kernel()).stRequestRedeem(msg.sender, _shares, _withVirtualShares(totalSupply()), _controller)
                : IAsyncJTWithdrawalKernel(_kernel()).jtRequestRedeem(msg.sender, _shares, _withVirtualShares(totalSupply()), _controller)
        );

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

    /// @inheritdoc IERC7540
    /// @dev Will revert if this tranche does not employ an asynchronous withdrawal flow
    function pendingRedeemRequest(
        uint256 _requestId,
        address _controller
    )
        external
        view
        virtual
        override(IERC7540)
        executionIsAsync(Action.WITHDRAW)
        returns (uint256 pendingShares)
    {
        pendingShares = (
            TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTWithdrawalKernel(_kernel()).stPendingRedeemRequest(_requestId, _controller)
                : IAsyncJTWithdrawalKernel(_kernel()).jtPendingRedeemRequest(_requestId, _controller)
        );
    }

    /// @inheritdoc IERC7540
    /// @dev Will revert if this tranche does not employ an asynchronous withdrawal flow
    function claimableRedeemRequest(
        uint256 _requestId,
        address _controller
    )
        external
        view
        virtual
        override(IERC7540)
        executionIsAsync(Action.WITHDRAW)
        returns (uint256 claimableShares)
    {
        return (
            TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTWithdrawalKernel(_kernel()).stClaimableRedeemRequest(_requestId, _controller)
                : IAsyncJTWithdrawalKernel(_kernel()).jtClaimableRedeemRequest(_requestId, _controller)
        );
    }

    // =============================
    // ERC-7887 Cancelation Functions
    // =============================

    /// @inheritdoc IERC7887
    /// @dev Will revert if this tranche does not employ an asynchronous deposit flow
    function cancelDepositRequest(
        uint256 _requestId,
        address _controller
    )
        external
        virtual
        override(IERC7887)
        checkRoleAndDelayIfGated(RoycoRoles.CANCEL_DEPOSIT_ROLE)
        whenNotPaused
        onlyCallerOrOperator(_controller)
        executionIsAsync(Action.DEPOSIT)
    {
        if (TRANCHE_TYPE() == TrancheType.SENIOR) {
            IAsyncSTDepositKernel(_kernel()).stCancelDepositRequest(msg.sender, _requestId, _controller);
        } else {
            IAsyncJTDepositKernel(_kernel()).jtCancelDepositRequest(msg.sender, _requestId, _controller);
        }

        emit CancelDepositRequest(_controller, _requestId, msg.sender);
    }

    /// @inheritdoc IERC7887
    /// @dev Will revert if this tranche does not employ an asynchronous deposit flow
    function pendingCancelDepositRequest(
        uint256 _requestId,
        address _controller
    )
        external
        view
        virtual
        override(IERC7887)
        executionIsAsync(Action.DEPOSIT)
        returns (bool isPending)
    {
        return (
            TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTDepositKernel(_kernel()).stPendingCancelDepositRequest(_requestId, _controller)
                : IAsyncJTDepositKernel(_kernel()).jtPendingCancelDepositRequest(_requestId, _controller)
        );
    }

    /// @inheritdoc IERC7887
    /// @dev Will revert if this tranche does not employ an asynchronous deposit flow
    function claimableCancelDepositRequest(
        uint256 _requestId,
        address _controller
    )
        external
        view
        virtual
        override(IERC7887)
        executionIsAsync(Action.DEPOSIT)
        returns (uint256 assets)
    {
        return (
            TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTDepositKernel(_kernel()).stClaimableCancelDepositRequest(_requestId, _controller)
                : IAsyncJTDepositKernel(_kernel()).jtClaimableCancelDepositRequest(_requestId, _controller)
        );
    }

    /// @inheritdoc IERC7887
    /// @dev Will revert if this tranche does not employ an asynchronous deposit flow
    function claimCancelDepositRequest(
        uint256 _requestId,
        address _receiver,
        address _controller
    )
        external
        virtual
        override(IERC7887)
        checkRoleAndDelayIfGated(RoycoRoles.CANCEL_DEPOSIT_ROLE)
        whenNotPaused
        onlyCallerOrOperator(_controller)
        executionIsAsync(Action.DEPOSIT)
    {
        // Expect the kernel to transfer the assets to the receiver directly after the cancellation is processed
        uint256 assets = (
            TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTDepositKernel(_kernel()).stClaimCancelDepositRequest(_requestId, _receiver, _controller)
                : IAsyncJTDepositKernel(_kernel()).jtClaimCancelDepositRequest(_requestId, _receiver, _controller)
        );

        emit CancelDepositClaim(_controller, _receiver, _requestId, msg.sender, assets);
    }

    /// @inheritdoc IERC7887
    /// @dev Will revert if this tranche does not employ an asynchronous withdrawal flow
    function cancelRedeemRequest(
        uint256 _requestId,
        address _controller
    )
        external
        virtual
        override(IERC7887)
        checkRoleAndDelayIfGated(RoycoRoles.CANCEL_REDEEM_ROLE)
        whenNotPaused
        onlyCallerOrOperator(_controller)
        executionIsAsync(Action.WITHDRAW)
    {
        if (TRANCHE_TYPE() == TrancheType.SENIOR) {
            IAsyncSTWithdrawalKernel(_kernel()).stCancelRedeemRequest(_requestId, _controller);
        } else {
            IAsyncJTWithdrawalKernel(_kernel()).jtCancelRedeemRequest(_requestId, _controller);
        }

        emit CancelRedeemRequest(_controller, _requestId, msg.sender);
    }

    /// @inheritdoc IERC7887
    /// @dev Will revert if this tranche does not employ an asynchronous withdrawal flow
    function pendingCancelRedeemRequest(
        uint256 _requestId,
        address _controller
    )
        external
        view
        virtual
        override(IERC7887)
        executionIsAsync(Action.WITHDRAW)
        returns (bool isPending)
    {
        return (
            TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTWithdrawalKernel(_kernel()).stPendingCancelRedeemRequest(_requestId, _controller)
                : IAsyncJTWithdrawalKernel(_kernel()).jtPendingCancelRedeemRequest(_requestId, _controller)
        );
    }

    /// @inheritdoc IERC7887
    /// @dev Will revert if this tranche does not employ an asynchronous withdrawal flow
    function claimableCancelRedeemRequest(
        uint256 _requestId,
        address _controller
    )
        external
        view
        virtual
        override(IERC7887)
        executionIsAsync(Action.WITHDRAW)
        returns (uint256 shares)
    {
        return (
            TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTWithdrawalKernel(_kernel()).stClaimableCancelRedeemRequest(_requestId, _controller)
                : IAsyncJTWithdrawalKernel(_kernel()).jtClaimableCancelRedeemRequest(_requestId, _controller)
        );
    }

    /// @inheritdoc IERC7887
    /// @dev Will revert if this tranche does not employ an asynchronous withdrawal flow
    function claimCancelRedeemRequest(
        uint256 _requestId,
        address _receiver,
        address _owner
    )
        external
        virtual
        override(IERC7887)
        checkRoleAndDelayIfGated(RoycoRoles.CANCEL_REDEEM_ROLE)
        whenNotPaused
        onlyCallerOrOperator(_owner)
        executionIsAsync(Action.WITHDRAW)
    {
        uint256 shares = (
            TRANCHE_TYPE() == TrancheType.SENIOR
                ? IAsyncSTWithdrawalKernel(_kernel()).stClaimCancelRedeemRequest(_requestId, _receiver, _owner)
                : IAsyncJTWithdrawalKernel(_kernel()).jtClaimCancelRedeemRequest(_requestId, _receiver, _owner)
        );

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
    function mintProtocolFeeShares(
        uint256 _protocolFeeAssets,
        uint256 _trancheTotalAssets,
        address _protocolFeeRecipient
    )
        external
        virtual
        override(IRoycoVaultTranche)
        onlyRole(RoycoRoles.ROYCO_KERNEL)
    {
        // Compute the shares to be minted to the protocol fee recipient to satisfy the ratio of total assets that the fee represents
        // Subtract fee assets from total tranche assets because fees are included in total tranche assets
        // Round in favor of the tranche
        uint256 protocolFeeSharesToMint = _convertToShares(_protocolFeeAssets, totalSupply(), (_trancheTotalAssets - _protocolFeeAssets), Math.Rounding.Floor);
        if (protocolFeeSharesToMint != 0) _mint(_protocolFeeRecipient, protocolFeeSharesToMint);
    }

    /// @inheritdoc IERC7575
    function share() external view virtual override(IERC7575) returns (address) {
        return address(this);
    }

    /// @inheritdoc IERC7575
    function vault(address _asset) external view virtual override(IERC7575) returns (address) {
        return _asset == asset() ? address(this) : address(0);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 _interfaceId) public pure virtual override(IERC165, AccessControlEnumerableUpgradeable) returns (bool) {
        return _interfaceId == type(IERC165).interfaceId || _interfaceId == type(ERC4626Upgradeable).interfaceId || _interfaceId == type(IERC7540).interfaceId
            || _interfaceId == type(IERC7575).interfaceId || _interfaceId == type(IERC7887).interfaceId || _interfaceId == type(IRoycoVaultTranche).interfaceId
            || _interfaceId == type(IAccessControlEnumerable).interfaceId;
    }

    /// @dev Returns the type of the tranche
    function TRANCHE_TYPE() public pure virtual returns (TrancheType);

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Doesn't transfer assets to the receiver. This is the responsibility of the kernel.
    function _withdraw(address _caller, address _receiver, address _owner, uint256 _assets, uint256 _shares) internal virtual override(ERC4626Upgradeable) {
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

        emit Withdraw(_caller, _receiver, _owner, _assets, _shares);
    }

    /**
     * @notice Returns the total tranche assets and shares after previewing a NAV synchronization in the kernel
     * @return trancheTotalAssets The total tranche controlled assets
     * @return trancheTotalShares The total supply of tranche shares (including marginally minted fee shares)
     */
    function _previewPostSyncTrancheState() internal view returns (uint256 trancheTotalAssets, uint256 trancheTotalShares) {
        // Get the post-sync state of the kernel for the tranche
        IRoycoKernel kernel = IRoycoKernel(_kernel());
        SyncedNAVsPacket memory packet = kernel.previewSyncTrancheNAVs();
        uint256 protocolFeeAssetsAccrued;
        if (TRANCHE_TYPE() == TrancheType.SENIOR) {
            trancheTotalAssets = packet.stEffectiveNAV;
            protocolFeeAssetsAccrued = packet.stProtocolFeeAccrued;
        } else {
            trancheTotalAssets = packet.jtEffectiveNAV;
            protocolFeeAssetsAccrued = packet.jtProtocolFeeAccrued;
        }

        // Convert the fee assets accrued to shares
        trancheTotalShares = totalSupply();
        // If fees were accrued, fee shares will be minted
        if (protocolFeeAssetsAccrued != 0) {
            // Simulate minting the fee shares and add them to the tranche's total shares
            // Deduct protocol fee assets accrued from the total assets since fees are included in total assets
            trancheTotalShares +=
                _convertToShares(protocolFeeAssetsAccrued, trancheTotalShares, (trancheTotalAssets - protocolFeeAssetsAccrued), Math.Rounding.Floor);
        }
    }

    /// @dev Returns the amount of shares that have a claim on the specified amount of tranche controlled assets
    function _convertToShares(uint256 _assets, uint256 _totalSupply, uint256 _totalAssets, Math.Rounding rounding) internal view returns (uint256) {
        return _assets.mulDiv(_withVirtualShares(_totalSupply), _withVirtualAssets(_totalAssets), rounding);
    }

    /// @dev Returns the amount of tranche controlled assets that the specified shares have a claim on
    function _convertToAssets(uint256 _shares, uint256 _totalSupply, uint256 _totalAssets, Math.Rounding rounding) internal view returns (uint256) {
        return _shares.mulDiv(_withVirtualAssets(_totalAssets), _withVirtualShares(_totalSupply), rounding);
    }

    /// @inheritdoc UUPSUpgradeable
    /// @dev Will revert if the caller is not the upgrader role
    function _authorizeUpgrade(address newImplementation) internal override checkRoleAndDelayIfGated(RoycoRoles.UPGRADER_ROLE) { }

    /// @dev Returns if the specified action employs a synchronous execution model
    function _isSync(Action _action) internal view returns (bool) {
        return (
            _action == Action.DEPOSIT
                ? RoycoTrancheStorageLib._getRoycoTrancheStorage().DEPOSIT_EXECUTION_MODEL
                : RoycoTrancheStorageLib._getRoycoTrancheStorage().WITHDRAW_EXECUTION_MODEL
        ) == ExecutionModel.SYNC;
    }

    /// @inheritdoc ERC4626Upgradeable
    function _decimalsOffset() internal view virtual override(ERC4626Upgradeable) returns (uint8) {
        return RoycoTrancheStorageLib._getRoycoTrancheStorage().decimalsOffset;
    }

    function _requestRedeemSharesBehavior() internal view virtual returns (RequestRedeemSharesBehavior) {
        return (
            TRANCHE_TYPE() == TrancheType.SENIOR
                ? RoycoTrancheStorageLib._getRoycoTrancheStorage().REQUEST_REDEEM_SHARES_ST_BEHAVIOR
                : RoycoTrancheStorageLib._getRoycoTrancheStorage().REQUEST_REDEEM_SHARES_JT_BEHAVIOR
        );
    }

    function _kernel() internal view virtual returns (address) {
        return RoycoTrancheStorageLib._getRoycoTrancheStorage().kernel;
    }

    function _withVirtualShares(uint256 _shares) internal view returns (uint256) {
        return _shares + 10 ** _decimalsOffset();
    }

    function _withVirtualAssets(uint256 _assets) internal pure returns (uint256) {
        return _assets + 1;
    }
}
