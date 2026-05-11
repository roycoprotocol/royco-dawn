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

/* @title The sum JT+ST raw NAV equals the sum JT+ST effective NAV.
 * @status Verified
 */
invariant sumEffectiveEqualsRaw() 
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV +
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV ==
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV +
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV
    filtered { f -> excludeUpgradeAndCall(f) }


/* @title If there is jtImpermanentLoss above dust the market state is FIXED_TERM.
 * @notice Currently violated by setting dust or initialize.
 */
invariant jtLossImpliesFixedTerm() 
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTImpermanentLoss > 
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.stNAVDustTolerance
    => roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastMarketState == RoycoAccountant.MarketState.FIXED_TERM
    filtered { f -> excludeUpgradeAndCall(f)}

/* @title If there is no jtImpermanentLoss the market state is PERPETUAL.
 * @notice Currently violated by redeeming (almost) all jt tokens.
 */
invariant noJTLossImpliesPerpetual() 
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTImpermanentLoss == 0
    => roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastMarketState == RoycoAccountant.MarketState.PERPETUAL
    filtered { f -> excludeUpgradeAndCall(f) }

/* @title If there is stImpermanentLoss the market state is PERPETUAL.
 */
invariant stLossImpliesPerpetual() 
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTImpermanentLoss > 0
    => roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastMarketState == RoycoAccountant.MarketState.PERPETUAL
    filtered { f -> excludeUpgradeAndCall(f) }

/* @title If there is stImpermanentLoss there cannot be jtImpermanentLoss
 */
invariant stLossImpliesNoJTLoss() 
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTImpermanentLoss > 0
    => roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTImpermanentLoss == 0
    filtered { f -> excludeUpgradeAndCall(f) }

/* @title If there is stImpermanentLoss the jtEffectiveNAV is zero
 * @notice This is violated by jtDeposit: it will increase jtEffectiveNAV without repaying the ST losses.  This is how the contract should work, so this invariant is not a good invariant for the contract.
 */
invariant stLossImpliesJTEffectivelyZero() 
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTImpermanentLoss > 0
    => roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV == 0
    filtered { f -> excludeUpgradeAndCall(f)}

/* @title If the termDuration is 0, the marketstate is always PERPTUAL.
 */
invariant termDurationZeroAlwaysPerpetual() 
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.fixedTermDurationSeconds == 0
    => roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastMarketState == RoycoAccountant.MarketState.PERPETUAL
    filtered { f -> excludeUpgradeAndCall(f)}


/*  There is no lastUtilization WAD
 * TODO: move to PRE properties
invariant utilizationHighImpliesPerpetual()
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastUtilizationWAD >=
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.liquidationUtilizationWAD
    || roycoAccountant.ext_Royco_storage_RoycoAccountantState.jtEffectiveNAV == 0
    => roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastMarketState == RoycoAccountant.MarketState.PERPETUAL;
*/

/* @title If the marketstate is FIXED_TERM, the fixedTermEndTimestamp must be set.
 * @notice violated by initialize, but this should not be possible to be executed once initialization is complete.
 */
invariant fixedTermIsBounded()
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastMarketState == RoycoAccountant.MarketState.FIXED_TERM
    => roycoAccountant.ext_Royco_storage_RoycoAccountantState.fixedTermEndTimestamp > 0
    filtered { f -> excludeUpgradeAndCall(f)}

/* TODO move to pre:
invariant noFeesWhenFixedTerm()
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastMarketState == RoycoAccountant.MarketState.FIXED_TERM
    => roycoAccountant.ext_Royco_storage_RoycoAccountantState.stProtocolFeeAccrued == 0
    && roycoAccountant.ext_Royco_storage_RoycoAccountantState.jtProtocolFeeAccrued == 0
    filtered { f -> excludeUpgradeAndCall(f)}
*/

invariant liquidationGreaterThanOne()
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.liquidationUtilizationWAD > WAD()
    filtered { f -> excludeUpgradeAndCall(f) }

invariant coverageBetaLessThanOne()
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.coverageWAD *
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.betaWAD < WAD()*WAD()
    filtered { f -> excludeUpgradeAndCall(f) }

/* @title Coverage is always at least the min coverage.
 * @notice The code contract doesn't satisfy the property and we need to exclude it by checking if _initialized is max_uint64.
 */
invariant coverageGreaterEqualMin()
    roycoAccountant.ext_openzeppelin_storage_Initializable._initialized != max_uint64 =>
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.coverageWAD >= MIN_COVERAGE_WAD()
    filtered { f -> excludeUpgradeAndCall(f) }

invariant coverageLessEqualMax()
    roycoAccountant.ext_Royco_storage_RoycoAccountantState.coverageWAD <= MAX_COVERAGE_WAD()
    filtered { f -> excludeUpgradeAndCall(f) }
