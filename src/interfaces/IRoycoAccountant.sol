// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoAccountantState } from "../libraries/RoycoAccountantStorageLib.sol";
import { Operation, SyncedNAVsPacket } from "../libraries/Types.sol";

/**
 * @title IRoycoAccountant
 * @notice Interface for the RoycoAccountant contract that manages tranche NAVs and coverage requirements
 */
interface IRoycoAccountant {
    /// @notice Thrown when the caller of the function is not the accountant's configured Royco Kernel
    error ONLY_ROYCO_KERNEL();

    /// @notice Thrown when the accountant's coverage config is invalid
    error INVALID_COVERAGE_CONFIG();

    /// @notice Thrown when the RDM address is null on initialization
    error NULL_RDM_ADDRESS();

    /// @notice Thrown when the configured protocol fee exceeds the maximum
    error MAX_PROTOCOL_FEE_EXCEEDED();

    /// @notice Thrown when the sum of the raw NAVs don't equal the sum of the effective NAVs of both tranches
    error NAV_CONSERVATION_VIOLATION();

    /// @notice Thrown when an operation results in an invalid NAV state in the post-operation synchronization
    error INVALID_POST_OP_STATE(Operation _op);

    /// @notice Thrown when the market's coverage requirement is unsatisfied
    error COVERAGE_REQUIREMENT_UNSATISFIED();

    /**
     * @notice Synchronizes the effective NAVs and debt obligations of both tranches before any tranche operation (deposit or withdrawal)
     * @dev Accrues JT yield share over time based on the market's RDM output
     * @dev Applies unrealized PnL and yield distribution
     * @dev Persists updated NAV and debt checkpoints for the next sync to use as reference
     * @param _stRawNAV The senior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the pure value of its invested assets
     * @return packet The NAV sync packet containing all mark to market accounting data
     */
    function preOpSyncTrancheNAVs(uint256 _stRawNAV, uint256 _jtRawNAV) external returns (SyncedNAVsPacket memory packet);

    /**
     * @notice Previews a synchronization of tranche NAVs based on the underlying PNL(s) and their effects on the current state of the loss waterfall
     * @param _stRawNAV The senior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the pure value of its invested assets
     * @return packet The NAV sync packet containing all mark to market accounting data
     * @return twJTYieldShareAccruedWAD The accumulated time-weighted JT yield share since the last yield distribution
     * @return yieldDistributed A boolean indicating whether ST yield was split between ST and JT
     */
    function previewSyncTrancheNAVs(
        uint256 _stRawNAV,
        uint256 _jtRawNAV
    )
        external
        view
        returns (SyncedNAVsPacket memory packet, uint192 twJTYieldShareAccruedWAD, bool yieldDistributed);

    /**
     * @notice Applies post-operation (deposit and withdrawal) raw NAV deltas to effective NAV checkpoints
     * @dev Interprets deltas strictly as deposits/withdrawals with no yield or coverage logic
     * @param _stRawNAV The senior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the pure value of its invested assets
     * @param _op The operation being executed in between the pre and post synchronizations
     */
    function postOpSyncTrancheNAVs(uint256 _stRawNAV, uint256 _jtRawNAV, Operation _op) external;

    /**
     * @notice Applies post-operation (deposit and withdrawal) raw NAV deltas to effective NAV checkpoints and enforces the coverage condition of the market
     * @dev Interprets deltas strictly as deposits/withdrawals with no yield or coverage logic
     * @dev Reverts if the coverage requirement is unsatisfied
     * @param _stRawNAV The senior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the pure value of its invested assets
     * @param _op The operation being executed in between the pre and post synchronizations
     */
    function postOpSyncTrancheNAVsAndEnforceCoverage(uint256 _stRawNAV, uint256 _jtRawNAV, Operation _op) external;

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
    function maxSTDepositGivenCoverage(uint256 _stRawNAV, uint256 _jtRawNAV) external view returns (uint256 maxSTDeposit);

    /**
     * @notice Returns the maximum assets withdrawable from the junior tranche without violating the market's coverage requirement
     * @dev Always rounds in favor of senior tranche protection
     * @param _stRawNAV The senior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the pure value of its invested assets
     * @return maxJTWithdrawal The maximum assets withdrawable from the junior tranche without violating the market's coverage requirement
     */
    function maxJTWithdrawalGivenCoverage(uint256 _stRawNAV, uint256 _jtRawNAV) external view returns (uint256 maxJTWithdrawal);
}
