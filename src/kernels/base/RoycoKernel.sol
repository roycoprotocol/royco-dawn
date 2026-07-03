// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IAccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from "../../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import { RoycoBase } from "../../base/RoycoBase.sol";
import { IRoycoAccountant } from "../../interfaces/IRoycoAccountant.sol";
import { IRoycoKernel } from "../../interfaces/IRoycoKernel.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { MAX_TRANCHE_UNITS, WAD, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../../libraries/Constants.sol";
import { AssetClaims, MarketState, Operation, SyncedAccountingState, TrancheType } from "../../libraries/Types.sol";
import { Math, NAV_UNIT, TRANCHE_UNIT, UnitsMathLib, toUint256 } from "../../libraries/Units.sol";
import { UtilsLib } from "../../libraries/UtilsLib.sol";

/**
 * @title RoycoKernel
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Abstract contract serving as the base for all Royco kernel implementations
 * @dev Provides the foundational logic for kernel contracts including pre and post operation NAV reconciliation, coverage enforcement logic,
 *      and base wiring for tranche synchronization. All concrete kernel implementations should inherit from the Royco Kernel.
 */
abstract contract RoycoKernel is IRoycoKernel, RoycoBase, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using UnitsMathLib for NAV_UNIT;
    using UnitsMathLib for TRANCHE_UNIT;

    /// @dev Storage slot for RoycoKernelState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoKernelState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROYCO_KERNEL_STORAGE_SLOT = 0xf8fc0d016168fef0a165a086b5a5dc3ffa533689ceaf1369717758ae5224c600;

    /// @inheritdoc IRoycoKernel
    address public immutable override(IRoycoKernel) SENIOR_TRANCHE;

    /// @inheritdoc IRoycoKernel
    address public immutable override(IRoycoKernel) ST_ASSET;

    /// @inheritdoc IRoycoKernel
    address public immutable override(IRoycoKernel) JUNIOR_TRANCHE;

    /// @inheritdoc IRoycoKernel
    address public immutable override(IRoycoKernel) JT_ASSET;

    /// @inheritdoc IRoycoKernel
    address public immutable override(IRoycoKernel) ACCOUNTANT;

    /// @notice Whether to enforce the tranche shares transfer whitelist
    bool public immutable ENFORCE_TRANCHE_SHARES_TRANSFER_WHITELIST;

    /// @dev Permissions the function to only be callable by the market's senior tranche
    /// @dev Should be placed on ST deposit and redeem functions
    modifier onlySeniorTranche() {
        require(msg.sender == SENIOR_TRANCHE, ONLY_SENIOR_TRANCHE());
        _;
    }

    /// @dev Permissions the function to only be callable by the market's junior tranche
    /// @dev Should be placed on JT deposit and redeem functions
    modifier onlyJuniorTranche() {
        require(msg.sender == JUNIOR_TRANCHE, ONLY_JUNIOR_TRANCHE());
        _;
    }

    /// @dev Permissions the function to only be callable by the market's senior or junior tranche
    modifier onlyTranche() {
        require(msg.sender == SENIOR_TRANCHE || msg.sender == JUNIOR_TRANCHE, ONLY_TRANCHE());
        _;
    }

    /// @dev Initializes and clears the quoter cache at the start and end of the call respectively
    /// @dev Should be placed on all functions that use the quoter cache
    modifier withQuoterCache() {
        _initializeQuoterCache();
        _;
        _clearQuoterCache();
    }

    // =============================
    // Construction and Initialization Functions
    // =============================

    /// @notice Constructs the base Royco kernel state
    /// @param _params The standard construction parameters for the Royco kernel
    constructor(RoycoKernelConstructionParams memory _params) {
        // Ensure that the tranche and accountant addresses are not null
        require(
            _params.seniorTranche != address(0) && _params.stAsset != address(0) && _params.juniorTranche != address(0) && _params.jtAsset != address(0)
                && _params.accountant != address(0),
            NULL_ADDRESS()
        );

        // Set the immutable addresses
        SENIOR_TRANCHE = _params.seniorTranche;
        ST_ASSET = _params.stAsset;
        JUNIOR_TRANCHE = _params.juniorTranche;
        JT_ASSET = _params.jtAsset;
        ACCOUNTANT = _params.accountant;
        ENFORCE_TRANCHE_SHARES_TRANSFER_WHITELIST = _params.enforceVaultSharesTransferWhitelist;
    }

    /**
     * @notice Initializes the base Royco kernel state
     * @dev Initializes any parent contracts and the base kernel state
     * @param _params The standard initialization parameters for the Royco kernel
     */
    function __RoycoKernel_init(RoycoKernelInitParams memory _params) internal onlyInitializing {
        // Ensure that the tranches and their corresponding assets in the kernel match
        require(
            IRoycoVaultTranche(SENIOR_TRANCHE).asset() == ST_ASSET && IRoycoVaultTranche(JUNIOR_TRANCHE).asset() == JT_ASSET,
            TRANCHE_AND_KERNEL_ASSETS_MISMATCH()
        );
        // Ensure that the initial authority and protocol fee recipient are not null
        require(_params.initialAuthority != address(0) && _params.protocolFeeRecipient != address(0), NULL_ADDRESS());

        // Initialize the base Royco kernel state
        __RoycoBase_init(_params.initialAuthority);

        RoycoKernelState storage $ = _getRoycoKernelStorage();
        $.protocolFeeRecipient = _params.protocolFeeRecipient;
        $.stSelfLiquidationBonusWAD = _params.stSelfLiquidationBonusWAD;
        $.isBlacklistEnabled = true; // Enable the blacklist by default

        emit ProtocolFeeRecipientUpdated(_params.protocolFeeRecipient);
    }

    // =============================
    // Tranche Asset Quoter Functions
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
    // Tranche Preview Functions
    // =============================

    /// @inheritdoc IRoycoKernel
    function stPreviewDeposit(TRANCHE_UNIT _assets)
        public
        view
        override(IRoycoKernel)
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated)
    {
        // Preview the state of the senior tranche before the deposit
        stateBeforeDeposit = _previewSyncTrancheAccounting();
        // Convert the assets to NAV units
        valueAllocated = stConvertTrancheUnitsToNAVUnits(_assets);
    }

    /// @inheritdoc IRoycoKernel
    function jtPreviewDeposit(TRANCHE_UNIT _assets)
        public
        view
        override(IRoycoKernel)
        returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated)
    {
        // Preview the state of the junior tranche before the deposit
        stateBeforeDeposit = _previewSyncTrancheAccounting();
        // Convert the assets to NAV units
        valueAllocated = jtConvertTrancheUnitsToNAVUnits(_assets);
    }

    /// @inheritdoc IRoycoKernel
    function stPreviewRedeem(uint256 _shares) public view override(IRoycoKernel) returns (AssetClaims memory userClaim) {
        // Preview the total claims the senior tranche has on each tranche's assets and the total shares after minting any protocol fee shares post-sync
        (SyncedAccountingState memory state, AssetClaims memory stNotionalClaims, uint256 totalShares) = previewSyncTrancheAccounting(TrancheType.SENIOR);

        // Calculate the user's claims based on the shares redeemed
        userClaim = UtilsLib.scaleAssetClaims(stNotionalClaims, _shares, totalShares);
        (userClaim,) = _applySeniorTrancheSelfLiquidationBonus(state, userClaim);
    }

    /// @inheritdoc IRoycoKernel
    function jtPreviewRedeem(uint256 _shares) public view override(IRoycoKernel) returns (AssetClaims memory userClaim) {
        // Preview the total claims the junior tranche has on each tranche's assets and the total shares after minting any protocol fee shares post-sync
        (, AssetClaims memory jtNotionalClaims, uint256 totalShares) = previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Calculate the user's claims based on the shares redeemed
        userClaim = UtilsLib.scaleAssetClaims(jtNotionalClaims, _shares, totalShares);
    }

    // =============================
    // Tranche Max Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoKernel
    /// @dev ST deposits are allowed only in a PERPETUAL market state, granted that the market's coverage requirement is satisfied post-deposit
    function stMaxDeposit(address _receiver) public view virtual override(IRoycoKernel) returns (TRANCHE_UNIT) {
        // If the receiver is blacklisted or the kernel is currently paused, return zero tranche units
        if (isBlacklisted(_receiver) || paused()) return ZERO_TRANCHE_UNITS;
        SyncedAccountingState memory state = _previewSyncTrancheAccounting();
        // ST deposits are disabled during a fixed-term market state
        if (state.marketState == MarketState.FIXED_TERM) return ZERO_TRANCHE_UNITS;
        // If ST IL exists, ST deposits are disabled to preclude existing ST's from getting diluted and realizing losses
        if (state.stImpermanentLoss != ZERO_NAV_UNITS) return ZERO_TRANCHE_UNITS;
        // ST deposits are enabled as long as ST IL is nonexistent and coverage is satisfied
        // No need to include ST liquidation proceeds in the raw NAV because those assets are not exposed to any volatility
        NAV_UNIT stMaxDepositableNAV = IRoycoAccountant(ACCOUNTANT).maxSTDepositGivenCoverage(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV());
        return stConvertNAVUnitsToTrancheUnits(stMaxDepositableNAV);
    }

    /// @inheritdoc IRoycoKernel
    /// @dev ST redemptions are allowed in PERPETUAL market states
    function stMaxWithdrawable(address _owner)
        public
        view
        virtual
        override(IRoycoKernel)
        returns (
            NAV_UNIT claimOnStNAV,
            NAV_UNIT claimOnJtNAV,
            NAV_UNIT stMaxWithdrawableNAV,
            NAV_UNIT jtMaxWithdrawableNAV,
            uint256 totalTrancheSharesAfterMintingFees
        )
    {
        // If the owner is blacklisted or the kernel is currently paused, return zero claims
        if (isBlacklisted(_owner) || paused()) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);

        SyncedAccountingState memory state;
        AssetClaims memory stNotionalClaims;
        (state, stNotionalClaims, totalTrancheSharesAfterMintingFees) = previewSyncTrancheAccounting(TrancheType.SENIOR);

        // ST redemptions are disabled during a fixed-term market state
        if (state.marketState == MarketState.FIXED_TERM) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);

        // Get the total claims the senior tranche has on each tranche's assets
        claimOnStNAV = stConvertTrancheUnitsToNAVUnits(stNotionalClaims.stAssets);
        claimOnJtNAV = jtConvertTrancheUnitsToNAVUnits(stNotionalClaims.jtAssets);

        // Bound the claims by the max withdrawable assets globally for each tranche and compute the cumulative NAV
        stMaxWithdrawableNAV = _getSeniorTrancheRawNAV();
        jtMaxWithdrawableNAV = _getJuniorTrancheRawNAV();
    }

    /// @inheritdoc IRoycoKernel
    /// @dev JT deposits are allowed if the market is in a PERPETUAL state
    function jtMaxDeposit(address _receiver) public view virtual override(IRoycoKernel) returns (TRANCHE_UNIT) {
        // If the receiver is blacklisted or the kernel is currently paused, return zero tranche units
        if (isBlacklisted(_receiver) || paused()) return ZERO_TRANCHE_UNITS;
        // JT deposits are disabled during a fixed-term market state
        if ((_previewSyncTrancheAccounting()).marketState == MarketState.FIXED_TERM) return ZERO_TRANCHE_UNITS;
        return MAX_TRANCHE_UNITS;
    }

    /// @inheritdoc IRoycoKernel
    /// @dev JT redemptions are allowed only in a PERPETUAL market state, granted that the market's coverage requirement is satisfied post-redemption
    function jtMaxWithdrawable(address _owner)
        public
        view
        virtual
        override(IRoycoKernel)
        returns (
            NAV_UNIT claimOnStNAV,
            NAV_UNIT claimOnJtNAV,
            NAV_UNIT stMaxWithdrawableNAV,
            NAV_UNIT jtMaxWithdrawableNAV,
            uint256 totalTrancheSharesAfterMintingFees
        )
    {
        // If the owner is blacklisted or the kernel is currently paused, return zero claims
        if (isBlacklisted(_owner) || paused()) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);

        // Get the total claims the junior tranche has on each tranche's assets
        SyncedAccountingState memory state;
        (state,, totalTrancheSharesAfterMintingFees) = previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // JT redemptions are disabled during a fixed-term market state
        if (state.marketState == MarketState.FIXED_TERM) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS, 0);

        // Use the precise NAV claims directly from the decomposition instead of round-tripping them through tranche units (NAV -> tranche -> NAV).
        (,, claimOnStNAV, claimOnJtNAV) = _decomposeNAVClaims(state);

        // Get the max withdrawable ST and JT assets in NAV units from the accountant considering the coverage requirement
        (, NAV_UNIT stClaimableGivenCoverage, NAV_UNIT jtClaimableGivenCoverage) =
            IRoycoAccountant(ACCOUNTANT).maxJTWithdrawalGivenCoverage(state.stRawNAV, state.jtRawNAV, claimOnStNAV, claimOnJtNAV);

        // Bound the claims by the max withdrawable assets globally for each tranche and compute the cumulative NAV
        stMaxWithdrawableNAV = stClaimableGivenCoverage;
        jtMaxWithdrawableNAV = jtClaimableGivenCoverage;
    }

    // =============================
    // External Tranche Accounting and Synchronization Functions
    // =============================

    /// @inheritdoc IRoycoKernel
    function syncTrancheAccounting()
        public
        virtual
        override(IRoycoKernel)
        whenNotPaused
        restricted
        nonReentrant
        withQuoterCache
        returns (SyncedAccountingState memory state)
    {
        // Execute a NAV accounting sync via the accountant to reconcile PNL
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

        // Derive the asset claims for this tranche
        claims = _deriveTrancheAssetClaims(_trancheType, state);

        // Return the requested tranche claims and total shares
        if (_trancheType == TrancheType.SENIOR) {
            (, totalTrancheShares) = IRoycoVaultTranche(SENIOR_TRANCHE).previewMintProtocolFeeShares(state.stProtocolFeeAccrued, state.stEffectiveNAV);
        } else {
            (, totalTrancheShares) = IRoycoVaultTranche(JUNIOR_TRANCHE).previewMintProtocolFeeShares(state.jtProtocolFeeAccrued, state.jtEffectiveNAV);
        }
    }

    // =============================
    // Senior Tranche Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoKernel
    /// @dev ST deposits are enabled only in a PERPETUAL market state, granted that the market's coverage requirement is satisfied post-deposit
    /// @dev ST deposits are disabled if the senior tranche has incurred any impermanent loss to prevent dilution
    function stDeposit(TRANCHE_UNIT _assets)
        external
        virtual
        override(IRoycoKernel)
        whenNotPaused
        onlySeniorTranche
        nonReentrant
        withQuoterCache
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt)
    {
        // Execute an accounting sync to reconcile underlying PNL
        SyncedAccountingState memory state = _preOpSyncTrancheAccounting();
        // ST deposits are disabled during a fixed-term market state
        require(state.marketState == MarketState.PERPETUAL, DISABLED_IN_FIXED_TERM_STATE());
        // If ST IL exists, ST deposits are disabled to preclude existing ST's from getting diluted and realizing losses
        require(state.stImpermanentLoss == ZERO_NAV_UNITS, ST_DEPOSIT_DISABLED_IN_LOSS());
        // The NAV to mint tranche shares at is the pre-deposit senior tranche controlled NAV
        navToMintSharesAt = state.stEffectiveNAV;
        // The precise value allocated is the value of the deposited assets
        valueAllocated = stConvertTrancheUnitsToNAVUnits(_assets);

        // Process the deposit for the senior tranche
        _stDepositAssets(_assets);

        // Execute a post-deposit sync on accounting and enforce the market's coverage requirement
        _postOpSyncTrancheAccountingAndEnforceCoverage(Operation.ST_DEPOSIT);
    }

    /// @inheritdoc IRoycoKernel
    /// @dev ST redemptions are enabled if the market is in a PERPETUAL state
    function stRedeem(
        uint256 _shares,
        address _receiver,
        bool _bypassRedemptionRestrictions
    )
        external
        virtual
        override(IRoycoKernel)
        whenNotPaused
        onlySeniorTranche
        nonReentrant
        withQuoterCache
        returns (AssetClaims memory userAssetClaims)
    {
        SyncedAccountingState memory state;
        uint256 totalTrancheShares;
        // Execute an accounting sync to reconcile underlying PNL
        (state, userAssetClaims, totalTrancheShares) = _preOpSyncTrancheAccounting(TrancheType.SENIOR);
        // ST redemptions are disabled during a fixed-term market state
        require(_bypassRedemptionRestrictions || state.marketState == MarketState.PERPETUAL, DISABLED_IN_FIXED_TERM_STATE());

        // Scale the cumulative tranche asset claims by the ratio of shares this user owns of the entire tranche
        // Protocol fee shares were minted in the pre-op sync, so the total tranche shares are up to date
        userAssetClaims = UtilsLib.scaleAssetClaims(userAssetClaims, _shares, totalTrancheShares);

        // Apply any ST self-liquidation bonus to the redeeming user's asset claims and retrieve the bonus NAV applied
        NAV_UNIT stSelfLiquidationBonusNAV;
        (userAssetClaims, stSelfLiquidationBonusNAV) = _applySeniorTrancheSelfLiquidationBonus(state, userAssetClaims);

        // Withdraw the asset claims from each tranche with the self-liquidation bonus applied and transfer them to the receiver
        _withdrawAssets(userAssetClaims, _receiver);

        // Execute a post-redeem sync on accounting and include any self-liquidation bonus
        _postOpSyncTrancheAccounting(Operation.ST_REDEEM, stSelfLiquidationBonusNAV);
    }

    // =============================
    // Junior Tranche Deposit and Redeem Functions
    // =============================

    /// @inheritdoc IRoycoKernel
    /// @dev JT deposits are enabled if the market is in a PERPETUAL state
    function jtDeposit(TRANCHE_UNIT _assets)
        external
        virtual
        override(IRoycoKernel)
        whenNotPaused
        onlyJuniorTranche
        nonReentrant
        withQuoterCache
        returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt)
    {
        // Execute an accounting sync to reconcile underlying PNL
        SyncedAccountingState memory state = _preOpSyncTrancheAccounting();
        // JT deposits are disabled during a fixed-term market state
        require(state.marketState == MarketState.PERPETUAL, DISABLED_IN_FIXED_TERM_STATE());
        // The NAV to mint tranche shares at is the pre-deposit junior tranche controlled NAV
        navToMintSharesAt = state.jtEffectiveNAV;
        // The precise value allocated is the value of the deposited assets
        valueAllocated = jtConvertTrancheUnitsToNAVUnits(_assets);

        // Process the deposit for the junior tranche
        _jtDepositAssets(_assets);

        // Execute a post-deposit sync on accounting
        _postOpSyncTrancheAccounting(Operation.JT_DEPOSIT, ZERO_NAV_UNITS);
    }

    /// @inheritdoc IRoycoKernel
    /// @dev JT redemptions are enabled only in a PERPETUAL market state (unless restrictions are bypassed for a seizure), granted that the market's coverage requirement is satisfied post-redemption
    function jtRedeem(
        uint256 _shares,
        address _receiver,
        bool _bypassRedemptionRestrictions
    )
        external
        virtual
        override(IRoycoKernel)
        whenNotPaused
        onlyJuniorTranche
        nonReentrant
        withQuoterCache
        returns (AssetClaims memory userAssetClaims)
    {
        // Execute a pre-op sync on accounting
        SyncedAccountingState memory state;
        uint256 totalTrancheShares;
        (state, userAssetClaims, totalTrancheShares) = _preOpSyncTrancheAccounting(TrancheType.JUNIOR);
        // JT redemptions are disabled during a fixed-term market state
        require(_bypassRedemptionRestrictions || state.marketState == MarketState.PERPETUAL, DISABLED_IN_FIXED_TERM_STATE());

        // Scale the cumulative tranche asset claims by the ratio of shares this user owns of the entire tranche
        // Protocol fee shares were minted in the pre-op sync, so the total tranche shares are up to date
        userAssetClaims = UtilsLib.scaleAssetClaims(userAssetClaims, _shares, totalTrancheShares);

        // Withdraw the asset claims from each tranche and transfer them to the receiver
        _withdrawAssets(userAssetClaims, _receiver);

        if (_bypassRedemptionRestrictions) {
            // Execute a post-redeem sync on accounting without enforcing the market's coverage requirement
            _postOpSyncTrancheAccounting(Operation.JT_REDEEM, ZERO_NAV_UNITS);
        } else {
            // Execute a post-redeem sync on accounting and enforce the market's coverage requirement
            _postOpSyncTrancheAccountingAndEnforceCoverage(Operation.JT_REDEEM);
        }
    }

    // =============================
    // Admin Functions
    // =============================

    /// @inheritdoc IRoycoKernel
    function setProtocolFeeRecipient(address _protocolFeeRecipient) external override(IRoycoKernel) restricted {
        require(_protocolFeeRecipient != address(0), NULL_ADDRESS());
        _getRoycoKernelStorage().protocolFeeRecipient = _protocolFeeRecipient;
        emit ProtocolFeeRecipientUpdated(_protocolFeeRecipient);
    }

    /// @inheritdoc IRoycoKernel
    function setSeniorTrancheSelfLiquidationBonus(uint64 _stSelfLiquidationBonusWAD) external override(IRoycoKernel) restricted {
        _getRoycoKernelStorage().stSelfLiquidationBonusWAD = _stSelfLiquidationBonusWAD;
        emit SeniorTrancheSelfLiquidationBonusUpdated(_stSelfLiquidationBonusWAD);
    }

    /// @inheritdoc IRoycoKernel
    function setBlacklistStatus(bool _blacklistEnabled) external override(IRoycoKernel) restricted {
        RoycoKernelState storage $ = _getRoycoKernelStorage();
        require($.isBlacklistEnabled != _blacklistEnabled, BLACKLIST_STATUS_ALREADY_SET(_blacklistEnabled));
        $.isBlacklistEnabled = _blacklistEnabled;
        emit BlacklistStatusUpdated(_blacklistEnabled);
    }

    /// @inheritdoc IRoycoKernel
    function blacklistAccounts(address[] calldata _accounts) external override(IRoycoKernel) restricted {
        require(_accounts.length != 0, EMPTY_ARRAY());
        RoycoKernelState storage $ = _getRoycoKernelStorage();
        for (uint256 i = 0; i < _accounts.length; i++) {
            address account = _accounts[i];
            require(account != address(0), NULL_ADDRESS());
            require(!$.isBlacklisted[account], ACCOUNT_ALREADY_BLACKLISTED(account));
            $.isBlacklisted[account] = true;
            emit AccountBlacklisted(account);
        }
    }

    /// @inheritdoc IRoycoKernel
    function unblacklistAccounts(address[] calldata _accounts) external override(IRoycoKernel) restricted {
        require(_accounts.length != 0, EMPTY_ARRAY());
        RoycoKernelState storage $ = _getRoycoKernelStorage();
        for (uint256 i = 0; i < _accounts.length; i++) {
            address account = _accounts[i];
            require(account != address(0), NULL_ADDRESS());
            require($.isBlacklisted[account], ACCOUNT_NOT_BLACKLISTED(account));
            $.isBlacklisted[account] = false;
            emit AccountUnblacklisted(account);
        }
    }

    // =============================
    // Tranche Compliance Methods
    // =============================

    /// @inheritdoc IRoycoKernel
    function isBlacklisted(address _account) public view override(IRoycoKernel) returns (bool) {
        RoycoKernelState storage $ = _getRoycoKernelStorage();
        return $.isBlacklistEnabled && $.isBlacklisted[_account];
    }

    /// @inheritdoc IRoycoKernel
    function preTrancheBalanceUpdateHook(address _caller, address _from, address _to, uint256 _value)
        external
        override(IRoycoKernel)
        onlyTranche
        whenNotPaused
    {
        // Check the blacklist if it is enabled
        bool blacklistEnabled = _getRoycoKernelStorage().isBlacklistEnabled;
        if (blacklistEnabled) {
            // Check if caller is blacklisted or not
            require(!isBlacklisted(_caller), ACCOUNT_BLACKLISTED(_caller));
            // Check if the sender is blacklisted if not a mint
            require(_from == address(0) || !isBlacklisted(_from), ACCOUNT_BLACKLISTED(_from));
        }
        // Check if the recipient is blacklisted if not a redeem
        if (_to != address(0)) {
            require(!blacklistEnabled || !isBlacklisted(_to), ACCOUNT_BLACKLISTED(_to));
            // If transferring shares, ensure that the recipient is a whitelisted LP for the tranche
            // It is assumed that the sender is already a whitelisted LP
            if (ENFORCE_TRANCHE_SHARES_TRANSFER_WHITELIST) {
                address authority = authority();
                // Check if the to address can call the deposit function on the tranche
                // @dev msg.sender is the tranche address
                (bool isWhitelistedTrancheLP,) = IAccessManager(authority).canCall(_to, msg.sender, IRoycoVaultTranche.deposit.selector);
                require(_to != authority && isWhitelistedTrancheLP, ACCOUNT_NOT_WHITELISTED_TRANCHE_LP(_to));
            }
        }

        // Call the market specific pre-balance update hook
        _preTrancheBalanceUpdate(_caller, _from, _to, _value);
    }

    /**
     * @notice Pre-balance update hook for the kernel
     * @dev Should be overridden by concrete kernel implementations to perform any additional checks or actions
     * @dev The caller is the address that initiated the balance update
     * @param _caller The address that initiated the balance update
     * @param _from The address from which the balance is being updated
     * @param _to The address to which the balance is being updated
     * @param _value The amount of the balance being updated
     */
    function _preTrancheBalanceUpdate(address _caller, address _from, address _to, uint256 _value) internal virtual { }

    // =============================
    // Internal Tranche Accounting Synchronization Functions
    // =============================

    /**
     * @notice Previews an accounting sync via the accountant
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function _previewSyncTrancheAccounting() internal view virtual whenNotPaused returns (SyncedAccountingState memory state) {
        // Preview an accounting sync via the accountant
        state = IRoycoAccountant(ACCOUNTANT).previewSyncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV());
    }

    /**
     * @notice Invokes the accountant to do a pre-operation (deposit and withdrawal) NAV sync and mints any protocol fee shares accrued
     * @dev A sync must be executed before every NAV mutating operation (deposit and withdrawal)
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function _preOpSyncTrancheAccounting() internal virtual returns (SyncedAccountingState memory state) {
        // Execute the pre-op sync via the accountant
        state = IRoycoAccountant(ACCOUNTANT).preOpSyncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV());

        // Collect any protocol fees accrued
        _collectProtocolFees(state.stProtocolFeeAccrued, state.jtProtocolFeeAccrued, state.stEffectiveNAV, state.jtEffectiveNAV);
    }

    /**
     * @notice Invokes the accountant to do a NAV sync and mints any protocol fee shares accrued
     * @dev A sync must be executed before every NAV mutating operation (deposit and withdrawal)
     * @notice Returns the asset claims and total tranche shares after minting any fees for the specified tranche
     * @param _trancheType An enumerator indicating which tranche to return claims and total tranche shares for
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     * @return claims The cumulative asset claims that the specified tranche is entitled to
     * @return totalTrancheShares The total shares outstanding in the specified tranche after minting any protocol fee shares
     */
    function _preOpSyncTrancheAccounting(TrancheType _trancheType)
        internal
        virtual
        returns (SyncedAccountingState memory state, AssetClaims memory claims, uint256 totalTrancheShares)
    {
        // Execute the pre-op sync via the accountant
        state = IRoycoAccountant(ACCOUNTANT).preOpSyncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV());

        // Collect any protocol fees accrued from the sync to the fee recipient
        RoycoKernelState storage $ = _getRoycoKernelStorage();
        address protocolFeeRecipient = $.protocolFeeRecipient;
        uint256 stTotalTrancheSharesAfterMintingFees;
        uint256 jtTotalTrancheSharesAfterMintingFees;
        // If the call needs to get total supply or mint shares for fees accrued for the senior tranche
        if (_trancheType == TrancheType.SENIOR || state.stProtocolFeeAccrued != ZERO_NAV_UNITS) {
            (, stTotalTrancheSharesAfterMintingFees) =
                IRoycoVaultTranche(SENIOR_TRANCHE).mintProtocolFeeShares(state.stProtocolFeeAccrued, state.stEffectiveNAV, protocolFeeRecipient);
        }
        // If the call needs to get total supply or mint shares for fees accrued for the junior tranche
        if (_trancheType == TrancheType.JUNIOR || state.jtProtocolFeeAccrued != ZERO_NAV_UNITS) {
            (, jtTotalTrancheSharesAfterMintingFees) =
                IRoycoVaultTranche(JUNIOR_TRANCHE).mintProtocolFeeShares(state.jtProtocolFeeAccrued, state.jtEffectiveNAV, protocolFeeRecipient);
        }

        // Assign the total supply of tranche shares for the specified tranche
        totalTrancheShares = (_trancheType == TrancheType.SENIOR ? stTotalTrancheSharesAfterMintingFees : jtTotalTrancheSharesAfterMintingFees);

        // Derive the asset claims for the specified tranche
        claims = _deriveTrancheAssetClaims(_trancheType, state);
    }

    /**
     * @notice Invokes the accountant to do a post-operation (deposit or withdrawal) NAV sync
     * @dev Must be executed after every NAV mutating operation that doesn't require a coverage check (ST redemption and JT deposit)
     * @param _op The operation being executed in between the pre and post synchronizations
     * @param _stSelfLiquidationBonusNAV The NAV of assets from JT effective NAV used as a bonus for ST redemptions (only applicable if _op == ST_REDEEM)
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function _postOpSyncTrancheAccounting(Operation _op, NAV_UNIT _stSelfLiquidationBonusNAV) internal virtual returns (SyncedAccountingState memory state) {
        // Execute the post-op sync on the accountant
        state = IRoycoAccountant(ACCOUNTANT).postOpSyncTrancheAccounting(_op, _getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV(), _stSelfLiquidationBonusNAV);
    }

    /**
     * @notice Invokes the accountant to do a post-operation (deposit or withdrawal) NAV sync and enforce that the market's coverage requirement is satisfied after reconciliation
     * @dev Must be executed after every NAV mutating operation that requires a coverage check (ST deposit and JT redemption)
     * @param _op The operation being executed in between the pre and post synchronizations
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function _postOpSyncTrancheAccountingAndEnforceCoverage(Operation _op) internal virtual returns (SyncedAccountingState memory state) {
        // Execute the post-op sync on the accountant
        state = IRoycoAccountant(ACCOUNTANT).postOpSyncTrancheAccountingAndEnforceCoverage(_op, _getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV());
    }

    /**
     * @notice Mints protocol fee shares to the fee recipient based on fees accrued on an accounting sync
     * @dev Shares are minted at the current effective NAV per share ratio, diluting existing holders proportionally
     * @dev Only mints if non-zero fees were accrued
     * @param _stProtocolFeeAccrued The NAV amount of protocol fees accrued from senior tranche yield
     * @param _jtProtocolFeeAccrued The NAV amount of protocol fees accrued from junior tranche yield
     * @param _stEffectiveNAV The senior tranche's effective NAV used to calculate shares to mint
     * @param _jtEffectiveNAV The junior tranche's effective NAV used to calculate shares to mint
     */
    function _collectProtocolFees(NAV_UNIT _stProtocolFeeAccrued, NAV_UNIT _jtProtocolFeeAccrued, NAV_UNIT _stEffectiveNAV, NAV_UNIT _jtEffectiveNAV) internal {
        if (_stProtocolFeeAccrued != ZERO_NAV_UNITS || _jtProtocolFeeAccrued != ZERO_NAV_UNITS) {
            RoycoKernelState storage $ = _getRoycoKernelStorage();
            address protocolFeeRecipient = $.protocolFeeRecipient;
            // If ST fees were accrued, mint ST protocol fee shares to the protocol fee recipient
            if (_stProtocolFeeAccrued != ZERO_NAV_UNITS) {
                IRoycoVaultTranche(SENIOR_TRANCHE).mintProtocolFeeShares(_stProtocolFeeAccrued, _stEffectiveNAV, protocolFeeRecipient);
            }
            // If JT fees were accrued, mint JT protocol fee shares to the protocol fee recipient
            if (_jtProtocolFeeAccrued != ZERO_NAV_UNITS) {
                IRoycoVaultTranche(JUNIOR_TRANCHE).mintProtocolFeeShares(_jtProtocolFeeAccrued, _jtEffectiveNAV, protocolFeeRecipient);
            }
        }
    }

    /**
     * @notice Derives the cumulative asset claims that the specified tranche is entitled to
     * @param _trancheType An enumerator indicating which tranche to return cumulative claims for
     * @param _state The synced NAV, impermanent loss, and fee accounting containing all mark to market accounting data
     * @return claims The cumulative asset claims that the specified tranche is entitled to
     */
    function _deriveTrancheAssetClaims(TrancheType _trancheType, SyncedAccountingState memory _state)
        internal
        view
        virtual
        returns (AssetClaims memory claims)
    {
        // Decompose the NAV claims for the tranches based on the synced accounting state
        (NAV_UNIT stClaimOnSelfRawNAV, NAV_UNIT stClaimOnJTRawNAV, NAV_UNIT jtClaimOnSTRawNAV, NAV_UNIT jtClaimOnSelfRawNAV) = _decomposeNAVClaims(_state);

        // Compute the cumulative asset claims for the specified tranche based on the NAV decomposition
        if (_trancheType == TrancheType.SENIOR) {
            if (stClaimOnSelfRawNAV != ZERO_NAV_UNITS) claims.stAssets = stConvertNAVUnitsToTrancheUnits(stClaimOnSelfRawNAV);
            if (stClaimOnJTRawNAV != ZERO_NAV_UNITS) claims.jtAssets = jtConvertNAVUnitsToTrancheUnits(stClaimOnJTRawNAV);
            claims.nav = _state.stEffectiveNAV;
        } else {
            if (jtClaimOnSTRawNAV != ZERO_NAV_UNITS) claims.stAssets = stConvertNAVUnitsToTrancheUnits(jtClaimOnSTRawNAV);
            if (jtClaimOnSelfRawNAV != ZERO_NAV_UNITS) claims.jtAssets = jtConvertNAVUnitsToTrancheUnits(jtClaimOnSelfRawNAV);
            claims.nav = _state.jtEffectiveNAV;
        }
    }

    /**
     * @notice Decomposes the synced accounting state into self-backed and cross-tranche NAV claims
     * @param _state The synced NAV, impermanent loss, and fee accounting containing all mark to market accounting data
     * @return stClaimOnSelfRawNAV The portion of ST's effective NAV that is funded by ST’s raw NAV
     * @return stClaimOnJTRawNAV The portion of ST's effective NAV that is funded by JT’s raw NAV
     * @return jtClaimOnSTRawNAV The portion of JT's effective NAV that is funded by ST’s raw NAV
     * @return jtClaimOnSelfRawNAV The portion of JT's effective NAV that is funded by JT’s raw NAV
     */
    function _decomposeNAVClaims(SyncedAccountingState memory _state)
        internal
        pure
        virtual
        returns (NAV_UNIT stClaimOnSelfRawNAV, NAV_UNIT stClaimOnJTRawNAV, NAV_UNIT jtClaimOnSTRawNAV, NAV_UNIT jtClaimOnSelfRawNAV)
    {
        // Cross-tranche claims (the NAV that can't funded by the tranche's own raw NAV)
        stClaimOnJTRawNAV = UnitsMathLib.saturatingSub(_state.stEffectiveNAV, _state.stRawNAV);
        jtClaimOnSTRawNAV = UnitsMathLib.saturatingSub(_state.jtEffectiveNAV, _state.jtRawNAV);

        // Self-backed portions (the NAV that can be funded by the tranche's own raw NAV)
        // NOTE: Since NAV conservation is enforced in the accountant, these will never underflow
        stClaimOnSelfRawNAV = (_state.stRawNAV - jtClaimOnSTRawNAV);
        jtClaimOnSelfRawNAV = (_state.jtRawNAV - stClaimOnJTRawNAV);
    }

    // =============================
    // Internal Utility Functions
    // =============================

    /**
     * @notice Returns the raw net asset value of the senior tranche denominated in the NAV units (USD, BTC, etc.) for this kernel
     * @return stRawNAV The pure net asset value of the senior tranche invested assets
     */
    function _getSeniorTrancheRawNAV() internal view virtual returns (NAV_UNIT stRawNAV) {
        // Get the yield bearing assets owned by ST and convert them to NAV units via the configured quoter
        return stConvertTrancheUnitsToNAVUnits(_getRoycoKernelStorage().stOwnedYieldBearingAssets);
    }

    /**
     * @notice Returns the raw net asset value of the junior tranche denominated in the NAV units (USD, BTC, etc.) for this kernel
     * @return jtRawNAV The pure net asset value of the junior tranche invested assets
     */
    function _getJuniorTrancheRawNAV() internal view virtual returns (NAV_UNIT jtRawNAV) {
        // Get the yield bearing assets owned by JT and convert them to NAV units via the configured quoter
        return jtConvertTrancheUnitsToNAVUnits(_getRoycoKernelStorage().jtOwnedYieldBearingAssets);
    }

    /**
     * @notice Process a deposit of senior tranche assets
     * @dev The ST vault has already transferred the assets to the kernel
     * @param _stAssets The senior tranche assets deposited by the ST LP
     */
    function _stDepositAssets(TRANCHE_UNIT _stAssets) internal virtual {
        // Credit the deposited assets to the senior tranche
        RoycoKernelState storage $ = _getRoycoKernelStorage();
        $.stOwnedYieldBearingAssets = $.stOwnedYieldBearingAssets + _stAssets;
    }

    /**
     * @notice Process a deposit of junior tranche assets
     * @dev The JT vault has already transferred the assets to the kernel
     * @param _jtAssets The junior tranche assets deposited by the JT LP
     */
    function _jtDepositAssets(TRANCHE_UNIT _jtAssets) internal virtual {
        // Credit the deposited assets to the junior tranche
        RoycoKernelState storage $ = _getRoycoKernelStorage();
        $.jtOwnedYieldBearingAssets = $.jtOwnedYieldBearingAssets + _jtAssets;
    }

    /**
     * @notice Withdraws any specified assets from each tranche and transfer them to the receiver
     * @param _claims The ST and JT assets to withdraw and transfer to the specified receiver
     * @param _receiver The receiver of the tranche asset claims
     */
    function _withdrawAssets(AssetClaims memory _claims, address _receiver) internal virtual {
        // Cache the individual claims
        TRANCHE_UNIT stAssetsToClaim = _claims.stAssets;
        TRANCHE_UNIT jtAssetsToClaim = _claims.jtAssets;

        // Debit the ST and JT assets being withdrawn from each tranche if non-zero
        RoycoKernelState storage $ = _getRoycoKernelStorage();
        if (stAssetsToClaim != ZERO_TRANCHE_UNITS) $.stOwnedYieldBearingAssets = $.stOwnedYieldBearingAssets - stAssetsToClaim;
        if (jtAssetsToClaim != ZERO_TRANCHE_UNITS) $.jtOwnedYieldBearingAssets = $.jtOwnedYieldBearingAssets - jtAssetsToClaim;

        // Credit the yield bearing assets being withdrawn to the receiver
        // Do one batch transfer if they are the same asset, else do two separate transfers
        if (ST_ASSET == JT_ASSET) {
            IERC20(ST_ASSET).safeTransfer(_receiver, toUint256(stAssetsToClaim + jtAssetsToClaim));
        } else {
            if (stAssetsToClaim != ZERO_TRANCHE_UNITS) IERC20(ST_ASSET).safeTransfer(_receiver, toUint256(stAssetsToClaim));
            if (jtAssetsToClaim != ZERO_TRANCHE_UNITS) IERC20(JT_ASSET).safeTransfer(_receiver, toUint256(jtAssetsToClaim));
        }
    }

    /**
     * @notice Computes and applies the self-liquidation bonus for ST redemptions when the liquidation utilization threshold is breached, sourced from JT asset claims
     * @dev The bonus incentivizes ST to self-liquidate by redeeming to delever the market
     * @dev After exiting the market, the bonus affords ST LPs the ability to:
     *      1. Absorb discounts/losses on secondary markets when liquidating the withdrawn exposure
     *      2. Absorb any duration risk associated with liquidating the withdrawn exposure
     * @dev The bonus is computed on the NAV being redeemed by the senior tranche
     * @dev The bonus is capped to ensure utilization does not increase, preventing bank run dynamics where one LP's bonus eats into coverage for remaining LPs
     * @param _state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     * @param _stUserClaims The claims of the redeeming ST user
     * @return stUserClaimsWithBonus The claims of the redeeming ST user after applying the self-liquidation bonus
     * @return stSelfLiquidationBonusNAV Bonus sourced from JT's claims on ST and JT assets
     */
    function _applySeniorTrancheSelfLiquidationBonus(
        SyncedAccountingState memory _state,
        AssetClaims memory _stUserClaims
    )
        internal
        view
        virtual
        returns (AssetClaims memory stUserClaimsWithBonus, NAV_UNIT stSelfLiquidationBonusNAV)
    {
        // If the liquidation utilization threshold has not been breached, there is no ST self-liquidation bonus remitted
        if (_state.utilizationWAD < _state.liquidationUtilizationWAD) return (_stUserClaims, ZERO_NAV_UNITS);

        // Compute the desired ST bonus based on the configured ST self-liquidation bonus rate
        NAV_UNIT desiredBonusNAV = _stUserClaims.nav.mulDiv(_getRoycoKernelStorage().stSelfLiquidationBonusWAD, WAD, Math.Rounding.Floor);

        // Decompose the NAV claims for the Junior Tranche to get the NAV claims for sourcing the bonus
        (,, NAV_UNIT jtClaimOnSTRawNAV,) = _decomposeNAVClaims(_state);

        // Compute the maximum bonus that doesn't increase utilization, preventing bank run dynamics
        NAV_UNIT maxUtilizationNeutralBonusNAV = _computeMaxUtilizationNeutralBonus(_state, _stUserClaims, jtClaimOnSTRawNAV);

        // Clamp the actual bonus by the remaining JT controlled NAV and the maximum utilization-neutral (leverage retaining or delevering) NAV
        stSelfLiquidationBonusNAV = UnitsMathLib.min(UnitsMathLib.min(desiredBonusNAV, _state.jtEffectiveNAV), maxUtilizationNeutralBonusNAV);

        // Preemptively return if there is no remaining bonus capital to remit
        if (stSelfLiquidationBonusNAV == ZERO_NAV_UNITS) return (_stUserClaims, ZERO_NAV_UNITS);

        // Compute the bonus NAV sourced from JT's claims on each tranche's NAV: prioritize ST assets over JT assets for sourcing
        // stSelfLiquidationBonusNAV <= (jtClaimOnSTRawNAV + jtClaimOnSelfRawNAV) since it was bounded by JT effective NAV already
        NAV_UNIT bonusFromJTClaimOnSTRawNAV = UnitsMathLib.min(stSelfLiquidationBonusNAV, jtClaimOnSTRawNAV);
        NAV_UNIT bonusFromJTClaimOnSelfRawNAV = (stSelfLiquidationBonusNAV - bonusFromJTClaimOnSTRawNAV);

        // Apply the derived bonus to the user's asset claims
        stUserClaimsWithBonus.stAssets = _stUserClaims.stAssets + stConvertNAVUnitsToTrancheUnits(bonusFromJTClaimOnSTRawNAV);
        stUserClaimsWithBonus.jtAssets = _stUserClaims.jtAssets + jtConvertNAVUnitsToTrancheUnits(bonusFromJTClaimOnSelfRawNAV);
        stUserClaimsWithBonus.nav = _stUserClaims.nav + stSelfLiquidationBonusNAV;
    }

    /**
     * @notice Computes the maximum self-liquidation bonus that doesn't increase utilization (market's leverage)
     * @dev Prevents bank run dynamics by ensuring one LP's bonus doesn't reduce coverage for remaining LPs
     * @dev Derivation:
     *      Post-redemption utilization must not exceed original utilization:
     *      U = Current utilization = ((ST_RAW_NAV + (JT_RAW_NAV * β)) * COV) / JT_EFFECTIVE_NAV
     *      U' = Post-redemption utilization (including bonus)
     *      Post-redemption utilization:
     *      U' = (((ST_RAW_NAV - ST_REDEMPTION_ST_RAW_NAV - BONUS_ST_RAW_NAV) + ((JT_RAW_NAV - ST_REDEMPTION_JT_RAW_NAV - BONUS_JT_RAW_NAV) * β)) * COV) / (JT_EFFECTIVE_NAV - BONUS_ST_RAW_NAV - BONUS_JT_RAW_NAV)
     *
     *      NOTE: INVARIANT: U' <= U
     *      Resulting invariant after simplification:
     *      COVERED_EXPOSURE = ST_RAW_NAV + JT_RAW_NAV * β
     *      BONUS_ST_RAW_NAV * (COVERED_EXPOSURE - JT_EFFECTIVE_NAV) + BONUS_JT_RAW_NAV * (COVERED_EXPOSURE - β * JT_EFFECTIVE_NAV) <= JT_EFFECTIVE_NAV * (ST_REDEMPTION_ST_RAW_NAV + ST_REDEMPTION_JT_RAW_NAV * β)
     *
     *      Since with β < 1 BONUS_ST_RAW_NAV is cheaper per unit, use the ST_RAW_NAV to source the bonus first:
     *      First Priority (BONUS_JT_RAW_NAV = 0):
     *          BONUS_MAX = (ST_REDEMPTION_ST_RAW_NAV + ST_REDEMPTION_JT_RAW_NAV * β) * JT_EFFECTIVE_NAV / (COVERED_EXPOSURE - JT_EFFECTIVE_NAV)
     *
     *      Second Priority (BONUS_ST_RAW_NAV = JT_CLAIM_ON_ST_RAW_NAV, maxed out):
     *          BONUS_MAX = (ST_REDEMPTION_ST_RAW_NAV + ST_REDEMPTION_JT_RAW_NAV * β + JT_CLAIM_ON_ST_RAW_NAV * (1 - β)) * JT_EFFECTIVE_NAV / (COVERED_EXPOSURE - β * JT_EFFECTIVE_NAV)
     *
     * @param _state The synced accounting state
     * @param _stUserClaims The ST user's base claims before bonus
     * @param _jtClaimOnSTRawNAV JT's cross-tranche claim on ST assets
     * @return maxUtilizationNeutralBonusNAV The maximum bonus NAV that maintains utilization neutrality
     */
    function _computeMaxUtilizationNeutralBonus(
        SyncedAccountingState memory _state,
        AssetClaims memory _stUserClaims,
        NAV_UNIT _jtClaimOnSTRawNAV
    )
        internal
        view
        returns (NAV_UNIT maxUtilizationNeutralBonusNAV)
    {
        // Preemptively return if there is no remaining capital to source a bonus from
        NAV_UNIT jtEffectiveNAV = _state.jtEffectiveNAV;
        if (jtEffectiveNAV == ZERO_NAV_UNITS) return ZERO_NAV_UNITS;

        // Compute the total covered exposure of the market, rounding up to be conservative
        NAV_UNIT totalCoveredExposure = _state.stRawNAV + _state.jtRawNAV.mulDiv(_state.betaWAD, WAD, Math.Rounding.Ceil);

        // Compute the ST LP's NAV claim on real exposure (with beta factored in)
        NAV_UNIT stUserWeightedClaimNAV = stConvertTrancheUnitsToNAVUnits(_stUserClaims.stAssets)
            + jtConvertTrancheUnitsToNAVUnits(_stUserClaims.jtAssets).mulDiv(_state.betaWAD, WAD, Math.Rounding.Floor);
        // If the weighted claim is zero, there is no bonus to apply
        if (stUserWeightedClaimNAV == ZERO_NAV_UNITS) return ZERO_NAV_UNITS;

        // Case 1: Bonus sourced entirely from JT's claim on ST assets
        // maxBonus = stUserWeightedClaimNAV * jtEffectiveNAV / (totalCoveredExposure - jtEffectiveNAV)
        NAV_UNIT stAssetSourcedMaxBonusNAV = stUserWeightedClaimNAV.mulDiv(jtEffectiveNAV, (totalCoveredExposure - jtEffectiveNAV), Math.Rounding.Floor);
        if (stAssetSourcedMaxBonusNAV <= _jtClaimOnSTRawNAV) return stAssetSourcedMaxBonusNAV;

        // Case 2: Bonus sourced from both JT's claim on ST assets and JT's claim on JT assets
        // maxBonus = (stUserWeightedClaimNAV + jtClaimOnSTRawNAV * (1 - β)) * jtEffectiveNAV / (totalCoveredExposure - β * jtEffectiveNAV)
        NAV_UNIT weightedClaimWithSTSourceAdjustmentNAV = stUserWeightedClaimNAV + _jtClaimOnSTRawNAV.mulDiv((WAD - _state.betaWAD), WAD, Math.Rounding.Floor);
        return weightedClaimWithSTSourceAdjustmentNAV.mulDiv(
            jtEffectiveNAV, (totalCoveredExposure - jtEffectiveNAV.mulDiv(_state.betaWAD, WAD, Math.Rounding.Floor)), Math.Rounding.Floor
        );
    }

    // =============================
    // Internal Quoter Cache Functions
    // =============================

    /**
     * @notice Initializes the quoter
     * @dev Should be called at the start of a call
     * @dev Typically used to initialize the cached tranche unit to NAV unit conversion rate
     */
    function _initializeQuoterCache() internal virtual;

    /**
     * @notice Clears the quoter cache
     * @dev Should be called at the end of a call
     * @dev Typically used to clear the cached tranche unit to NAV unit conversion rate
     */
    function _clearQuoterCache() internal virtual;

    // =============================
    // Kernel State Accessor Functions
    // =============================

    /// @inheritdoc IRoycoKernel
    function getState() external view override(IRoycoKernel) returns (RoycoKernelStateView memory) {
        RoycoKernelState storage $ = _getRoycoKernelStorage();
        return RoycoKernelStateView({
            isBlacklistEnabled: $.isBlacklistEnabled,
            protocolFeeRecipient: $.protocolFeeRecipient,
            stSelfLiquidationBonusWAD: $.stSelfLiquidationBonusWAD,
            stOwnedYieldBearingAssets: $.stOwnedYieldBearingAssets,
            jtOwnedYieldBearingAssets: $.jtOwnedYieldBearingAssets
        });
    }

    /**
     * @notice Returns a storage pointer to the RoycoKernelState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer to the kernel's state
     */
    function _getRoycoKernelStorage() internal pure returns (RoycoKernelState storage $) {
        assembly ("memory-safe") {
            $.slot := ROYCO_KERNEL_STORAGE_SLOT
        }
    }
}
