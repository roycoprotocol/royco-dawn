// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { MarketState, Operation, SyncedAccountingState } from "../libraries/Types.sol";
import { NAV_UNIT } from "../libraries/Units.sol";

/**
 * @title IRoycoAccountant
 * @notice Interface for the RoycoAccountant contract that manages tranche NAVs and coverage requirements
 */
interface IRoycoAccountant {
    /**
     * @notice Initialization parameters for the Royco Accountant
     * @custom:field stProtocolFeeWAD - The market's configured protocol fee percentage taken from yield earned by the senior tranche, scaled to WAD precision
     * @custom:field jtProtocolFeeWAD - The market's configured protocol fee percentage taken from yield earned by the junior tranche, scaled to WAD precision
     * @custom:field yieldShareProtocolFeeWAD - The market's configured protocol fee percentage taken from the yield share (risk premium) payed from the senior tranche yield to the junior tranche, scaled to WAD precision
     * @custom:field coverageWAD - The coverage ratio that the senior tranche is expected to be protected by, scaled to WAD precision
     * @custom:field betaWAD - The junior tranche's sensitivity to the same downside stress that affects the senior tranche, scaled to WAD precision
     *                         For example, beta is 0 when JT is in the RFR and 1 when JT is in the same opportunity as senior
     * @custom:field ydm - The market's Yield Distribution Model (YDM), responsible for determining the yield share (risk premium) payed from the senior tranche yield to the junior tranche
     * @custom:field ydmInitializationData - The data used to initialize the YDM for this market
     * @custom:field fixedTermDurationSeconds - The duration of a fixed term for this market in seconds
     * @custom:field liquidationUtilizationWAD - The liquidation utilization threshold for this market, scaled to WAD precision
     * @custom:field stNAVDustTolerance - The worst case dust tolerance for stRawNAV from underlying NAV quoting/rounding
     * @custom:field jtNAVDustTolerance - The worst case dust tolerance for jtRawNAV from underlying NAV quoting/rounding
     */
    struct RoycoAccountantInitParams {
        uint64 stProtocolFeeWAD;
        uint64 jtProtocolFeeWAD;
        uint64 yieldShareProtocolFeeWAD;
        uint64 coverageWAD;
        uint96 betaWAD;
        address ydm;
        bytes ydmInitializationData;
        uint24 fixedTermDurationSeconds;
        uint256 liquidationUtilizationWAD;
        NAV_UNIT stNAVDustTolerance;
        NAV_UNIT jtNAVDustTolerance;
    }

    /**
     * @notice Storage state for the Royco Accountant
     * @custom:storage-location erc7201:Royco.storage.RoycoAccountantState
     * @custom:field lastMarketState - The last recorded state of this market (perpetual or fixed term)
     * @custom:field fixedTermDurationSeconds - The duration of a fixed term for this market in seconds
     * @custom:field fixedTermEndTimestamp - The end timestamp of the currently ongoing fixed term (set to 0 if the market is in a perpetual state)
     * @custom:field coverageWAD - The coverage percentage that the senior tranche is expected to be protected by, scaled to WAD precision
     * @custom:field betaWAD - JT's percentage sensitivity to the same downside stress that affects ST, scaled to WAD precision
     *                         For example, beta is 0 when JT is in the RFR and 1e18 (100%) when JT is in the same opportunity as senior
     * @custom:field stProtocolFeeWAD - The market's configured protocol fee percentage charged from yield earned by the senior tranche, scaled to WAD precision
     * @custom:field jtProtocolFeeWAD - The market's configured protocol fee percentage charged from yield earned by the junior tranche, scaled to WAD precision
     * @custom:field yieldShareProtocolFeeWAD - The market's configured protocol fee percentage charged from the yield share (risk premium) payed from the senior tranche yield to the junior tranche, scaled to WAD precision
     * @custom:field liquidationUtilizationWAD - The liquidation utilization threshold for this market, scaled to WAD precision
     * @custom:field ydm - The market's Yield Distribution Model (YDM), responsible for determining the yield share (risk premium) payed from the senior tranche yield to the junior tranche
     * @custom:field lastSTRawNAV - The last recorded pure NAV (excluding any coverage taken and yield shared) of the senior tranche
     * @custom:field lastJTRawNAV - The last recorded pure NAV (excluding any coverage given and yield shared) of the junior tranche
     * @custom:field lastSTEffectiveNAV - The last recorded effective NAV (including any prior applied coverage, ST yield distribution, and uncovered losses) of the senior tranche
     * @custom:field lastJTEffectiveNAV - The last recorded effective NAV (including any prior provided coverage, JT yield, ST yield distribution, and JT losses) of the junior tranche
     * @custom:field lastSTImpermanentLoss - The impermanent loss that ST has suffered after exhausting JT's loss-absorption buffer
     *                                   This represents the first claim on capital that the senior tranche has on future ST and JT recoveries
     * @custom:field lastJTImpermanentLoss - The impermanent loss that JT has suffered after providing coverage for ST losses
     *                                           This represents the second claim on capital that the junior tranche has on future ST recoveries
     * @custom:field twJTYieldShareAccruedWAD - The time-weighted junior tranche yield share (YDM output) since the last yield distribution, scaled to WAD precision
     * @custom:field lastAccrualTimestamp - The timestamp at which the time-weighted JT yield share accumulator was last updated
     * @custom:field lastDistributionTimestamp - The timestamp at which the last ST yield distribution occurred
     * @custom:field stNAVDustTolerance - The worst case dust tolerance for stRawNAV from underlying NAV quoting/rounding
     * @custom:field jtNAVDustTolerance - The worst case dust tolerance for jtRawNAV from underlying NAV quoting/rounding
     */
    struct RoycoAccountantState {
        MarketState lastMarketState;
        uint24 fixedTermDurationSeconds;
        uint32 fixedTermEndTimestamp;
        uint64 coverageWAD;
        uint96 betaWAD;
        uint64 stProtocolFeeWAD;
        uint64 jtProtocolFeeWAD;
        uint64 yieldShareProtocolFeeWAD;
        uint256 liquidationUtilizationWAD;
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
        NAV_UNIT stNAVDustTolerance;
        NAV_UNIT jtNAVDustTolerance;
    }

    /**
     * @notice Emitted when JT's share of ST yield is accrued based on the market's utilization since the last accrual
     * @param jtYieldShareWAD JT's instantaneous yield share (YDM output) based on utilization since the last accrual
     * @param twJTYieldShareAccruedWAD The time-weighted JT yield share accrued since the last yield distribution
     * @param accrualTimestamp The timestamp of this JT yield share accrual
     */
    event JuniorTrancheYieldShareAccrued(uint256 jtYieldShareWAD, uint256 twJTYieldShareAccruedWAD, uint32 accrualTimestamp);

    /**
     * @notice Emitted when a fixed term regime is commenced by this market
     * @param fixedTermEndTimestamp The end timestamp of the new fixed term regime
     */
    event FixedTermCommenced(uint32 fixedTermEndTimestamp);

    /**
     * @notice Emitted when a pre or post operation tranche accounting synchronization is executed
     * @param resultingState The resulting market state after synchronizing the tranche accounting
     */
    event TrancheAccountingSynced(SyncedAccountingState resultingState);

    /**
     * @notice Emitted when the YDM (Yield Distribution Model) address is updated
     * @param ydm The new YDM address
     */
    event YDMUpdated(address ydm);

    /**
     * @notice Emitted when the senior tranche protocol fee percentage is updated
     * @param stProtocolFeeWAD The new protocol fee percentage charged on senior tranche yield, scaled to WAD precision
     */
    event SeniorTrancheProtocolFeeUpdated(uint64 stProtocolFeeWAD);

    /**
     * @notice Emitted when the junior tranche protocol fee percentage is updated
     * @param jtProtocolFeeWAD The new protocol fee percentage charged on junior tranche yield, scaled to WAD precision
     */
    event JuniorTrancheProtocolFeeUpdated(uint64 jtProtocolFeeWAD);

    /**
     * @notice Emitted when the yield share (risk premium) protocol fee percentage is updated
     * @param yieldShareProtocolFeeWAD The new protocol fee percentage charged from the yield share (risk premium) payed from the senior tranche yield to the junior tranche, scaled to WAD precision
     */
    event YieldShareProtocolFeeUpdated(uint64 yieldShareProtocolFeeWAD);

    /**
     * @notice Emitted when the coverage percentage requirement is updated
     * @param coverageWAD The new coverage percentage, scaled to WAD precision
     */
    event CoverageUpdated(uint64 coverageWAD);

    /**
     * @notice Emitted when the beta sensitivity parameter is updated
     * @param betaWAD The new beta parameter representing JT's sensitivity to downside stress, scaled to WAD precision
     */
    event BetaUpdated(uint96 betaWAD);

    /**
     * @notice Emitted when the liquidation threshold parameter is updated
     * @param liquidationUtilizationWAD The new liquidation utilization threshold for this market, scaled to WAD precision
     */
    event LiquidationUtilizationUpdated(uint256 liquidationUtilizationWAD);

    /**
     * @notice Emitted when the fixed term duration is updated
     * @param fixedTermDurationSeconds The new fixed term duration for this market in seconds
     */
    event FixedTermDurationUpdated(uint24 fixedTermDurationSeconds);

    /**
     * @notice Emitted when ST's dust tolerance is updated
     * @param stNAVDustTolerance The dust tolerance in NAV units to account for minuscule deltas in the ST's underlying NAV calculations
     */
    event SeniorTrancheDustToleranceUpdated(NAV_UNIT stNAVDustTolerance);

    /**
     * @notice Emitted when JT's dust tolerance is updated
     * @param jtNAVDustTolerance The dust tolerance in NAV units to account for minuscule deltas in the JT's underlying NAV calculations
     */
    event JuniorTrancheDustToleranceUpdated(NAV_UNIT jtNAVDustTolerance);

    /**
     * @notice Emitted when JT's coverage loss is realized and reset to zero when transitioning from a fixed term state to a perpetual state
     * @param jtImpermanentLossErased The amount of JT coverage loss erased when transitioning from a fixed term state to a perpetual state
     */
    event JTImpermanentLossReset(NAV_UNIT jtImpermanentLossErased);

    /**
     * @notice Emitted when a fixed term regime is ended by this market
     */
    event FixedTermEnded();

    /// @notice Thrown when the caller of the function is not the accountant's configured Royco Kernel
    error ONLY_ROYCO_KERNEL();

    /// @notice Thrown when the accountant's coverage configuration is invalid (can be due to incorrect coverage, beta, or liquidation utilization values)
    error INVALID_COVERAGE_CONFIG();

    /// @notice Thrown when the configured protocol fee exceeds the maximum
    error MAX_PROTOCOL_FEE_EXCEEDED();

    /// @notice Thrown when the YDM failed to initialize
    error FAILED_TO_INITIALIZE_YDM(bytes data);

    /// @notice Thrown when the sum of the raw NAVs don't equal the sum of the effective NAVs of both tranches
    error NAV_CONSERVATION_VIOLATION();

    /// @notice Thrown when the operation and NAVs passed to post-op lead to an invalid state
    error INVALID_POST_OP_STATE(Operation _op);

    /// @notice Thrown when the market's coverage requirement is unsatisfied
    error COVERAGE_REQUIREMENT_UNSATISFIED();

    /**
     * @notice Retrieves the address of the kernel tied to this accountant
     * @return kernel The kernel that this accountant maintains mark-to-market NAV, impermanent loss, and fee accounting for
     */
    function KERNEL() external view returns (address kernel);

    /**
     * @notice Synchronizes the effective NAVs and impermanent losses of both tranches by marking them to market
     * @dev Must be called before any NAV mutating operation
     * @dev Accrues JT yield share over time based on the market's YDM output
     * @dev Persists updated NAV and impermanent loss checkpoints for the next sync to use as reference
     * @param _stRawNAV The senior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the pure value of its invested assets
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function preOpSyncTrancheAccounting(NAV_UNIT _stRawNAV, NAV_UNIT _jtRawNAV) external returns (SyncedAccountingState memory state);

    /**
     * @notice Previews a synchronization of the effective NAVs and impermanent losses of both tranches by marking them to market
     * @param _stRawNAV The senior tranche's current raw NAV: the pure value of its invested assets
     * @param _jtRawNAV The junior tranche's current raw NAV: the pure value of its invested assets
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function previewSyncTrancheAccounting(NAV_UNIT _stRawNAV, NAV_UNIT _jtRawNAV) external view returns (SyncedAccountingState memory state);

    /**
     * @notice Applies post-operation (deposit or redemption) raw NAV deltas to effective NAV checkpoints
     * @dev Strictly interprets NAV deltas as deposits/redemptions instead of PNL
     * @param _op The operation being executed in between the pre and post operation synchronizations
     * @param _stRawNAV The post-op senior tranche's raw NAV
     * @param _jtRawNAV The post-op junior tranche's raw NAV
     * @param _stSelfLiquidationBonusNAV The self-liquidation bonus remitted to an ST LP on redemption after the liquidation utilization threshold has been breached, sourced from JT effective NAV
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function postOpSyncTrancheAccounting(
        Operation _op,
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV,
        NAV_UNIT _stSelfLiquidationBonusNAV
    )
        external
        returns (SyncedAccountingState memory state);

    /**
     * @notice Applies post-operation (deposit or redemption) raw NAV deltas to effective NAV checkpoints and enforces the market's coverage condition
     * @dev Strictly interprets NAV deltas as deposits/redemptions instead of PNL
     * @dev Reverts if the coverage requirement is unsatisfied after the NAVs have been marked to market
     * @param _op The operation being executed in between the pre and post operation synchronizations
     * @param _stRawNAV The post-op senior tranche's raw NAV
     * @param _jtRawNAV The post-op junior tranche's raw NAV
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function postOpSyncTrancheAccountingAndEnforceCoverage(
        Operation _op,
        NAV_UNIT _stRawNAV,
        NAV_UNIT _jtRawNAV
    )
        external
        returns (SyncedAccountingState memory state);

    /**
     * @notice Returns if the market's coverage requirement is satisfied
     * @dev If this condition is unsatisfied, senior deposits and junior withdrawals must be blocked to prevent undercollateralized exposure
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
     * @notice Updates the YDM (Yield Distribution Model) address for this market
     * @dev Only callable by a designated admin
     * @param _ydm The new YDM address to set
     * @param _ydmInitializationData The data used to initialize the new YDM for this market
     */
    function setYDM(address _ydm, bytes calldata _ydmInitializationData) external;

    /**
     * @notice Updates the senior tranche protocol fee percentage for this market
     * @dev Only callable by a designated admin
     * @param _stProtocolFeeWAD The new protocol fee percentage charged on senior tranche yield, scaled to WAD precision
     */
    function setSeniorTrancheProtocolFee(uint64 _stProtocolFeeWAD) external;

    /**
     * @notice Updates the junior tranche protocol fee percentage for this market
     * @dev Only callable by a designated admin
     * @param _jtProtocolFeeWAD The new protocol fee percentage charged on junior tranche yield, scaled to WAD precision
     */
    function setJuniorTrancheProtocolFee(uint64 _jtProtocolFeeWAD) external;

    /**
     * @notice Updates the yield share (risk premium) protocol fee percentage for this market
     * @dev Only callable by a designated admin
     * @param _yieldShareProtocolFeeWAD The new protocol fee percentage charged on the yield share (risk premium) payed from senior tranche yield to the junior tranche, scaled to WAD precision
     */
    function setYieldShareProtocolFee(uint64 _yieldShareProtocolFeeWAD) external;

    /**
     * @notice Updates the coverage percentage requirement for this market
     * @dev Only callable by a designated admin
     * @param _coverageWAD The new coverage percentage, scaled to WAD precision
     */
    function setCoverage(uint64 _coverageWAD) external;

    /**
     * @notice Updates the beta sensitivity parameter for this market
     * @dev Only callable by a designated admin
     * @param _betaWAD The new beta parameter representing JT's sensitivity to downside stress, scaled to WAD precision
     */
    function setBeta(uint96 _betaWAD) external;

    /**
     * @notice Updates the liquidation utilization threshold for this market
     * @dev Only callable by a designated admin
     * @param _liquidationUtilizationWAD The new liquidation utilization threshold for this market, scaled to WAD precision
     */
    function setLiquidationUtilization(uint256 _liquidationUtilizationWAD) external;

    /**
     * @notice Updates the coverage configuration (coverage, beta, and liquidation utilization) for this market
     * @dev Only callable by a designated admin
     * @param _coverageWAD The new coverage percentage, scaled to WAD precision
     * @param _betaWAD The new beta parameter representing JT's sensitivity to downside stress, scaled to WAD precision
     * @param _liquidationUtilizationWAD The new liquidation utilization threshold for this market, scaled to WAD precision
     */
    function setCoverageConfiguration(uint64 _coverageWAD, uint96 _betaWAD, uint256 _liquidationUtilizationWAD) external;

    /**
     * @notice Updates the fixed term duration for this market
     * @dev Setting the fixed term duration to 0 will force the market into an eternally perpetual state
     * @dev Only callable by a designated admin
     * @param _fixedTermDurationSeconds The new fixed term duration for this market in seconds
     */
    function setFixedTermDuration(uint24 _fixedTermDurationSeconds) external;

    /**
     * @notice Updates ST's dust tolerance in NAV units to account for minuscule deltas in the underlying protocol's NAV calculations, due to rounding
     * @dev Can be safely set to 0 if the underlying investments do not exhibit rounding behavior
     * @dev Only callable by a designated admin
     * @param _stNAVDustTolerance The ST NAV tolerance for rounding discrepancies
     */
    function setSeniorTrancheDustTolerance(NAV_UNIT _stNAVDustTolerance) external;

    /**
     * @notice Updates JT's dust tolerance in NAV units to account for minuscule deltas in the underlying protocol's NAV calculations, due to rounding
     * @dev Can be safely set to 0 if the underlying investments do not exhibit rounding behavior
     * @dev Only callable by a designated admin
     * @param _jtNAVDustTolerance The JT NAV tolerance for rounding discrepancies
     */
    function setJuniorTrancheDustTolerance(NAV_UNIT _jtNAVDustTolerance) external;

    /**
     * @notice Returns the state of the accountant
     * @return state The state of the accountant
     */
    function getState() external pure returns (RoycoAccountantState memory state);
}
