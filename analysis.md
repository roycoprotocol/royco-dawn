# `depositSameJunior` Rule — Violation Analysis

## The Rule

`depositSameJunior` asserts that two consecutive identical JT deposits should mint approximately the same number of shares (within a tolerance of 20):

```cvl
uint256 shares1 = juniorTranche.deposit(e, amount, owner);
uint256 shares2 = juniorTranche.deposit(e, amount, owner);
assert shares1 <= shares2 + 20;
```

Shares are computed as `totalSupply × amount / jtEffectiveNAV`. The assertion fails when `jtEffectiveNAV` is much lower during the first deposit than during the second.

---

## Root Cause

All counterexamples share the same structural cause: **a stale `lastJTRawNAV` checkpoint that is much larger than the actual current raw NAV**.

When the first deposit triggers `_preOpSyncTrancheAccounting` (RoycoAccountant.sol:603), the function recomputes raw NAV from on-chain assets and compares it to the stored checkpoint. A large negative delta (`deltaJTRawNAV = currentRawNAV − lastJTRawNAV`) causes `jtEffectiveNAV` to collapse. The first depositor mints shares at this depressed valuation. By the time the second deposit runs its own sync, the NAV has partially recovered (deposits add capital, YDM distributes yield), so `jtEffectiveNAV` is higher and the second depositor gets fewer shares for the same amount.

### Deposit pricing formula

```
shares = totalSupply × depositAmount / jtEffectiveNAV
```

A lower `jtEffectiveNAV` at first deposit → more shares → violation.

---

## The FIXED_TERM Protection Mechanism — and Why It Fails

`jtDeposit` requires the market to be in `PERPETUAL` state (RoycoKernel.sol:426). When JT suffers significant impermanent loss (`jtImpermanentLoss`), the market should transition to `FIXED_TERM`, blocking further JT deposits until the loss is resolved. This is the intended protection against the violation.

However, the pre-op sync that computes the new market state **runs before** the require check:

```solidity
// RoycoKernel.sol:424–426
SyncedAccountingState memory state = _preOpSyncTrancheAccounting();  // ← sync first
require(state.marketState == MarketState.PERPETUAL, ...);              // ← then check
```

The require checks the **post-sync** market state, not the stored one. This means a sync that transitions `FIXED_TERM → PERPETUAL` satisfies the require in the same call that makes the deposit.

### The branch logic (RoycoAccountant.sol:597–637)

```solidity
uint256 utilizationWAD = UtilsLib.computeUtilization(
    _stRawNAV, _jtRawNAV, betaWAD, coverageWAD, jtEffectiveNAV
);
uint256 liquidationUtilizationWAD = $.liquidationUtilizationWAD;

// Branch 1: force PERPETUAL, erase all IL
if (
    fixedTermDurationSeconds == 0
    || (initialMarketState == FIXED_TERM && fixedTermEndTimestamp <= block.timestamp)
    || utilizationWAD >= liquidationUtilizationWAD
    || stImpermanentLoss != 0
) {
    jtImpermanentLoss = 0;
    resultingMarketState = PERPETUAL;

// Branch 2: loss within dust tolerance, stay PERPETUAL
} else if (jtImpermanentLoss <= stNAVDustTolerance + jtNAVDustTolerance) {
    if (initialMarketState == PERPETUAL || jtImpermanentLoss == 0)
        resultingMarketState = PERPETUAL;
    else
        resultingMarketState = FIXED_TERM;

// Branch 3: trigger FIXED_TERM
} else {
    resultingMarketState = FIXED_TERM;
    if (initialMarketState == PERPETUAL)
        fixedTermEndTimestamp = block.timestamp + fixedTermDurationSeconds;
}
```

FIXED_TERM (Branch 3) only fires in a **narrow corridor**: all four Branch 1 conditions are false, *and* `jtImpermanentLoss > dustTolerance`. Every counterexample found an escape route from this corridor.

---

## All Ways FIXED_TERM Fails to Trigger

### Branch 1 — forces PERPETUAL and erases IL unconditionally

#### 1. `fixedTermDurationSeconds == 0`
The market is configured as permanently perpetual. FIXED_TERM is structurally impossible regardless of impermanent loss. IL is always erased.

**Found in:** CE2 (`6893_52d9c2e678a04885bcfa61eae2184f4d`)

---

#### 2. Previous fixed term just expired
When `initialMarketState == FIXED_TERM` and `fixedTermEndTimestamp <= block.timestamp`, the elapsed-term sub-condition fires.

Because the pre-op sync runs before the require check, the sequence in `jtDeposit` is:
1. Sync detects `fixedTermEndTimestamp (1) ≤ block.timestamp (1)`
2. Branch 1 fires: all IL erased, `resultingMarketState = PERPETUAL`
3. `require PERPETUAL` → passes
4. Deposit proceeds at the collapsed NAV

The new IL computed in that same sync (from the stale NAV checkpoint) is erased as part of the transition. A fresh fixed term could only be started on the *next* sync (Branch 3 at line 636 sets `fixedTermEndTimestamp = block.timestamp + fixedTermDurationSeconds` only when transitioning from PERPETUAL). The first depositor has already received their discounted shares.

Note: `betaWAD = 0` appeared alongside this bypass (CE4). With `stRawNAV = 0` and `betaWAD = 0`, `totalCoveredExposure = 0` (UtilsLib.sol:44–46), so `utilizationWAD = 0`. This prevents Branch 1 from accidentally firing via the utilization check — ensuring only the elapsed-term sub-condition is the active bypass.

**Found in:** CE4 (`6893_3a101c9c72a34c0fab1afbedcd90864c`)

---

#### 3. `utilizationWAD >= liquidationUtilizationWAD`

Utilization is computed as:
```solidity
// UtilsLib.sol:44,50
totalCoveredExposure = stRawNAV + jtRawNAV.mulDiv(betaWAD, WAD, Ceil);
if (totalCoveredExposure == 0) return 0;                                   // early exit
utilization = coverageWAD.mulDiv(totalCoveredExposure, jtEffectiveNAV, Ceil);
```

Branch 1 fires via this condition in two distinct scenarios:

**3a. `liquidationUtilizationWAD == 0`**
Since `uint256 >= 0` is always true, `utilizationWAD (any) >= 0` fires Branch 1 unconditionally — exactly like `fixedTermDurationSeconds == 0` but via a different field.

This state is theoretically excluded by the `liquidationGreaterThanOne` invariant (AccountantInvariants.spec:155–158), which requires `liquidationUtilizationWAD > WAD`. However, the invariant is guarded:
```cvl
invariant liquidationGreaterThanOne()
    roycoAccountant._initialized != max_uint64 =>
    roycoAccountant.liquidationUtilizationWAD > WAD()
```
`RoycoBase` calls `_disableInitializers()` in its constructor (RoycoBase.sol:20), setting `_initialized = MAX_UINT64` on the implementation contract. In this state the antecedent is false, the invariant is vacuously satisfied, and `liquidationUtilizationWAD = 0` is unconstrained.

The Certora Prover analyzes the implementation contract directly (not through the proxy). It picks `_initialized = MAX_UINT64` as the initial state, making `requireInvariant liquidationGreaterThanOne()` inside `requireAllInvariants_Accountant()` add no useful constraint on `liquidationUtilizationWAD`.

**Found in:** CE3 (`6893_63b60152b37c431b834036c5a33316a8`). Closed by adding `require liquidationUtilizationWAD > WAD()` directly.

**3b. Loss so large it collapses `jtEffectiveNAV`**
A sufficiently large loss shrinks `jtEffectiveNAV` toward zero, driving `utilization = coverageWAD × totalExposure / jtEffectiveNAV` above `liquidationUtilizationWAD`. This fires Branch 1 even with a properly configured `liquidationUtilizationWAD > WAD`.

This is intentional protocol behavior: a near-insolvent JT tranche should not block ST redemptions with a FIXED_TERM lock. But the consequence is that very large losses paradoxically receive *less* protection than moderate losses.

**Not yet exploited in a counterexample, but structurally possible.**

---

#### 4. `stImpermanentLoss != 0`
If ST already carries impermanent loss, the market is in a distressed state. Branch 1 forces PERPETUAL so ST can redeem and the YDM can restore collateralization. Any JT impermanent loss computed in the same sync is erased alongside ST's.

**Not yet exploited in a counterexample, but structurally possible.**

---

### Branch 2 — stays PERPETUAL via dust tolerance

#### 5. `jtImpermanentLoss <= stNAVDustTolerance + jtNAVDustTolerance` (from PERPETUAL)
If the computed IL after the NAV collapse falls within the combined dust tolerance, the market stays PERPETUAL. The prover can engineer the initial state so the resulting `jtImpermanentLoss` lands exactly at or below the tolerance ceiling.

In CE1, `jtNAVDustTolerance = 4` and the sync produced `jtImpermanentLoss = 4` — the tolerance was set by the prover to exactly absorb the result of an enormous NAV collapse (`2^255 → 4`). The dust tolerance branch is designed to absorb rounding noise; here it absorbed a catastrophic loss.

**Found in:** CE1 (`6893_5388c4d2792543b297314df3d0ee699a`, main counterexample)

---

## Four Counterexamples Summary

| | CE1 (main) | CE2 | CE3 | CE4 |
|-|------------|-----|-----|-----|
| Job | `5388c4d2` | `52d9c2e6` | `63b60152` | `3a101c9c` |
| `fixedTermDurationSeconds` | 1 | **0** | 1 | 1 |
| `jtNAVDustTolerance` | **4** | 0 | 0 | 0 |
| `liquidationUtilizationWAD` | WAD+1 | — | **0** (via `_initialized=MAX_UINT64`) | WAD+1 |
| `initialMarketState` | PERPETUAL | PERPETUAL | PERPETUAL | **FIXED_TERM** |
| `fixedTermEndTimestamp` | — | — | — | **= block.timestamp** |
| `betaWAD` | >0 | 0 | >0 | **0** |
| Bypass branch | Branch 2 | Branch 1, sub 1 | Branch 1, sub 3a | Branch 1, sub 2 |
| Bypass mechanism | Dust tolerance = resulting IL | Permanently perpetual | Liquidation threshold vacuously 0 | Expired fixed term |
| NAV mismatch | `2^254×` (near-zero oracle rate) | ~4.6× (realistic rate) | ~10× | ~7× |
| Shares1 / Shares2 | 123 / 102 | 142 / 121 | 61 / 40 | shares1 > shares2 + 20 |
| Precondition added after | — | `fixedTermDurationSeconds > 0` | `liquidationUtilizationWAD > WAD()` | pending |

---

## Preconditions Needed in the Rule

| # | Condition | Closes |
|---|-----------|--------|
| 1 | `require fixedTermDurationSeconds > 0` ✓ | CE2: permanently perpetual |
| 2 | `require stNAVDustTolerance == 0 && jtNAVDustTolerance == 0` ✓ | CE1: dust tolerance bypass |
| 3 | `require liquidationUtilizationWAD > WAD()` ✓ | CE3: zero liquidation threshold |
| 4 | `require lastMarketState == PERPETUAL` | CE4: expired fixed term |
| 5 | `require lastSTImpermanentLoss == 0` | Branch 1 sub 4: distressed state |
| 6 | Bound NAV mismatch (e.g. `require lastJTRawNAV <= jtOwnedYieldBearingAssets × K`) | All: stale checkpoint |

**Note on precondition 3:** The direct `require` is necessary because `requireInvariant liquidationGreaterThanOne()` is insufficient — the invariant's `_initialized != max_uint64` guard is vacuously bypassed when the prover sets `_initialized = MAX_UINT64` (the implementation contract's constructor state).

**Note on precondition 3b (loss-collapses-utilization):** Hard to exclude with a simple require. Requires either bounding the NAV mismatch tightly enough that the post-sync `jtEffectiveNAV` cannot drop below `totalCoveredExposure / liquidationUtilizationWAD`, or accepting that this case represents legitimate protocol behavior (forced PERPETUAL near insolvency) and treating it as out of scope for this rule.
