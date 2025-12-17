// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoBase } from "../base/RoycoBase.sol";
import { IRDM } from "../interfaces/IRDM.sol";
import { IRoycoAccountant, Operation } from "../interfaces/IRoycoAccountant.sol";
import { MAX_PROTOCOL_FEE_WAD, MIN_COVERAGE_WAD, WAD, ZERO_NAV_UNITS } from "../libraries/Constants.sol";
import { RoycoAccountantInitParams, RoycoAccountantState, RoycoAccountantStorageLib } from "../libraries/RoycoAccountantStorageLib.sol";
import { NAV_UNIT, SyncedAccountingState } from "../libraries/Types.sol";
import { UnitsMathLib, toNAVUnits } from "../libraries/Units.sol";
import { Math, UtilsLib } from "../libraries/UtilsLib.sol";

contract RoycoAccountant is IRoycoAccountant, RoycoBase {
    using Math for uint256;
    using UnitsMathLib for NAV_UNIT;

    /// @dev Enforces that the function is called by the accountant's Royco kernel
    modifier onlyRoycoKernel() {
        require(msg.sender == RoycoAccountantStorageLib._getRoycoAccountantStorage().kernel, ONLY_ROYCO_KERNEL());
        _;
    }

    /**
     * @notice Initializes the Royco accountant state
     * @param _params The initialization parameters for the Royco accountant
     * @param _initialAuthority The initial authority for the Royco accountant
     */
    function initialize(RoycoAccountantInitParams calldata _params, address _initialAuthority) external initializer {
        // Validate the inital coverage requirement
        _validateCoverageRequirement(_params.coverageWAD, _params.betaWAD);
        // Ensure that the RDM is not null
        require(_params.rdm != address(0), NULL_RDM_ADDRESS());
        // Ensure that the protocol fee percentage is valid
        require(_params.protocolFeeWAD <= MAX_PROTOCOL_FEE_WAD, MAX_PROTOCOL_FEE_EXCEEDED());
        // Initialize the base state of the accountant
        __RoycoBase_init(_initialAuthority);
        // Initialize the state of the accountant
        RoycoAccountantStorageLib.__RoycoAccountant_init(_params);
    }

    /// @inheritdoc IRoycoAccountant
    function preOpSyncTrancheAccounting(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV
    )
        external
        override(IRoycoAccountant)
        onlyRoycoKernel
        returns (SyncedAccountingState memory state)
    {
        // Get the storage pointer to the base kernel state
        RoycoAccountantState storage $ = RoycoAccountantStorageLib._getRoycoAccountantStorage();

        // Accrue the JT yield share since the last accrual and preview the tranche NAVs and debts synchronization
        bool yieldDistributed;
        (state, yieldDistributed) = _previewSyncTrancheAccounting(_stRawNAV, _jtRawNAV, _accrueJTYieldShare());

        // ST yield was split between ST and JT
        if (yieldDistributed) {
            // Reset the accumulator and update the last yield distribution timestamp
            delete $.twJTYieldShareAccruedWAD;
            $.lastDistributionTimestamp = uint32(block.timestamp);
        }

        // Checkpoint the mark to market NAVs and debts
        $.lastSTRawNAV = _stRawNAV;
        $.lastJTRawNAV = _jtRawNAV;
        $.lastSTEffectiveNAV = state.stEffectiveNAV;
        $.lastJTEffectiveNAV = state.jtEffectiveNAV;
        $.lastSTCoverageDebt = state.stCoverageDebt;
        $.lastJTCoverageDebt = state.jtCoverageDebt;
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
        (state,) = _previewSyncTrancheAccounting(_stRawNAV, _jtRawNAV, _previewJTYieldShareAccrual());
    }

    /// @inheritdoc IRoycoAccountant
    function postOpSyncTrancheAccounting(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        Operation _op
    )
        public
        override(IRoycoAccountant)
        onlyRoycoKernel
        returns (SyncedAccountingState memory state)
    {
        // Get the storage pointer to the base kernel state
        RoycoAccountantState storage $ = RoycoAccountantStorageLib._getRoycoAccountantStorage();
        if (_op == Operation.ST_INCREASE_NAV) {
            // Compute the delta in the raw NAV of the senior tranche
            int256 deltaST = UnitsMathLib.computeNAVDelta(_stRawNAV, $.lastSTRawNAV);
            require(deltaST >= 0, INVALID_POST_OP_STATE(_op));
            // Update the post-operation raw NAV ST checkpoint
            $.lastSTRawNAV = _stRawNAV;
            // Apply the deposit to the senior tranche's effective NAV
            $.lastSTEffectiveNAV = $.lastSTEffectiveNAV + toNAVUnits(deltaST);
        } else if (_op == Operation.JT_INCREASE_NAV) {
            // Compute the delta in the raw NAV of the junior tranche
            int256 deltaJT = UnitsMathLib.computeNAVDelta(_jtRawNAV, $.lastJTRawNAV);
            require(deltaJT >= 0, INVALID_POST_OP_STATE(_op));
            // New JT deposits do not go towards paying off existing JT coverage debt (subsidizing old losses)
            // They are treated as an addition to the future loss-absorption buffer
            // Update the post-operation raw NAV ST checkpoint
            $.lastJTRawNAV = _jtRawNAV;
            // Apply the deposit to the junior tranche's effective NAV
            $.lastJTEffectiveNAV = $.lastJTEffectiveNAV + toNAVUnits(deltaJT);
        } else {
            // Compute the deltas in the raw NAVs of each tranche after an operation's execution and cache the raw NAVs
            // The deltas represent the NAV changes after a deposit and withdrawal
            int256 deltaST = UnitsMathLib.computeNAVDelta(_stRawNAV, $.lastSTRawNAV);
            int256 deltaJT = UnitsMathLib.computeNAVDelta(_jtRawNAV, $.lastJTRawNAV);

            // Update the post-operation raw NAV checkpoints
            $.lastSTRawNAV = _stRawNAV;
            $.lastJTRawNAV = _jtRawNAV;

            if (_op == Operation.ST_DECREASE_NAV) {
                require(deltaST <= 0 && deltaJT <= 0, INVALID_POST_OP_STATE(_op));
                // Senior withdrew: The NAV deltas include the discrete withdrawal amount in addition to any coverage pulled from JT to ST
                // If the withdrawal used JT capital as coverage to facilitate this ST withdrawal
                NAV_UNIT preWithdrawalSTEffectiveNAV = $.lastSTEffectiveNAV;
                // The actual amount withdrawn was the delta in ST raw NAV and the coverage applied from JT
                $.lastSTEffectiveNAV = preWithdrawalSTEffectiveNAV - (toNAVUnits(-deltaST) + toNAVUnits(-deltaJT));
                // Proportionally reduce system debts, rounding in favor of senior
                // The withdrawing senior LP has realized its proportional share of past covered losses, settling the realized portion between JT and ST
                NAV_UNIT coverageDebt = $.lastSTCoverageDebt;
                if (coverageDebt != ZERO_NAV_UNITS) {
                    $.lastSTCoverageDebt = coverageDebt.mulDiv($.lastSTEffectiveNAV, preWithdrawalSTEffectiveNAV, Math.Rounding.Floor);
                }
                // The withdrawing senior LP has realized its proportional share of past uncovered losses and associated recovery optionality
                coverageDebt = $.lastJTCoverageDebt;
                if (coverageDebt != ZERO_NAV_UNITS) {
                    $.lastJTCoverageDebt = coverageDebt.mulDiv($.lastSTEffectiveNAV, preWithdrawalSTEffectiveNAV, Math.Rounding.Ceil);
                }
            } else if (_op == Operation.JT_DECREASE_NAV) {
                require(deltaJT <= 0 && deltaST <= 0, INVALID_POST_OP_STATE(_op));
                // Junior withdrew: The NAV deltas include the discrete withdrawal amount in addition to any assets (yield + debt repayments) pulled from ST to JT
                // JT LPs cannot settle debts on withdrawal since they don't have discretion on when coverage applied to ST (stCoverageDebt) and uncovered ST losses (jtCoverageDebt) can be realized
                // The actual amount withdrawn by JT was the delta in JT raw NAV and the assets claimed from ST
                $.lastJTEffectiveNAV = $.lastJTEffectiveNAV - (toNAVUnits(-deltaJT) + toNAVUnits(-deltaST));
                // Enforce the expected relationship between JT NAVs and ST coverage debt (outstanding applied coverage)
                require($.lastJTEffectiveNAV + $.lastSTCoverageDebt >= _jtRawNAV, INVALID_POST_OP_STATE(_op));
            }
        }
        // Construct the synced NAVs state to return to the caller
        // No fees are ever taken on post-op sync
        state = SyncedAccountingState(
            _stRawNAV, _jtRawNAV, $.lastSTEffectiveNAV, $.lastJTEffectiveNAV, $.lastSTCoverageDebt, $.lastJTCoverageDebt, ZERO_NAV_UNITS, ZERO_NAV_UNITS
        );
        // Enforce the NAV conservation invariant
        require((_stRawNAV + _jtRawNAV) == (state.stEffectiveNAV + state.jtEffectiveNAV), NAV_CONSERVATION_VIOLATION());
    }

    /// @inheritdoc IRoycoAccountant
    function postOpSyncTrancheAccountingAndEnforceCoverage(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        Operation _op
    )
        external
        override(IRoycoAccountant)
        onlyRoycoKernel
        returns (SyncedAccountingState memory state)
    {
        // Execute a post-op NAV synchronization
        state = postOpSyncTrancheAccounting(_stRawNAV, _jtRawNAV, _op);
        // Enforce the market's coverage requirement
        require(isCoverageRequirementSatisfied(), COVERAGE_REQUIREMENT_UNSATISFIED());
    }

    /**
     * @inheritdoc IRoycoAccountant
     * @dev Junior capital must be sufficient to absorb losses to the senior exposure up to the coverage ratio
     * @dev Informally: junior loss absorbtion buffer >= total covered exposure
     * @dev Formally: JT_EFFECTIVE_NAV >= (ST_RAW_NAV + (JT_RAW_NAV * BETA_%)) * COV_%
     *      JT_EFFECTIVE_NAV is JT's current loss absorbtion buffer after applying all prior JT yield accrual and coverage adjustments
     *      ST_RAW_NAV and JT_RAW_NAV are the mark-to-market NAVs of the tranches
     *      BETA_% is the JT's sensitivity to the same downside stress that affects ST (eg. 0 if JT is in RFR and 1 if JT and ST are in the same opportunity)
     * @dev If we rearrange the coverage requirement, we get:
     *      1 >= ((ST_RAW_NAV + (JT_RAW_NAV * BETA_%)) * COV_%) / JT_EFFECTIVE_NAV
     *      Notice that the RHS is identical to how we define utilization
     *      Hence, the coverage requirement can be written as 1 >= Utilization, or equivalently, Utilization <= 1
     */
    function isCoverageRequirementSatisfied() public view override(IRoycoAccountant) returns (bool) {
        // Get the storage pointer to the base kernel state
        RoycoAccountantState storage $ = RoycoAccountantStorageLib._getRoycoAccountantStorage();
        // Compute the utilization and return whether or not the senior tranche is properly collateralized based on persisted NAVs
        uint256 utilization = UtilsLib.computeUtilization($.lastSTRawNAV, $.lastJTRawNAV, $.betaWAD, $.coverageWAD, $.lastJTEffectiveNAV);
        return (utilization <= WAD);
    }

    /**
     * @inheritdoc IRoycoAccountant
     * @dev Coverage Invariant: JT_EFFECTIVE_NAV >= (ST_RAW_NAV + (JT_RAW_NAV * BETA_%)) * COV_%
     * @dev Max assets depositable into ST, x: JT_EFFECTIVE_NAV = ((ST_RAW_NAV + x) + (JT_RAW_NAV * BETA_%)) * COV_%
     *      Isolate x: x = (JT_EFFECTIVE_NAV / COV_%) - (JT_RAW_NAV * BETA_%) - ST_RAW_NAV
     */
    function maxSTDepositGivenCoverage(NAV_UNIT _stRawNAV, NAV_UNIT _jtRawNAV) external view override(IRoycoAccountant) returns (NAV_UNIT) {
        // Get the storage pointer to the base kernel state
        RoycoAccountantState storage $ = RoycoAccountantStorageLib._getRoycoAccountantStorage();
        // Preview a NAV sync to get the market's current state
        (SyncedAccountingState memory state,) = _previewSyncTrancheAccounting(_stRawNAV, _jtRawNAV, _previewJTYieldShareAccrual());
        // Solve for x, rounding in favor of senior protection
        // Compute the total covered assets by the junior tranche loss absorption buffer
        NAV_UNIT totalCoveredAssets = state.jtEffectiveNAV.mulDiv(WAD, $.coverageWAD, Math.Rounding.Floor);
        // Compute the assets required to cover current junior tranche exposure
        NAV_UNIT jtCoverageRequired = _jtRawNAV.mulDiv($.betaWAD, WAD, Math.Rounding.Ceil);
        // Compute the assets required to cover current senior tranche exposure
        NAV_UNIT stCoverageRequired = _stRawNAV;
        // Compute the amount of assets that can be deposited into senior while retaining full coverage
        return totalCoveredAssets.saturatingSub(jtCoverageRequired).saturatingSub(stCoverageRequired);
    }

    /**
     * @inheritdoc IRoycoAccountant
     * @dev Coverage Invariant: JT_EFFECTIVE_NAV >= (ST_RAW_NAV + (JT_RAW_NAV * BETA_%)) * COV_%
     * @dev Max assets withdrawable from JT, y: (JT_EFFECTIVE_NAV - y) = (ST_RAW_NAV + ((JT_RAW_NAV - y) * BETA_%)) * COV_%
     *      Isolate y: y = (JT_EFFECTIVE_NAV - (COV_% * (ST_RAW_NAV + (JT_RAW_NAV * BETA_%)))) / (1 - (BETA_% * COV_%))
     */
    function maxJTWithdrawalGivenCoverage(NAV_UNIT _stRawNAV, NAV_UNIT _jtRawNAV) external view override(IRoycoAccountant) returns (NAV_UNIT) {
        // Get the storage pointer to the base kernel state and cache beta and coverage
        RoycoAccountantState storage $ = RoycoAccountantStorageLib._getRoycoAccountantStorage();
        uint256 betaWAD = $.betaWAD;
        uint256 coverageWAD = $.coverageWAD;
        // Preview a NAV sync to get the market's current state
        (SyncedAccountingState memory state,) = _previewSyncTrancheAccounting(_stRawNAV, _jtRawNAV, _previewJTYieldShareAccrual());
        // Solve for y, rounding in favor of senior protection
        // Compute the total covered exposure of the underlying investment
        NAV_UNIT totalCoveredExposure = _stRawNAV + _jtRawNAV.mulDiv(betaWAD, WAD, Math.Rounding.Ceil);
        // Compute the minimum junior tranche assets required to cover the exposure as per the market's coverage requirement
        NAV_UNIT requiredJTAssets = totalCoveredExposure.mulDiv(coverageWAD, WAD, Math.Rounding.Ceil);
        // Compute the surplus coverage currently provided by the junior tranche based on its currently remaining loss-absorption buffer
        NAV_UNIT surplusJTAssets = UnitsMathLib.saturatingSub(state.jtEffectiveNAV, requiredJTAssets);
        // Compute how much coverage the system retains per 1 unit of JT assets withdrawn scaled to WAD precision
        uint256 coverageRetentionWAD = WAD - betaWAD.mulDiv(coverageWAD, WAD, Math.Rounding.Floor);
        // Return how much of the surplus can be withdrawn while satisfying the coverage requirement
        return surplusJTAssets.mulDiv(WAD, coverageRetentionWAD, Math.Rounding.Floor);
    }

    /**
     * @notice Syncs all tranche NAVs and debts based on unrealized PNLs of the underlying investment(s)
     * @param _stRawNAV The senior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the pure value of its invested assets
     * @param _twJTYieldShareAccruedWAD The currently accrued time-weighted JT yield share RDM output since the last distribution, scaled to WAD precision
     * @return state A struct containing all synced NAV, debt, and fee data after executing the sync
     * @return yieldDistributed A boolean indicating whether ST yield was split between ST and JT
     */
    function _previewSyncTrancheAccounting(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        uint192 _twJTYieldShareAccruedWAD
    )
        internal
        view
        returns (SyncedAccountingState memory state, bool yieldDistributed)
    {
        // Get the storage pointer to the base kernel state
        RoycoAccountantState storage $ = RoycoAccountantStorageLib._getRoycoAccountantStorage();

        // Compute the deltas in the raw NAVs of each tranche
        // The deltas represent the unrealized PNL of the underlying investment since the last NAV checkpoints
        int256 deltaST = UnitsMathLib.computeNAVDelta(_stRawNAV, $.lastSTRawNAV);
        int256 deltaJT = UnitsMathLib.computeNAVDelta(_jtRawNAV, $.lastJTRawNAV);

        // Cache the last checkpointed effective NAV and coverage debt for each tranche
        NAV_UNIT stEffectiveNAV = $.lastSTEffectiveNAV;
        NAV_UNIT jtEffectiveNAV = $.lastJTEffectiveNAV;
        NAV_UNIT stCoverageDebt = $.lastSTCoverageDebt;
        NAV_UNIT jtCoverageDebt = $.lastJTCoverageDebt;
        NAV_UNIT stProtocolFeeAccrued;
        NAV_UNIT jtProtocolFeeAccrued;

        /// @dev STEP_APPLY_JT_LOSS: The JT assets depreciated in value
        if (deltaJT < 0) {
            /// @dev STEP_JT_ABSORB_LOSS: JT's remaning loss-absorption buffer incurs as much of the loss as possible
            NAV_UNIT jtLoss = toNAVUnits(-deltaJT);
            NAV_UNIT jtAbsorbableLoss = UnitsMathLib.min(jtLoss, jtEffectiveNAV);
            if (jtAbsorbableLoss != ZERO_NAV_UNITS) {
                // Incur the maximum absorbable losses to remaining JT loss capital
                jtEffectiveNAV = (jtEffectiveNAV - jtAbsorbableLoss);
                // Reduce the residual JT loss by the loss absorbed
                jtLoss = (jtLoss - jtAbsorbableLoss);
            }
            /// @dev STEP_ST_INCURS_RESIDUAL_LOSSES: Residual loss after emptying JT's remaning loss-absorption buffer are incurred by ST
            if (jtLoss != ZERO_NAV_UNITS) {
                // The excess loss is absorbed by ST
                stEffectiveNAV = (stEffectiveNAV - jtLoss);
                // Repay ST debt to JT
                // This is equivalent to retroactively reducing previously applied coverage
                // Thus, the liability is flipped to JT debt to ST
                stCoverageDebt = (stCoverageDebt - jtLoss);
                jtCoverageDebt = (jtCoverageDebt + jtLoss);
            }
            /// @dev STEP_APPLY_JT_GAIN: The JT assets appreciated in value
        } else if (deltaJT > 0) {
            NAV_UNIT jtGain = toNAVUnits(deltaJT);
            /// @dev STEP_REPAY_JT_COVERAGE_DEBT: Pay off any JT debt to ST (previously uncovered losses)
            NAV_UNIT jtDebtRepayment = UnitsMathLib.min(jtGain, jtCoverageDebt);
            if (jtDebtRepayment != ZERO_NAV_UNITS) {
                // Repay JT debt to ST
                // This is equivalent to retroactively applying coverage for previously uncovered losses
                // Thus, the liability is flipped to ST debt to JT
                jtCoverageDebt = (jtCoverageDebt - jtDebtRepayment);
                stCoverageDebt = (stCoverageDebt + jtDebtRepayment);
                // Apply the repayment (retroactive coverage) to the ST
                stEffectiveNAV = (stEffectiveNAV + jtDebtRepayment);
                jtGain = (jtGain - jtDebtRepayment);
            }
            /// @dev STEP_JT_ACCRUES_RESIDUAL_GAINS: JT accrues any remaining appreciation after repaying liabilities
            if (jtGain != ZERO_NAV_UNITS) {
                // Compute the protocol fee taken on this JT yield accrual - will be used to mint JT shares to the protocol fee recipient at the updated JT effective NAV
                jtProtocolFeeAccrued = jtGain.mulDiv($.protocolFeeWAD, WAD, Math.Rounding.Floor);
                // Book the residual gains to the JT
                jtEffectiveNAV = (jtEffectiveNAV + jtGain);
            }
        }

        /// @dev STEP_APPLY_ST_LOSS: The ST assets depreciated in value
        if (deltaST < 0) {
            NAV_UNIT stLoss = toNAVUnits(-deltaST);
            /// @dev STEP_APPLY_JT_COVERAGE_TO_ST: Apply any possible coverage to ST provided by JT's loss-absorption buffer
            NAV_UNIT coverageApplied = UnitsMathLib.min(stLoss, jtEffectiveNAV);
            if (coverageApplied != ZERO_NAV_UNITS) {
                jtEffectiveNAV = (jtEffectiveNAV - coverageApplied);
                // Any coverage provided is a ST liability to JT
                stCoverageDebt = (stCoverageDebt + coverageApplied);
            }
            /// @dev STEP_ST_INCURS_RESIDUAL_LOSSES: Apply any uncovered losses by JT to ST
            NAV_UNIT netStLoss = stLoss - coverageApplied;
            if (netStLoss != ZERO_NAV_UNITS) {
                // Apply residual losses to ST
                stEffectiveNAV = (stEffectiveNAV - netStLoss);
                // The uncovered portion of the ST loss is a JT liability to ST
                jtCoverageDebt = (jtCoverageDebt + netStLoss);
            }
            /// @dev STEP_APPLY_ST_GAIN: The ST assets appreciated in value
        } else if (deltaST > 0) {
            NAV_UNIT stGain = toNAVUnits(deltaST);
            /// @dev STEP_REPAY_JT_COVERAGE_DEBT: The first priority of repayment to reverse the loss-waterfall is making ST whole again
            // Repay JT debt to ST: previously uncovered ST losses
            NAV_UNIT debtRepayment = UnitsMathLib.min(stGain, jtCoverageDebt);
            if (debtRepayment != ZERO_NAV_UNITS) {
                // Pay back JT debt to ST: making ST whole again
                stEffectiveNAV = (stEffectiveNAV + debtRepayment);
                jtCoverageDebt = (jtCoverageDebt - debtRepayment);
                // Deduct the repayment from the ST gains and return if no gains are left
                stGain = (stGain - debtRepayment);
            }
            /// @dev STEP_REPAY_ST_COVERAGE_DEBT: The second priority of repayment to reverse the loss-waterfall is making JT whole again
            // Repay ST debt to JT: previously applied coverage from JT to ST
            debtRepayment = UnitsMathLib.min(stGain, stCoverageDebt);
            if (debtRepayment != ZERO_NAV_UNITS) {
                // Pay back ST debt to JT: making JT whole again
                jtEffectiveNAV = (jtEffectiveNAV + debtRepayment);
                stCoverageDebt = (stCoverageDebt - debtRepayment);
                // Deduct the repayment from the remaining ST gains and return if no gains are left
                stGain = (stGain - debtRepayment);
            }
            /// @dev STEP_DISTRIBUTE_YIELD: There are no remaining debts in the system, the residual gains will be used to distribute yield to both tranches
            if (stGain != ZERO_NAV_UNITS) {
                // Bring the twJTYieldShareAccruedWAD to the top of the stack
                uint256 twJTYieldShareAccruedWAD = _twJTYieldShareAccruedWAD;
                // Compute the time weighted average JT share of yield
                uint256 elapsed = block.timestamp - $.lastDistributionTimestamp;
                uint256 protocolFeeWAD = $.protocolFeeWAD;
                // If the last yield distribution wasn't in this block, split the yield between ST and JT
                if (elapsed != 0) {
                    // Compute the ST gain allocated to JT based on its time weighted yield share since the last distribution, rounding in favor of the senior tranche
                    NAV_UNIT jtGain = stGain.mulDiv(twJTYieldShareAccruedWAD, (elapsed * WAD), Math.Rounding.Floor);
                    // Apply the yield split to JT's effective NAV
                    if (jtGain != ZERO_NAV_UNITS) {
                        // Compute the protocol fee taken on this JT yield accrual (will be used to mint shares to the protocol fee recipient) at the updated JT effective NAV
                        jtProtocolFeeAccrued = (jtProtocolFeeAccrued + jtGain.mulDiv(protocolFeeWAD, WAD, Math.Rounding.Floor));
                        jtEffectiveNAV = (jtEffectiveNAV + jtGain);
                        stGain = (stGain - jtGain);
                    }
                }
                // Compute the protocol fee taken on this ST yield accrual (will be used to mint shares to the protocol fee recipient) at the updated JT effective NAV
                stProtocolFeeAccrued = stGain.mulDiv(protocolFeeWAD, WAD, Math.Rounding.Floor);
                // Book the residual gain to the ST
                stEffectiveNAV = (stEffectiveNAV + stGain);
                // Mark yield as distributed
                yieldDistributed = true;
            }
        }
        // Enforce the NAV conservation invariant
        require((_stRawNAV + _jtRawNAV) == (stEffectiveNAV + jtEffectiveNAV), NAV_CONSERVATION_VIOLATION());
        // Construct the synced NAVs state to return to the caller
        state = SyncedAccountingState(
            _stRawNAV, _jtRawNAV, stEffectiveNAV, jtEffectiveNAV, stCoverageDebt, jtCoverageDebt, stProtocolFeeAccrued, jtProtocolFeeAccrued
        );
    }

    /**
     * @notice Accrues the JT yield share since the last yield distribution
     * @dev Gets the instantaneous JT yield share and accumulates it over the time elapsed since the last accrual
     * @return The updated time-weighted JT yield share since the last yield distribution
     */
    function _accrueJTYieldShare() internal returns (uint192) {
        // Get the storage pointer to the base kernel state
        RoycoAccountantState storage $ = RoycoAccountantStorageLib._getRoycoAccountantStorage();

        // Get the last update timestamp
        uint256 lastUpdate = $.lastAccrualTimestamp;
        if (lastUpdate == 0) {
            $.lastAccrualTimestamp = uint32(block.timestamp);
            return 0;
        }

        // Compute the elapsed time since the last update
        uint256 elapsed = block.timestamp - lastUpdate;
        // Preemptively return if last accrual was in the same block
        if (elapsed == 0) return $.twJTYieldShareAccruedWAD;

        // Get the instantaneous JT yield share, scaled to WAD precision
        uint256 jtYieldShareWAD = IRDM($.rdm).jtYieldShare($.lastSTRawNAV, $.lastJTRawNAV, $.betaWAD, $.coverageWAD, $.lastJTEffectiveNAV);
        // TODO: Should we revert instead? Don't want to DOS system on faulty RDM, so this seems like the best possible way to handle
        if (jtYieldShareWAD > WAD) jtYieldShareWAD = WAD;
        // Accrue the time-weighted yield share accrued to JT since the last tranche interaction
        $.lastAccrualTimestamp = uint32(block.timestamp);
        return ($.twJTYieldShareAccruedWAD += uint192(jtYieldShareWAD * elapsed));
    }

    /**
     * @notice Computes and returns the currently accrued JT yield share since the last yield distribution
     * @dev Gets the instantaneous JT yield share and accumulates it over the time elapsed since the last accrual
     * @return The updated time-weighted JT yield share since the last yield distribution
     */
    function _previewJTYieldShareAccrual() internal view returns (uint192) {
        // Get the storage pointer to the base kernel state
        RoycoAccountantState storage $ = RoycoAccountantStorageLib._getRoycoAccountantStorage();

        // Get the last update timestamp
        uint256 lastUpdate = $.lastAccrualTimestamp;
        if (lastUpdate == 0) return 0;

        // Compute the elapsed time since the last update
        uint256 elapsed = block.timestamp - lastUpdate;
        // Preemptively return if last accrual was in the same block
        if (elapsed == 0) return $.twJTYieldShareAccruedWAD;

        // Get the instantaneous JT yield share, scaled to WAD precision
        uint256 jtYieldShareWAD = IRDM($.rdm).previewJTYieldShare($.lastSTRawNAV, $.lastJTRawNAV, $.betaWAD, $.coverageWAD, $.lastJTEffectiveNAV);
        // TODO: Should we revert instead? Don't want to DOS system on faulty RDM, so this seems like the best possible way to handle
        if (jtYieldShareWAD > WAD) jtYieldShareWAD = WAD;
        // Apply the accural of JT yield share to the accumulator, weighted by the time elapsed
        return ($.twJTYieldShareAccruedWAD + uint192(jtYieldShareWAD * elapsed));
    }

    /// @inheritdoc IRoycoAccountant
    function setRDM(address _rdm) external override(IRoycoAccountant) restricted {
        // Ensure that the RDM is not null
        require(_rdm != address(0), NULL_RDM_ADDRESS());
        // Set the new RDM
        RoycoAccountantStorageLib._getRoycoAccountantStorage().rdm = _rdm;
    }

    /// @inheritdoc IRoycoAccountant
    function setProtocolFee(uint64 _protocolFeeWAD) external override(IRoycoAccountant) restricted {
        // Ensure that the protocol fee percentage is valid
        require(_protocolFeeWAD <= MAX_PROTOCOL_FEE_WAD, MAX_PROTOCOL_FEE_EXCEEDED());
        // Set the new protocol fee percentage
        RoycoAccountantStorageLib._getRoycoAccountantStorage().protocolFeeWAD = _protocolFeeWAD;
    }

    /// @inheritdoc IRoycoAccountant
    function setCoverage(uint64 _coverageWAD) external override(IRoycoAccountant) restricted {
        RoycoAccountantState storage $ = RoycoAccountantStorageLib._getRoycoAccountantStorage();
        // Validate the new coverage requirement
        _validateCoverageRequirement(_coverageWAD, $.betaWAD);
        // Set the new coverage percentage
        $.coverageWAD = _coverageWAD;
    }

    /// @inheritdoc IRoycoAccountant
    function setBeta(uint96 _betaWAD) external override(IRoycoAccountant) restricted {
        RoycoAccountantState storage $ = RoycoAccountantStorageLib._getRoycoAccountantStorage();
        // Validate the new coverage requirement
        _validateCoverageRequirement($.coverageWAD, _betaWAD);
        // Set the new beta parameter
        $.betaWAD = _betaWAD;
    }

    /// @inheritdoc IRoycoAccountant
    function getState() external view override(IRoycoAccountant) returns (RoycoAccountantState memory) {
        return RoycoAccountantStorageLib._getRoycoAccountantStorage();
    }

    /// @notice Validates the coverage requirement parameters of the market
    /// @param _coverageWAD The coverage ratio that the senior tranche is expected to be protected by, scaled to WAD precision
    /// @param _betaWAD The JT's sensitivity to the same downside stress that affects ST, scaled to WAD precision
    /// @dev Ensures coverage is within bounds and prevents JT withdrawal lockup
    /// @dev Coverage must be >= MIN_COVERAGE_WAD and < WAD to maintain valid range
    /// @dev The product of coverage and beta must be < WAD to prevent permanent withdrawal blocking
    function _validateCoverageRequirement(uint64 _coverageWAD, uint96 _betaWAD) internal pure {
        // Ensure that the coverage requirement is valid
        require((_coverageWAD >= MIN_COVERAGE_WAD) && (_coverageWAD < WAD), INVALID_COVERAGE_CONFIG());
        // Ensure that JT withdrawals are not permanently bricked
        require(uint256(_coverageWAD).mulDiv(_betaWAD, WAD, Math.Rounding.Ceil) < WAD, INVALID_COVERAGE_CONFIG());
    }
}
