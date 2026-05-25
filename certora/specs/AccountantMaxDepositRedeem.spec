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
definition saturatingSub(mathint a, mathint b) returns mathint = (a < b ? 0 : a - b);

hook TIMESTAMP uint256 time {
    require to_mathint(time) < MAX_TIMESTAMP(), "timestamp below protocol end date";
    require to_mathint(time) >= lastTimestamp, "timestamp is monotone";
    lastTimestamp = time;
}

definition excludeUpgradeAndCall(method f) returns bool =
    f.selector != sig:upgradeToAndCall(address,bytes).selector;

/* @title KER10 */
rule maxStDepositCorrect {
    env e;
    RoycoAccountant.NAV_UNIT stRawNAV;
    RoycoAccountant.NAV_UNIT jtRawNAV;
    RoycoAccountant.NAV_UNIT maxSTDeposit;
    RoycoAccountant.SyncedAccountingState state;
    RoycoAccountant.NAV_UNIT stDeposit;


    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV == jtRawNAV, "assumption: no price change";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV == stRawNAV, "assumption: no price change";
    maxSTDeposit = roycoAccountant.maxSTDepositGivenCoverage(e, stRawNAV, jtRawNAV);
    require maxSTDeposit > 0, "not yet fully utilized";
    require stDeposit <= maxSTDeposit, "deposit less than max";
    require stRawNAV + stDeposit < 2^250;
    roycoAccountant.preOpSyncTrancheAccounting(e, stRawNAV, jtRawNAV);
    RoycoAccountant.NAV_UNIT newSTRawNAV = assert_uint256(stRawNAV + stDeposit);
    state = roycoAccountant.postOpSyncTrancheAccounting(e, RoycoAccountant.Operation.ST_DEPOSIT, newSTRawNAV, jtRawNAV, 0);
    assert state.utilizationWAD <= WAD(), "utilization is below max";
}

/* @title KER09 */
rule maxJtRedeemCorrect {
    env e;
    RoycoAccountant.NAV_UNIT stRawNAV;
    RoycoAccountant.NAV_UNIT jtRawNAV;
    RoycoAccountant.AssetClaims jtNotionalClaims;
    RoycoAccountant.NAV_UNIT claimOnStNAV;
    RoycoAccountant.NAV_UNIT claimOnJtNAV;
    RoycoAccountant.NAV_UNIT totalClaimable;
    RoycoAccountant.NAV_UNIT stClaimable;
    RoycoAccountant.NAV_UNIT jtClaimable;
    RoycoAccountant.NAV_UNIT maxJTRedeem;
    RoycoAccountant.NAV_UNIT jtRedeem;
    RoycoAccountant.SyncedAccountingState statePre;
    RoycoAccountant.SyncedAccountingState statePost;
    uint256 totalTrancheSharesAfterMintingFees;
 
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV == jtRawNAV, "assumption: no price change";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV == stRawNAV, "assumption: no price change";

    statePre = roycoAccountant.previewSyncTrancheAccounting(e, stRawNAV, jtRawNAV);
    claimOnStNAV = assert_uint256(saturatingSub(statePre.jtEffectiveNAV, statePre.jtRawNAV));
    claimOnJtNAV = assert_uint256(statePre.jtRawNAV - saturatingSub(statePre.stEffectiveNAV, statePre.stRawNAV));

    (totalClaimable, stClaimable, jtClaimable) = roycoAccountant.maxJTWithdrawalGivenCoverage(e, stRawNAV, jtRawNAV, claimOnStNAV, claimOnJtNAV);
    require jtRedeem < totalClaimable, "redeem less than max";
    require jtRedeem < totalClaimable, "redeem less than max";
    RoycoAccountant.NAV_UNIT newSTRawNAV = assert_uint256(stRawNAV - (jtRedeem * claimOnStNAV) / (claimOnStNAV + claimOnJtNAV));
    RoycoAccountant.NAV_UNIT newJTRawNAV = assert_uint256(jtRawNAV - (jtRedeem * claimOnJtNAV) / (claimOnStNAV + claimOnJtNAV));
    statePost = roycoAccountant.postOpSyncTrancheAccounting(e, RoycoAccountant.Operation.JT_REDEEM, newSTRawNAV, newJTRawNAV, 0);
    assert statePost.utilizationWAD <= WAD();
}

