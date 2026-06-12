// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoBase } from "../base/RoycoBase.sol";
import { IRoycoAccountant } from "../interfaces/IRoycoAccountant.sol";
import { IRoycoDawnKernel } from "../interfaces/IRoycoDawnKernel.sol";
import { IYDM } from "../interfaces/IYDM.sol";
import { AccountingLib } from "../libraries/AccountingLib.sol";
import { MAX_COVERAGE_WAD, MAX_PROTOCOL_FEE_WAD, MIN_COVERAGE_WAD, WAD, ZERO_NAV_UNITS } from "../libraries/Constants.sol";
import {
    AccountingCheckpoint,
    MarketState,
    MarketStateTransitionParams,
    NAV_UNIT,
    Operation,
    PnLWaterfallParams,
    SyncedAccountingState
} from "../libraries/Types.sol";
import { UnitsMathLib, toNAVUnits, toUint256 } from "../libraries/Units.sol";
import { Math, UtilsLib } from "../libraries/UtilsLib.sol";

/**
 * @title RoycoAccountant
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Performs and tracks the core accounting operations for a Royco market
 * @notice Responsible for marking tranche NAVs to market, tracking the JT coverage impermanent loss, distributing yield via the YDM, and computing protocol fees
 * @notice Responsible for tracking the operational and coverage state of the Royco market
 */
contract RoycoAccountant is IRoycoAccountant, RoycoBase {
    using Math for uint256;
    using UnitsMathLib for NAV_UNIT;

    /// @dev Storage slot for RoycoAccountantState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoAccountantState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROYCO_ACCOUNTANT_STORAGE_SLOT = 0xc8240830e1172c6f1489139d8edb11776c3d3b2f893e3f4ce0fb541305a63a00;

    /// @inheritdoc IRoycoAccountant
    address public immutable override(IRoycoAccountant) KERNEL;

    /// @dev Permissions the function to only be callable by the market's kernel
    /// @dev Should be placed on all state mutating NAV synchronization functions
    modifier onlyRoycoKernel() {
        require(msg.sender == KERNEL, ONLY_ROYCO_KERNEL());
        _;
    }

    /// @dev Synchronizes the market's accounting to reconcile unrealized PNL at the start of the call
    modifier withSyncedAccounting() {
        IRoycoDawnKernel(KERNEL).syncTrancheAccounting();
        _;
    }

    /// @dev Enforces the NAV conservation property of the checkpoint passed into the accountant's synchronization and view functions
    /// @param _checkpoint The candidate accounting checkpoint to validate before consumption
    modifier enforceNAVConservation(AccountingCheckpoint memory _checkpoint) {
        AccountingLib.enforceNAVConservation(_checkpoint);
        _;
    }

    // =============================
    // Construction and Initialization Functions
    // =============================

    /// @dev Constructs the accountant with the specified kernel
    /// @param _kernel - The kernel that this accountant maintains mark-to-market NAV, JT coverage impermanent loss, and fee accounting for
    constructor(address _kernel) {
        // Ensure the specified kernel is not null and immutably set it
        require(_kernel != address(0), NULL_ADDRESS());
        KERNEL = _kernel;
    }

    /**
     * @notice Initializes the Royco accountant state
     * @param _params The initialization parameters for the Royco accountant
     * @param _initialAuthority The initial authority for the Royco accountant
     */
    function initialize(RoycoAccountantInitParams calldata _params, address _initialAuthority) external initializer {
        // Initialize the base state of the accountant
        __RoycoBase_init(_initialAuthority);

        // Ensure that the protocol fee percentage is valid
        require(
            _params.stProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD && _params.jtProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD
                && _params.yieldShareProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD,
            MAX_PROTOCOL_FEE_EXCEEDED()
        );
        // Validate the market's initial coverage configuration
        _validateCoverageConfig(_params.coverageWAD, _params.betaWAD, _params.liquidationUtilizationWAD);
        // Initialize the YDM for this market
        _initializeYDM(_params.ydm, _params.ydmInitializationData);

        // Initialize the state of the accountant
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        $.fixedTermDurationSeconds = _params.fixedTermDurationSeconds;
        emit FixedTermDurationUpdated(_params.fixedTermDurationSeconds);
        $.stProtocolFeeWAD = _params.stProtocolFeeWAD;
        emit SeniorTrancheProtocolFeeUpdated(_params.stProtocolFeeWAD);
        $.jtProtocolFeeWAD = _params.jtProtocolFeeWAD;
        emit JuniorTrancheProtocolFeeUpdated(_params.jtProtocolFeeWAD);
        $.yieldShareProtocolFeeWAD = _params.yieldShareProtocolFeeWAD;
        emit YieldShareProtocolFeeUpdated(_params.yieldShareProtocolFeeWAD);
        $.coverageWAD = _params.coverageWAD;
        emit CoverageUpdated(_params.coverageWAD);
        $.betaWAD = _params.betaWAD;
        emit BetaUpdated(_params.betaWAD);
        $.liquidationUtilizationWAD = _params.liquidationUtilizationWAD;
        emit LiquidationUtilizationUpdated(_params.liquidationUtilizationWAD);
        $.ydm = _params.ydm;
        emit YDMUpdated(_params.ydm);
        $.stNAVDustTolerance = _params.stNAVDustTolerance;
        emit SeniorTrancheDustToleranceUpdated(_params.stNAVDustTolerance);
        $.jtNAVDustTolerance = _params.jtNAVDustTolerance;
        emit JuniorTrancheDustToleranceUpdated(_params.jtNAVDustTolerance);
        $.effectiveNAVDustTolerance = _params.stNAVDustTolerance + _params.jtNAVDustTolerance;
    }

    // =============================
    // NAV Synchronization Functions
    // =============================

    /// @inheritdoc IRoycoAccountant
    function preOpSyncTrancheAccounting(
        AccountingCheckpoint memory _checkpoint,
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV
    )
        public
        override(IRoycoAccountant)
        onlyRoycoKernel
        enforceNAVConservation(_checkpoint)
        returns (SyncedAccountingState memory state)
    {
        // Get the storage pointer to the accountant state
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();

        // Preview synchronization of the tranche NAVs and the JT coverage impermanent loss
        MarketState initialMarketState;
        bool yieldDistributed;
        NAV_UNIT jtCoverageImpermanentLossErased;
        (state, initialMarketState, yieldDistributed, jtCoverageImpermanentLossErased) =
            _previewSyncTrancheAccounting(_checkpoint, _stRawNAV, _jtRawNAV, _accrueJTYieldShare());

        // ST yield was split between ST and JT
        if (yieldDistributed) {
            // Reset the accumulator and update the last yield distribution timestamp
            delete $.twJTYieldShareAccruedWAD;
            $.lastDistributionTimestamp = uint32(block.timestamp);
        }

        // Checkpoint the resulting market state, mark-to-market NAVs, and the JT coverage impermanent loss
        $.lastMarketState = state.marketState;
        $.lastSTRawNAV = _stRawNAV;
        $.lastJTRawNAV = _jtRawNAV;
        $.lastSTEffectiveNAV = state.stEffectiveNAV;
        $.lastJTEffectiveNAV = state.jtEffectiveNAV;
        $.lastJTCoverageImpermanentLoss = state.jtCoverageImpermanentLoss;

        // If the market transitioned from a perpetual to a fixed-term state, set the end timestamp of the fixed-term
        if (initialMarketState == MarketState.PERPETUAL && state.marketState == MarketState.FIXED_TERM) {
            $.fixedTermEndTimestamp = state.fixedTermEndTimestamp;
            emit FixedTermCommenced(state.fixedTermEndTimestamp);
        } else if (initialMarketState == MarketState.FIXED_TERM && state.marketState == MarketState.PERPETUAL) {
            emit FixedTermEnded();
        }

        // If the JT Coverage IL was erased, signal the resetting
        if (jtCoverageImpermanentLossErased != ZERO_NAV_UNITS) {
            emit JTCoverageImpermanentLossReset(jtCoverageImpermanentLossErased);
        }

        emit TrancheAccountingSynced(state);
    }

    /// @inheritdoc IRoycoAccountant
    function previewSyncTrancheAccounting(
        AccountingCheckpoint memory _checkpoint,
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV
    )
        public
        view
        override(IRoycoAccountant)
        enforceNAVConservation(_checkpoint)
        returns (SyncedAccountingState memory state)
    {
        (state,,,) = _previewSyncTrancheAccounting(_checkpoint, _stRawNAV, _jtRawNAV, _previewJTYieldShareAccrual());
    }

    /// @inheritdoc IRoycoAccountant
    function postOpSyncTrancheAccounting(
        Operation _op,
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        NAV_UNIT _stSelfLiquidationBonusNAV
    )
        public
        override(IRoycoAccountant)
        onlyRoycoKernel
        returns (SyncedAccountingState memory state)
    {
        // Get the storage pointer to the accountant state
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();

        // Compute the deltas in the raw NAVs of each tranche
        int256 deltaSTRawNAV = UnitsMathLib.computeNAVDelta(_stRawNAV, $.lastSTRawNAV);
        int256 deltaJTRawNAV = UnitsMathLib.computeNAVDelta(_jtRawNAV, $.lastJTRawNAV);

        // Cache the last checkpointed NAVs and the JT coverage impermanent loss
        NAV_UNIT stEffectiveNAV = $.lastSTEffectiveNAV;
        NAV_UNIT jtEffectiveNAV = $.lastJTEffectiveNAV;
        NAV_UNIT jtCoverageImpermanentLoss = $.lastJTCoverageImpermanentLoss;

        // Apply the effects of the operation that was executed
        if (_op == Operation.ST_DEPOSIT) {
            require(deltaSTRawNAV > 0 && deltaJTRawNAV == 0 && _stSelfLiquidationBonusNAV == ZERO_NAV_UNITS, INVALID_POST_OP_STATE(_op));
            // New ST deposits are treated as an addition to the future ST exposure
            stEffectiveNAV = stEffectiveNAV + toNAVUnits(deltaSTRawNAV);
        } else if (_op == Operation.JT_DEPOSIT) {
            require(deltaJTRawNAV > 0 && deltaSTRawNAV == 0 && _stSelfLiquidationBonusNAV == ZERO_NAV_UNITS, INVALID_POST_OP_STATE(_op));
            // New JT deposits are treated as an addition to the future loss-absorption buffer
            jtEffectiveNAV = jtEffectiveNAV + toNAVUnits(deltaJTRawNAV);
        } else {
            require(deltaSTRawNAV <= 0 && deltaJTRawNAV <= 0, INVALID_POST_OP_STATE(_op));
            // Get the total value redeemed
            NAV_UNIT totalRedemptionNAV = (toNAVUnits(-deltaSTRawNAV) + toNAVUnits(-deltaJTRawNAV));
            if (_op == Operation.ST_REDEEM) {
                require(totalRedemptionNAV > ZERO_NAV_UNITS, INVALID_POST_OP_STATE(_op));
                // Reduce JT effective NAV by the the bonus provided from its assets
                jtEffectiveNAV = jtEffectiveNAV - _stSelfLiquidationBonusNAV;
                // Reduce ST effective NAV by the total redemptions without the bonus provided from JT effective NAV
                stEffectiveNAV = stEffectiveNAV - (totalRedemptionNAV - _stSelfLiquidationBonusNAV);
            } else if (_op == Operation.JT_REDEEM) {
                // JT cannot get a bonus from its own NAV
                require(totalRedemptionNAV > ZERO_NAV_UNITS && _stSelfLiquidationBonusNAV == ZERO_NAV_UNITS, INVALID_POST_OP_STATE(_op));
                // The actual amount withdrawn from JT effective NAV could be from both tranches (its own share of its NAV, ST yield share, IL repayments, etc.)
                jtEffectiveNAV = jtEffectiveNAV - totalRedemptionNAV;
                // The withdrawing junior LP has realized its proportional share of past JT losses from coverage applied and its associated recovery optionality, rounding in favor of senior
                if (jtCoverageImpermanentLoss != ZERO_NAV_UNITS) {
                    jtCoverageImpermanentLoss = jtCoverageImpermanentLoss.mulDiv(jtEffectiveNAV, $.lastJTEffectiveNAV, Math.Rounding.Floor);
                    $.lastJTCoverageImpermanentLoss = jtCoverageImpermanentLoss;
                }
            }
        }

        // Enforce the NAV conservation invariant
        AccountingLib.enforceNAVConservation(_stRawNAV, _jtRawNAV, stEffectiveNAV, jtEffectiveNAV);

        // Checkpoint the mark-to-market NAVs
        $.lastSTRawNAV = _stRawNAV;
        $.lastJTRawNAV = _jtRawNAV;
        $.lastSTEffectiveNAV = stEffectiveNAV;
        $.lastJTEffectiveNAV = jtEffectiveNAV;

        // Marshal the post-sync state and return to the caller
        uint256 betaWAD = $.betaWAD;
        uint256 coverageWAD = $.coverageWAD;
        state = SyncedAccountingState({
            // The market state is guaranteed to be identical to the persisted
            marketState: $.lastMarketState,
            stRawNAV: _stRawNAV,
            jtRawNAV: _jtRawNAV,
            stEffectiveNAV: stEffectiveNAV,
            jtEffectiveNAV: jtEffectiveNAV,
            jtCoverageImpermanentLoss: jtCoverageImpermanentLoss,
            // No protocol fees taken on deposit or withdrawal
            stProtocolFeeAccrued: ZERO_NAV_UNITS,
            jtProtocolFeeAccrued: ZERO_NAV_UNITS,
            utilizationWAD: UtilsLib.computeUtilization(_stRawNAV, _jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV),
            fixedTermEndTimestamp: $.fixedTermEndTimestamp,
            coverageWAD: coverageWAD,
            betaWAD: betaWAD,
            liquidationUtilizationWAD: $.liquidationUtilizationWAD
        });
    }

    /// @inheritdoc IRoycoAccountant
    function postOpSyncTrancheAccountingAndEnforceCoverage(
        Operation _op,
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV
    )
        external
        override(IRoycoAccountant)
        returns (SyncedAccountingState memory state)
    {
        // Execute a post-op NAV synchronization
        // This is called during a ST Deposit or JT Withdrawal, so the self-liquidation bonus is not applicable
        state = postOpSyncTrancheAccounting(_op, _stRawNAV, _jtRawNAV, ZERO_NAV_UNITS);
        // Enforce the market's coverage requirement
        require(_isCoverageRequirementSatisfied(state.utilizationWAD), COVERAGE_REQUIREMENT_UNSATISFIED());
    }

    // =============================
    // Coverage Checking Functions
    // =============================

    /// @inheritdoc IRoycoAccountant
    function isCoverageRequirementSatisfied() public view override(IRoycoAccountant) returns (bool) {
        // Get the storage pointer to the accountant state
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        // Compute the utilization and return whether or not the senior tranche is properly collateralized based on persisted NAVs
        uint256 utilization = UtilsLib.computeUtilization($.lastSTRawNAV, $.lastJTRawNAV, $.betaWAD, $.coverageWAD, $.lastJTEffectiveNAV);
        return _isCoverageRequirementSatisfied(utilization);
    }

    /**
     * @inheritdoc IRoycoAccountant
     * @dev Coverage Invariant: JT_EFFECTIVE_NAV >= (ST_RAW_NAV + (JT_RAW_NAV * β)) * COV
     * @dev Max assets depositable into ST, x: JT_EFFECTIVE_NAV = ((ST_RAW_NAV + x) + (JT_RAW_NAV * β)) * COV
     *      Isolate x: x = (JT_EFFECTIVE_NAV / COV) - (JT_RAW_NAV * β) - ST_RAW_NAV
     */
    function maxSTDepositGivenCoverage(
        AccountingCheckpoint memory _checkpoint,
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV
    )
        external
        view
        override(IRoycoAccountant)
        enforceNAVConservation(_checkpoint)
        returns (NAV_UNIT maxSTDeposit)
    {
        // Get the storage pointer to the accountant state
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        // Preview a NAV sync to get the market's current state
        (SyncedAccountingState memory state,,,) = _previewSyncTrancheAccounting(_checkpoint, _stRawNAV, _jtRawNAV, _previewJTYieldShareAccrual());
        // Solve for x, rounding in favor of senior protection
        // Compute the total covered assets by the junior tranche loss absorption buffer
        NAV_UNIT totalCoveredAssets = state.jtEffectiveNAV.mulDiv(WAD, $.coverageWAD, Math.Rounding.Floor);
        // Compute the assets required to cover current junior tranche exposure
        // Also account for JT's dust tolerance to preclude reverts due to rounding after ST deposit (if both are exposed to the same underlying rounding)
        NAV_UNIT jtCoverageRequired = _jtRawNAV.mulDiv($.betaWAD, WAD, Math.Rounding.Ceil) + $.jtNAVDustTolerance;
        // Compute the amount of assets that can be deposited into senior while retaining full coverage
        // Also account for ST's dust tolerance to preclude reverts due to rounding after ST deposit
        maxSTDeposit = totalCoveredAssets.saturatingSub(jtCoverageRequired).saturatingSub(_stRawNAV).saturatingSub($.stNAVDustTolerance);
    }

    /**
     * @inheritdoc IRoycoAccountant
     * @dev Coverage Invariant: JT_EFFECTIVE_NAV >= (ST_RAW_NAV + (JT_RAW_NAV * β)) * COV
     * @dev When assets are claimed from the JT, they are always liquidated in the same proportion as the tranche's total claims on the ST and JT assets
     * @dev Let S be the JT's total claims on ST assets and J be the JT's total claims on JT assets, in NAV Units. The total claims on the ST and JT assets are S + J NAV Units
     * @dev Let K_S be S / (S + J) and K_J be J / (S + J)
     * @dev Therefore, if a total NAV of y is claimed from the JT, K_S * y will be claimed from the ST_RAW_NAV and K_J * y will be claimed from the JT_RAW_NAV
     * @dev Max assets withdrawable from JT, y: (JT_EFFECTIVE_NAV - y) = ((ST_RAW_NAV - K_S * y) + ((JT_RAW_NAV - K_J * y) * β)) * COV
     *      Isolate y: y = (JT_EFFECTIVE_NAV - (COV * (ST_RAW_NAV + (JT_RAW_NAV * β)))) / (1 - (COV * (K_S + β * K_J)))
     */
    function maxJTWithdrawalGivenCoverage(
        AccountingCheckpoint memory _checkpoint,
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        NAV_UNIT _jtClaimOnStUnits,
        NAV_UNIT _jtClaimOnJtUnits
    )
        external
        view
        override(IRoycoAccountant)
        enforceNAVConservation(_checkpoint)
        returns (NAV_UNIT totalNAVClaimable, NAV_UNIT stClaimable, NAV_UNIT jtClaimable)
    {
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();

        // Get the surplus JT assets in NAV units
        // Preview a NAV sync to get the market's current state
        (SyncedAccountingState memory state,,,) = _previewSyncTrancheAccounting(_checkpoint, _stRawNAV, _jtRawNAV, _previewJTYieldShareAccrual());
        uint256 betaWAD = $.betaWAD;
        // Compute the total covered exposure of the underlying investment, rounding in favor of senior protection
        NAV_UNIT totalCoveredExposure = _stRawNAV + _jtRawNAV.mulDiv(betaWAD, WAD, Math.Rounding.Ceil);
        // Compute the minimum junior tranche assets required to cover the exposure as per the market's coverage requirement
        NAV_UNIT requiredJTAssets = totalCoveredExposure.mulDiv($.coverageWAD, WAD, Math.Rounding.Ceil);
        // Compute the surplus coverage currently provided by the junior tranche based on its currently remaining loss-absorption buffer
        // Also account for the effective dust tolerance required to preclude reverts due to rounding after JT redemptions
        NAV_UNIT surplusJTAssets = state.jtEffectiveNAV.saturatingSub(requiredJTAssets)
            .saturatingSub($.stNAVDustTolerance + $.jtNAVDustTolerance.mulDiv(betaWAD, WAD, Math.Rounding.Ceil));
        if (surplusJTAssets == ZERO_NAV_UNITS) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS);

        // Compute the total JT claim on NAV and preemptively return if zero
        NAV_UNIT totalJTClaims = _jtClaimOnStUnits + _jtClaimOnJtUnits;
        if (totalJTClaims == ZERO_NAV_UNITS) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS);
        // Calculate K_S
        uint256 kS_WAD = toUint256(_jtClaimOnStUnits.mulDiv(WAD, totalJTClaims, Math.Rounding.Floor));
        // Calculate K_J
        uint256 kJ_WAD = toUint256(_jtClaimOnJtUnits.mulDiv(WAD, totalJTClaims, Math.Rounding.Floor));
        // Compute how much coverage the system retains per 1 nav unit of JT assets withdrawn scaled to WAD precision
        uint256 coverageRetentionWAD =
            (WAD - uint256($.coverageWAD).mulDiv(kS_WAD + uint256(betaWAD).mulDiv(kJ_WAD, WAD, Math.Rounding.Floor), WAD, Math.Rounding.Floor));
        // Calculate how much of the surplus can be withdrawn while satisfying the coverage requirement
        totalNAVClaimable = surplusJTAssets.mulDiv(WAD, coverageRetentionWAD, Math.Rounding.Floor);
        if (totalNAVClaimable == ZERO_NAV_UNITS) return (ZERO_NAV_UNITS, ZERO_NAV_UNITS, ZERO_NAV_UNITS);

        // Split it into individual tranche's claims
        stClaimable = totalNAVClaimable.mulDiv(kS_WAD, WAD, Math.Rounding.Floor);
        jtClaimable = totalNAVClaimable.mulDiv(kJ_WAD, WAD, Math.Rounding.Floor);
    }

    /**
     * @notice Returns whether the coverage requirement is satisfied given the utilization
     * @dev Junior capital must be sufficient to absorb losses to the senior exposure up to the coverage ratio
     * @dev Informally: junior loss absorption buffer >= total covered exposure
     * @dev Formally: JT_EFFECTIVE_NAV >= (ST_RAW_NAV + (JT_RAW_NAV * β)) * COV
     *      JT_EFFECTIVE_NAV is JT's current loss absorption buffer after applying all prior JT yield accrual and coverage adjustments
     *      ST_RAW_NAV and JT_RAW_NAV are the mark-to-market NAVs of the tranches
     *      β is the JT's sensitivity to the same downside stress that affects ST (eg. 0 if JT is in RFR and 1 if JT and ST are in the same opportunity)
     * @dev If we rearrange the coverage requirement, we get:
     *      1 >= ((ST_RAW_NAV + (JT_RAW_NAV * β)) * COV) / JT_EFFECTIVE_NAV
     *      Notice that the RHS is identical to how we define utilization
     *      Hence, the coverage requirement can be written as 1 >= Utilization, or equivalently, Utilization <= 1
     * @param _utilizationWAD The utilization of the market, scaled to WAD precision
     * @return satisfied A boolean indicating whether the coverage requirement is satisfied
     */
    function _isCoverageRequirementSatisfied(uint256 _utilizationWAD) internal pure returns (bool) {
        return (_utilizationWAD <= WAD);
    }

    // =============================
    // Internal NAV Synchronization and Yield Share Accrual Functions
    // =============================

    /**
     * @notice Synchronizes all tranche NAVs and the JT coverage impermanent loss based on unrealized PNLs of the underlying investment(s)
     * @param _stRawNAV The senior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the pure value of its invested assets
     * @param _twJTYieldShareAccruedWAD The currently accrued time-weighted JT yield share YDM output since the last distribution, scaled to WAD precision
     * @return state A struct containing all mark-to-market NAV, JT coverage impermanent loss, and fee data after executing the sync
     * @return initialMarketState The initial state the market was in before the synchronization
     * @return yieldDistributed A boolean indicating whether ST yield was split between ST and JT
     * @return jtCoverageImpermanentLossErased The amount of JT coverage loss erased (reset to 0)
     */
    function _previewSyncTrancheAccounting(
        AccountingCheckpoint memory _checkpoint,
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        uint192 _twJTYieldShareAccruedWAD
    )
        internal
        view
        returns (SyncedAccountingState memory state, MarketState initialMarketState, bool yieldDistributed, NAV_UNIT jtCoverageImpermanentLossErased)
    {
        // Get the storage pointer to the accountant state
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();

        // The market state that this sync transitions from
        initialMarketState = $.lastMarketState;

        // Resolve the YDM inputs consumed by the waterfall's yield split once per sync
        // NOTE: They depend only on last-sync state, so they are constant for any raw NAV inputs measured against this checkpoint
        uint256 elapsedSinceLastDistribution = block.timestamp - $.lastDistributionTimestamp;
        // The instantaneous share is only consumed when the last distribution happened in the same block, so it is fetched lazily
        uint256 instantaneousJTYieldShareWAD = elapsedSinceLastDistribution == 0
            ? IYDM($.ydm).previewJTYieldShare(initialMarketState, $.lastSTRawNAV, $.lastJTRawNAV, $.betaWAD, $.coverageWAD, $.lastJTEffectiveNAV)
            : 0;
        // The JT yield share can never exceed 100% of senior appreciation: a larger share means the YDM is buggy
        require(instantaneousJTYieldShareWAD <= WAD, INVALID_YDM_OUTPUT());

        // Cache the effective NAV dust tolerance: the worst-case dust is bounded by the sum of the raw NAV dust tolerances
        NAV_UNIT effectiveNAVDustTolerance = $.effectiveNAVDustTolerance;

        // Execute the PnL attribution and settlement waterfall
        AccountingCheckpoint memory postPnLWaterfallCheckpoint;
        NAV_UNIT stProtocolFeeAccrued;
        NAV_UNIT jtProtocolFeeAccrued;
        (postPnLWaterfallCheckpoint, stProtocolFeeAccrued, jtProtocolFeeAccrued, yieldDistributed) = AccountingLib.applyProfitAndLossWaterfall(
            _stRawNAV,
            _jtRawNAV,
            PnLWaterfallParams({
                checkpoint: _checkpoint,
                twJTYieldShareAccruedWAD: _twJTYieldShareAccruedWAD,
                instantaneousJTYieldShareWAD: instantaneousJTYieldShareWAD,
                elapsedSinceLastDistribution: elapsedSinceLastDistribution,
                stProtocolFeeWAD: $.stProtocolFeeWAD,
                jtProtocolFeeWAD: $.jtProtocolFeeWAD,
                yieldShareProtocolFeeWAD: $.yieldShareProtocolFeeWAD,
                effectiveNAVDustTolerance: effectiveNAVDustTolerance
            })
        );

        // Apply the market state transition resulting from this sync and marshal the post-sync state
        (state, jtCoverageImpermanentLossErased) = AccountingLib.applyStateTransition(
            initialMarketState,
            MarketStateTransitionParams({
                postPnLWaterfallCheckpoint: postPnLWaterfallCheckpoint,
                stProtocolFeeAccrued: stProtocolFeeAccrued,
                jtProtocolFeeAccrued: jtProtocolFeeAccrued,
                betaWAD: $.betaWAD,
                coverageWAD: $.coverageWAD,
                effectiveNAVDustTolerance: effectiveNAVDustTolerance,
                fixedTermDurationSeconds: $.fixedTermDurationSeconds,
                fixedTermEndTimestamp: $.fixedTermEndTimestamp,
                liquidationUtilizationWAD: $.liquidationUtilizationWAD,
                currentTimestamp: block.timestamp
            })
        );
    }

    /**
     * @notice Accrues the JT yield share since the last yield distribution
     * @dev Gets the instantaneous JT yield share and weights it by the time elapsed since the last accrual
     * @return twJTYieldShareAccruedWAD The updated time-weighted JT yield share since the last yield distribution
     */
    function _accrueJTYieldShare() internal returns (uint192 twJTYieldShareAccruedWAD) {
        // Get the storage pointer to the accountant state
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();

        // Get the last update timestamp
        uint256 lastUpdate = $.lastAccrualTimestamp;
        if (lastUpdate == 0) {
            // Initialize the checkpoint timestamps if this is the first accrual
            $.lastAccrualTimestamp = uint32(block.timestamp);
            $.lastDistributionTimestamp = uint32(block.timestamp);
            return 0;
        }

        // Compute the elapsed time since the last update
        uint256 elapsed = block.timestamp - lastUpdate;
        // Preemptively return if last accrual was in the same block
        if (elapsed == 0) return $.twJTYieldShareAccruedWAD;

        // Get the instantaneous JT yield share, scaled to WAD precision
        uint256 jtYieldShareWAD = IYDM($.ydm).jtYieldShare($.lastMarketState, $.lastSTRawNAV, $.lastJTRawNAV, $.betaWAD, $.coverageWAD, $.lastJTEffectiveNAV);
        // The JT yield share can never exceed 100% of senior appreciation: a larger share means the YDM is buggy
        require(jtYieldShareWAD <= WAD, INVALID_YDM_OUTPUT());

        // Accrue the time-weighted yield share accrued to JT since the last tranche interaction
        twJTYieldShareAccruedWAD = $.twJTYieldShareAccruedWAD += uint192(jtYieldShareWAD * elapsed);
        $.lastAccrualTimestamp = uint32(block.timestamp);

        emit JuniorTrancheYieldShareAccrued(jtYieldShareWAD, twJTYieldShareAccruedWAD, uint32(block.timestamp));
    }

    /**
     * @notice Computes and returns the currently accrued JT yield share since the last yield distribution
     * @dev Gets the instantaneous JT yield share and weights it by the time elapsed since the last accrual
     * @return The updated time-weighted JT yield share since the last yield distribution
     */
    function _previewJTYieldShareAccrual() internal view returns (uint192) {
        // Get the storage pointer to the accountant state
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();

        // Get the last update timestamp
        uint256 lastUpdate = $.lastAccrualTimestamp;
        if (lastUpdate == 0) return 0;

        // Compute the elapsed time since the last update
        uint256 elapsed = block.timestamp - lastUpdate;
        // Preemptively return if last accrual was in the same block
        if (elapsed == 0) return $.twJTYieldShareAccruedWAD;

        // Get the instantaneous JT yield share, scaled to WAD precision
        uint256 jtYieldShareWAD =
            IYDM($.ydm).previewJTYieldShare($.lastMarketState, $.lastSTRawNAV, $.lastJTRawNAV, $.betaWAD, $.coverageWAD, $.lastJTEffectiveNAV);
        // The JT yield share can never exceed 100% of senior appreciation: a larger share means the YDM is buggy
        require(jtYieldShareWAD <= WAD, INVALID_YDM_OUTPUT());

        // Apply the accrual of JT yield share to the accumulator, weighted by the time elapsed
        return ($.twJTYieldShareAccruedWAD + uint192(jtYieldShareWAD * elapsed));
    }

    // =============================
    // Administrative Functions
    // =============================

    /// @inheritdoc IRoycoAccountant
    function setYDM(address _ydm, bytes calldata _ydmInitializationData) external override(IRoycoAccountant) restricted {
        // Best-effort sync to settle unrealized PNL under the outgoing YDM
        // NOTE: A reverting sync is tolerated since this setter is the only recovery path from a sync-bricking YDM
        KERNEL.call(abi.encodeCall(IRoycoDawnKernel.syncTrancheAccounting, ()));
        // Initialize and set the new YDM for this market
        _initializeYDM(_ydm, _ydmInitializationData);
        _getRoycoAccountantStorage().ydm = _ydm;
        emit YDMUpdated(_ydm);
    }

    /// @inheritdoc IRoycoAccountant
    function setSeniorTrancheProtocolFee(uint64 _stProtocolFeeWAD) external override(IRoycoAccountant) restricted withSyncedAccounting {
        // Ensure that the protocol fee percentage is valid
        require(_stProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD, MAX_PROTOCOL_FEE_EXCEEDED());
        _getRoycoAccountantStorage().stProtocolFeeWAD = _stProtocolFeeWAD;
        emit SeniorTrancheProtocolFeeUpdated(_stProtocolFeeWAD);
    }

    /// @inheritdoc IRoycoAccountant
    function setJuniorTrancheProtocolFee(uint64 _jtProtocolFeeWAD) external override(IRoycoAccountant) restricted withSyncedAccounting {
        // Ensure that the protocol fee percentage is valid
        require(_jtProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD, MAX_PROTOCOL_FEE_EXCEEDED());
        _getRoycoAccountantStorage().jtProtocolFeeWAD = _jtProtocolFeeWAD;
        emit JuniorTrancheProtocolFeeUpdated(_jtProtocolFeeWAD);
    }

    /// @inheritdoc IRoycoAccountant
    function setYieldShareProtocolFee(uint64 _yieldShareProtocolFeeWAD) external override(IRoycoAccountant) restricted withSyncedAccounting {
        // Ensure that the protocol fee percentage is valid
        require(_yieldShareProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD, MAX_PROTOCOL_FEE_EXCEEDED());
        _getRoycoAccountantStorage().yieldShareProtocolFeeWAD = _yieldShareProtocolFeeWAD;
        emit YieldShareProtocolFeeUpdated(_yieldShareProtocolFeeWAD);
    }

    /// @inheritdoc IRoycoAccountant
    function setCoverage(uint64 _coverageWAD) external override(IRoycoAccountant) restricted withSyncedAccounting {
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        // Validate the new coverage configuration
        _validateCoverageConfig(_coverageWAD, $.betaWAD, $.liquidationUtilizationWAD);
        $.coverageWAD = _coverageWAD;
        emit CoverageUpdated(_coverageWAD);
    }

    /// @inheritdoc IRoycoAccountant
    function setBeta(uint96 _betaWAD) external override(IRoycoAccountant) restricted withSyncedAccounting {
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        // Validate the new coverage configuration
        _validateCoverageConfig($.coverageWAD, _betaWAD, $.liquidationUtilizationWAD);
        $.betaWAD = _betaWAD;
        emit BetaUpdated(_betaWAD);
    }

    /// @inheritdoc IRoycoAccountant
    function setLiquidationUtilization(uint256 _liquidationUtilizationWAD) external override(IRoycoAccountant) restricted withSyncedAccounting {
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        // Validate the new coverage configuration
        _validateCoverageConfig($.coverageWAD, $.betaWAD, _liquidationUtilizationWAD);
        $.liquidationUtilizationWAD = _liquidationUtilizationWAD;
        emit LiquidationUtilizationUpdated(_liquidationUtilizationWAD);
    }

    /// @inheritdoc IRoycoAccountant
    function setCoverageConfiguration(
        uint64 _coverageWAD,
        uint96 _betaWAD,
        uint256 _liquidationUtilizationWAD
    )
        external
        override(IRoycoAccountant)
        restricted
        withSyncedAccounting
    {
        // Validate the new coverage configuration
        _validateCoverageConfig(_coverageWAD, _betaWAD, _liquidationUtilizationWAD);
        // Set the new config
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        $.coverageWAD = _coverageWAD;
        emit CoverageUpdated(_coverageWAD);
        $.betaWAD = _betaWAD;
        emit BetaUpdated(_betaWAD);
        $.liquidationUtilizationWAD = _liquidationUtilizationWAD;
        emit LiquidationUtilizationUpdated(_liquidationUtilizationWAD);
    }

    /// @inheritdoc IRoycoAccountant
    function setFixedTermDuration(uint24 _fixedTermDurationSeconds) external override(IRoycoAccountant) restricted withSyncedAccounting {
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        $.fixedTermDurationSeconds = _fixedTermDurationSeconds;
        // If the specified duration is 0, the market will permanently be in a perpetual state
        if (_fixedTermDurationSeconds == 0) {
            emit JTCoverageImpermanentLossReset($.lastJTCoverageImpermanentLoss);
            $.lastJTCoverageImpermanentLoss = ZERO_NAV_UNITS;
            $.lastMarketState = MarketState.PERPETUAL;
        }
        emit FixedTermDurationUpdated(_fixedTermDurationSeconds);
    }

    /// @inheritdoc IRoycoAccountant
    function setSeniorTrancheDustTolerance(NAV_UNIT _stNAVDustTolerance) external override(IRoycoAccountant) restricted withSyncedAccounting {
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        $.stNAVDustTolerance = _stNAVDustTolerance;
        // Update the cached effective NAV dust tolerance
        $.effectiveNAVDustTolerance = _stNAVDustTolerance + $.jtNAVDustTolerance;
        emit SeniorTrancheDustToleranceUpdated(_stNAVDustTolerance);
    }

    /// @inheritdoc IRoycoAccountant
    function setJuniorTrancheDustTolerance(NAV_UNIT _jtNAVDustTolerance) external override(IRoycoAccountant) restricted withSyncedAccounting {
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        $.jtNAVDustTolerance = _jtNAVDustTolerance;
        // Update the cached effective NAV dust tolerance
        $.effectiveNAVDustTolerance = $.stNAVDustTolerance + _jtNAVDustTolerance;
        emit JuniorTrancheDustToleranceUpdated(_jtNAVDustTolerance);
    }

    // =============================
    // Internal Utility Functions
    // =============================

    /**
     * @notice Validates the coverage requirement parameters of the market
     * @param _coverageWAD The coverage ratio that the senior tranche is expected to be protected by, scaled to WAD precision
     * @param _betaWAD The JT's sensitivity to the same downside stress that affects ST, scaled to WAD precision
     * @param _liquidationUtilizationWAD The liquidation utilization threshold for this market, scaled to WAD precision
     */
    function _validateCoverageConfig(uint64 _coverageWAD, uint96 _betaWAD, uint256 _liquidationUtilizationWAD) internal pure {
        require(
            // Ensure that the coverage requirement is valid
            (_coverageWAD >= MIN_COVERAGE_WAD) && (_coverageWAD <= MAX_COVERAGE_WAD) && 
                // Ensure that beta is valid
                // NOTE: Beta cannot exceed 1 because the junior tranche should never be in a more loss-prone investment than the senior tranche
                (_betaWAD <= WAD) && 
                // Ensure that JT withdrawals are not permanently bricked
                (uint256(_coverageWAD).mulDiv(_betaWAD, WAD, Math.Rounding.Ceil) < WAD) && 
                // Ensure that the liquidation utilization threshold can only be breached once the NAVs have experienced losses
                (_liquidationUtilizationWAD > WAD),
            INVALID_COVERAGE_CONFIG()
        );
    }

    /**
     * @notice Initializes the YDM (Yield Distribution Model) if required for this market
     * @param _ydm The new YDM address to set
     * @param _ydmInitializationData The data used to initialize the new YDM for this market
     */
    function _initializeYDM(address _ydm, bytes calldata _ydmInitializationData) internal {
        // Ensure that the YDM is not null
        require(_ydm != address(0), NULL_ADDRESS());
        // Initialize the YDM if required
        if (_ydmInitializationData.length != 0) {
            (bool success, bytes memory data) = _ydm.call(_ydmInitializationData);
            require(success, FAILED_TO_INITIALIZE_YDM(data));
        }
    }

    // =============================
    // Accountant State Accessor Functions
    // =============================

    /// @inheritdoc IRoycoAccountant
    function getLastAccountingCheckpoint() external view override(IRoycoAccountant) returns (AccountingCheckpoint memory) {
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        return AccountingCheckpoint({
            stRawNAV: $.lastSTRawNAV,
            jtRawNAV: $.lastJTRawNAV,
            stEffectiveNAV: $.lastSTEffectiveNAV,
            jtEffectiveNAV: $.lastJTEffectiveNAV,
            jtCoverageImpermanentLoss: $.lastJTCoverageImpermanentLoss
        });
    }

    /// @inheritdoc IRoycoAccountant
    function getState() external pure override(IRoycoAccountant) returns (RoycoAccountantState memory) {
        return _getRoycoAccountantStorage();
    }

    /**
     * @notice Returns a storage pointer to the RoycoAccountantState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer to the accountant's state
     */
    function _getRoycoAccountantStorage() private pure returns (RoycoAccountantState storage $) {
        assembly ("memory-safe") {
            $.slot := ROYCO_ACCOUNTANT_STORAGE_SLOT
        }
    }
}
