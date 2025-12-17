// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoBase } from "../../base/RoycoBase.sol";
import { IRoycoKernel } from "../../interfaces/kernel/IRoycoKernel.sol";
import { IRoycoVaultTranche } from "../../interfaces/tranche/IRoycoVaultTranche.sol";
import { ZERO_NAV_UNITS } from "../../libraries/Constants.sol";
import { RoycoKernelInitParams, RoycoKernelState, RoycoKernelStorageLib } from "../../libraries/RoycoKernelStorageLib.sol";
import { SyncedAccountingState, TrancheAssetClaims, TrancheType } from "../../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, UnitsMathLib } from "../../libraries/Units.sol";
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

    /**
     * @notice Initializes the base kernel state
     * @dev Initializes any parent contracts and the base kernel state
     * @param _params The initialization parameters for the Royco kernel
     * @param _stAsset The address of the asset that ST is denominated in: constitutes the ST's tranche units (type and precision)
     * @param _jtAsset The address of the asset that JT is denominated in: constitutes the JT's tranche units (type and precision)
     * @param _initialAuthority The initial authority for the base kernel
     */
    function __RoycoKernel_init(RoycoKernelInitParams memory _params, address _stAsset, address _jtAsset, address _initialAuthority) internal onlyInitializing {
        __RoycoBase_init(_initialAuthority);
        __RoycoKernel_init_unchained(_params, _stAsset, _jtAsset);
    }

    /**
     * @notice Initializes the base kernel state
     * @dev Checks the initial market's configuration and initializes the base kernel state
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
    function stMaxAssetsDeposit(address _receiver) external view override(IRoycoKernel) returns (TRANCHE_UNIT) {
        NAV_UNIT stMaxAssetsDepositableNAV = _accountant().maxSTDepositGivenCoverage(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV());
        return UnitsMathLib.min(_maxSTDepositGlobally(_receiver), _stConvertNAVUnitsToTrancheUnits(stMaxAssetsDepositableNAV));
    }

    /// @inheritdoc IRoycoKernel
    function stMaxWithdrawableNAV(address) external view override(IRoycoKernel) returns (NAV_UNIT) {
        // TODO: account for liq constraints
        return _accountant().previewSyncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV()).stEffectiveNAV;
    }

    /// @inheritdoc IRoycoKernel
    function jtMaxAssetsDeposit(address _receiver) external view override(IRoycoKernel) returns (TRANCHE_UNIT) {
        return _jtMaxAssetDepositGlobally(_receiver);
    }

    /// @inheritdoc IRoycoKernel
    function jtMaxWithdrawableNAV(address) external view override(IRoycoKernel) returns (NAV_UNIT) {
        // TODO: account for liq constraints
        return _accountant().maxJTWithdrawalGivenCoverage(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV());
    }

    /// @inheritdoc IRoycoKernel
    function getSTRawNAV() external view override(IRoycoKernel) returns (NAV_UNIT) {
        return _getSeniorTrancheRawNAV();
    }

    /// @inheritdoc IRoycoKernel
    function getJTRawNAV() external view override(IRoycoKernel) returns (NAV_UNIT) {
        return _getJuniorTrancheRawNAV();
    }

    /// @inheritdoc IRoycoKernel
    function getJTAssetClaims() external view override(IRoycoKernel) returns (TrancheAssetClaims memory claims) {
        (, claims,) = previewSyncTrancheAccounting(TrancheType.JUNIOR);
    }

    /// @inheritdoc IRoycoKernel
    function getSTAssetClaims() external view override(IRoycoKernel) returns (TrancheAssetClaims memory claims) {
        (, claims,) = previewSyncTrancheAccounting(TrancheType.SENIOR);
    }

    /// @inheritdoc IRoycoKernel
    function getState() external view override(IRoycoKernel) returns (RoycoKernelState memory) {
        return RoycoKernelStorageLib._getRoycoKernelStorage();
    }

    /// @inheritdoc IRoycoKernel
    function syncTrancheAccounting() external override(IRoycoKernel) restricted returns (SyncedAccountingState memory state) {
        // Execute a pre-op accounting sync via the accountant
        return _preOpSyncTrancheAccounting();
    }

    /// @inheritdoc IRoycoKernel
    function previewSyncTrancheAccounting(TrancheType _trancheType)
        public
        view
        override(IRoycoKernel)
        returns (SyncedAccountingState memory state, TrancheAssetClaims memory claims, uint256 totalTrancheShares)
    {
        // Preview an accounting sync via the accountant
        state = _accountant().previewSyncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV());

        // Decompose effective NAVs into self-backed NAV claims and cross-tranche NAV claims
        (NAV_UNIT stNAVClaimOnSelf, NAV_UNIT stNAVClaimOnJT, NAV_UNIT jtNAVClaimOnSelf, NAV_UNIT jtNAVClaimOnST) = _decomposeNAVClaims(state);

        // Marshal the tranche claims for this tranche given the decomposed claims
        claims = _marshalTrancheAssetClaims(
            _trancheType, state.stEffectiveNAV, state.jtEffectiveNAV, stNAVClaimOnSelf, stNAVClaimOnJT, jtNAVClaimOnSelf, jtNAVClaimOnST
        );

        // Preview the total tranche shares after minting any protocol fee shares post-sync
        RoycoKernelState storage $ = RoycoKernelStorageLib._getRoycoKernelStorage();
        if (_trancheType == TrancheType.SENIOR) {
            (, totalTrancheShares) = IRoycoVaultTranche($.seniorTranche).previewMintProtocolFeeShares(state.stProtocolFeeAccrued, state.stEffectiveNAV);
        } else {
            (, totalTrancheShares) = IRoycoVaultTranche($.juniorTranche).previewMintProtocolFeeShares(state.jtProtocolFeeAccrued, state.jtEffectiveNAV);
        }
    }

    /**
     * @notice Invokes the accountant to do a pre-operation (deposit and withdrawal) NAV sync
     * @dev Should be called on every NAV mutating user operation
     * @param _trancheType An enum indicating which tranche to return claims and total tranche shares for
     * @return state The synced NAV, debt, and fee accounting containing all mark to market accounting data
     * @return claims The claims on ST and JT assets that the specified tranche has denominated in tranche-native units
     * @return totalTrancheShares The total shares outstanding in the specified tranche after minting any protocol fee shares
     */
    function _preOpSyncTrancheAccounting(TrancheType _trancheType)
        internal
        returns (SyncedAccountingState memory state, TrancheAssetClaims memory claims, uint256 totalTrancheShares)
    {
        // Execute the pre-op sync via the accountant
        state = _preOpSyncTrancheAccounting();

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
        claims = _marshalTrancheAssetClaims(
            _trancheType, state.stEffectiveNAV, state.jtEffectiveNAV, stNAVClaimOnSelf, stNAVClaimOnJT, jtNAVClaimOnSelf, jtNAVClaimOnST
        );
    }

    /**
     * @notice Invokes the accountant to do a post-operation (deposit and withdrawal) NAV sync
     * @dev Should be called on every NAV mutating user operation
     * @param _trancheType An enum indicating which tranche to return claims and total tranche shares for
     * @param _op The operation being executed in between the pre and post synchronizations
     * @return state The synced NAV, debt, and fee accounting containing all mark to market accounting data
     * @return claims The claims on ST and JT assets that the specified tranche has denominated in tranche-native units
     */
    function _postOpSyncTrancheAccounting(
        TrancheType _trancheType,
        Operation _op
    )
        internal
        returns (SyncedAccountingState memory state, TrancheAssetClaims memory claims)
    {
        // Execute the pre-op sync via the accountant
        state = _postOpSyncTrancheAccounting(_op);

        // Decompose effective NAVs into self-backed NAV claims and cross-tranche NAV claims
        (NAV_UNIT stNAVClaimOnSelf, NAV_UNIT stNAVClaimOnJT, NAV_UNIT jtNAVClaimOnSelf, NAV_UNIT jtNAVClaimOnST) = _decomposeNAVClaims(state);

        // Marshal the tranche claims for this tranche given the decomposed claims
        claims = _marshalTrancheAssetClaims(
            _trancheType, state.stEffectiveNAV, state.jtEffectiveNAV, stNAVClaimOnSelf, stNAVClaimOnJT, jtNAVClaimOnSelf, jtNAVClaimOnST
        );
    }

    /**
     * @notice Invokes the accountant to do a pre-operation (deposit and withdrawal) NAV sync
     * @dev Should be called on every NAV mutating user operation
     * @return state The synced NAV, debt, and fee accounting containing all mark to market accounting data
     */
    function _preOpSyncTrancheAccounting() internal returns (SyncedAccountingState memory state) {
        // Execute the pre-op sync via the accountant
        return _accountant().preOpSyncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV());
    }

    /**
     * @notice Invokes the accountant to do a post-operation (deposit and withdrawal) NAV sync
     * @dev Should be called on every NAV mutating user operation that doesn't require a coverage check
     * @param _op The operation being executed in between the pre and post synchronizations
     * @return state The synced NAV, debt, and fee accounting containing all mark to market accounting data
     */
    function _postOpSyncTrancheAccounting(Operation _op) internal returns (SyncedAccountingState memory state) {
        // Execute the post-op sync on the accountant
        state = _accountant().postOpSyncTrancheAccounting(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV(), _op);
    }

    /**
     * @notice Invokes the accountant to do a post-operation (deposit and withdrawal) NAV sync and checks the market's coverage requirement is satisfied
     * @dev Should be called on every NAV mutating user operation that requires a coverage check: ST deposit and JT withdrawal
     * @param _op The operation being executed in between the pre and post synchronizations
     * @return state The synced NAV, debt, and fee accounting containing all mark to market accounting data
     */
    function _postOpSyncTrancheAccountingAndEnforceCoverage(Operation _op) internal returns (SyncedAccountingState memory state) {
        // Execute the post-op sync on the accountant
        return _accountant().postOpSyncTrancheAccountingAndEnforceCoverage(_getSeniorTrancheRawNAV(), _getJuniorTrancheRawNAV(), _op);
    }

    /**
     * @notice Decomposes effective NAVs into self-backed NAV claims and cross-tranche NAV claims
     * @param _state The synced NAV, debt, and fee accounting containing all mark to market accounting data
     * @return stNAVClaimOnSelf The portion of ST's effective NAV that must be funded by ST’s raw NAV
     * @return stNAVClaimOnJT The portion of ST's effective NAV that must be funded by JT’s raw NAV
     * @return jtNAVClaimOnSelf The portion of JT's effective NAV that must be funded by JT’s raw NAV
     * @return jtNAVClaimOnST The portion of JT's effective NAV that must be funded by ST’s raw NAV
     */
    function _decomposeNAVClaims(SyncedAccountingState memory _state)
        internal
        pure
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
    function _marshalTrancheAssetClaims(
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
        returns (TrancheAssetClaims memory claims)
    {
        if (_trancheType == TrancheType.SENIOR) {
            if (_stNAVClaimOnSelf != ZERO_NAV_UNITS) claims.stAssets = _stConvertNAVUnitsToTrancheUnits(_stNAVClaimOnSelf);
            if (_stNAVClaimOnJT != ZERO_NAV_UNITS) claims.jtAssets = _jtConvertNAVUnitsToTrancheUnits(_stNAVClaimOnJT);
            claims.effectiveNAV = _stEffectiveNAV;
        } else {
            if (_jtNAVClaimOnST != ZERO_NAV_UNITS) claims.stAssets = _stConvertNAVUnitsToTrancheUnits(_jtNAVClaimOnST);
            if (_jtNAVClaimOnSelf != ZERO_NAV_UNITS) claims.jtAssets = _jtConvertNAVUnitsToTrancheUnits(_jtNAVClaimOnSelf);
            claims.effectiveNAV = _jtEffectiveNAV;
        }
    }

    /// @notice Returns this kernel's accountant casted to the IRoycoAccountant interface
    /// @return The Royco Accountant for this kernel
    function _accountant() internal view returns (IRoycoAccountant) {
        return IRoycoAccountant(RoycoKernelStorageLib._getRoycoKernelStorage().accountant);
    }

    /// @inheritdoc IRoycoKernel
    function stConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _stAssets) external view override(IRoycoKernel) returns (NAV_UNIT) {
        return _stConvertTrancheUnitsToNAVUnits(_stAssets);
    }

    /// @inheritdoc IRoycoKernel
    function jtConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _jtAssets) external view override(IRoycoKernel) returns (NAV_UNIT) {
        return _jtConvertTrancheUnitsToNAVUnits(_jtAssets);
    }

    /// @inheritdoc IRoycoKernel
    function stConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) external view override(IRoycoKernel) returns (TRANCHE_UNIT) {
        return _stConvertNAVUnitsToTrancheUnits(_navAssets);
    }

    /// @inheritdoc IRoycoKernel
    function jtConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) external view override(IRoycoKernel) returns (TRANCHE_UNIT) {
        return _jtConvertNAVUnitsToTrancheUnits(_navAssets);
    }

    /// @notice Returns the raw net asset value of the senior tranche denominated in the NAV units (USD, BTC, etc.) for this kernel
    /// @return The pure net asset value of the senior tranche invested assets
    function _getSeniorTrancheRawNAV() internal view virtual returns (NAV_UNIT);

    /// @notice Returns the raw net asset value of the junior tranche denominated in the NAV units (USD, BTC, etc.) for this kernel
    /// @return The pure net asset value of the junior tranche invested assets
    function _getJuniorTrancheRawNAV() internal view virtual returns (NAV_UNIT);

    /// @dev Internal helper used for internal unit converions and the external getters
    function _stConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _stAssets) internal view virtual returns (NAV_UNIT);

    /// @dev Internal helper used for internal unit converions and the external getters
    function _jtConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _jtAssets) internal view virtual returns (NAV_UNIT);

    /// @dev Internal helper used for internal unit converions and the external getters
    function _stConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) internal view virtual returns (TRANCHE_UNIT);

    /// @dev Internal helper used for internal unit converions and the external getters
    function _jtConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) internal view virtual returns (TRANCHE_UNIT);

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the senior tranche globally
     * @dev Implementation should consider protocol-wide limits and liquidity constraints
     * @param _receiver The receiver of the shares for the assets being deposited (used to enforce white/black lists)
     */
    function _maxSTDepositGlobally(address _receiver) internal view virtual returns (TRANCHE_UNIT);

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the junior tranche globally
     * @dev Implementation should consider protocol-wide limits and liquidity constraints
     * @param _receiver The receiver of the shares for the assets being deposited (used to enforce white/black lists)
     */
    function _jtMaxAssetDepositGlobally(address _receiver) internal view virtual returns (TRANCHE_UNIT);

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn from the senior tranche globally
     * @dev Implementation should consider protocol-wide limits and liquidity constraints
     * @param _owner The owner of the assets being withdrawn (used to enforce white/black lists)
     */
    function _maxSTWithdrawalGlobally(address _owner) internal view virtual returns (TRANCHE_UNIT);

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn from the junior tranche globally
     * @dev Implementation should consider protocol-wide limits and liquidity constraints
     * @param _owner The owner of the assets being withdrawn (used to enforce white/black lists)
     */
    function _maxJTWithdrawalGlobally(address _owner) internal view virtual returns (TRANCHE_UNIT);

    /**
     * @notice Previews the amount of ST assets that would be redeemed for a given amount of ST assets
     * @param _stAssets The ST assets denominated in its tranche units to redeem
     * @return redeemedSTAssets The amount of ST assets that would be redeemed for the given amount of ST assets
     */
    function _previewWithdrawSTAssets(TRANCHE_UNIT _stAssets) internal view virtual returns (TRANCHE_UNIT redeemedSTAssets);

    /**
     * @notice Withdraws ST assets to the specified receiver
     * @param _stAssets The ST assets denominated in its tranche units to withdraw to the receiver
     * @param _receiver The receiver of the ST assets
     */
    function _withdrawSTAssets(TRANCHE_UNIT _stAssets, address _receiver) internal virtual;

    /**
     * @notice Previews the amount of JT assets that would be redeemed for a given amount of JT assets
     * @param _jtAssets The JT assets denominated in its tranche units to redeem
     * @return redeemedJTAssets The amount of JT assets that would be redeemed for the given amount of JT assets
     */
    function _previewWithdrawJTAssets(TRANCHE_UNIT _jtAssets) internal view virtual returns (TRANCHE_UNIT redeemedJTAssets);

    /**
     * @notice Withdraws JT assets to the specified receiver
     * @param _jtAssets The JT assets denominated in its tranche units to withdraw to the receiver
     * @param _receiver The receiver of the JT assets
     */
    function _withdrawJTAssets(TRANCHE_UNIT _jtAssets, address _receiver) internal virtual;
}
