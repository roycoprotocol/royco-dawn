// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoBase } from "../base/RoycoBase.sol";
import { IRoycoAccountant, Operation } from "../interfaces/IRoycoAccountant.sol";
import { IYDM } from "../interfaces/IYDM.sol";
import { IRoycoKernel } from "../interfaces/kernel/IRoycoKernel.sol";
import { MAX_PROTOCOL_FEE_WAD, MIN_COVERAGE_WAD, WAD, ZERO_NAV_UNITS } from "../libraries/Constants.sol";
import { NAV_UNIT, SyncedAccountingState } from "../libraries/Types.sol";
import { UnitsMathLib, toNAVUnits, toUint256 } from "../libraries/Units.sol";
import { Math, UtilsLib } from "../libraries/UtilsLib.sol";

contract RoycoAccountant is IRoycoAccountant, RoycoBase {
    using Math for uint256;
    using UnitsMathLib for NAV_UNIT;

    /// @dev Storage slot for RoycoAccountantState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoAccountantState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROYCO_ACCOUNTANT_STORAGE_SLOT = 0xc8240830e1172c6f1489139d8edb11776c3d3b2f893e3f4ce0fb541305a63a00;

    /// @dev Enforces that the function is called by the accountant's Royco kernel
    /// forge-lint: disable-next-item(unwrapped-modifier-logic)
    modifier onlyRoycoKernel() {
        require(msg.sender == _getRoycoAccountantStorage().kernel, ONLY_ROYCO_KERNEL());
        _;
    }

    /// @dev Enforces that the kernel's accounting is synced before the function is called
    /// forge-lint: disable-next-item(unwrapped-modifier-logic)
    modifier withSyncedAccounting() {
        IRoycoKernel(_getRoycoAccountantStorage().kernel).syncTrancheAccounting();
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
        // Ensure that the YDM is not null
        require(_params.ydm != address(0), NULL_YDM_ADDRESS());
        // Ensure that the protocol fee percentage is valid
        require(_params.stProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD && _params.jtProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD, MAX_PROTOCOL_FEE_EXCEEDED());

        // Initialize the base state of the accountant
        __RoycoBase_init(_initialAuthority);

        // Initialize the YDM if required
        if (_params.ydmInitializationData.length != 0) {
            (bool success, bytes memory data) = _params.ydm.call(_params.ydmInitializationData);
            require(success, FAILED_TO_INITIALIZE_YDM(data));
        }

        // Initialize the state of the accountant
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        $.kernel = _params.kernel;
        $.stProtocolFeeWAD = _params.stProtocolFeeWAD;
        $.jtProtocolFeeWAD = _params.jtProtocolFeeWAD;
        $.coverageWAD = _params.coverageWAD;
        $.betaWAD = _params.betaWAD;
        $.ydm = _params.ydm;
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
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();

        // Accrue the JT yield share since the last accrual and preview the tranche NAVs and impermanent loss synchronization
        bool yieldDistributed;
        (state, yieldDistributed) = _previewSyncTrancheAccounting(_stRawNAV, _jtRawNAV, _accrueJTYieldShare());

        // ST yield was split between ST and JT
        if (yieldDistributed) {
            // Reset the accumulator and update the last yield distribution timestamp
            delete $.twJTYieldShareAccruedWAD;
            $.lastDistributionTimestamp = uint32(block.timestamp);
        }

        // Checkpoint the mark to market NAVs and impermanent losses
        $.lastSTRawNAV = _stRawNAV;
        $.lastJTRawNAV = _jtRawNAV;
        $.lastSTEffectiveNAV = state.stEffectiveNAV;
        $.lastJTEffectiveNAV = state.jtEffectiveNAV;
        $.lastSTImpermanentLoss = state.stImpermanentLoss;
        $.lastJTImpermanentLoss = state.jtImpermanentLoss;

        emit PreOpTrancheAccountingSynced(state);
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
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        if (_op == Operation.ST_INCREASE_NAV) {
            // Compute the delta in the raw NAV of the senior tranche
            int256 deltaST = UnitsMathLib.computeNAVDelta(_stRawNAV, $.lastSTRawNAV);
            require(deltaST >= 0, INVALID_POST_OP_STATE(_op));
            // New ST deposits are treated as an addition to the future ST exposure
            $.lastSTRawNAV = _stRawNAV;
            $.lastSTEffectiveNAV = $.lastSTEffectiveNAV + toNAVUnits(deltaST);
        } else if (_op == Operation.JT_INCREASE_NAV) {
            // Compute the delta in the raw NAV of the junior tranche
            int256 deltaJT = UnitsMathLib.computeNAVDelta(_jtRawNAV, $.lastJTRawNAV);
            require(deltaJT >= 0, INVALID_POST_OP_STATE(_op));
            // New JT deposits are treated as an addition to the future loss-absorption buffer
            $.lastJTRawNAV = _jtRawNAV;
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
                // Proportionally reduce the market's impermanent losses, rounding in favor of senior
                // The withdrawing senior LP has realized its proportional share of past covered losses, settling the realized portion between JT and ST
                NAV_UNIT impermanentLoss = $.lastJTImpermanentLoss;
                if (impermanentLoss != ZERO_NAV_UNITS) {
                    $.lastJTImpermanentLoss = impermanentLoss.mulDiv($.lastSTEffectiveNAV, preWithdrawalSTEffectiveNAV, Math.Rounding.Floor);
                }
                // The withdrawing senior LP has realized its proportional share of past uncovered losses and associated recovery optionality
                impermanentLoss = $.lastSTImpermanentLoss;
                if (impermanentLoss != ZERO_NAV_UNITS) {
                    $.lastSTImpermanentLoss = impermanentLoss.mulDiv($.lastSTEffectiveNAV, preWithdrawalSTEffectiveNAV, Math.Rounding.Ceil);
                }
            } else if (_op == Operation.JT_DECREASE_NAV) {
                require(deltaJT <= 0 && deltaST <= 0, INVALID_POST_OP_STATE(_op));
                // Junior withdrew: The NAV deltas include the discrete withdrawal amount in addition to any assets (yield + impermanent loss repayments) pulled from ST to JT
                // JT LPs cannot settle IL on withdrawal since they don't have discretion on when coverage applied to ST (jtImpermanentLoss) and uncovered ST losses (stImpermanentLoss) can be realized
                // The actual amount withdrawn by JT was the delta in JT raw NAV and the assets claimed from ST
                $.lastJTEffectiveNAV = $.lastJTEffectiveNAV - (toNAVUnits(-deltaJT) + toNAVUnits(-deltaST));
            }
        }
        // Construct the synced NAVs state to return to the caller
        // No fees are ever taken on post-op sync
        state = SyncedAccountingState({
            stRawNAV: _stRawNAV,
            jtRawNAV: _jtRawNAV,
            stEffectiveNAV: $.lastSTEffectiveNAV,
            jtEffectiveNAV: $.lastJTEffectiveNAV,
            stImpermanentLoss: $.lastSTImpermanentLoss,
            jtImpermanentLoss: $.lastJTImpermanentLoss,
            stProtocolFeeAccrued: ZERO_NAV_UNITS,
            jtProtocolFeeAccrued: ZERO_NAV_UNITS
        });
        // Enforce the NAV conservation invariant
        require((_stRawNAV + _jtRawNAV) == (state.stEffectiveNAV + state.jtEffectiveNAV), NAV_CONSERVATION_VIOLATION());

        emit PostOpTrancheAccountingSynced(_op, state);
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
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
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
    function maxSTDepositGivenCoverage(NAV_UNIT _stRawNAV, NAV_UNIT _jtRawNAV) external view override(IRoycoAccountant) returns (NAV_UNIT maxSTDeposit) {
        // Get the storage pointer to the base kernel state
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
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
        maxSTDeposit = totalCoveredAssets.saturatingSub(jtCoverageRequired).saturatingSub(stCoverageRequired);
    }

    /**
     * @inheritdoc IRoycoAccountant
     * @dev Coverage Invariant: JT_EFFECTIVE_NAV >= (ST_RAW_NAV + (JT_RAW_NAV * BETA_%)) * COV_%
     * @dev When assets are claimed from the JT, they are always liquidated in the same proportion as the tranche's total claims on the ST and JT assets
     * @dev Let S be the JT's total claims on ST assets and J be the JT's total claims on JT assets, in NAV Units. The total claims on the ST and JT assets are S + J NAV Units
     * @dev Let K_S be S / (S + J) and K_J be J / (S + J)
     * @dev Therefore, if a total NAV of y is claimed from the JT, K_S * y will be claimed from the ST_RAW_NAV and K_J * y will be claimed from the JT_RAW_NAV
     * @dev Max assets withdrawable from JT, y: (JT_EFFECTIVE_NAV - y) = ((ST_RAW_NAV - K_S * y) + ((JT_RAW_NAV - K_J * y) * BETA_%)) * COV_%
     *      Isolate y: y = (JT_EFFECTIVE_NAV - (COV_% * (ST_RAW_NAV + (JT_RAW_NAV * BETA_%)))) / (1 - (COV_% * (K_S + BETA_% * K_J)))
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
        NAV_UNIT surplusJTAssets = _calculateSurplusJtAssetsInNav(_stRawNAV, _jtRawNAV);
        // Calculate K_S
        uint256 kS_WAD = toUint256(_jtClaimOnStUnits.mulDiv(WAD, _jtClaimOnStUnits + _jtClaimOnJtUnits, Math.Rounding.Floor));
        // Calculate K_J
        uint256 kJ_WAD = toUint256(_jtClaimOnJtUnits.mulDiv(WAD, _jtClaimOnStUnits + _jtClaimOnJtUnits, Math.Rounding.Floor));
        // Compute how much coverage the system retains per 1 nav unit of JT assets withdrawn scaled to WAD precision
        uint256 coverageRetentionWAD =
            (WAD - uint256($.coverageWAD).mulDiv(kS_WAD + uint256($.betaWAD).mulDiv(kJ_WAD, WAD, Math.Rounding.Floor), WAD, Math.Rounding.Floor));
        // Return how much of the surplus can be withdrawn while satisfying the coverage requirement
        totalNAVClaimable = surplusJTAssets.mulDiv(WAD, coverageRetentionWAD, Math.Rounding.Floor);
        stClaimable = totalNAVClaimable.mulDiv(kS_WAD, WAD, Math.Rounding.Floor);
        jtClaimable = totalNAVClaimable.mulDiv(kJ_WAD, WAD, Math.Rounding.Floor);
    }

    /**
     * @notice Calculates the surplus JT assets in NAV units
     * @param _stRawNAV The senior tranche's current raw NAV in the market's NAV units
     * @param _jtRawNAV The junior tranche's current raw NAV in the market's NAV units
     * @return surplusJTAssets The surplus JT assets in NAV units
     */
    function _calculateSurplusJtAssetsInNav(NAV_UNIT _stRawNAV, NAV_UNIT _jtRawNAV) internal view returns (NAV_UNIT surplusJTAssets) {
        // Get the storage pointer to the base kernel state and cache beta and coverage
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        uint256 betaWAD = $.betaWAD;
        // Preview a NAV sync to get the market's current state
        (SyncedAccountingState memory state,) = _previewSyncTrancheAccounting(_stRawNAV, _jtRawNAV, _previewJTYieldShareAccrual());
        // Compute the total covered exposure of the underlying investment, rounding in favor of senior protection
        NAV_UNIT totalCoveredExposure = _stRawNAV + _jtRawNAV.mulDiv(betaWAD, WAD, Math.Rounding.Ceil);
        // Compute the minimum junior tranche assets required to cover the exposure as per the market's coverage requirement
        NAV_UNIT requiredJTAssets = totalCoveredExposure.mulDiv($.coverageWAD, WAD, Math.Rounding.Ceil);
        // Compute the surplus coverage currently provided by the junior tranche based on its currently remaining loss-absorption buffer
        surplusJTAssets = UnitsMathLib.saturatingSub(state.jtEffectiveNAV, requiredJTAssets);
    }

    /**
     * @notice Syncs all tranche NAVs and impermanent losses based on unrealized PNLs of the underlying investment(s)
     * @param _stRawNAV The senior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the pure value of its invested assets
     * @param _twJTYieldShareAccruedWAD The currently accrued time-weighted JT yield share YDM output since the last distribution, scaled to WAD precision
     * @return state A struct containing all synced NAV, impermanent losses, and fee data after executing the sync
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
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();

        // Compute the deltas in the raw NAVs of each tranche
        // The deltas represent the unrealized PNL of the underlying investment since the last NAV checkpoints
        int256 deltaST = UnitsMathLib.computeNAVDelta(_stRawNAV, $.lastSTRawNAV);
        int256 deltaJT = UnitsMathLib.computeNAVDelta(_jtRawNAV, $.lastJTRawNAV);

        // Cache the last checkpointed effective NAV and impermanent losses for each tranche
        NAV_UNIT stEffectiveNAV = $.lastSTEffectiveNAV;
        NAV_UNIT jtEffectiveNAV = $.lastJTEffectiveNAV;
        NAV_UNIT jtImpermanentLoss = $.lastJTImpermanentLoss;
        NAV_UNIT stImpermanentLoss = $.lastSTImpermanentLoss;
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
                // Reduce the JT impermanent loss
                // This is equivalent to retroactively reducing previously applied coverage
                // Thus, the JT impermanent loss is now born by ST
                jtImpermanentLoss = (jtImpermanentLoss - jtLoss);
                stImpermanentLoss = (stImpermanentLoss + jtLoss);
            }
            /// @dev STEP_APPLY_JT_GAIN: The JT assets appreciated in value
        } else if (deltaJT > 0) {
            NAV_UNIT jtGain = toNAVUnits(deltaJT);
            /// @dev STEP_ST_IMPERMANENT_LOSS_RECOVERY: First, reduce any ST impermanent loss (first claim on appreciation)
            NAV_UNIT stImpermanentLossRecovery = UnitsMathLib.min(jtGain, stImpermanentLoss);
            if (stImpermanentLossRecovery != ZERO_NAV_UNITS) {
                // Reduce the ST impermanent loss
                // This is equivalent to retroactively applying coverage for previously uncovered losses
                // Thus, the ST impermanent loss is now born by JT
                stImpermanentLoss = (stImpermanentLoss - stImpermanentLossRecovery);
                jtImpermanentLoss = (jtImpermanentLoss + stImpermanentLossRecovery);
                // Apply the retroactive coverage to the ST
                stEffectiveNAV = (stEffectiveNAV + stImpermanentLossRecovery);
                jtGain = (jtGain - stImpermanentLossRecovery);
            }
            /// @dev STEP_JT_ACCRUES_RESIDUAL_GAINS: JT accrues any remaining appreciation after repaying liabilities
            if (jtGain != ZERO_NAV_UNITS) {
                // Compute the protocol fee taken on this JT yield accrual - will be used to mint JT shares to the protocol fee recipient at the updated JT effective NAV
                jtProtocolFeeAccrued = jtGain.mulDiv($.jtProtocolFeeWAD, WAD, Math.Rounding.Floor);
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
                jtImpermanentLoss = (jtImpermanentLoss + coverageApplied);
            }
            /// @dev STEP_ST_INCURS_RESIDUAL_LOSSES: Apply any uncovered losses by JT to ST
            NAV_UNIT netStLoss = stLoss - coverageApplied;
            if (netStLoss != ZERO_NAV_UNITS) {
                // Apply residual losses to ST
                stEffectiveNAV = (stEffectiveNAV - netStLoss);
                // The uncovered portion of the ST loss is a JT liability to ST
                stImpermanentLoss = (stImpermanentLoss + netStLoss);
            }
            /// @dev STEP_APPLY_ST_GAIN: The ST assets appreciated in value
        } else if (deltaST > 0) {
            NAV_UNIT stGain = toNAVUnits(deltaST);
            /// @dev STEP_ST_IMPERMANENT_LOSS_RECOVERY: The first priority of repayment to reverse the loss-waterfall is making ST whole again
            NAV_UNIT impermanentLossRecovery = UnitsMathLib.min(stGain, stImpermanentLoss);
            if (impermanentLossRecovery != ZERO_NAV_UNITS) {
                // Recover as much of the ST impermanent loss as possible
                stEffectiveNAV = (stEffectiveNAV + impermanentLossRecovery);
                stImpermanentLoss = (stImpermanentLoss - impermanentLossRecovery);
                // Deduct the ST IL recovery from the ST gains
                stGain = (stGain - impermanentLossRecovery);
            }
            /// @dev STEP_JT_IMPERMANENT_LOSS_RECOVERY: The second priority of repayment to reverse the loss-waterfall is making JT whole again
            impermanentLossRecovery = UnitsMathLib.min(stGain, jtImpermanentLoss);
            if (impermanentLossRecovery != ZERO_NAV_UNITS) {
                // Recover as much of the JT impermanent loss as possible
                jtEffectiveNAV = (jtEffectiveNAV + impermanentLossRecovery);
                jtImpermanentLoss = (jtImpermanentLoss - impermanentLossRecovery);
                // Deduct the JT IL recovery from the ST gains
                stGain = (stGain - impermanentLossRecovery);
            }
            /// @dev STEP_DISTRIBUTE_YIELD: There are no remaining impermanent losses in the system, the residual gains will be used to distribute yield to both tranches
            if (stGain != ZERO_NAV_UNITS) {
                uint256 jtProtocolFeeWAD = $.jtProtocolFeeWAD;
                // Bring the twJTYieldShareAccruedWAD to the top of the stack
                uint256 twJTYieldShareAccruedWAD = _twJTYieldShareAccruedWAD;
                // Compute the time weighted average JT share of yield
                uint256 elapsed = block.timestamp - $.lastDistributionTimestamp;
                // If the last yield distribution wasn't in this block, split the yield between ST and JT
                if (elapsed != 0) {
                    // Compute the ST gain allocated to JT based on its time weighted yield share since the last distribution, rounding in favor of the senior tranche
                    NAV_UNIT jtGain = stGain.mulDiv(twJTYieldShareAccruedWAD, (elapsed * WAD), Math.Rounding.Floor);
                    // Apply the yield split to JT's effective NAV
                    if (jtGain != ZERO_NAV_UNITS) {
                        // Compute the protocol fee taken on this JT yield accrual (will be used to mint shares to the protocol fee recipient) at the updated JT effective NAV
                        jtProtocolFeeAccrued = (jtProtocolFeeAccrued + jtGain.mulDiv(jtProtocolFeeWAD, WAD, Math.Rounding.Floor));
                        jtEffectiveNAV = (jtEffectiveNAV + jtGain);
                        stGain = (stGain - jtGain);
                    }
                }
                // Compute the protocol fee taken on this ST yield accrual (will be used to mint shares to the protocol fee recipient) at the updated JT effective NAV
                stProtocolFeeAccrued = stGain.mulDiv($.stProtocolFeeWAD, WAD, Math.Rounding.Floor);
                // Book the residual gain to the ST
                stEffectiveNAV = (stEffectiveNAV + stGain);
                // Mark yield as distributed
                yieldDistributed = true;
            }
        }
        // Enforce the NAV conservation invariant
        require((_stRawNAV + _jtRawNAV) == (stEffectiveNAV + jtEffectiveNAV), NAV_CONSERVATION_VIOLATION());
        // Construct the synced NAVs state to return to the caller
        state = SyncedAccountingState({
            stRawNAV: _stRawNAV,
            jtRawNAV: _jtRawNAV,
            stEffectiveNAV: stEffectiveNAV,
            jtEffectiveNAV: jtEffectiveNAV,
            stImpermanentLoss: stImpermanentLoss,
            jtImpermanentLoss: jtImpermanentLoss,
            stProtocolFeeAccrued: stProtocolFeeAccrued,
            jtProtocolFeeAccrued: jtProtocolFeeAccrued
        });
    }

    /**
     * @notice Accrues the JT yield share since the last yield distribution
     * @dev Gets the instantaneous JT yield share and accumulates it over the time elapsed since the last accrual
     * @return twJTYieldShareAccruedWAD The updated time-weighted JT yield share since the last yield distribution
     */
    function _accrueJTYieldShare() internal returns (uint192 twJTYieldShareAccruedWAD) {
        // Get the storage pointer to the base kernel state
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
        uint256 jtYieldShareWAD = IYDM($.ydm).jtYieldShare($.lastSTRawNAV, $.lastJTRawNAV, $.betaWAD, $.coverageWAD, $.lastJTEffectiveNAV);
        // Ensure that JT cannot earn more than 100% of senior appreciation
        if (jtYieldShareWAD > WAD) jtYieldShareWAD = WAD;

        // Accrue the time-weighted yield share accrued to JT since the last tranche interaction
        /// forge-lint: disable-next-item(unsafe-typecast)
        twJTYieldShareAccruedWAD = $.twJTYieldShareAccruedWAD += uint192(jtYieldShareWAD * elapsed);
        $.lastAccrualTimestamp = uint32(block.timestamp);

        emit JuniorTrancheYieldShareAccrued(jtYieldShareWAD, twJTYieldShareAccruedWAD, uint32(block.timestamp));
    }

    /**
     * @notice Computes and returns the currently accrued JT yield share since the last yield distribution
     * @dev Gets the instantaneous JT yield share and accumulates it over the time elapsed since the last accrual
     * @return The updated time-weighted JT yield share since the last yield distribution
     */
    function _previewJTYieldShareAccrual() internal view returns (uint192) {
        // Get the storage pointer to the base kernel state
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();

        // Get the last update timestamp
        uint256 lastUpdate = $.lastAccrualTimestamp;
        if (lastUpdate == 0) return 0;

        // Compute the elapsed time since the last update
        uint256 elapsed = block.timestamp - lastUpdate;
        // Preemptively return if last accrual was in the same block
        if (elapsed == 0) return $.twJTYieldShareAccruedWAD;

        // Get the instantaneous JT yield share, scaled to WAD precision
        uint256 jtYieldShareWAD = IYDM($.ydm).previewJTYieldShare($.lastSTRawNAV, $.lastJTRawNAV, $.betaWAD, $.coverageWAD, $.lastJTEffectiveNAV);
        // Ensure that JT cannot earn more than 100% of senior appreciation
        if (jtYieldShareWAD > WAD) jtYieldShareWAD = WAD;

        // Apply the accural of JT yield share to the accumulator, weighted by the time elapsed
        /// forge-lint: disable-next-item(unsafe-typecast)
        return ($.twJTYieldShareAccruedWAD + uint192(jtYieldShareWAD * elapsed));
    }

    /// @inheritdoc IRoycoAccountant
    function setYDM(address _ydm) external override(IRoycoAccountant) restricted withSyncedAccounting {
        // Ensure that the YDM is not null
        require(_ydm != address(0), NULL_YDM_ADDRESS());
        // Set the new YDM
        _getRoycoAccountantStorage().ydm = _ydm;
    }

    /// @inheritdoc IRoycoAccountant
    function setSeniorTrancheProtocolFee(uint64 _stProtocolFeeWAD) external override(IRoycoAccountant) restricted withSyncedAccounting {
        // Ensure that the protocol fee percentage is valid
        require(_stProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD, MAX_PROTOCOL_FEE_EXCEEDED());
        // Set the new protocol fee percentage
        _getRoycoAccountantStorage().stProtocolFeeWAD = _stProtocolFeeWAD;
    }

    /// @inheritdoc IRoycoAccountant
    function setJuniorTrancheProtocolFee(uint64 _jtProtocolFeeWAD) external override(IRoycoAccountant) restricted withSyncedAccounting {
        // Ensure that the protocol fee percentage is valid
        require(_jtProtocolFeeWAD <= MAX_PROTOCOL_FEE_WAD, MAX_PROTOCOL_FEE_EXCEEDED());
        // Set the new protocol fee percentage
        _getRoycoAccountantStorage().jtProtocolFeeWAD = _jtProtocolFeeWAD;
    }

    /// @inheritdoc IRoycoAccountant
    function setCoverage(uint64 _coverageWAD) external override(IRoycoAccountant) restricted withSyncedAccounting {
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        // Validate the new coverage requirement
        _validateCoverageRequirement(_coverageWAD, $.betaWAD);
        // Set the new coverage percentage
        $.coverageWAD = _coverageWAD;
    }

    /// @inheritdoc IRoycoAccountant
    function setBeta(uint96 _betaWAD) external override(IRoycoAccountant) restricted withSyncedAccounting {
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        // Validate the new coverage requirement
        _validateCoverageRequirement($.coverageWAD, _betaWAD);
        // Set the new beta parameter
        $.betaWAD = _betaWAD;
    }

    /// @inheritdoc IRoycoAccountant
    function getState() external view override(IRoycoAccountant) returns (RoycoAccountantState memory) {
        return _getRoycoAccountantStorage();
    }

    /**
     * @notice Validates the coverage requirement parameters of the market
     * @param _coverageWAD The coverage ratio that the senior tranche is expected to be protected by, scaled to WAD precision
     * @param _betaWAD The JT's sensitivity to the same downside stress that affects ST, scaled to WAD precisiong
     */
    function _validateCoverageRequirement(uint64 _coverageWAD, uint96 _betaWAD) internal pure {
        // Ensure that the coverage requirement is valid
        require((_coverageWAD >= MIN_COVERAGE_WAD) && (_coverageWAD < WAD), INVALID_COVERAGE_CONFIG());
        // Ensure that JT withdrawals are not permanently bricked
        require(uint256(_coverageWAD).mulDiv(_betaWAD, WAD, Math.Rounding.Ceil) < WAD, INVALID_COVERAGE_CONFIG());
    }

    /**
     * @notice Returns a storage pointer to the RoycoAccountantState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer to the accountant's state
     */
    function _getRoycoAccountantStorage() internal pure returns (RoycoAccountantState storage $) {
        assembly ("memory-safe") {
            $.slot := ROYCO_ACCOUNTANT_STORAGE_SLOT
        }
    }
}
