using RoycoAccountant as roycoAccountant;

methods {
    function _.consumeScheduledOp(address,bytes) external => NONDET;
    function _.canCall(address,address,bytes4) external => NONDET;
    function _.syncTrancheAccounting() external => NONDET;
    function _.previewJTYieldShare(RoycoAccountant.MarketState,RoycoAccountant.NAV_UNIT,RoycoAccountant.NAV_UNIT,uint256,uint256,RoycoAccountant.NAV_UNIT) external => NONDET;
    function _.jtYieldShare(RoycoAccountant.MarketState,RoycoAccountant.NAV_UNIT,RoycoAccountant.NAV_UNIT,uint256,uint256,RoycoAccountant.NAV_UNIT) external => NONDET;
}

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

invariant sumEffectiveEqualsRaw() 
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV +
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV ==
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV +
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV
    filtered { f -> excludeUpgradeAndCall(f) }

invariant marketStateValid()
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastMarketState == RoycoAccountant.MarketState.PERPETUAL
    || roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastMarketState == RoycoAccountant.MarketState.FIXED_TERM
    filtered { f -> excludeUpgradeAndCall(f) }


invariant anyLossImpliesJTEffectivelyZero() 
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTImpermanentLoss > 0
    || roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTImpermanentLoss > 0
    || roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastMarketState != RoycoAccountant.MarketState.PERPETUAL
    => roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV == 0
    filtered { f -> excludeUpgradeAndCall(f)}
{
    preserved { 
        requireInvariant stLossImpliesPerpetual();
        requireInvariant stLossImpliesNoJTLoss();
    }
}

//TODO: why stNAVDust instead of jtNAVDust?  Is this a bug in RoycoAccountant or intentional?
invariant jtLossImpliesFixedTerm() 
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTImpermanentLoss > 
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.stNAVDustTolerance
    => roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastMarketState == RoycoAccountant.MarketState.FIXED_TERM
    filtered { f -> excludeUpgradeAndCall(f)}

invariant noJTLossImpliesPerpetual() 
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTImpermanentLoss == 0
    => roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastMarketState == RoycoAccountant.MarketState.PERPETUAL
    filtered { f -> excludeUpgradeAndCall(f) }

invariant stLossImpliesPerpetual() 
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTImpermanentLoss > 0
    => roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastMarketState == RoycoAccountant.MarketState.PERPETUAL
    filtered { f -> excludeUpgradeAndCall(f) }

invariant stLossImpliesNoJTLoss() 
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTImpermanentLoss > 0
    => roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTImpermanentLoss == 0
    filtered { f -> excludeUpgradeAndCall(f) }

invariant termDurationZeroAlwaysPerpetual() 
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.fixedTermDurationSeconds == 0
    => roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastMarketState == RoycoAccountant.MarketState.PERPETUAL
    filtered { f -> excludeUpgradeAndCall(f)}

invariant fixedTermIsBounded()
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastMarketState == RoycoAccountant.MarketState.FIXED_TERM
    => roycoAccountant.ext_Royco_storage_RoycoAccountantState.fixedTermEndTimestamp > 0
    filtered { f -> excludeUpgradeAndCall(f)}
