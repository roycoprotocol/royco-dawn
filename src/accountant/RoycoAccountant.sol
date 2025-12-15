// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Initializable } from "../../lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import { IRDM } from "../interfaces/IRDM.sol";
import { IRoycoAccountant, Operation } from "../interfaces/IRoycoAccountant.sol";

import { IRoycoVaultTranche } from "../interfaces/tranche/IRoycoVaultTranche.sol";
import { RoycoAccountantInitParams, RoycoAccountantState, RoycoAccountantStorageLib } from "../libraries/RoycoAccountantStorageLib.sol";
import { SyncedNAVsPacket } from "../libraries/Types.sol";
import { ConstantsLib, Math, UtilsLib } from "../libraries/UtilsLib.sol";

contract RoycoAccountant is Initializable, IRoycoAccountant {
    using Math for uint256;

    /// @dev Enforces that the function is called by the accountant's Royco kernel
    modifier onlyRoycoKernel() {
        require(msg.sender == RoycoAccountantStorageLib._getRoycoAccountantStorage().kernel, ONLY_ROYCO_KERNEL());
        _;
    }

    /**
     * @notice Initializes the Royco accountant state
     * @param _params The initialization parameters for the Royco accountant
     */
    function initialize(RoycoAccountantInitParams calldata _params) internal initializer {
        // Ensure that the coverage requirement is valid
        require(_params.coverageWAD < ConstantsLib.WAD && _params.coverageWAD >= ConstantsLib.MIN_COVERAGE_WAD, INVALID_COVERAGE_CONFIG());
        // Ensure that JT withdrawals are not permanently bricked
        require(uint256(_params.coverageWAD).mulDiv(_params.betaWAD, ConstantsLib.WAD, Math.Rounding.Ceil) < ConstantsLib.WAD, INVALID_COVERAGE_CONFIG());
        // Ensure that the RDM is not null
        require(_params.rdm != address(0), NULL_RDM_ADDRESS());
        // Ensure that the protocol fee configuration is valid
        require(_params.protocolFeeWAD <= ConstantsLib.MAX_PROTOCOL_FEE_WAD, MAX_PROTOCOL_FEE_EXCEEDED());
        // Initialize the state of the accountant
        RoycoAccountantStorageLib.__RoycoAccountant_init(_params);
    }

    /// @inheritdoc IRoycoAccountant
    function preOpSyncTrancheNAVs(
        uint256 _stRawNAV,
        uint256 _jtRawNAV
    )
        external
        override(IRoycoAccountant)
        onlyRoycoKernel
        returns (SyncedNAVsPacket memory packet)
    {
        // Get the storage pointer to the base kernel state
        RoycoAccountantState storage $ = RoycoAccountantStorageLib._getRoycoAccountantStorage();

        // Preview the new NAVs and protocol fees accrued for each tranche based on PNL(s) of the underlying investment(s)
        uint192 twJTYieldShareAccruedWAD;
        bool yieldDistributed;
        (packet, twJTYieldShareAccruedWAD, yieldDistributed) = previewSyncTrancheNAVs(_stRawNAV, _jtRawNAV);

        // Accrue the time-weighted yield share accrued to JT since the last tranche interaction
        $.twJTYieldShareAccruedWAD = twJTYieldShareAccruedWAD;
        $.lastAccrualTimestamp = uint32(block.timestamp);

        // ST yield was split between ST and JT
        if (yieldDistributed) {
            // Reset the accumulator and update the last yield distribution timestamp
            delete $.twJTYieldShareAccruedWAD;
            $.lastDistributionTimestamp = uint32(block.timestamp);
        }

        // Checkpoint the mark to market NAVs and debts
        $.lastSTRawNAV = _stRawNAV;
        $.lastJTRawNAV = _jtRawNAV;
        $.lastSTEffectiveNAV = packet.stEffectiveNAV;
        $.lastJTEffectiveNAV = packet.jtEffectiveNAV;
        $.lastSTCoverageDebt = packet.stCoverageDebt;
        $.lastJTCoverageDebt = packet.jtCoverageDebt;
    }

    /// @inheritdoc IRoycoAccountant
    function previewSyncTrancheNAVs(
        uint256 _stRawNAV,
        uint256 _jtRawNAV
    )
        public
        view
        override(IRoycoAccountant)
        returns (SyncedNAVsPacket memory packet, uint192 twJTYieldShareAccruedWAD, bool yieldDistributed)
    {
        // Get the storage pointer to the base kernel state
        RoycoAccountantState storage $ = RoycoAccountantStorageLib._getRoycoAccountantStorage();

        // Preview the time-weighted yield share accrued to JT since the last tranche interaction
        twJTYieldShareAccruedWAD = _previewJTYieldShareAccrual();

        // Compute the deltas in the raw NAVs of each tranche
        // The deltas represent the unrealized PNL of the underlying investment since the last NAV checkpoints
        int256 deltaST = _computeRawNAVDelta(_stRawNAV, $.lastSTRawNAV);
        int256 deltaJT = _computeRawNAVDelta(_jtRawNAV, $.lastJTRawNAV);

        // Cache the last checkpointed effective NAV and coverage debt for each tranche
        uint256 stEffectiveNAV = $.lastSTEffectiveNAV;
        uint256 jtEffectiveNAV = $.lastJTEffectiveNAV;
        uint256 stCoverageDebt = $.lastSTCoverageDebt;
        uint256 jtCoverageDebt = $.lastJTCoverageDebt;
        uint256 stProtocolFeeAccrued;
        uint256 jtProtocolFeeAccrued;

        /// @dev STEP_APPLY_JT_LOSS: The JT assets depreciated in value
        if (deltaJT < 0) {
            /// @dev STEP_JT_ABSORB_LOSS: JT's remaning loss-absorption buffer incurs as much of the loss as possible
            uint256 jtLoss = uint256(-deltaJT);
            uint256 jtAbsorbableLoss = Math.min(jtLoss, jtEffectiveNAV);
            if (jtAbsorbableLoss != 0) {
                // Incur the maximum absorbable losses to remaining JT loss capital
                jtEffectiveNAV -= jtAbsorbableLoss;
                // Reduce the residual JT loss by the loss absorbed
                jtLoss -= jtAbsorbableLoss;
            }
            /// @dev STEP_ST_INCURS_RESIDUAL_LOSSES: Residual loss after emptying JT's remaning loss-absorption buffer are incurred by ST
            if (jtLoss != 0) {
                // The excess loss is absorbed by ST
                stEffectiveNAV -= jtLoss;
                // Repay ST debt to JT
                // This is equivalent to retroactively reducing previously applied coverage
                // Thus, the liability is flipped to JT debt to ST
                stCoverageDebt -= jtLoss;
                jtCoverageDebt += jtLoss;
            }
            /// @dev STEP_APPLY_JT_GAIN: The JT assets appreciated in value
        } else if (deltaJT > 0) {
            uint256 jtGain = uint256(deltaJT);
            /// @dev STEP_REPAY_JT_COVERAGE_DEBT: Pay off any JT debt to ST (previously uncovered losses)
            uint256 jtDebtRepayment = Math.min(jtGain, jtCoverageDebt);
            if (jtDebtRepayment != 0) {
                // Repay JT debt to ST
                // This is equivalent to retroactively applying coverage for previously uncovered losses
                // Thus, the liability is flipped to ST debt to JT
                jtCoverageDebt -= jtDebtRepayment;
                stCoverageDebt += jtDebtRepayment;
                // Apply the repayment (retroactive coverage) to the ST
                stEffectiveNAV += jtDebtRepayment;
                jtGain -= jtDebtRepayment;
            }
            /// @dev STEP_JT_ACCRUES_RESIDUAL_GAINS: JT accrues any remaining appreciation after repaying liabilities
            if (jtGain != 0) {
                // Compute the protocol fee taken on this JT yield accrual - will be used to mint JT shares to the protocol fee recipient at the updated JT effective NAV
                jtProtocolFeeAccrued = jtGain.mulDiv($.protocolFeeWAD, ConstantsLib.WAD, Math.Rounding.Floor);
                // Book the residual gains to the JT
                jtEffectiveNAV += jtGain;
            }
        }

        /// @dev STEP_APPLY_ST_LOSS: The ST assets depreciated in value
        if (deltaST < 0) {
            uint256 stLoss = uint256(-deltaST);
            /// @dev STEP_APPLY_JT_COVERAGE_TO_ST: Apply any possible coverage to ST provided by JT's loss-absorption buffer
            uint256 coverageApplied = Math.min(stLoss, jtEffectiveNAV);
            if (coverageApplied != 0) {
                jtEffectiveNAV -= coverageApplied;
                // Any coverage provided is a ST liability to JT
                stCoverageDebt += coverageApplied;
            }
            /// @dev STEP_ST_INCURS_RESIDUAL_LOSSES: Apply any uncovered losses by JT to ST
            uint256 netStLoss = stLoss - coverageApplied;
            if (netStLoss != 0) {
                // Apply residual losses to ST
                stEffectiveNAV -= netStLoss;
                // The uncovered portion of the ST loss is a JT liability to ST
                jtCoverageDebt += netStLoss;
            }
            /// @dev STEP_APPLY_ST_GAIN: The ST assets appreciated in value
        } else if (deltaST > 0) {
            uint256 stGain = uint256(deltaST);
            /// @dev STEP_REPAY_JT_COVERAGE_DEBT: The first priority of repayment to reverse the loss-waterfall is making ST whole again
            // Repay JT debt to ST: previously uncovered ST losses
            uint256 debtRepayment = Math.min(stGain, jtCoverageDebt);
            if (debtRepayment != 0) {
                // Pay back JT debt to ST: making ST whole again
                stEffectiveNAV += debtRepayment;
                jtCoverageDebt -= debtRepayment;
                // Deduct the repayment from the ST gains and return if no gains are left
                stGain -= debtRepayment;
            }
            /// @dev STEP_REPAY_ST_COVERAGE_DEBT: The second priority of repayment to reverse the loss-waterfall is making JT whole again
            // Repay ST debt to JT: previously applied coverage from JT to ST
            debtRepayment = Math.min(stGain, stCoverageDebt);
            if (debtRepayment != 0) {
                // Pay back ST debt to JT: making JT whole again
                jtEffectiveNAV += debtRepayment;
                stCoverageDebt -= debtRepayment;
                // Deduct the repayment from the remaining ST gains and return if no gains are left
                stGain -= debtRepayment;
            }
            /// @dev STEP_DISTRIBUTE_YIELD: There are no remaining debts in the system, the residual gains will be used to distribute yield to both tranches
            if (stGain != 0) {
                // Compute the time weighted average JT share of yield
                uint256 elapsed = block.timestamp - $.lastDistributionTimestamp;
                uint256 protocolFeeWAD = $.protocolFeeWAD;
                // If the last yield distribution wasn't in this block, split the yield between ST and JT
                if (elapsed != 0) {
                    // Compute the ST gain allocated to JT based on its time weighted yield share since the last distribution, rounding in favor of the senior tranche
                    uint256 jtGain = stGain.mulDiv((twJTYieldShareAccruedWAD / elapsed), ConstantsLib.WAD, Math.Rounding.Floor);
                    // Apply the yield split to JT's effective NAV
                    if (jtGain != 0) {
                        // Compute the protocol fee taken on this JT yield accrual (will be used to mint shares to the protocol fee recipient) at the updated JT effective NAV
                        jtProtocolFeeAccrued += jtGain.mulDiv(protocolFeeWAD, ConstantsLib.WAD, Math.Rounding.Floor);
                        jtEffectiveNAV += jtGain;
                        stGain -= jtGain;
                    }
                    yieldDistributed = true;
                }
                // Compute the protocol fee taken on this ST yield accrual (will be used to mint shares to the protocol fee recipient) at the updated JT effective NAV
                stProtocolFeeAccrued = stGain.mulDiv(protocolFeeWAD, ConstantsLib.WAD, Math.Rounding.Floor);
                // Book the residual gain to the ST
                stEffectiveNAV += stGain;
            }
        }
        // Enforce the NAV conservation invariant
        require((_stRawNAV + _jtRawNAV) == (stEffectiveNAV + jtEffectiveNAV), NAV_CONSERVATION_VIOLATION());
        // Construct the synced NAVs packet to return to the caller
        packet =
            SyncedNAVsPacket(_stRawNAV, _jtRawNAV, stEffectiveNAV, jtEffectiveNAV, stCoverageDebt, jtCoverageDebt, stProtocolFeeAccrued, jtProtocolFeeAccrued);
    }

    /// @inheritdoc IRoycoAccountant
    function postOpSyncTrancheNAVs(uint256 _stRawNAV, uint256 _jtRawNAV, Operation _op) public override(IRoycoAccountant) onlyRoycoKernel {
        // Get the storage pointer to the base kernel state
        RoycoAccountantState storage $ = RoycoAccountantStorageLib._getRoycoAccountantStorage();
        if (_op == Operation.ST_DEPOSIT) {
            // Compute the delta in the raw NAV of the senior tranche: deposits must increase NAV
            int256 deltaST = _computeRawNAVDelta(_stRawNAV, $.lastSTRawNAV);
            require(deltaST > 0, INVALID_POST_OP_STATE(_op));
            // Update the post-operation raw NAV ST checkpoint
            $.lastSTRawNAV = _stRawNAV;
            // Apply the deposit to the senior tranche's effective NAV
            $.lastSTEffectiveNAV += uint256(deltaST);
        } else if (_op == Operation.JT_DEPOSIT) {
            // Compute the delta in the raw NAV of the junior tranche: deposits must increase NAV
            int256 deltaJT = _computeRawNAVDelta(_jtRawNAV, $.lastJTRawNAV);
            require(deltaJT > 0, INVALID_POST_OP_STATE(_op));
            // Update the post-operation raw NAV ST checkpoint
            $.lastJTRawNAV = _jtRawNAV;
            // Apply the deposit to the junior tranche's effective NAV
            $.lastJTEffectiveNAV += uint256(deltaJT);
        } else {
            // Compute the deltas in the raw NAVs of each tranche after an operation's execution and cache the raw NAVs
            // The deltas represent the NAV changes after a deposit and withdrawal
            int256 deltaST = _computeRawNAVDelta(_stRawNAV, $.lastSTRawNAV);
            int256 deltaJT = _computeRawNAVDelta(_jtRawNAV, $.lastJTRawNAV);

            // Update the post-operation raw NAV checkpoints
            $.lastSTRawNAV = _stRawNAV;
            $.lastJTRawNAV = _jtRawNAV;

            if (_op == Operation.ST_WITHDRAW) {
                // ST withdrawals must decrease ST NAV and leave JT NAV decreased or unchanged (coverage realization)
                // Or they must leave ST NAV unchanged and decrease JT NAV (pure coverage realization)
                require((deltaST < 0 && deltaJT <= 0) || (deltaST == 0 && deltaJT < 0), INVALID_POST_OP_STATE(_op));
                // Senior withdrew: The NAV deltas include the discrete withdrawal amount in addition to any coverage pulled from JT to ST
                // If the withdrawal used JT capital as coverage to facilitate this ST withdrawal
                uint256 preWithdrawalSTEffectiveNAV = $.lastSTEffectiveNAV;
                if (deltaJT < 0) {
                    // The actual amount withdrawn was the delta in ST raw NAV and the coverage applied from JT
                    uint256 coverageRealized = uint256(-deltaJT);
                    $.lastSTEffectiveNAV = preWithdrawalSTEffectiveNAV - (uint256(-deltaST) + coverageRealized);
                    // The withdrawing senior LP has realized its proportional share of past covered losses, settling the realized portion between JT and ST
                    $.lastSTCoverageDebt -= coverageRealized;
                } else {
                    // Apply the withdrawal to the senior tranche's effective NAV
                    $.lastSTEffectiveNAV = preWithdrawalSTEffectiveNAV - uint256(-deltaST);
                }
                // The withdrawing senior LP has realized its proportional share of past uncovered losses and associated recovery optionality
                // Round in favor of senior
                uint256 jtCoverageDebt = $.lastJTCoverageDebt;
                if (jtCoverageDebt != 0) {
                    $.lastJTCoverageDebt = jtCoverageDebt.mulDiv($.lastSTEffectiveNAV, preWithdrawalSTEffectiveNAV, Math.Rounding.Ceil);
                }
            } else if (_op == Operation.JT_WITHDRAW) {
                // JT withdrawals must decrease JT NAV and leave ST NAV decreased or unchanged (yield claiming)
                require(deltaJT < 0 && deltaST <= 0, INVALID_POST_OP_STATE(_op));
                // Junior withdrew: The NAV deltas include the discrete withdrawal amount in addition to any assets (yield + debt repayments) pulled from ST to JT
                // JT LPs cannot settle debts on withdrawal since they don't have discretion on when coverage applied to ST (stCoverageDebt) and uncovered ST losses (jtCoverageDebt) can be realized
                // If ST delta was negative, the actual amount withdrawn by JT was the delta in JT raw NAV and the assets claimed from ST
                if (deltaST < 0) $.lastJTEffectiveNAV -= (uint256(-deltaJT) + uint256(-deltaST));
                // Apply the pure withdrawal to the junior tranche's effective NAV
                else $.lastJTEffectiveNAV -= uint256(-deltaJT);

                // TODO: Enforce the expected relationship between JT NAVs and ST coverage debt (currently applied and pullable coverage)
                // require($.lastJTEffectiveNAV + $.lastSTCoverageDebt >= _jtRawNAV);
            }
        }
        // Enforce the NAV conservation invariant
        require(($.lastSTRawNAV + $.lastJTRawNAV) == ($.lastSTEffectiveNAV + $.lastJTEffectiveNAV), NAV_CONSERVATION_VIOLATION());
    }

    /// @inheritdoc IRoycoAccountant
    function postOpSyncTrancheNAVsAndEnforceCoverage(uint256 _stRawNAV, uint256 _jtRawNAV, Operation _op) external override(IRoycoAccountant) onlyRoycoKernel {
        // Execute a post-op NAV synchronization
        postOpSyncTrancheNAVs(_stRawNAV, _jtRawNAV, _op);
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
        return (utilization <= ConstantsLib.WAD);
    }

    /**
     * @inheritdoc IRoycoAccountant
     * @dev Coverage Invariant: JT_EFFECTIVE_NAV >= (ST_RAW_NAV + (JT_RAW_NAV * BETA_%)) * COV_%
     * @dev Max assets depositable into ST, x: JT_EFFECTIVE_NAV = ((ST_RAW_NAV + x) + (JT_RAW_NAV * BETA_%)) * COV_%
     *      Isolate x: x = (JT_EFFECTIVE_NAV / COV_%) - (JT_RAW_NAV * BETA_%) - ST_RAW_NAV
     */
    function maxSTDepositGivenCoverage(uint256 _stRawNAV, uint256 _jtRawNAV) external view override(IRoycoAccountant) onlyRoycoKernel returns (uint256) {
        // Get the storage pointer to the base kernel state
        RoycoAccountantState storage $ = RoycoAccountantStorageLib._getRoycoAccountantStorage();
        // Preview a NAV sync to get the market's current state
        (SyncedNAVsPacket memory packet,,) = previewSyncTrancheNAVs(_stRawNAV, _jtRawNAV);
        // Solve for x, rounding in favor of senior protection
        // Compute the total covered assets by the junior tranche loss absorption buffer
        uint256 totalCoveredAssets = packet.jtEffectiveNAV.mulDiv(ConstantsLib.WAD, $.coverageWAD, Math.Rounding.Floor);
        // Compute the assets required to cover current junior tranche exposure
        uint256 jtCoverageRequired = _jtRawNAV.mulDiv($.betaWAD, ConstantsLib.WAD, Math.Rounding.Ceil);
        // Compute the assets required to cover current senior tranche exposure
        uint256 stCoverageRequired = _stRawNAV;
        // Compute the amount of assets that can be deposited into senior while retaining full coverage
        return totalCoveredAssets.saturatingSub(jtCoverageRequired).saturatingSub(stCoverageRequired);
    }

    /**
     * @inheritdoc IRoycoAccountant
     * @dev Coverage Invariant: JT_EFFECTIVE_NAV >= (ST_RAW_NAV + (JT_RAW_NAV * BETA_%)) * COV_%
     * @dev Max assets withdrawable from JT, y: (JT_EFFECTIVE_NAV - y) = (ST_RAW_NAV + ((JT_RAW_NAV - y) * BETA_%)) * COV_%
     *      Isolate y: y = (JT_EFFECTIVE_NAV - (COV_% * (ST_RAW_NAV + (JT_RAW_NAV * BETA_%)))) / (1 - (BETA_% * COV_%))
     */
    function maxJTWithdrawalGivenCoverage(uint256 _stRawNAV, uint256 _jtRawNAV) external view override(IRoycoAccountant) onlyRoycoKernel returns (uint256) {
        // Get the storage pointer to the base kernel state and cache beta and coverage
        RoycoAccountantState storage $ = RoycoAccountantStorageLib._getRoycoAccountantStorage();
        uint256 betaWAD = $.betaWAD;
        uint256 coverageWAD = $.coverageWAD;
        // Preview a NAV sync to get the market's current state
        (SyncedNAVsPacket memory packet,,) = previewSyncTrancheNAVs(_stRawNAV, _jtRawNAV);
        // Solve for y, rounding in favor of senior protection
        // Compute the total covered exposure of the underlying investment
        uint256 totalCoveredExposure = _stRawNAV + _jtRawNAV.mulDiv(betaWAD, ConstantsLib.WAD, Math.Rounding.Ceil);
        // Compute the minimum junior tranche assets required to cover the exposure as per the market's coverage requirement
        uint256 requiredJTAssets = totalCoveredExposure.mulDiv(coverageWAD, ConstantsLib.WAD, Math.Rounding.Ceil);
        // Compute the surplus coverage currently provided by the junior tranche based on its currently remaining loss-absorption buffer
        uint256 surplusJTAssets = Math.saturatingSub(packet.jtEffectiveNAV, requiredJTAssets);
        // Compute how much coverage the system retains per 1 unit of JT assets withdrawn scaled by WAD
        uint256 coverageRetentionWAD = ConstantsLib.WAD - betaWAD.mulDiv(coverageWAD, ConstantsLib.WAD, Math.Rounding.Floor);
        // Return how much of the surplus can be withdrawn while satisfying the coverage requirement
        return surplusJTAssets.mulDiv(ConstantsLib.WAD, coverageRetentionWAD, Math.Rounding.Floor);
    }

    /**
     * @notice Computes the currently accrued JT yield share since the last yield distribution
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

        // Get the instantaneous JT yield share, scaled by WAD
        // TODO: add a non-view funcs for stateful RDMs
        uint256 jtYieldShareWAD = IRDM($.rdm).getJTYieldShare($.lastSTRawNAV, $.lastJTRawNAV, $.betaWAD, $.coverageWAD, $.lastJTEffectiveNAV);
        // Apply the accural of JT yield share to the accumulator, weighted by the time elapsed
        return ($.twJTYieldShareAccruedWAD + uint192(jtYieldShareWAD * elapsed));
    }

    /**
     * @notice Computes raw NAV deltas for a tranche
     * @param _currentRawNAV The current raw NAV
     * @param _lastRawNAV The last recorded raw NAV
     * @return deltaNAV The delta between the last recorded and current raw NAV
     */
    function _computeRawNAVDelta(uint256 _currentRawNAV, uint256 _lastRawNAV) internal pure returns (int256 deltaNAV) {
        deltaNAV = int256(_currentRawNAV) - int256(_lastRawNAV);
    }
}
