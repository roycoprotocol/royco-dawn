using RoycoAccountant as roycoAccountant;

methods {
    function _.consumeScheduledOp(address,bytes) external => NONDET;
    function _.canCall(address,address,bytes4) external => NONDET;
    function _.syncTrancheAccounting() external => NONDET;
    function _.previewJTYieldShare(RoycoAccountant.MarketState,RoycoAccountant.NAV_UNIT,RoycoAccountant.NAV_UNIT,uint256,uint256,RoycoAccountant.NAV_UNIT) external => NONDET;
    function _.jtYieldShare(RoycoAccountant.MarketState,RoycoAccountant.NAV_UNIT,RoycoAccountant.NAV_UNIT,uint256,uint256,RoycoAccountant.NAV_UNIT) external => NONDET;
}

definition excludeUpgradeAndCall(method f) returns bool =
    f.selector != sig:upgradeToAndCall(address,bytes).selector;

invariant sumEffectiveEqualsRaw() 
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV +
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV ==
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV +
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV
    filtered { f -> excludeUpgradeAndCall(f) }

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
