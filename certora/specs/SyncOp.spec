/*
 * MODULE
 * @module RoycoAccountant
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption upgradeToAndCall is excluded from all rules — it can reinitialize the contract
 * @global_assumption block.timestamp is monotonically non-decreasing and below the protocol end date (~2104)
 * @global_assumption stNAVDustTolerance is 0 in PRE01 to simplify the fee/loss relationship
 *
 * PROPERTIES
 * @property PRE01 yieldDistributed (fees accrued) implies stImpermanentLoss = jtImpermanentLoss = 0 and marketstate = PERPETUAL
 * @property PRE02 marketstate = FIXED_TERM implies fixedTermEndTimestamp > 0
 * @property PRE03 marketstate = FIXED_TERM implies stProtocolFeeAccrued = 0 and jtProtocolFeeAccrued = 0
 * @property PRE04 if stImpermanentLoss was 0 before the call, then stImpermanentLoss > 0 after implies jtEffectiveNAV = 0
 * @property PRE05 if stImpermanentLoss > 0, then jtEffectiveNAV does not increase
 * @property POST01 postOpSyncTrancheAccounting distributes no fees
 * @property POST02 raw NAV changes are reflected directly in effective NAV; cross-tranche effects match expected rules per operation
 * @property POST03 jtEffectiveNAV increases only when the operation is JT_DEPOSIT
 * @property POST04 on stRedeem or jtRedeem, stImpermanentLoss decreases proportionately to stEffectiveNAV
 * @property POST05 on jtRedeem, jtImpermanentLoss decreases proportionately to jtEffectiveNAV
 * @property KER06 ST NAV per share only decreases when stImpermanentLoss increases (i.e., when jtEffectiveNAV is zero)
 * @property PreSyncProportionalPriceIncrease If stRawNAV and jtRawNAV both increase by the same rational factor (uniform underlying-asset price increase), jtEffectiveNAV must also increase by that same factor within 2 NAV units of rounding error
 */

import "../lib-summaries/OpenZeppelin/OZ_Math.spec";

using RoycoAccountant as roycoAccountant;

methods {
    function _.consumeScheduledOp(address,bytes) external => NONDET;
    function _.canCall(address,address,bytes4) external => NONDET;
    function _.syncTrancheAccounting() external => NONDET;
    function _.previewJTYieldShare(RoycoAccountant.MarketState,RoycoAccountant.NAV_UNIT,RoycoAccountant.NAV_UNIT,uint256,uint256,RoycoAccountant.NAV_UNIT) external => NONDET;
    function _.jtYieldShare(RoycoAccountant.MarketState,RoycoAccountant.NAV_UNIT,RoycoAccountant.NAV_UNIT,uint256,uint256,RoycoAccountant.NAV_UNIT) external => NONDET;
}

definition WAD() returns mathint = 10^18;
definition MIN_COVERAGE_WAD() returns mathint = 10^16;   // 1 %
definition MAX_COVERAGE_WAD() returns mathint = 10^18-1; // 99.9999999999999999 %

// Ghost variable that tracks the last timestamp.
ghost mathint lastTimestamp;

// The maximum timestamp the protocol supports
// TODO: This is 2104 since it's unsigned, but may still be worth mentioning the small limit.
definition MAX_TIMESTAMP() returns mathint = max_uint32 - 86400 * 365;

hook TIMESTAMP uint256 time {
    require to_mathint(time) < MAX_TIMESTAMP(), "timestamp below protocol end date";
    require to_mathint(time) >= lastTimestamp, "timestamp is monotone";
    lastTimestamp = time;
}

definition excludeUpgradeAndCall(method f) returns bool =
    f.selector != sig:upgradeToAndCall(address,bytes).selector;

/**
 * @title Fees distributed only in PERPETUAL state with no impermanent loss
 * @description If either protocol fee is non-zero (yield was distributed), then both stImpermanentLoss and jtImpermanentLoss must be zero and the market must be in PERPETUAL state.
 * @link_property PRE01
 * @assumption stNAVDustTolerance = 0 and jtNAVDustTolerance = 0 to not fail for dust jtImpermanentLoss
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/2ccf304b236e4ee39b5b160a688f8551?anonymousKey=942881ad9cfc21904dc8c0a5fd02199a3c956149
 */
rule preSyncNoYieldMeansNoFee()
{
    env e;
    RoycoAccountant.NAV_UNIT newStRawNAV;
    RoycoAccountant.NAV_UNIT newJtRawNAV;
    RoycoAccountant.SyncedAccountingState state;

    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.stNAVDustTolerance == 0, "Assume no Dust limit";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.jtNAVDustTolerance == 0, "Assume no Dust limit";

    state = roycoAccountant.preOpSyncTrancheAccounting(e, newStRawNAV, newJtRawNAV);

    assert state.stProtocolFeeAccrued != 0 || state.jtProtocolFeeAccrued != 0 =>
        state.stImpermanentLoss == 0 && state.jtImpermanentLoss == 0 && state.marketState == RoycoAccountant.MarketState.PERPETUAL;
}

/**
 * @title FIXED_TERM state in preOpSync implies fixedTermEndTimestamp is set
 * @description When preOpSync returns a FIXED_TERM market state, the end timestamp must be non-zero — a fixed-term period without a deadline is invalid.
 * @link_property PRE02
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/2ccf304b236e4ee39b5b160a688f8551?anonymousKey=942881ad9cfc21904dc8c0a5fd02199a3c956149
 */
rule preSyncFixedTermHasTimestamp()
{
    env e;
    RoycoAccountant.NAV_UNIT newStRawNAV;
    RoycoAccountant.NAV_UNIT newJtRawNAV;
    RoycoAccountant.SyncedAccountingState state;

    state = roycoAccountant.preOpSyncTrancheAccounting(e, newStRawNAV, newJtRawNAV);

    assert state.marketState == RoycoAccountant.MarketState.FIXED_TERM =>
        state.fixedTermEndTimestamp > 0;
}

/**
 * @title FIXED_TERM state in preOpSync implies no protocol fees accrued
 * @description When preOpSync returns a FIXED_TERM market state, at least one of stProtocolFeeAccrued and jtProtocolFeeAccrued must be zero; fees are only distributed when the market is in PERPETUAL mode.
 * @link_property PRE03
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/2ccf304b236e4ee39b5b160a688f8551?anonymousKey=942881ad9cfc21904dc8c0a5fd02199a3c956149
 */
rule preSyncFixedTermNoFee()
{
    env e;
    RoycoAccountant.NAV_UNIT newStRawNAV;
    RoycoAccountant.NAV_UNIT newJtRawNAV;
    RoycoAccountant.SyncedAccountingState state;

    state = roycoAccountant.preOpSyncTrancheAccounting(e, newStRawNAV, newJtRawNAV);

    assert state.marketState == RoycoAccountant.MarketState.FIXED_TERM =>
        state.stProtocolFeeAccrued == 0 || state.jtProtocolFeeAccrued == 0;
}


/**
 * @title Newly introduced ST impermanent loss implies jtEffectiveNAV = 0
 * @description If stImpermanentLoss was zero before the call but becomes positive after preOpSync, then jtEffectiveNAV must be zero — JT must be fully depleted before ST can take losses.
 * @link_property PRE04
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/2ccf304b236e4ee39b5b160a688f8551?anonymousKey=942881ad9cfc21904dc8c0a5fd02199a3c956149
 */
rule preSyncNewStLossImpliesJTEffectiveZero()
{
    env e;
    RoycoAccountant.NAV_UNIT newStRawNAV;
    RoycoAccountant.NAV_UNIT newJtRawNAV;
    RoycoAccountant.SyncedAccountingState state;

    RoycoAccountant.NAV_UNIT stLossBeforeCall = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTImpermanentLoss;

    state = roycoAccountant.preOpSyncTrancheAccounting(e, newStRawNAV, newJtRawNAV);

    assert state.stImpermanentLoss > stLossBeforeCall => state.jtEffectiveNAV == 0;
}

/**
 * @title Existing ST impermanent loss prevents jtEffectiveNAV from increasing
 * @description If stImpermanentLoss > 0 before preOpSync, then jtEffectiveNAV must not increase after the call — new yield cannot benefit JT while ST is in a loss position.
 * @link_property PRE05
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/2ccf304b236e4ee39b5b160a688f8551?anonymousKey=942881ad9cfc21904dc8c0a5fd02199a3c956149
 */
rule preSyncStLossImpliesJTEffectiveCannotIncrease()
{
    env e;
    RoycoAccountant.NAV_UNIT newStRawNAV;
    RoycoAccountant.NAV_UNIT newJtRawNAV;
    RoycoAccountant.SyncedAccountingState state;

    RoycoAccountant.NAV_UNIT jtEffNAVBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;

    state = roycoAccountant.preOpSyncTrancheAccounting(e, newStRawNAV, newJtRawNAV);

    assert state.stImpermanentLoss > 0 => state.jtEffectiveNAV <= jtEffNAVBefore;
}

/**
 * @title postOpSyncTrancheAccounting never distributes protocol fees
 * @description The post-operation sync only updates NAV accounting; protocol fees are exclusively distributed through preOpSync.
 * @link_property POST01
 * @status VERIFEID
 * @report https://prover.certora.com/output/74728/2ccf304b236e4ee39b5b160a688f8551?anonymousKey=942881ad9cfc21904dc8c0a5fd02199a3c956149
 */
rule postSyncNoFees() {
    env e;
    RoycoAccountant.Operation op;
    RoycoAccountant.NAV_UNIT newStRawNAV;
    RoycoAccountant.NAV_UNIT newJtRawNAV;
    RoycoAccountant.NAV_UNIT stSelfLiqBonusNAV;
    RoycoAccountant.SyncedAccountingState state;

    state = roycoAccountant.postOpSyncTrancheAccounting(e, op, newStRawNAV, newJtRawNAV, stSelfLiqBonusNAV);

    assert state.stProtocolFeeAccrued == 0;
    assert state.jtProtocolFeeAccrued == 0;
}

/**
 * @title Raw NAV changes are reflected directly in effective NAV per operation type
 * @description The total effective NAV change always equals the total raw NAV change. Cross-tranche effects follow per-operation rules: ST_DEPOSIT and JT_DEPOSIT do not affect the other tranche's effective NAV (except ST_REDEEM which transfers the self-liquidation bonus to JT).
 * @link_property POST02
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/2ccf304b236e4ee39b5b160a688f8551?anonymousKey=942881ad9cfc21904dc8c0a5fd02199a3c956149
 */
rule postSyncRawChangeDirectlyReflected() {
    env e;
    RoycoAccountant.Operation op;
    RoycoAccountant.NAV_UNIT stRawNAVBefore;
    RoycoAccountant.NAV_UNIT jtRawNAVBefore;
    RoycoAccountant.NAV_UNIT stEffectiveNAVBefore;
    RoycoAccountant.NAV_UNIT jtEffectiveNAVBefore;
    RoycoAccountant.NAV_UNIT newStRawNAV;
    RoycoAccountant.NAV_UNIT newJtRawNAV;
    RoycoAccountant.NAV_UNIT stSelfLiqBonusNAV;
    RoycoAccountant.SyncedAccountingState state;
    mathint deltaST;
    mathint deltaJT;
    mathint deltaEffJT;
    mathint deltaEffST;

    jtRawNAVBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV;
    stRawNAVBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV;

    require stRawNAVBefore < 2^255, "assume no signed overflow";
    require jtRawNAVBefore < 2^255, "assume no signed overflow";
    require newStRawNAV < 2^255, "assume no signed overflow";
    require newJtRawNAV < 2^255, "assume no signed overflow";

    jtEffectiveNAVBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    stEffectiveNAVBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV;
    deltaJT = newJtRawNAV - jtRawNAVBefore;
    deltaST = newStRawNAV - stRawNAVBefore;

    state = roycoAccountant.postOpSyncTrancheAccounting(e, op, newStRawNAV, newJtRawNAV, stSelfLiqBonusNAV);

    deltaEffJT = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV - jtEffectiveNAVBefore;
    deltaEffST = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV - stEffectiveNAVBefore;

    // All operations preserve the Eff = Raw invariant.
    assert deltaEffJT + deltaEffST == deltaJT + deltaST;

    // ST operations only change the JT effective NAV because of self liquidation bonus.
    assert op == RoycoAccountant.Operation.ST_REDEEM => deltaEffJT == -stSelfLiqBonusNAV;
    assert op == RoycoAccountant.Operation.ST_DEPOSIT => deltaEffJT == 0;
    
    // JT operations don't change the ST effective NAV.
    assert op == RoycoAccountant.Operation.JT_REDEEM => deltaEffST == 0;
    assert op == RoycoAccountant.Operation.JT_DEPOSIT => deltaEffST == 0;
}


/**
 * @title jtEffectiveNAV only increases on JT_DEPOSIT
 * @description The only operation that may increase jtEffectiveNAV is JT_DEPOSIT; all other operations (ST_DEPOSIT, ST_REDEEM, JT_REDEEM) must not increase jtEffectiveNAV.
 * @link_property POST03
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/2ccf304b236e4ee39b5b160a688f8551?anonymousKey=942881ad9cfc21904dc8c0a5fd02199a3c956149
 */
rule postSyncOnlyJTDepositIncreasesJTEffective() {
    env e;
    RoycoAccountant.Operation op;
    RoycoAccountant.NAV_UNIT newStRawNAV;
    RoycoAccountant.NAV_UNIT newJtRawNAV;
    RoycoAccountant.NAV_UNIT stSelfLiqBonusNAV;
    RoycoAccountant.SyncedAccountingState state;

    RoycoAccountant.NAV_UNIT jtEffNAVBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;

    state = roycoAccountant.postOpSyncTrancheAccounting(e, op, newStRawNAV, newJtRawNAV, stSelfLiqBonusNAV);

    assert state.jtEffectiveNAV > jtEffNAVBefore => op == RoycoAccountant.Operation.JT_DEPOSIT;
}

/**
 * @title stImpermanentLoss decreases proportionately to stEffectiveNAV on redeem
 * @description On ST_REDEEM or JT_REDEEM, stImpermanentLoss decreases in proportion to the reduction in stEffectiveNAV, ensuring the loss-per-NAV ratio is preserved (up to rounding).
 * @link_property POST04
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/2ccf304b236e4ee39b5b160a688f8551?anonymousKey=942881ad9cfc21904dc8c0a5fd02199a3c956149
 */
rule postSyncSTImpermanentLossProportionally() {
    env e;

    RoycoAccountant.Operation op;
    RoycoAccountant.NAV_UNIT effNAVBefore;
    RoycoAccountant.NAV_UNIT impermanentLossBefore;
    RoycoAccountant.NAV_UNIT effNAVAfter;
    RoycoAccountant.NAV_UNIT impermanentLossAfter;
    RoycoAccountant.NAV_UNIT newStRawNAV;
    RoycoAccountant.NAV_UNIT newJtRawNAV;
    RoycoAccountant.NAV_UNIT stSelfLiqBonusNAV;
    RoycoAccountant.SyncedAccountingState state;

    impermanentLossBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTImpermanentLoss;
    effNAVBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV;

    require op == RoycoAccountant.Operation.JT_REDEEM || op == RoycoAccountant.Operation.ST_REDEEM, "assume redeem operations";
    state = roycoAccountant.postOpSyncTrancheAccounting(e, op, newStRawNAV, newJtRawNAV, stSelfLiqBonusNAV);
    impermanentLossAfter = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTImpermanentLoss;
    effNAVAfter = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV;
    assert state.stImpermanentLoss == impermanentLossAfter;

    assert impermanentLossAfter * effNAVBefore >= impermanentLossBefore * effNAVAfter, "impermanentLoss per NAV increases";
    assert (impermanentLossAfter - 1) * effNAVBefore <= impermanentLossBefore * effNAVAfter, "impermanentLoss only suffers rounding";
}

/**
 * @title jtImpermanentLoss decreases proportionately to jtEffectiveNAV on redeem
 * @description On JT_REDEEM, jtImpermanentLoss decreases in proportion to the reduction in jtEffectiveNAV, ensuring the loss-per-NAV ratio is preserved (up to rounding).
 * @link_property POST05
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/2ccf304b236e4ee39b5b160a688f8551?anonymousKey=942881ad9cfc21904dc8c0a5fd02199a3c956149
 */
rule postSyncJTImpermanentLossProportionally() {
    env e;

    RoycoAccountant.Operation op;
    RoycoAccountant.NAV_UNIT effNAVBefore;
    RoycoAccountant.NAV_UNIT impermanentLossBefore;
    RoycoAccountant.NAV_UNIT effNAVAfter;
    RoycoAccountant.NAV_UNIT impermanentLossAfter;
    RoycoAccountant.NAV_UNIT newStRawNAV;
    RoycoAccountant.NAV_UNIT newJtRawNAV;
    RoycoAccountant.NAV_UNIT stSelfLiqBonusNAV;
    RoycoAccountant.SyncedAccountingState state;

    impermanentLossBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTImpermanentLoss;
    effNAVBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;

    require effNAVBefore < 2^255, "assume no signed overflow";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV < 2^255, "assume no signed overflow";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV < 2^255, "assume no signed overflow";
    require newStRawNAV < 2^255, "assume no signed overflow";
    require newJtRawNAV < 2^255, "assume no signed overflow";


    require op == RoycoAccountant.Operation.ST_REDEEM => impermanentLossBefore == 0, "st_redeem reverts in fixed_term state, jtImpermanentLoss is below dust in perpetual state, ignore dust";
    require op == RoycoAccountant.Operation.JT_REDEEM || op == RoycoAccountant.Operation.ST_REDEEM, "assume redeem operations";
    state = roycoAccountant.postOpSyncTrancheAccounting(e, op, newStRawNAV, newJtRawNAV, stSelfLiqBonusNAV);
    impermanentLossAfter = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTImpermanentLoss;
    effNAVAfter = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    assert state.jtImpermanentLoss == impermanentLossAfter;

    assert impermanentLossAfter * effNAVBefore <= impermanentLossBefore * effNAVAfter, "impermanentLoss per NAV decreases";
    assert (impermanentLossAfter + 1) * effNAVBefore >= impermanentLossBefore * effNAVAfter, "impermanentLoss only suffers rounding";
}

/**
 * @title ST effective NAV per share only decreases when jtEffectiveNAV is zero
 * @description The ST NAV can only decline if JT has been fully depleted (jtEffectiveNAV = 0), meaning losses have exhausted the JT buffer and are now hitting ST.
 * @link_property KER06
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/2ccf304b236e4ee39b5b160a688f8551?anonymousKey=942881ad9cfc21904dc8c0a5fd02199a3c956149
 */
rule StNAVIncreasesUnlessJTIsZero() {

    env e;
    RoycoAccountant.NAV_UNIT newStRawNAV;
    RoycoAccountant.NAV_UNIT newJtRawNAV;
    RoycoAccountant.SyncedAccountingState state;

    RoycoAccountant.NAV_UNIT stEffectiveNAVBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV;

    state = roycoAccountant.preOpSyncTrancheAccounting(e, newStRawNAV, newJtRawNAV);

    RoycoAccountant.NAV_UNIT stEffectiveNAVAfter = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV;
    RoycoAccountant.NAV_UNIT jtEffectiveNAVAfter = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;

    assert stEffectiveNAVAfter < stEffectiveNAVBefore => jtEffectiveNAVAfter == 0;
}

/**
 * @title Proportional raw NAV increase leads to proportional JT effective NAV increase
 * @description If stRawNAV and jtRawNAV both increase by the same rational factor — i.e.
 *   newStRawNAV / oldStRawNAV = newJtRawNAV / oldJtRawNAV — simulating a uniform
 *   underlying-asset price increase, then jtEffectiveNAV must also increase by that same
 *   factor.  Allowed deviation: at most 2 NAV units of absolute rounding error.
 *   Formally: |newJtEffectiveNAV * oldStRawNAV - oldJtEffectiveNAV * newStRawNAV|
 *             ≤ 2 * oldStRawNAV
 * @link_property PreSyncProportionalPriceIncrease
 * @status TIMEOUT
 */
rule preSyncProportionalPriceIncreasePreservesJTEffectiveCase1()
{
    env e;
    RoycoAccountant.NAV_UNIT newStRawNAV;
    RoycoAccountant.NAV_UNIT newJtRawNAV;

    RoycoAccountant.NAV_UNIT oldStRawNAV = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV;
    RoycoAccountant.NAV_UNIT oldJtRawNAV = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV;
    RoycoAccountant.NAV_UNIT oldStEffectiveNAV = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV;
    RoycoAccountant.NAV_UNIT oldJtEffectiveNAV = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;

    require oldJtEffectiveNAV >= oldJtRawNAV, "case 1";

    // Both starting NAVs must be positive so the price factor is well-defined.
    //require oldStRawNAV > 0, "NAV must exist";
    //require oldJtRawNAV > 0, "NAV must exist";
    // There must be no ST impermanent loss
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTImpermanentLoss == 0;
    require oldStRawNAV + oldJtRawNAV == oldStEffectiveNAV + oldJtEffectiveNAV, "main NAV invariant";

    // Same rational factor: newSt / oldSt = newJt / oldJt  (cross-multiplication form)
    require to_mathint(newStRawNAV) * to_mathint(oldJtRawNAV) ==
            to_mathint(newJtRawNAV) * to_mathint(oldStRawNAV), "same rational price factor";

    // Price is non-decreasing (simulating a price increase, not a decrease)
    require to_mathint(newStRawNAV) >= to_mathint(oldStRawNAV);
    require to_mathint(newJtRawNAV) >= to_mathint(oldJtRawNAV);

    // Overflow guards for intermediate products
    //require oldStRawNAV < 2^255, "assume no signed overflow";
    //require oldJtRawNAV < 2^255, "assume no signed overflow";
    //require newStRawNAV < 2^255, "assume no signed overflow";
    //require newJtRawNAV < 2^255, "assume no signed overflow";
    //require oldJtEffectiveNAV < 2^255, "assume no signed overflow";

    roycoAccountant.preOpSyncTrancheAccounting(e, newStRawNAV, newJtRawNAV);

    RoycoAccountant.NAV_UNIT newJtEffectiveNAV = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    RoycoAccountant.NAV_UNIT newStEffectiveNAV = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV;

    // jtEffectiveNAV must increase at least by the same rational factor, up to 2 NAV rounding.
    // Equivalent (avoiding division) to: newJtEff + 2 >= oldJtEff * newSt / oldSt
    assert to_mathint(oldJtEffectiveNAV) * to_mathint(newStRawNAV) <=
           (to_mathint(newJtEffectiveNAV) + 2) * to_mathint(oldStRawNAV),
           "JT effective NAV grew by at least the price factor (up to 2 NAV rounding)";
}


/**
 * @title Proportional raw NAV increase leads to proportional JT effective NAV increase
 * @description If stRawNAV and jtRawNAV both increase by the same rational factor — i.e.
 *   newStRawNAV / oldStRawNAV = newJtRawNAV / oldJtRawNAV — simulating a uniform
 *   underlying-asset price increase, then jtEffectiveNAV must also increase by that same
 *   factor.  Allowed deviation: at most 2 NAV units of absolute rounding error.
 *   Formally: |newJtEffectiveNAV * oldStRawNAV - oldJtEffectiveNAV * newStRawNAV|
 *             ≤ 2 * oldStRawNAV
 * @link_property PreSyncProportionalPriceIncrease
 * @status TIMEOUT
 */
rule preSyncProportionalPriceIncreasePreservesJTEffectiveCase2()
{
    env e;
    RoycoAccountant.NAV_UNIT newStRawNAV;
    RoycoAccountant.NAV_UNIT newJtRawNAV;

    RoycoAccountant.NAV_UNIT oldStRawNAV = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV;
    RoycoAccountant.NAV_UNIT oldJtRawNAV = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV;
    RoycoAccountant.NAV_UNIT oldStEffectiveNAV = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV;
    RoycoAccountant.NAV_UNIT oldJtEffectiveNAV = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;

    require oldJtEffectiveNAV < oldJtRawNAV, "case 2";

    // Both starting NAVs must be positive so the price factor is well-defined.
    //require oldStRawNAV > 0, "NAV must exist";
    //require oldJtRawNAV > 0, "NAV must exist";
    // There must be no ST impermanent loss
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTImpermanentLoss == 0;
    require oldStRawNAV + oldJtRawNAV == oldStEffectiveNAV + oldJtEffectiveNAV, "main NAV invariant";

    // Same rational factor: newSt / oldSt = newJt / oldJt  (cross-multiplication form)
    require to_mathint(newStRawNAV) * to_mathint(oldJtRawNAV) ==
            to_mathint(newJtRawNAV) * to_mathint(oldStRawNAV), "same rational price factor";

    // Price is non-decreasing (simulating a price increase, not a decrease)
    require to_mathint(newStRawNAV) >= to_mathint(oldStRawNAV);
    require to_mathint(newJtRawNAV) >= to_mathint(oldJtRawNAV);

    // Overflow guards for intermediate products
    //require oldStRawNAV < 2^255, "assume no signed overflow";
    //require oldJtRawNAV < 2^255, "assume no signed overflow";
    //require newStRawNAV < 2^255, "assume no signed overflow";
    //require newJtRawNAV < 2^255, "assume no signed overflow";
    //require oldJtEffectiveNAV < 2^255, "assume no signed overflow";

    roycoAccountant.preOpSyncTrancheAccounting(e, newStRawNAV, newJtRawNAV);

    RoycoAccountant.NAV_UNIT newJtEffectiveNAV = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    RoycoAccountant.NAV_UNIT newStEffectiveNAV = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV;

    // jtEffectiveNAV must increase at least by the same rational factor, up to 2 NAV rounding.
    // Equivalent (avoiding division) to: newJtEff + 2 >= oldJtEff * newSt / oldSt
    assert to_mathint(oldJtEffectiveNAV) * to_mathint(newStRawNAV) <=
           (to_mathint(newJtEffectiveNAV) + 2) * to_mathint(oldStRawNAV),
           "JT effective NAV grew by at least the price factor (up to 2 NAV rounding)";
}
