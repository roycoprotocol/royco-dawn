/*
 * MODULE
 * @module RoycoAccountant
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption the maximum supported timestamp is the year 2104.
 * @global_assumption upgradeToAndCall is excluded from all invariants — it can reinitialize the contract
 * @global_assumption initialize is excluded from some invariants - it cannot be called after intialization
 * @global_assumption block.timestamp is monotonically non-decreasing and below the protocol end date (~2104)
 *
 * PROPERTIES
 * @property INV01 jtEffectiveNAV + stEffectiveNAV = jtRawNAV + stRawNAV at all times
 * @property INV02 jtImpermanentLoss > dust implies marketstate = FIXED_TERM
 * @property INV03 jtImpermanentLoss = 0 implies marketstate = PERPETUAL
 * @property INV05 stImpermanentLoss > 0 implies marketstate = PERPETUAL (distressed state)
 * @property INV06 fixedTermDurationSeconds = 0 implies marketstate = PERPETUAL (no fixed-term allowed)
 * @property PRE02 marketstate = FIXED_TERM implies fixedTermEndTimestamp > 0
 * @property CNF01 liquidationUtilizationWAD > WAD (liquidation threshold above 100%)
 * @property CNF02 coverageWAD * betaWAD < WAD^2 (product of coverage and beta below 1.0)
 * @property CNF03 MIN_COVERAGE_WAD <= coverageWAD <= MAX_COVERAGE_WAD
 * @property CNF04 betaWAD <= WAD (beta sensitivity capped at 100%)
 */

import "../lib-summaries/OpenZeppelin/OZ_Math.spec";
import "../summaries/summaries-Timestamp.spec";

using RoycoAccountant as roycoAccountant;

methods {
    function _.consumeScheduledOp(address,bytes) external => NONDET;
    function _.canCall(address,address,bytes4) external => NONDET;
    function _.syncTrancheAccounting() external => NONDET;
    function _.previewJTYieldShare(RoycoAccountant.MarketState,RoycoAccountant.NAV_UNIT,RoycoAccountant.NAV_UNIT,uint256,uint256,RoycoAccountant.NAV_UNIT) external => NONDET;
    function _.jtYieldShare(RoycoAccountant.MarketState,RoycoAccountant.NAV_UNIT,RoycoAccountant.NAV_UNIT,uint256,uint256,RoycoAccountant.NAV_UNIT) external => NONDET;
}

definition excludeUpgradeAndCall(method f) returns bool =
    f.selector != sig:roycoAccountant.upgradeToAndCall(address,bytes).selector;
definition excludeInitialize(method f) returns bool =
    f.selector != sig:roycoAccountant.initialize(IRoycoAccountant.RoycoAccountantInitParams, address).selector;

/**
 * @title JT+ST effective NAV equals JT+ST raw NAV
 * @description The total effective NAV equals the total raw NAV at all times: impermanent losses are transferred between tranches, not created or destroyed.
 * @link_property INV01
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/8424974adf7d4bb1bb083e5fbb0c368d?anonymousKey=3d7421d2b19b0f945e54967f4d552b66d9939303
 */
invariant sumEffectiveEqualsRaw()
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV +
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV ==
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV +
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV
    filtered { f -> excludeUpgradeAndCall(f) }


/**
 * @title JT impermanent loss above dust implies FIXED_TERM market state
 * @description If jtImpermanentLoss exceeds the dust tolerance, the market must be in FIXED_TERM state. JT losses only arise when a fixed-term market settles below par.
 * Violated by setDustTolerance, which temporarily creates an inconsistent states.
 * @link_property INV02
 * @assumption initialize and upgradeAndCall are excluded.
 */
invariant jtLossImpliesFixedTerm()
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTImpermanentLoss > 
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.stNAVDustTolerance +
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.jtNAVDustTolerance
    => roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastMarketState == RoycoAccountant.MarketState.FIXED_TERM
    filtered { f -> excludeUpgradeAndCall(f) && excludeInitialize(f) }

/**
 * @title Zero JT impermanent loss implies PERPETUAL market state
 * @description When jtImpermanentLoss = 0, the market must be in PERPETUAL state; there is no ongoing fixed-term settlement with unrecovered losses.
 * Violated temporarily when nearly all JT tokens are redeemed: the market does not switch to PERPETUAL immediately.
 * @link_property INV03
 */
invariant noJTLossImpliesPerpetual()
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTImpermanentLoss == 0
    => roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastMarketState == RoycoAccountant.MarketState.PERPETUAL
    filtered { f -> excludeUpgradeAndCall(f) }

/**
 * @title ST impermanent loss implies PERPETUAL market state
 * @description When stImpermanentLoss > 0, the market is in a distressed PERPETUAL state where JT has been fully depleted and ST bears residual losses.
 * @link_property INV05
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/8424974adf7d4bb1bb083e5fbb0c368d?anonymousKey=3d7421d2b19b0f945e54967f4d552b66d9939303
 */
invariant stLossImpliesPerpetual()
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTImpermanentLoss > 0
    => roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastMarketState == RoycoAccountant.MarketState.PERPETUAL
    filtered { f -> excludeUpgradeAndCall(f) }

/**
 * @title ST impermanent loss and JT impermanent loss are mutually exclusive
 * @description ST and JT losses cannot coexist: JT loss occurs during FIXED_TERM settlement, while ST loss occurs in the PERPETUAL distressed state after JT is depleted.
 * @link_property INV05
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/8424974adf7d4bb1bb083e5fbb0c368d?anonymousKey=3d7421d2b19b0f945e54967f4d552b66d9939303
 */
invariant stLossImpliesNoJTLoss()
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTImpermanentLoss > 0
    => roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTImpermanentLoss == 0
    filtered { f -> excludeUpgradeAndCall(f) }

/**
 * @title ST impermanent loss implies jtEffectiveNAV is zero
 * @description This would mean JT has no value while ST is in deficit. Violated by design: jtDeposit increases jtEffectiveNAV even when stImpermanentLoss > 0, as new JT deposits do not first repay ST losses.
 * @link_property INV05
 * @ignore Violated by jtDeposit by design — new JT liquidity does not retroactively cover ST losses
 */
invariant stLossImpliesJTEffectivelyZero()
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTImpermanentLoss > 0
    => roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV == 0
    filtered { f -> excludeUpgradeAndCall(f)}

/**
 * @title Zero fixedTermDurationSeconds implies PERPETUAL market state
 * @description When the fixed-term duration is configured as 0, no fixed-term transitions are allowed and the market must always remain in PERPETUAL mode.
 * @link_property INV06
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/8424974adf7d4bb1bb083e5fbb0c368d?anonymousKey=3d7421d2b19b0f945e54967f4d552b66d9939303
 */
invariant termDurationZeroAlwaysPerpetual()
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.fixedTermDurationSeconds == 0
    => roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastMarketState == RoycoAccountant.MarketState.PERPETUAL
    filtered { f -> excludeUpgradeAndCall(f) && excludeInitialize(f) }


/**
 * @title FIXED_TERM market state implies fixedTermEndTimestamp is set
 * @description A fixed-term period without a deadline is invalid; when in FIXED_TERM state the end timestamp must be non-zero.
 * @link_property PRE02
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/8424974adf7d4bb1bb083e5fbb0c368d?anonymousKey=3d7421d2b19b0f945e54967f4d552b66d9939303
 */
invariant fixedTermIsBounded()
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastMarketState == RoycoAccountant.MarketState.FIXED_TERM
    => roycoAccountant.ext_Royco_storage_RoycoAccountantState.fixedTermEndTimestamp > 0
    filtered { f -> excludeUpgradeAndCall(f)}

/**
 * @title liquidationUtilizationWAD is always greater than WAD (100%)
 * @description The liquidation threshold must exceed 100% utilization to provide a meaningful safe zone between full coverage and forced liquidation.
 * @link_property CNF01
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/8424974adf7d4bb1bb083e5fbb0c368d?anonymousKey=3d7421d2b19b0f945e54967f4d552b66d9939303
 */
invariant liquidationGreaterThanOne()
    roycoAccountant.ext_openzeppelin_storage_Initializable._initialized != max_uint64 =>
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.liquidationUtilizationWAD > WAD()
    filtered { f -> excludeUpgradeAndCall(f) }

/**
 * @title coverageWAD * betaWAD < WAD^2
 * @description The product of coverage and beta must be below 1 to ensure the utilization denominator remains positive and the coverage formula yields valid results.
 * @link_property CNF02
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/8424974adf7d4bb1bb083e5fbb0c368d?anonymousKey=3d7421d2b19b0f945e54967f4d552b66d9939303
 */
invariant coverageBetaLessThanOne()
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.coverageWAD *
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.betaWAD < WAD()*WAD()
    filtered { f -> excludeUpgradeAndCall(f) }

/**
 * @title coverageWAD is at least MIN_COVERAGE_WAD (1%)
 * @description The coverage parameter has a minimum of 1% to prevent degenerate configurations that would make the utilization formula meaningless.
 * @link_property CNF03
 * @assumption Uninitialized contracts (where _initialized != max_uint64) are excluded as coverage may not yet be set
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/8424974adf7d4bb1bb083e5fbb0c368d?anonymousKey=3d7421d2b19b0f945e54967f4d552b66d9939303
 */
invariant coverageGreaterEqualMin()
    roycoAccountant.ext_openzeppelin_storage_Initializable._initialized != max_uint64 =>
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.coverageWAD >= MIN_COVERAGE_WAD()
    filtered { f -> excludeUpgradeAndCall(f) }

/**
 * @title coverageWAD is at most MAX_COVERAGE_WAD (≈100%)
 * @description The coverage parameter has a maximum just below 100% to ensure the protocol always retains some buffer above the liquidation threshold.
 * @link_property CNF03
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/8424974adf7d4bb1bb083e5fbb0c368d?anonymousKey=3d7421d2b19b0f945e54967f4d552b66d9939303
 */
invariant coverageLessEqualMax()
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.coverageWAD <= MAX_COVERAGE_WAD()
    filtered { f -> excludeUpgradeAndCall(f) }

/**
 * @title betaWAD is at most WAD (100%)
 * @description The beta sensitivity parameter is capped at 100% by _validateCoverageConfig, ensuring JT exposure never amplifies beyond its raw NAV.
 * @link_property CNF04
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/be414a149ce34af2828d68cb21f00baf/?anonymousKey=031099bb549ea30eb830ebe196a58fd501e59bf7
 */
invariant betaLessEqualOne()
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.betaWAD <= WAD()
    filtered { f -> excludeUpgradeAndCall(f) }

function requireAllInvariants_Accountant()
{
    requireInvariant sumEffectiveEqualsRaw();
    requireInvariant jtLossImpliesFixedTerm();
    requireInvariant noJTLossImpliesPerpetual();
    requireInvariant stLossImpliesPerpetual();
    requireInvariant stLossImpliesNoJTLoss();
    requireInvariant stLossImpliesJTEffectivelyZero();
    requireInvariant termDurationZeroAlwaysPerpetual();
    requireInvariant fixedTermIsBounded();
    requireInvariant liquidationGreaterThanOne();
    requireInvariant coverageBetaLessThanOne();
    requireInvariant coverageGreaterEqualMin();
    requireInvariant coverageLessEqualMax();
    requireInvariant betaLessEqualOne();
}