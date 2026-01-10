// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Operation, SyncedAccountingState } from "../libraries/Types.sol";
import { NAV_UNIT } from "../libraries/Units.sol";

/**
 * @title IRoycoAccountant
 * @notice Interface for the RoycoAccountant contract that manages tranche NAVs and coverage requirements
 */
interface IRoycoAccountant {
    /**
     * @notice Initialization parameters for the Royco Accountant
     * @custom:field kernel - The kernel that this accountant maintains NAV, impermanent loss, and fee accounting for
     * @custom:field stProtocolFeeWAD - The market's configured protocol fee percentage taken from yield earned by the senior tranche, scaled to WAD precision
     * @custom:field jtProtocolFeeWAD - The market's configured protocol fee percentage taken from yield earned by the junior tranche, scaled to WAD precision
     * @custom:field coverageWAD - The coverage ratio that the senior tranche is expected to be protected by, scaled to WAD precision
     * @custom:field betaWAD - The junior tranche's sensitivity to the same downside stress that affects the senior tranche, scaled to WAD precision
     *                         For example, beta is 0 when JT is in the RFR and 1 when JT is in the same opportunity as senior
     * @custom:field ydm - The market's Yield Distribution Model (YDM), responsible for determining the ST's yield split between ST and JT
     * @custom:field ydmInitializationData - The data used to initialize the YDM for this market
     */
    struct RoycoAccountantInitParams {
        address kernel;
        uint64 stProtocolFeeWAD;
        uint64 jtProtocolFeeWAD;
        uint64 coverageWAD;
        uint96 betaWAD;
        address ydm;
        bytes ydmInitializationData;
    }

    /**
     * @notice Storage state for the Royco Accountant
     * @custom:storage-location erc7201:Royco.storage.RoycoAccountantState
     * @custom:field kernel - The kernel that this accountant maintains NAV, impermanent loss, and fee accounting for
     * @custom:field coverageWAD - The coverage percentage that the senior tranche is expected to be protected by, scaled to WAD precision
     * @custom:field betaWAD - JT's percentage sensitivity to the same downside stress that affects ST, scaled to WAD precision
     *                         For example, beta is 0 when JT is in the RFR and 1e18 (100%) when JT is in the same opportunity as senior
     * @custom:field stProtocolFeeWAD - The market's configured protocol fee percentage taken from yield earned by the senior tranche, scaled to WAD precision
     * @custom:field jtProtocolFeeWAD - The market's configured protocol fee percentage taken from yield earned by the junior tranche, scaled to WAD precision
     * @custom:field ydm - The market's Yield Distribution Model (YDM), responsible for determining the ST's yield split between ST and JT
     * @custom:field lastSTRawNAV - The last recorded pure NAV (excluding any coverage taken and yield shared) of the senior tranche
     * @custom:field lastJTRawNAV - The last recorded pure NAV (excluding any coverage given and yield shared) of the junior tranche
     * @custom:field lastSTEffectiveNAV - The last recorded effective NAV (including any prior applied coverage, ST yield distribution, and uncovered losses) of the senior tranche
     * @custom:field lastJTEffectiveNAV - The last recorded effective NAV (including any prior provided coverage, JT yield, ST yield distribution, and JT losses) of the junior tranche
     * @custom:field lastSTImpermanentLoss - The impermanent loss that ST has suffered after exhausting JT's loss-absorption buffer
     *                                       This represents the first claim on capital that the senior tranche has on future recoveries
     * @custom:field lastJTImpermanentLoss - The impermanent loss that JT has suffered after providing coverage for ST losses
     *                                       This represents the second claim on capital that the junior tranche has on future recoveries
     * @custom:field twJTYieldShareAccruedWAD - The time-weighted junior tranche yield share (YDM output) since the last yield distribution, scaled to WAD precision
     * @custom:field lastAccrualTimestamp - The timestamp at which the time-weighted JT yield share accumulator was last updated
     * @custom:field lastDistributionTimestamp - The timestamp at which the last ST yield distribution occurred
     */
    struct RoycoAccountantState {
        address kernel;
        uint64 stProtocolFeeWAD;
        uint64 jtProtocolFeeWAD;
        uint64 coverageWAD;
        uint96 betaWAD;
        address ydm;
        NAV_UNIT lastSTRawNAV;
        NAV_UNIT lastJTRawNAV;
        NAV_UNIT lastSTEffectiveNAV;
        NAV_UNIT lastJTEffectiveNAV;
        NAV_UNIT lastSTImpermanentLoss;
        NAV_UNIT lastJTImpermanentLoss;
        uint192 twJTYieldShareAccruedWAD;
        uint32 lastAccrualTimestamp;
        uint32 lastDistributionTimestamp;
    }

    /**
     * @notice Emitted when JT's share of ST yield is accrued based on the market's utilization since the last accrual
     * @param jtYieldShareWAD JT's instantaneous yield share (YDM output) based on utilization since the last accrual
     * @param twJTYieldShareAccruedWAD The time-weighted JT yield share accrued since the last yield distribution
     * @param accrualTimestamp The timestamp of this JT yield share accrual
     */
    event JuniorTrancheYieldShareAccrued(uint256 jtYieldShareWAD, uint256 twJTYieldShareAccruedWAD, uint32 accrualTimestamp);

    /**
     * @notice Emitted when a pre-operation tranche accounting synchronization is executed
     * @param resultingState The resulting market state after synchronizing the tranche accounting
     */
    event PreOpTrancheAccountingSynced(SyncedAccountingState resultingState);

    /**
     * @notice Emitted when a post-operation tranche accounting synchronization is executed
     * @param op The operation executed right before this accounting synchronization
     * @param resultingState The resulting market state after synchronizing the tranche accounting
     */
    event PostOpTrancheAccountingSynced(Operation op, SyncedAccountingState resultingState);

    /// @notice Thrown when the YDM failed to initialize
    error FAILED_TO_INITIALIZE_YDM(bytes data);

    /// @notice Thrown when the caller of the function is not the accountant's configured Royco Kernel
    error ONLY_ROYCO_KERNEL();

    /// @notice Thrown when the accountant's coverage config is invalid
    error INVALID_COVERAGE_CONFIG();

    /// @notice Thrown when the YDM address is null on initialization
    error NULL_YDM_ADDRESS();

    /// @notice Thrown when the configured protocol fee exceeds the maximum
    error MAX_PROTOCOL_FEE_EXCEEDED();

    /// @notice Thrown when the sum of the raw NAVs don't equal the sum of the effective NAVs of both tranches
    error NAV_CONSERVATION_VIOLATION();

    /// @notice Thrown when an operation results in an invalid NAV state in the post-operation synchronization
    error INVALID_POST_OP_STATE(Operation _op);

    /// @notice Thrown when the market's coverage requirement is unsatisfied
    error COVERAGE_REQUIREMENT_UNSATISFIED();

    /**
     * @notice Synchronizes the effective NAVs and impermanent losses of both tranches before any tranche operation (deposit or withdrawal)
     * @dev Accrues JT yield share over time based on the market's YDM output
     * @dev Applies unrealized PnL and yield distribution
     * @dev Persists updated NAV and impermanent loss checkpoints for the next sync to use as reference
     * @param _stRawNAV The senior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the pure value of its invested assets
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark to market accounting data
     */
    function preOpSyncTrancheAccounting(NAV_UNIT _stRawNAV, NAV_UNIT _jtRawNAV) external returns (SyncedAccountingState memory state);

    /**
     * @notice Previews a synchronization of tranche NAVs based on the underlying PNL(s) and their effects on the current state of the loss waterfall
     * @param _stRawNAV The senior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the pure value of its invested assets
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark to market accounting data
     */
    function previewSyncTrancheAccounting(NAV_UNIT _stRawNAV, NAV_UNIT _jtRawNAV) external view returns (SyncedAccountingState memory state);

    /**
     * @notice Applies post-operation (deposit and withdrawal) raw NAV deltas to effective NAV checkpoints
     * @dev Interprets deltas strictly as deposits/withdrawals with no yield or coverage logic
     * @param _stRawNAV The senior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the pure value of its invested assets
     * @param _op The operation being executed in between the pre and post synchronizations
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark to market accounting data
     */
    function postOpSyncTrancheAccounting(NAV_UNIT _stRawNAV, NAV_UNIT _jtRawNAV, Operation _op) external returns (SyncedAccountingState memory state);

    /**
     * @notice Applies post-operation (deposit and withdrawal) raw NAV deltas to effective NAV checkpoints and enforces the coverage condition of the market
     * @dev Interprets deltas strictly as deposits/withdrawals with no yield or coverage logic
     * @dev Reverts if the coverage requirement is unsatisfied
     * @param _stRawNAV The senior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the pure value of its invested assets
     * @param _op The operation being executed in between the pre and post synchronizations
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark to market accounting data
     */
    function postOpSyncTrancheAccountingAndEnforceCoverage(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        Operation _op
    )
        external
        returns (SyncedAccountingState memory state);

    /**
     * @notice Returns if the market’s coverage requirement is satisfied
     * @dev If this condition is unsatisfied, senior deposits and junior withdrawals must be blocked to prevent undercollateralized senior exposure
     * @return satisfied A boolean indicating whether the market's coverage requirement is satisfied based on the persisted NAV checkpoints
     */
    function isCoverageRequirementSatisfied() external view returns (bool satisfied);

    /**
     * @notice Returns the maximum assets depositable into the senior tranche without violating the market's coverage requirement
     * @dev Always rounds in favor of senior tranche protection
     * @param _stRawNAV The senior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the pure value of its invested assets
     * @return maxSTDeposit The maximum assets depositable into the senior tranche without violating the market's coverage requirement
     */
    function maxSTDepositGivenCoverage(NAV_UNIT _stRawNAV, NAV_UNIT _jtRawNAV) external view returns (NAV_UNIT maxSTDeposit);

    /**
     * @notice Returns the maximum assets withdrawable from the junior tranche without violating the market's coverage requirement
     * @dev Always rounds in favor of senior tranche protection
     * @param _stRawNAV The senior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtClaimOnStUnits The total claims on ST assets that the junior tranche has denominated in NAV units
     * @param _jtClaimOnJtUnits The total claims on JT assets that the junior tranche has denominated in NAV units
     * @return totalNAVClaimable The maximum NAV that can be claimed from the junior tranche without violating the market's coverage requirement
     * @return stClaimable The maximum claims on ST assets that the junior tranche can withdraw, denominated in NAV units
     * @return jtClaimable The maximum claims on JT assets that the junior tranche can withdraw, denominated in NAV units
     */
    function maxJTWithdrawalGivenCoverage(
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        NAV_UNIT _jtClaimOnStUnits,
        NAV_UNIT _jtClaimOnJtUnits
    )
        external
        view
        returns (NAV_UNIT totalNAVClaimable, NAV_UNIT stClaimable, NAV_UNIT jtClaimable);

    /**
     * @notice Updates the YDM (Yield Distribution Model) address
     * @dev Only callable by a designated admin
     * @param _ydm The new YDM address to set
     */
    function setYDM(address _ydm) external;

    /**
     * @notice Updates the senior tranche protocol fee percentage
     * @dev Only callable by a designated admin
     * @param _stProtocolFeeWAD The new protocol fee percentage charged on senior tranche yield, scaled to WAD precision
     */
    function setSeniorTrancheProtocolFee(uint64 _stProtocolFeeWAD) external;

    /**
     * @notice Updates the junior tranche protocol fee percentage
     * @dev Only callable by a designated admin
     * @param _jtProtocolFeeWAD The new protocol fee percentage charged on junior tranche yield, scaled to WAD precision
     */
    function setJuniorTrancheProtocolFee(uint64 _jtProtocolFeeWAD) external;

    /**
     * @notice Updates the coverage percentage requirement
     * @dev Only callable by a designated admin
     * @param _coverageWAD The new coverage percentage in WAD format
     */
    function setCoverage(uint64 _coverageWAD) external;

    /**
     * @notice Updates the beta sensitivity parameter
     * @dev Only callable by a designated admin
     * @param _betaWAD The new beta parameter in WAD format representing JT's sensitivity to downside stress
     */
    function setBeta(uint96 _betaWAD) external;

    /**
     * @notice Returns the state of the accountant
     * @return state The state of the accountant
     */
    function getState() external view returns (RoycoAccountantState memory state);
}
