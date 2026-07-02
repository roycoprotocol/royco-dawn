// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoBase } from "../base/RoycoBase.sol";
import { IRoycoAccountant } from "../interfaces/IRoycoAccountant.sol";
import { IRoycoKernel } from "../interfaces/IRoycoKernel.sol";
import { IYDM } from "../interfaces/IYDM.sol";
import { MAX_COVERAGE_WAD, MAX_PROTOCOL_FEE_WAD, MIN_COVERAGE_WAD, WAD, ZERO_NAV_UNITS } from "../libraries/Constants.sol";
import { MarketState, NAV_UNIT, Operation, SyncedAccountingState } from "../libraries/Types.sol";
import { UnitsMathLib, toNAVUnits, toUint256 } from "../libraries/Units.sol";
import { Math, UtilsLib } from "../libraries/UtilsLib.sol";

/**
 * @title RoycoAccountant
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Performs and tracks the core accounting operations for a Royco market
 * @notice Responsible for marking tranche NAVs to market, tracking impermanent losses, distributing yield via the YDM, and computing protocol fees
 * @notice Responsible for tracking the operational and coverage state of the Royco market
 */
contract RoycoAccountant is IRoycoAccountant, RoycoBase {
    using Math for uint256;
    using UnitsMathLib for NAV_UNIT;
    using UnitsMathLib for uint256;

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
        IRoycoKernel(KERNEL).syncTrancheAccounting();
        _;
    }

    // =============================
    // Construction and Initialization Functions
    // =============================

    /// @dev Constructs the accountant with the specified kernel
    /// @param _kernel - The kernel that this accountant maintains mark-to-market NAV, impermanent loss, and fee accounting for
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
    }

    // =============================
    // NAV Synchronization Functions
    // =============================

    /// @inheritdoc IRoycoAccountant
    function preOpSyncTrancheAccounting(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV
    )
        public
        override(IRoycoAccountant)
        onlyRoycoKernel
        returns (SyncedAccountingState memory state)
    {
        // Get the storage pointer to the accountant state
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();

        // Preview synchronization of the tranche NAVs and impermanent losses
        MarketState initialMarketState;
        bool yieldDistributed;
        NAV_UNIT jtImpermanentLossErased;
        (state, initialMarketState, yieldDistributed, jtImpermanentLossErased) = _previewSyncTrancheAccounting(_stRawNAV, _jtRawNAV, _accrueJTYieldShare());

        // ST yield was split between ST and JT
        if (yieldDistributed) {
            // Reset the accumulator and update the last yield distribution timestamp
            delete $.twJTYieldShareAccruedWAD;
            $.lastDistributionTimestamp = uint32(block.timestamp);
        }

        // Checkpoint the resulting market state, mark-to-market NAVs, and impermanent losses
        $.lastMarketState = state.marketState;
        $.lastSTRawNAV = _stRawNAV;
        $.lastJTRawNAV = _jtRawNAV;
        $.lastSTEffectiveNAV = state.stEffectiveNAV;
        $.lastJTEffectiveNAV = state.jtEffectiveNAV;
        $.lastSTImpermanentLoss = state.stImpermanentLoss;
        $.lastJTImpermanentLoss = state.jtImpermanentLoss;

        // If the market transitioned from a perpetual to a fixed-term state, set the end timestamp of the fixed-term
        if (initialMarketState == MarketState.PERPETUAL && state.marketState == MarketState.FIXED_TERM) {
            $.fixedTermEndTimestamp = state.fixedTermEndTimestamp;
            emit FixedTermCommenced(state.fixedTermEndTimestamp);
        } else if (initialMarketState == MarketState.FIXED_TERM && state.marketState == MarketState.PERPETUAL) {
            emit FixedTermEnded();
        }

        // If the JT Coverage IL was erased, signal the resetting
        if (jtImpermanentLossErased != ZERO_NAV_UNITS) {
            emit JTImpermanentLossReset(jtImpermanentLossErased);
        }

        emit TrancheAccountingSynced(state);
    }

    /// @inheritdoc IRoycoAccountant
    function previewSyncTrancheAccounting(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV
    )
        public
        view
        override(IRoycoAccountant)
        returns (SyncedAccountingState memory state)
    {
        (state,,,) = _previewSyncTrancheAccounting(_stRawNAV, _jtRawNAV, _previewJTYieldShareAccrual());
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

        // Cache the last checkpointed NAVs and impermanent losses for each tranche
        NAV_UNIT stEffectiveNAV = $.lastSTEffectiveNAV;
        NAV_UNIT jtEffectiveNAV = $.lastJTEffectiveNAV;
        NAV_UNIT stImpermanentLoss = $.lastSTImpermanentLoss;
        NAV_UNIT jtImpermanentLoss = $.lastJTImpermanentLoss;

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
                // The withdrawing senior LP has realized its proportional share of past uncovered losses and associated recovery optionality, rounding in favor of senior
                if (stImpermanentLoss != ZERO_NAV_UNITS) {
                    stImpermanentLoss = stImpermanentLoss.mulDiv(stEffectiveNAV, $.lastSTEffectiveNAV, Math.Rounding.Ceil);
                    $.lastSTImpermanentLoss = stImpermanentLoss;
                }
            } else if (_op == Operation.JT_REDEEM) {
                // JT cannot get a bonus from its own NAV
                require(totalRedemptionNAV > ZERO_NAV_UNITS && _stSelfLiquidationBonusNAV == ZERO_NAV_UNITS, INVALID_POST_OP_STATE(_op));
                // The actual amount withdrawn from JT effective NAV could be from both tranches (its own share of its NAV, ST yield share, IL repayments, etc.)
                jtEffectiveNAV = jtEffectiveNAV - totalRedemptionNAV;
                // The withdrawing junior LP has realized its proportional share of past JT losses from coverage applied and its associated recovery optionality, rounding in favor of senior
                if (jtImpermanentLoss != ZERO_NAV_UNITS) {
                    jtImpermanentLoss = jtImpermanentLoss.mulDiv(jtEffectiveNAV, $.lastJTEffectiveNAV, Math.Rounding.Floor);
                    $.lastJTImpermanentLoss = jtImpermanentLoss;
                }
            }
        }

        // Enforce the NAV conservation invariant
        require((_stRawNAV + _jtRawNAV) == (stEffectiveNAV + jtEffectiveNAV), NAV_CONSERVATION_VIOLATION());

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
            stImpermanentLoss: stImpermanentLoss,
            jtImpermanentLoss: jtImpermanentLoss,
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
    function maxSTDepositGivenCoverage(NAV_UNIT _stRawNAV, NAV_UNIT _jtRawNAV) external view override(IRoycoAccountant) returns (NAV_UNIT maxSTDeposit) {
        // Get the storage pointer to the accountant state
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        // Preview a NAV sync to get the market's current state
        (SyncedAccountingState memory state,,,) = _previewSyncTrancheAccounting(_stRawNAV, _jtRawNAV, _previewJTYieldShareAccrual());
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
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        NAV_UNIT _jtClaimOnStUnits,
        NAV_UNIT _jtClaimOnJtUnits
    )
        external
        view
        override(IRoycoAccountant)
        returns (NAV_UNIT totalNAVClaimable, NAV_UNIT stClaimable, NAV_UNIT jtClaimable)
    {
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();

        // Get the surplus JT assets in NAV units
        // Preview a NAV sync to get the market's current state
        (SyncedAccountingState memory state,,,) = _previewSyncTrancheAccounting(_stRawNAV, _jtRawNAV, _previewJTYieldShareAccrual());
        uint256 betaWAD = $.betaWAD;
        // Compute the total covered exposure of the underlying investment, rounding in favor of senior protection
        NAV_UNIT totalCoveredExposure = _stRawNAV + _jtRawNAV.mulDiv(betaWAD, WAD, Math.Rounding.Ceil);
        // Compute the minimum junior tranche assets required to cover the exposure as per the market's coverage requirement
        NAV_UNIT requiredJTAssets = totalCoveredExposure.mulDiv($.coverageWAD, WAD, Math.Rounding.Ceil);
        // Compute the surplus coverage currently provided by the junior tranche based on its currently remaining loss-absorption buffer
        // Also account for the effective dust tolerance required to preclude reverts due to rounding after JT redemptions
        // Additionally absorb the worst case inner-ceil rounding in the utilization computation
        NAV_UNIT surplusJTAssets = state.jtEffectiveNAV.saturatingSub(requiredJTAssets)
            .saturatingSub($.stNAVDustTolerance + $.jtNAVDustTolerance.mulDiv(betaWAD, WAD, Math.Rounding.Ceil)).saturatingSub(toNAVUnits(uint256(2)));
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
     * @notice Synchronizes all tranche NAVs and impermanent losses based on unrealized PNLs of the underlying investment(s)
     * @param _stRawNAV The senior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the pure value of its invested assets
     * @param _twJTYieldShareAccruedWAD The currently accrued time-weighted JT yield share YDM output since the last distribution, scaled to WAD precision
     * @return state A struct containing all mark-to-market NAV, impermanent losses, and fee data after executing the sync
     * @return initialMarketState The initial state the market was in before the synchronization
     * @return yieldDistributed A boolean indicating whether ST yield was split between ST and JT
     * @return jtImpermanentLossErased The amount of JT coverage loss erased (reset to 0)
     */
    function _previewSyncTrancheAccounting(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        uint192 _twJTYieldShareAccruedWAD
    )
        internal
        view
        returns (SyncedAccountingState memory state, MarketState initialMarketState, bool yieldDistributed, NAV_UNIT jtImpermanentLossErased)
    {
        // Get the storage pointer to the accountant state
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();

        // Cache the last checkpointed effective NAV for each tranche
        NAV_UNIT stEffectiveNAV = $.lastSTEffectiveNAV;
        NAV_UNIT jtEffectiveNAV = $.lastJTEffectiveNAV;
        // Compute the deltas for each tranche's effective NAV based on their last checkpointed economic claims on each tranche's raw NAVs
        int256 deltaSTEffectiveNAV;
        int256 deltaJTEffectiveNAV;
        {
            // Cache the last checkpointed raw NAV for each tranche
            NAV_UNIT lastSTRawNAV = $.lastSTRawNAV;
            NAV_UNIT lastJTRawNAV = $.lastJTRawNAV;

            // Last cross-tranche claims (the NAV that can't be funded by the tranche's own raw NAV)
            NAV_UNIT stClaimOnJTRawNAV = UnitsMathLib.saturatingSub(stEffectiveNAV, lastSTRawNAV);
            NAV_UNIT jtClaimOnSTRawNAV = UnitsMathLib.saturatingSub(jtEffectiveNAV, lastJTRawNAV);
            // Last self-backed portion of the senior tranche's claim (the NAV funded by ST's own raw NAV)
            // NOTE: NAV conservation guarantees that this cannot underflow
            NAV_UNIT stClaimOnSTRawNAV = (lastSTRawNAV - jtClaimOnSTRawNAV);

            // Compute the deltas in the raw NAVs of each tranche
            // The deltas represent the unrealized PNL of the underlying investment since the last NAV checkpoints
            int256 deltaSTRawNAV = UnitsMathLib.computeNAVDelta(_stRawNAV, lastSTRawNAV);
            int256 deltaJTRawNAV = UnitsMathLib.computeNAVDelta(_jtRawNAV, lastJTRawNAV);

            // Attribute each raw NAV's signed PNL to ST in proportion to its claim against that raw NAV
            // The resulting deltas are rounded down: in favor of seniors on losses and juniors on gains
            // When the last ST raw NAV is zero, conservation forces ST's claim on its raw NAV to zero: route the delta to ST if it has live effective claims, else leave it as residual to JT to avoid inflating NAV against zero ST shares outstanding
            int256 deltaSTClaimOnSTRawNAV = lastSTRawNAV == ZERO_NAV_UNITS
                ? (stEffectiveNAV > ZERO_NAV_UNITS ? deltaSTRawNAV : int256(0))
                : _attributeDeltaToClaimOnRawNAV(deltaSTRawNAV, stClaimOnSTRawNAV, lastSTRawNAV);
            int256 deltaSTClaimOnJTRawNAV = _attributeDeltaToClaimOnRawNAV(deltaJTRawNAV, stClaimOnJTRawNAV, lastJTRawNAV);

            // ST's effective NAV delta is the sum of its claim-weighted shares of each pool's PNL and JT's effective NAV delta is computed as the residual
            // NOTE: NAV conservation holds: positive and negative rounding drift is absorbed by juniors
            deltaSTEffectiveNAV = deltaSTClaimOnSTRawNAV + deltaSTClaimOnJTRawNAV;
            deltaJTEffectiveNAV = (deltaSTRawNAV + deltaJTRawNAV) - deltaSTEffectiveNAV;
        }

        // Cache the last checkpointed market state and impermanent losses for each tranche
        initialMarketState = $.lastMarketState;
        NAV_UNIT stImpermanentLoss = $.lastSTImpermanentLoss;
        NAV_UNIT jtImpermanentLoss = $.lastJTImpermanentLoss;
        NAV_UNIT stProtocolFeeAccrued;
        NAV_UNIT jtProtocolFeeAccrued;

        // Effective NAV deltas are claim-weighted linear combinations of stRawNAV and jtRawNAV deltas, so the worst-case dust is bounded by the sum of the raw NAV dust tolerances
        NAV_UNIT effectiveNAVDustTolerance = $.stNAVDustTolerance + $.jtNAVDustTolerance;

        // The net JT gains after ST IL recovery. The JT protocol fee accrued is calculated using this NAV.
        NAV_UNIT jtNetGain = ZERO_NAV_UNITS;
        // Mark both the tranche NAVs to market
        /// @dev STEP_APPLY_JT_LOSS: The JT assets depreciated in value
        if (deltaJTEffectiveNAV < 0) {
            /// @dev STEP_JT_ABSORB_LOSS: JT's remaning loss-absorption buffer incurs as much of the loss as possible
            NAV_UNIT jtLoss = toNAVUnits(-deltaJTEffectiveNAV);
            NAV_UNIT jtAbsorbableLoss = UnitsMathLib.min(jtLoss, jtEffectiveNAV);
            if (jtAbsorbableLoss != ZERO_NAV_UNITS) {
                // Incur the maximum absorbable losses to remaining JT loss capital
                jtEffectiveNAV = (jtEffectiveNAV - jtAbsorbableLoss);
                jtLoss = (jtLoss - jtAbsorbableLoss);
            }
            /// @dev STEP_ST_INCURS_RESIDUAL_LOSSES: Residual loss after emptying JT's remaning loss-absorption buffer are incurred by ST
            if (jtLoss != ZERO_NAV_UNITS) {
                // The excess loss is absorbed by ST
                stEffectiveNAV = (stEffectiveNAV - jtLoss);
                // This is booked as ST impermanent loss
                stImpermanentLoss = (stImpermanentLoss + jtLoss);
            }
            /// @dev STEP_APPLY_JT_GAIN: The JT assets appreciated in value
        } else if (deltaJTEffectiveNAV > 0) {
            NAV_UNIT jtGain = toNAVUnits(deltaJTEffectiveNAV);
            /// @dev STEP_ST_IMPERMANENT_LOSS_RECOVERY: First, recover any ST impermanent losses (first claim on JT appreciation)
            NAV_UNIT stImpermanentLossRecovery = UnitsMathLib.min(jtGain, stImpermanentLoss);
            if (stImpermanentLossRecovery != ZERO_NAV_UNITS) {
                // Recover as much of the ST impermanent loss as possible
                stImpermanentLoss = (stImpermanentLoss - stImpermanentLossRecovery);
                // Apply the retroactive coverage to the ST
                stEffectiveNAV = (stEffectiveNAV + stImpermanentLossRecovery);
                jtGain = (jtGain - stImpermanentLossRecovery);
            }
            /// @dev STEP_JT_ACCRUES_RESIDUAL_GAINS: JT accrues any remaining appreciation after clearing ST IL
            if (jtGain != ZERO_NAV_UNITS) {
                jtNetGain = jtGain;
                // Compute the protocol fee taken on this JT yield accrual if it is not attributable to any rounding/dust
                if (jtNetGain > effectiveNAVDustTolerance) jtProtocolFeeAccrued = jtNetGain.mulDiv($.jtProtocolFeeWAD, WAD, Math.Rounding.Floor);
                // Book the residual gains to the JT
                jtEffectiveNAV = (jtEffectiveNAV + jtNetGain);
            }
        }

        /// @dev STEP_APPLY_ST_LOSS: The ST assets depreciated in value
        if (deltaSTEffectiveNAV < 0) {
            NAV_UNIT stLoss = toNAVUnits(-deltaSTEffectiveNAV);
            /// @dev STEP_APPLY_JT_COVERAGE_TO_ST: Apply any possible coverage to ST provided by JT's loss-absorption buffer
            NAV_UNIT coverageApplied = UnitsMathLib.min(stLoss, jtEffectiveNAV);
            if (coverageApplied != ZERO_NAV_UNITS) {
                // If there was a JT protocol fee taken on their appreciation, recalculate it using the JT net gain after applying coverage applied
                if (jtProtocolFeeAccrued != ZERO_NAV_UNITS) {
                    jtNetGain = jtNetGain.saturatingSub(coverageApplied);
                    jtProtocolFeeAccrued =
                        (jtNetGain > effectiveNAVDustTolerance) ? jtNetGain.mulDiv($.jtProtocolFeeWAD, WAD, Math.Rounding.Floor) : ZERO_NAV_UNITS;
                }
                // Apply the coverage to JT effective NAV
                jtEffectiveNAV = (jtEffectiveNAV - coverageApplied);
                // Any coverage provided is a ST liability to JT
                jtImpermanentLoss = (jtImpermanentLoss + coverageApplied);
                stLoss = stLoss - coverageApplied;
            }
            /// @dev STEP_ST_INCURS_RESIDUAL_LOSSES: Apply any uncovered losses by JT to ST
            if (stLoss != ZERO_NAV_UNITS) {
                // Apply residual losses to ST
                stEffectiveNAV = (stEffectiveNAV - stLoss);
                // The uncovered portion of the ST loss is a JT liability to ST
                stImpermanentLoss = (stImpermanentLoss + stLoss);
            }
            /// @dev STEP_APPLY_ST_GAIN: The ST assets appreciated in value
        } else if (deltaSTEffectiveNAV > 0) {
            NAV_UNIT stGain = toNAVUnits(deltaSTEffectiveNAV);
            /// @dev STEP_ST_IMPERMANENT_LOSS_RECOVERY: First, recover any ST impermanent losses (first claim on ST appreciation)
            NAV_UNIT impermanentLossRecovery = UnitsMathLib.min(stGain, stImpermanentLoss);
            if (impermanentLossRecovery != ZERO_NAV_UNITS) {
                // Recover as much of the ST impermanent loss as possible
                stImpermanentLoss = (stImpermanentLoss - impermanentLossRecovery);
                // Apply the ST IL recovery
                stEffectiveNAV = (stEffectiveNAV + impermanentLossRecovery);
                stGain = (stGain - impermanentLossRecovery);
            }
            /// @dev STEP_JT_COVERAGE_IMPERMANENT_LOSS_RECOVERY: Second, recover any JT coverage inflicted impermanent losses (second claim on ST appreciation)
            impermanentLossRecovery = UnitsMathLib.min(stGain, jtImpermanentLoss);
            if (impermanentLossRecovery != ZERO_NAV_UNITS) {
                // Recover as much of the JT coverage impermanent loss as possible
                jtImpermanentLoss = (jtImpermanentLoss - impermanentLossRecovery);
                // Apply the JT coverage IL recovery
                jtEffectiveNAV = (jtEffectiveNAV + impermanentLossRecovery);
                stGain = (stGain - impermanentLossRecovery);
            }
            /// @dev STEP_DISTRIBUTE_YIELD: There are no remaining impermanent losses that ST yield is obligated to repay, the residual gains will be used to distribute yield to both tranches
            if (stGain != ZERO_NAV_UNITS) {
                // Mark yield as distributed if the gain is not attributable to any rounding/dust
                if (stGain > effectiveNAVDustTolerance) yieldDistributed = true;
                // Compute the time weighted average JT share of yield
                uint256 elapsed = block.timestamp - $.lastDistributionTimestamp;
                // If the last yield distribution happened in the same block, use the instantaneous JT yield share. Else, use the time-weighted average JT yield share since the last distribution
                NAV_UNIT yieldShare;
                if (elapsed == 0) {
                    // Get the instantaneous YDM output and ensure that the yield share cannot be more than 100% of senior appreciation
                    uint256 instantaneousJtYieldShareWAD =
                        IYDM($.ydm).previewJTYieldShare(initialMarketState, $.lastSTRawNAV, $.lastJTRawNAV, $.betaWAD, $.coverageWAD, $.lastJTEffectiveNAV);
                    if (instantaneousJtYieldShareWAD > WAD) instantaneousJtYieldShareWAD = WAD;
                    yieldShare = stGain.mulDiv(instantaneousJtYieldShareWAD, WAD, Math.Rounding.Floor);
                } else {
                    yieldShare = stGain.mulDiv(_twJTYieldShareAccruedWAD, elapsed * WAD, Math.Rounding.Floor);
                }
                // Apply the yield split to JT's effective NAV
                if (yieldShare != ZERO_NAV_UNITS) {
                    // Compute the protocol fee taken on the yield share accrual if it is not attributable to any rounding/dust
                    if (yieldDistributed) {
                        jtProtocolFeeAccrued = (jtProtocolFeeAccrued + yieldShare.mulDiv($.yieldShareProtocolFeeWAD, WAD, Math.Rounding.Floor));
                    }
                    jtEffectiveNAV = (jtEffectiveNAV + yieldShare);
                    stGain = (stGain - yieldShare);
                }
                // Compute the protocol fee taken on this ST yield accrual if it is not attributable to any rounding/dust
                if (yieldDistributed) stProtocolFeeAccrued = stGain.mulDiv($.stProtocolFeeWAD, WAD, Math.Rounding.Floor);
                // Book the residual gain to the ST
                stEffectiveNAV = (stEffectiveNAV + stGain);
            }
        }

        // Enforce the NAV conservation invariant
        require((_stRawNAV + _jtRawNAV) == (stEffectiveNAV + jtEffectiveNAV), NAV_CONSERVATION_VIOLATION());

        // Determine the resulting market state:
        // 1. Forced Perpetual: The fixed-term duration is set to 0 (permanently perpetual), current fixed-term elapsed, or liquidation utilization threshold has been breached (undercollateralized) or ST IL exists (distressed)
        // 2. Normal Perpetual: JT coverage IL is within dust tolerance (staying perpetual) or fully recovered (exiting fixed-term for perpetual)
        // 3. Fixed-term: The JT coverage IL is above the dust tolerance of the market, fixed-term duration hasn't elapsed, liquidation utilization threshold hasn't been breached, and ST IL nonexistent
        MarketState resultingMarketState;
        uint32 fixedTermEndTimestamp = $.fixedTermEndTimestamp;
        uint24 fixedTermDurationSeconds = $.fixedTermDurationSeconds;
        uint96 betaWAD = $.betaWAD;
        uint64 coverageWAD = $.coverageWAD;
        uint256 utilizationWAD = UtilsLib.computeUtilization(_stRawNAV, _jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV);
        uint256 liquidationUtilizationWAD = $.liquidationUtilizationWAD;
        // If the market is permanently perpetual, the fixed-term elapsed, undercollateralized, or distressed, the market must be in a a perpetual state
        if (
            fixedTermDurationSeconds == 0 || (initialMarketState == MarketState.FIXED_TERM && fixedTermEndTimestamp <= block.timestamp)
                || utilizationWAD >= liquidationUtilizationWAD || stImpermanentLoss != ZERO_NAV_UNITS
        ) {
            // JT coverage impermanent loss has to be explicitly cleared in this branch:
            // If the fixed-term duration is 0, the market is permanently in a perpetual state and never incurs any JT coverage IL
            // If the current fixed-term has elapsed, the market needs to transition to a perpetual state since the transient JT protection period is complete
            // If the liquidation utilization threshold has been breached without existent ST IL, the market is approaching an uncollateralized state: ST needs to be able to withdraw to avoid losses and the YDM needs to kick in to reinstate proper collateralization
            // If ST IL exists, the market is in a distressed state: STs need to be able to book losses and any future appreciation will go to making ST whole again
            jtImpermanentLossErased = jtImpermanentLoss;
            jtImpermanentLoss = ZERO_NAV_UNITS;
            // Transition to a perpetual state
            resultingMarketState = MarketState.PERPETUAL;
            fixedTermEndTimestamp = 0;
            // If the market has less than dust coverage provided by JT
        } else if (jtImpermanentLoss <= effectiveNAVDustTolerance) {
            // JT coverage IL is either nonexistent or can be attributed to dust ST losses (eg. rounding in the underlying ST NAV)
            // If market was in a perpetual state or the coverage IL was completely wiped, transition to a perpetual state
            if (initialMarketState == MarketState.PERPETUAL || jtImpermanentLoss == ZERO_NAV_UNITS) {
                // Transition to a perpetual state
                resultingMarketState = MarketState.PERPETUAL;
                fixedTermEndTimestamp = 0;
                // If market was in a fixed-term state, remain in it until dust tolerance is completely restored
            } else {
                // This ensures that we always have a buffer of at least the dust tolerance when entering a fresh perpetual state
                resultingMarketState = MarketState.FIXED_TERM;
                // Fees are not taken in a fixed-term state
                stProtocolFeeAccrued = ZERO_NAV_UNITS; // Formality: Should naturally never be non-zero in a fixed-term state
                jtProtocolFeeAccrued = ZERO_NAV_UNITS;
            }
        } else {
            resultingMarketState = MarketState.FIXED_TERM;
            // Fees are not taken in a fixed-term state
            stProtocolFeeAccrued = ZERO_NAV_UNITS; // Formality: Should naturally never be non-zero in a fixed-term state
            jtProtocolFeeAccrued = ZERO_NAV_UNITS;
            // If the market was in a perpetual state, update the fixed-term end timestamp
            if (initialMarketState == MarketState.PERPETUAL) fixedTermEndTimestamp = uint32(block.timestamp + fixedTermDurationSeconds);
        }

        // Marshal the post-sync state and return to the caller
        state = SyncedAccountingState({
            marketState: resultingMarketState,
            stRawNAV: _stRawNAV,
            jtRawNAV: _jtRawNAV,
            stEffectiveNAV: stEffectiveNAV,
            jtEffectiveNAV: jtEffectiveNAV,
            stImpermanentLoss: stImpermanentLoss,
            jtImpermanentLoss: jtImpermanentLoss,
            stProtocolFeeAccrued: stProtocolFeeAccrued,
            jtProtocolFeeAccrued: jtProtocolFeeAccrued,
            utilizationWAD: utilizationWAD,
            fixedTermEndTimestamp: fixedTermEndTimestamp,
            coverageWAD: coverageWAD,
            betaWAD: betaWAD,
            liquidationUtilizationWAD: liquidationUtilizationWAD
        });
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
        // Ensure that JT cannot earn more than 100% of senior appreciation
        if (jtYieldShareWAD > WAD) jtYieldShareWAD = WAD;

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
        // Ensure that JT cannot earn more than 100% of senior appreciation
        if (jtYieldShareWAD > WAD) jtYieldShareWAD = WAD;

        // Apply the accrual of JT yield share to the accumulator, weighted by the time elapsed
        return ($.twJTYieldShareAccruedWAD + uint192(jtYieldShareWAD * elapsed));
    }

    // =============================
    // Administrative Functions
    // =============================

    /// @inheritdoc IRoycoAccountant
    function setYDM(address _ydm, bytes calldata _ydmInitializationData) external override(IRoycoAccountant) restricted withSyncedAccounting {
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
            emit JTImpermanentLossReset($.lastJTImpermanentLoss);
            $.lastJTImpermanentLoss = ZERO_NAV_UNITS;
            $.lastMarketState = MarketState.PERPETUAL;
        }
        emit FixedTermDurationUpdated(_fixedTermDurationSeconds);
    }

    /// @inheritdoc IRoycoAccountant
    function setSeniorTrancheDustTolerance(NAV_UNIT _stNAVDustTolerance) external override(IRoycoAccountant) restricted withSyncedAccounting {
        _getRoycoAccountantStorage().stNAVDustTolerance = _stNAVDustTolerance;
        emit SeniorTrancheDustToleranceUpdated(_stNAVDustTolerance);
    }

    /// @inheritdoc IRoycoAccountant
    function setJuniorTrancheDustTolerance(NAV_UNIT _jtNAVDustTolerance) external override(IRoycoAccountant) restricted withSyncedAccounting {
        _getRoycoAccountantStorage().jtNAVDustTolerance = _jtNAVDustTolerance;
        emit JuniorTrancheDustToleranceUpdated(_jtNAVDustTolerance);
    }

    // =============================
    // Internal Utility Functions
    // =============================

    /**
     * @notice Attributes a portion of a signed raw NAV delta to a tranche based on its proportional claim on the raw NAV
     * @param _delta The signed raw NAV delta to attribute
     * @param _claimOnTrancheRawNAV The tranche's claim against the raw NAV
     * @param _lastTrancheRawNAV The total raw NAV of the pool at the last checkpoint
     * @return attributedDelta The signed share of the delta attributable to the claim holder
     */
    function _attributeDeltaToClaimOnRawNAV(
        int256 _delta,
        NAV_UNIT _claimOnTrancheRawNAV,
        NAV_UNIT _lastTrancheRawNAV
    )
        internal
        pure
        returns (int256 attributedDelta)
    {
        // No NAV to attribute to the tranche if any operand is zero
        if (_delta == 0 || _claimOnTrancheRawNAV == ZERO_NAV_UNITS || _lastTrancheRawNAV == ZERO_NAV_UNITS) return 0;

        // Work in unsigned magnitudes for the proportional split, then re-apply the original sign
        // Floor on the magnitude routes the leftover wei from rounding into the complementary tranche
        uint256 absDelta = _delta < 0 ? uint256(-_delta) : uint256(_delta);
        uint256 attributedMagnitude = absDelta.mulDiv(_claimOnTrancheRawNAV, _lastTrancheRawNAV, Math.Rounding.Floor);
        attributedDelta = _delta < 0 ? -int256(attributedMagnitude) : int256(attributedMagnitude);
    }

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
