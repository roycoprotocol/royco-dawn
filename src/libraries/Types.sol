// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { NAV_UNIT, QUOTE_UNIT, TRANCHE_UNIT } from "./Units.sol";
/**
 * @title MarketState
 * @notice Defines the operational state of a Royco market
 * @custom:state PERPETUAL
 *      Normal operating state where market forces govern behavior
 *      - The market is healthy (no losses over dust tolerance) or it is severely undercollateralized (liquidation utilization breach) or uncollateralized (ST IL != 0 or JT_EFFECTIVE_NAV == 0)
 *      - Both tranches liquid (within coverage constraints) unless ST impermanent loss exists (ST deposits are blocked)
 *      - Adaptive curve YDM adapts based on utilization
 * @custom:state FIXED_TERM
 *      Temporary recovery state triggered when JT provides coverage for ST drawdown
 *      - ST experienced a fully covered drawdown but the market is still healthy in terms of its liquidation utilization threshold
 *      - Fixed term that starts when JT coverage impermanent loss is first incurred
 *      - ST redemptions blocked: protects existing JT from realizing losses by ST withdrawing coverage on arbitrary volatility
 *      - JT deposits blocked: protects existing JT from realizing losses by new JT diluting them on arbitrary volatility
 *      - Adaptive curve YDM does not adapt (prevents adaptation during recovery since market forces aren't influencing utilization, underlying PNL is)
 *      - Automatically transitions to PERPETUAL when term elapses, clearing JT coverage impermanent losses
 */
enum MarketState {
    PERPETUAL,
    FIXED_TERM
}

/**
 * @title AssetClaims
 * @dev A struct representing claims on senior tranche assets, junior tranche assets, and NAV
 * @custom:field stAssets - The claim on senior tranche assets denominated in ST's tranche units
 * @custom:field jtAssets - The claim on junior tranche assets denominated in JT's tranche units
 * @custom:field nav - The net asset value of these claims in NAV units
 */
struct AssetClaims {
    TRANCHE_UNIT stAssets;
    TRANCHE_UNIT jtAssets;
    NAV_UNIT nav;
}

/**
 * @title LiquidityPositionClaims
 * @dev A struct representing liquidity position claims on senior tranche shares and quote assets for Royco Dusk Kernel
 * @custom:field stShares - The claim on senior tranche shares that the liquidity position holds
 * @custom:field quoteAssets - The claim on quote assets that the liquidity position holds denominated in quote units
 */
struct LiquidityPositionClaims {
    uint256 stShares;
    QUOTE_UNIT quoteAssets;
}

/**
 * @title SyncedAccountingState
 * @dev Contains all current mark-to-market NAV accounting data, metrics, and coverage configuration for the market's tranches
 * @custom:field marketState - The current state of the Royco market (perpetual or fixed term)
 * @custom:field stRawNAV - The senior tranche's current raw NAV: the pure value of its invested assets
 * @custom:field jtRawNAV - The junior tranche's current raw NAV: the pure value of its invested assets
 * @custom:field stEffectiveNAV - Senior tranche effective NAV: includes applied coverage, its share of ST yield, and uncovered losses
 * @custom:field jtEffectiveNAV - Junior tranche effective NAV: includes provided coverage, JT yield, its share of ST yield, and JT losses
 * @custom:field stImpermanentLoss - The impermanent loss that ST has suffered after exhausting JT's loss-absorption buffer
 *                                   This represents the first claim on capital that the senior tranche has on future ST and JT recoveries
 * @custom:field jtImpermanentLoss - The impermanent loss that JT has suffered after providing coverage for ST losses
 *                                   This represents the second claim on capital that the junior tranche has on future ST recoveries
 * @custom:field stProtocolFeeAccrued - Protocol fee taken on ST yield on this sync
 * @custom:field jtProtocolFeeAccrued - Protocol fee taken on JT yield on this sync
 * @custom:field utilizationWAD - The current utilization of the market, scaled to WAD precision
 * @custom:field fixedTermEndTimestamp - The timestamp at which the fixed term ends. Set to 0 if the market is not in a fixed term state
 * @custom:field coverageWAD - The coverage percentage that the senior tranche is expected to be protected by, scaled to WAD precision
 * @custom:field betaWAD - JT's percentage sensitivity to the same downside stress that affects ST, scaled to WAD precision
 *                         For example, beta is 0 when JT is in the RFR and 1e18 (100%) when JT is in the same opportunity as senior
 * @custom:field liquidationUtilizationWAD - The liquidation utilization threshold for this market, scaled to WAD precision
 */
struct SyncedAccountingState {
    // The market's current operating state (PERPETUAL or FIXED_TERM)
    MarketState marketState;
    // The market's marked-to-market NAVs, impermanent losses, and fees
    NAV_UNIT stRawNAV;
    NAV_UNIT jtRawNAV;
    NAV_UNIT stEffectiveNAV;
    NAV_UNIT jtEffectiveNAV;
    NAV_UNIT stImpermanentLoss;
    NAV_UNIT jtImpermanentLoss;
    NAV_UNIT stProtocolFeeAccrued;
    NAV_UNIT jtProtocolFeeAccrued;
    // The market's derived state metrics
    uint256 utilizationWAD;
    uint32 fixedTermEndTimestamp;
    // The market's coverage configuration
    uint256 coverageWAD;
    uint256 betaWAD;
    uint256 liquidationUtilizationWAD;
}

/**
 * @title AccountingCheckpoint
 * @dev Contains a mark-to-market NAV accounting checkpoint for the market's tranches
 * @custom:field stRawNAV - The pure NAV (excluding any coverage taken and yield shared) of the senior tranche
 * @custom:field jtRawNAV - The pure NAV (excluding any coverage given and yield shared) of the junior tranche
 * @custom:field stEffectiveNAV - The effective NAV (including any prior applied coverage, ST yield distribution, and uncovered losses) of the senior tranche
 * @custom:field jtEffectiveNAV - The effective NAV (including any prior provided coverage, JT yield, ST yield distribution, and JT losses) of the junior tranche
 * @custom:field stImpermanentLoss - The impermanent loss that ST has suffered after exhausting JT's loss-absorption buffer
 *                                   This represents the first claim on capital that the senior tranche has on future ST and JT recoveries
 * @custom:field jtImpermanentLoss - The impermanent loss that JT has suffered after providing coverage for ST losses
 *                                   This represents the second claim on capital that the junior tranche has on future ST recoveries
 */
struct AccountingCheckpoint {
    NAV_UNIT stRawNAV;
    NAV_UNIT jtRawNAV;
    NAV_UNIT stEffectiveNAV;
    NAV_UNIT jtEffectiveNAV;
    NAV_UNIT stImpermanentLoss;
    NAV_UNIT jtImpermanentLoss;
}

/**
 * @title PnLWaterfallParams
 * @dev The fixed inputs of the PnL waterfall: everything it consumes besides the current raw NAVs
 * @dev Built once per sync and held constant, so the waterfall can be evaluated repeatedly at different raw NAVs against one consistent set of inputs
 * @custom:field checkpoint - The previous sync's accounting checkpoint (must conserve NAV)
 *                            Its raw NAVs are the baseline the deltas are measured against, its effective NAVs define the cross-tranche claims
 *                            that attribute those deltas, and its effective NAVs and impermanent losses seed the settlement's opening balances
 * @custom:field twJTYieldShareAccruedWAD - The accrued time-weighted JT yield share YDM output since the last distribution, scaled to WAD precision
 * @custom:field instantaneousJTYieldShareWAD - The instantaneous JT yield share YDM output, scaled to WAD precision (consumed only when `elapsedSinceLastDistribution` is zero)
 *                                              Must be validated by the caller to be at most WAD (100% of senior appreciation) before being passed in
 * @custom:field elapsedSinceLastDistribution - The seconds elapsed since the last yield distribution
 * @custom:field stProtocolFeeWAD - The protocol fee rate on ST yield, scaled to WAD precision
 * @custom:field jtProtocolFeeWAD - The protocol fee rate on JT yield, scaled to WAD precision
 * @custom:field yieldShareProtocolFeeWAD - The protocol fee rate on the JT yield share, scaled to WAD precision
 * @custom:field effectiveNAVDustTolerance - The effective NAV dust tolerance: gains within it are treated as rounding dust and accrue no fees
 */
struct PnLWaterfallParams {
    AccountingCheckpoint checkpoint;
    uint192 twJTYieldShareAccruedWAD;
    uint256 instantaneousJTYieldShareWAD;
    uint256 elapsedSinceLastDistribution;
    uint64 stProtocolFeeWAD;
    uint64 jtProtocolFeeWAD;
    uint64 yieldShareProtocolFeeWAD;
    NAV_UNIT effectiveNAVDustTolerance;
}

/**
 * @title MarketStateTransitionParams
 * @dev The inputs of the market state transition: the synced accounting data produced by the PnL waterfall alongside the market's coverage and fixed-term configuration
 * @dev The market state the transition originates from is passed alongside this struct
 * @custom:field postPnLWaterfallCheckpoint - The checkpoint output by the PnL waterfall: the current raw NAVs alongside the settled effective NAVs and impermanent losses
 * @custom:field stProtocolFeeAccrued - The protocol fee accrued on ST yield by the waterfall
 * @custom:field jtProtocolFeeAccrued - The protocol fee accrued on JT yield and the JT yield share by the waterfall
 * @custom:field betaWAD - The JT's sensitivity to the same downside stress that affects ST, scaled to WAD precision
 * @custom:field coverageWAD - The coverage ratio that the senior tranche is expected to be protected by, scaled to WAD precision
 * @custom:field effectiveNAVDustTolerance - The effective NAV dust tolerance of the market
 * @custom:field fixedTermDurationSeconds - The market's configured fixed-term duration (0 means permanently perpetual)
 * @custom:field fixedTermEndTimestamp - The currently persisted fixed-term end timestamp
 * @custom:field liquidationUtilizationWAD - The market's liquidation utilization threshold, scaled to WAD precision
 * @custom:field currentTimestamp - The current block timestamp, passed in so the transition stays pure and deterministic from its arguments
 */
struct MarketStateTransitionParams {
    AccountingCheckpoint postPnLWaterfallCheckpoint;
    NAV_UNIT stProtocolFeeAccrued;
    NAV_UNIT jtProtocolFeeAccrued;
    uint96 betaWAD;
    uint64 coverageWAD;
    NAV_UNIT effectiveNAVDustTolerance;
    uint24 fixedTermDurationSeconds;
    uint32 fixedTermEndTimestamp;
    uint256 liquidationUtilizationWAD;
    uint256 currentTimestamp;
}

/**
 * @title Operation
 * @dev Defines the type of operation being executed by the user
 * @custom:type ST_DEPOSIT - A senior tranche deposit that increases ST's effective NAV
 * @custom:type ST_REDEEM - A senior tranche redemption that decreases ST's effective NAV
 * @custom:type JT_DEPOSIT - A junior tranche deposit that increases JT's effective NAV
 * @custom:type JT_REDEEM - A junior tranche redemption that decreases JT's effective NAV
 */
enum Operation {
    ST_DEPOSIT,
    ST_REDEEM,
    JT_DEPOSIT,
    JT_REDEEM
}

/**
 * @title TrancheType
 * @dev Defines the two types of Royco tranches deployed per market.
 * @custom:type SENIOR - The identifier for the senior tranche (protected capital)
 * @custom:type JUNIOR - The identifier for the junior tranche (first-loss capital)
 */
enum TrancheType {
    SENIOR,
    JUNIOR
}

/**
 * @title KernelType
 * @dev Defines the two types of Royco Kernels
 * @custom:type DAWN - The identifier for a Royco Dawn Kernel
 *              Dawn kernels transform the risk profile of an asset: junior tranches serve as first-loss capital
 * @custom:type DUSK - The identifier for a Royco Dusk Kernel
 *              Dusk kernels transform the risk and liquidity profile of an asset: junior tranches serve as first-loss capital and secondary liquidity for senior tranches
 */
enum KernelType {
    DAWN,
    DUSK
}

/**
 * @title ConversionRateCacheKey
 * @dev Identifies which transient conversion-rate cache slot a quoter is looking up
 * @custom:type UNIFIED_TRANCHE_UNIT - The unified tranche unit cache slot used by kernels where ST and JT share a single conversion rate (e.g., Identical kernels)
 * @custom:type SENIOR_TRANCHE_UNIT - The senior tranche unit cache slot used by kernels with distinct ST and JT assets
 * @custom:type JUNIOR_TRANCHE_UNIT - The junior tranche unit cache slot used by kernels with distinct ST and JT assets
 * @custom:type QUOTE_UNIT - The quote asset cache slot used by Dusk kernels
 */
enum ConversionRateCacheKey {
    UNIFIED_TRANCHE_UNIT,
    SENIOR_TRANCHE_UNIT,
    JUNIOR_TRANCHE_UNIT,
    QUOTE_UNIT
}

