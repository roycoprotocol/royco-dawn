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

/* @title PRE01 */
rule preSyncNoYieldMeansNoFee()
{
    env e;
    RoycoAccountant.NAV_UNIT newStRawNAV;
    RoycoAccountant.NAV_UNIT newJtRawNAV;
    RoycoAccountant.SyncedAccountingState state;

    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.stNAVDustTolerance == 0, "Assume no Dust limit";

    state = roycoAccountant.preOpSyncTrancheAccounting(e, newStRawNAV, newJtRawNAV);

    assert state.stProtocolFeeAccrued != 0 || state.jtProtocolFeeAccrued != 0 =>
        state.stImpermanentLoss == 0 && state.jtImpermanentLoss == 0 && state.marketState == RoycoAccountant.MarketState.PERPETUAL;
}

/* @title PRE01b */
rule preSyncNoYieldMeansNoFeeCorrected()
{
    env e;
    RoycoAccountant.NAV_UNIT newStRawNAV;
    RoycoAccountant.NAV_UNIT newJtRawNAV;
    RoycoAccountant.SyncedAccountingState state;

    RoycoAccountant.NAV_UNIT jtEffectiveNAVBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    RoycoAccountant.NAV_UNIT stEffectiveNAVBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV;
    require jtEffectiveNAVBefore < 2^250, "NAV in range";
    require stEffectiveNAVBefore < 2^250, "NAV in range";

    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV < 2^250, "NAV in range";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV < 2^250, "NAV in range";

    state = roycoAccountant.preOpSyncTrancheAccounting(e, newStRawNAV, newJtRawNAV);

    assert state.stProtocolFeeAccrued != 0 => state.stEffectiveNAV > stEffectiveNAVBefore;
    assert state.jtProtocolFeeAccrued != 0 => state.jtEffectiveNAV > jtEffectiveNAVBefore;
}

/* @title PRE02 */
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

/* @title PRE03 */
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


/* @title PRE04 */
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

/* @title PRE05 */
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

/* @title POST01 */
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


/* @title POST03 */
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

