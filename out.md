
## Counterexample Analysis: `depositSameJunior` Rule Violation

### Summary
The rule checks that two identical deposits of the same amount should result in approximately the same number of shares (within a tolerance of 20 shares). **The counterexample shows a violation where the first depositor receives 123 shares but the second depositor receives only 102 shares for the same deposit of 4 assets** - a difference of 21 shares that exceeds the allowed tolerance.

### Root Cause: Junior Tranche Effective NAV Inflation

The issue stems from **impermanent loss recovery dynamics** that cause the Junior Tranche's effective NAV to increase disproportionately between deposits, creating unfavorable pricing for later depositors.

### Detailed Scenario

**Initial State (highly unusual):**
- JT total supply: 494 shares
- lastJTRawNAV: `2^255 - 10` (artificially large value)
- lastJTEffectiveNAV: `2^255 + 2` (even larger!)
- lastJTImpermanentLoss: 3

**After first kernel.jtDeposit(amount=4):**
- lastJTRawNAV: 0 → **2**
- lastJTEffectiveNAV: `2^255 + 2` → **4**
- lastJTImpermanentLoss: 3 → **4**

The accounting sync dramatically reduces the NAV from the huge initial values to realistic numbers. The mechanism is explained in detail below.

### How the Accounting Sync Resets `lastJTEffectiveNAV` from `2^255+2` to 4

The change happens inside `preOpSyncTrancheAccounting`, called at the start of `jtDeposit`. This function recomputes effective NAV from current on-chain assets and **overwrites** the stored value — it does not carry forward the old `2^255+2`.

**Step 1 — `jtRawNAV` computes as 0**

`RoycoKernel.sol:766` calls `jtConvertTrancheUnitsToNAVUnits(jtOwnedYieldBearingAssets=2)`, which reaches `IdenticalAssetsOracleQuoter.sol:163`:
```solidity
return toNAVUnits(toUint256(_assets.mulDiv(_getCachedTrancheUnitToNAVUnitConversionRateWAD(), TRANCHE_UNIT_SCALE_FACTOR, Math.Rounding.Floor)));
```
The cached value `2^255+1` encodes an oracle rate of **1** — the sentinel bit (`1 << 255`, defined at `IdenticalAssetsOracleQuoter.sol:29`) is ORed in at line 133 as a cache-presence flag, then XORed back off at line 155:
```
stored:   getRate() | 2^255  =  1 | 2^255  =  2^255+1
reading:  (2^255+1) ^ 2^255  =  1   ← actual oracle rate
```
With `TRANCHE_UNIT_SCALE_FACTOR = 10^decimals` (set at line 56 from the asset's ERC20 decimals), the floor division at line 163:
```
floor(2 × 1 / 10^decimals)  =  0
```
...rounds to zero for any asset with ≥ 1 decimal. This is **not an overflow** — OZ's `mulDiv` uses 512-bit intermediate arithmetic — it is simply integer floor division of a near-zero oracle rate. `_jtRawNAV=0` is then passed into `preOpSyncTrancheAccounting` at `RoycoKernel.sol:603` (ctpp trace line 1511/1869).

**Step 2 — The huge stored `lastJTRawNAV = 2^255−10` creates a massive negative delta**

Inside `_previewSyncTrancheAccounting` (`RoycoAccountant.sol:405`), at line 438:
```solidity
int256 deltaJTRawNAV = UnitsMathLib.computeNAVDelta(_jtRawNAV, lastJTRawNAV);
// = computeNAVDelta(0, 2^255−10)  →  a huge negative number ≈ −(2^255−10)
```
At `RoycoAccountant.sol:451`, JT's effective NAV delta inherits most of this:
```solidity
deltaJTEffectiveNAV = (deltaSTRawNAV + deltaJTRawNAV) - deltaSTEffectiveNAV;
// ≈ −(2^255 − 3)
```

**Step 3 — JT absorbs its own huge loss, landing near zero (`RoycoAccountant.sol:468–474`)**
```solidity
NAV_UNIT jtLoss = toNAVUnits(-deltaJTEffectiveNAV);          // = 2^255 − 3
NAV_UNIT jtAbsorbableLoss = UnitsMathLib.min(jtLoss, jtEffectiveNAV); // = 2^255 − 3
jtEffectiveNAV = (jtEffectiveNAV - jtAbsorbableLoss);
// (2^255 + 2) − (2^255 − 3) = 5
```

**Step 4 — JT covers 1 unit of ST loss, landing at 4 (`RoycoAccountant.sol:507–521`)**

The ST delta is also negative (−1), so JT provides coverage:
```solidity
NAV_UNIT coverageApplied = UnitsMathLib.min(stLoss, jtEffectiveNAV); // = min(1, 5) = 1
jtEffectiveNAV = (jtEffectiveNAV - coverageApplied);   // 5 − 1 = 4
jtImpermanentLoss = (jtImpermanentLoss + coverageApplied); // 3 + 1 = 4
```

**Step 5 — Store (`RoycoAccountant.sol:136`, ctpp trace line 5114)**
```solidity
$.lastJTEffectiveNAV = state.jtEffectiveNAV;  // = 4
```
The old `2^255+2` is simply overwritten.

**Summary of Solidity locations:**
| What | File | Line |
|------|------|------|
| Conversion rate unmasked to `1` | `IdenticalAssetsOracleQuoter.sol` | 155 |
| `jtRawNAV = floor(2 × 1 / WAD) = 0` | `IdenticalAssetsOracleQuoter.sol` | 163 |
| `_getJuniorTrancheRawNAV()` entry point | `RoycoKernel.sol` | 766 |
| Passes `jtRawNAV=0` to accountant | `RoycoKernel.sol` | 603 |
| Huge `deltaJTRawNAV` from old checkpoint | `RoycoAccountant.sol` | 438 |
| Huge `deltaJTEffectiveNAV` computed | `RoycoAccountant.sol` | 451 |
| JT absorbs its own loss: `5 = (2^255+2) − (2^255−3)` | `RoycoAccountant.sol` | 468–474 |
| JT covers ST loss: `4 = 5 − 1` | `RoycoAccountant.sol` | 510–521 |
| `lastJTEffectiveNAV` written to `4` | `RoycoAccountant.sol` | 136 |

### Why the Market Does Not Enter FIXED_TERM After the NAV Collapse

`jtDeposit` requires `marketState == PERPETUAL` (`RoycoKernel.sol:426`). A natural question is: why doesn't the catastrophic NAV collapse (from `2^255+2` to `4`) trigger a FIXED_TERM transition, which would block the second deposit?

The market state decision in `_previewSyncTrancheAccounting` (`RoycoAccountant.sol:598–637`) checks three branches:

**Branch 1 — forced PERPETUAL with IL erasure (line 600–613):** requires one of:
- `fixedTermDurationSeconds == 0` — it's `1` ✗
- `utilizationWAD >= liquidationUtilizationWAD` — utilization is `ceil(coverageWAD × 6 / 4) = 2`, liquidation threshold is `WAD+1 ≈ 10^18` — far below ✗
- `stImpermanentLoss != 0` — the 1-unit ST loss was fully covered by JT (`coverageApplied=1`), so ST has no residual impermanent loss ✗

**Branch 2 — dust tolerance PERPETUAL (line 615–621):** `jtImpermanentLoss <= effectiveNAVDustTolerance`:
- `jtImpermanentLoss = 4`
- `effectiveNAVDustTolerance = stNAVDustTolerance + jtNAVDustTolerance = 0 + 4 = 4`
- `4 <= 4` → **true**

Since `initialMarketState == PERPETUAL` (line 618), this resolves to `resultingMarketState = PERPETUAL`. The market **stays perpetual** and both deposits proceed.

**Why this matters:** The dust tolerance branch is intended to absorb minor rounding losses. Here it is absorbing an enormous NAV collapse (`2^255+2 → 4`), because the resulting `jtImpermanentLoss` happened to land exactly at the dust tolerance ceiling. The prover engineered this by setting `jtNAVDustTolerance = 4` in the initial state — exactly equal to the `jtImpermanentLoss = 4` produced by the collapse. This is not coincidental: the prover chose this value specifically to keep the market perpetual.

This reveals a second issue independent of the NAV values: **`jtNAVDustTolerance` can bypass the FIXED_TERM guard after a large impermanent loss event**, as long as the resulting `jtImpermanentLoss` does not exceed the tolerance. A large `jtNAVDustTolerance` acts as a loophole. Adding a precondition constraining `jtNAVDustTolerance` to a small realistic value (e.g., `require jtNAVDustTolerance <= SOME_SMALL_BOUND`) would close this path.

**First Deposit (from initial state, amount=4):**
- Total Supply: 494
- Total Assets (effectiveNAVToMintAt): **4**
- Shares minted: `494 × 1 / 4 = 123.5` → **123 shares**
- Share price: 4/494 ≈ 0.008 assets per share

**After first deposit completes:**
- lastJTRawNAV: 2
- lastJTEffectiveNAV: 2 → **6** (increased by 2!)
- Total Supply: 617 shares

**Second Deposit (amount=4):**
- Total Supply: 617
- Total Assets (effectiveNAVToMintAt): **6**  
- Shares minted: `617 × 1 / 6 = 102.83` → **102 shares**
- Share price: 6/617 ≈ 0.0097 assets per share

### The Problem

The effective NAV increases from 4 to 6 between the two identical deposits. This happens because:

1. **Impermanent loss is being partially erased** as deposits occur
2. The formula is: `effectiveNAV = rawNAV + impermanentLoss - erosion`
3. As deposits are made, some impermanent loss gets "erased" (reduced from 4 to 4, but the effective NAV still increased)
4. The raw NAV increased by only 2 (from 0 to 2), but effective NAV increased by 2 (from 4 to 6), suggesting the accounting is recovering losses

**This creates a dilution vulnerability**: The first depositor gets a better price (more shares per asset) than subsequent depositors with identical deposits.

### Legitimacy Assessment

**The starting state appears illegitimate or at least highly unusual:**
- Having `lastJTRawNAV = 2^255 - 10` and `lastJTEffectiveNAV = 2^255 + 2` represents an enormous, unrealistic value
- These values would require junior tranche assets worth half the maximum uint256 value
- This state could only occur through:
  - Severe overflow/underflow bugs
  - Uninitialized or corrupted storage
  - Intentional manipulation

**However, even if we accept the state transition from the huge values to realistic ones:**
- The core issue remains: identical deposits yield significantly different shares (123 vs 102)
- This represents a **17% difference** in share allocation for identical contributions
- This exceeds the 20-share tolerance specifically because of impermanent loss recovery dynamics

### Possible Theories

**Theory 1: The specification tolerance is too strict**
The 20-share tolerance may be insufficient to account for legitimate rounding and impermanent loss recovery during sequential deposits. The protocol's impermanent loss mechanism intentionally changes effective NAV as deposits help "heal" losses.

**Theory 2: There's an implementation bug in impermanent loss accounting**
The way impermanent loss is calculated and erased during deposits may be flawed, causing excessive NAV inflation that unfairly benefits earlier depositors.

**Theory 3: The initial state is invalid (most likely)**
The counterexample relies on an unrealistic starting state with massive NAV values that then collapse. If such a state cannot legitimately occur, this counterexample may not represent a real vulnerability.

---

## Second Counterexample: Same Violation With Smaller Values

A separate counterexample (`6893_52d9c2e678a04885bcfa61eae2184f4d`) reproduces the same rule violation with numbers small enough to trace by hand.

### Initial State

| Field | Value |
|-------|-------|
| JT total supply | 71 shares |
| `lastJTRawNAV` | **74** |
| `lastJTEffectiveNAV` | 60 |
| `lastJTImpermanentLoss` | 1 |
| `lastSTEffectiveNAV` | 14 |
| `lastSTRawNAV` (derived by NAV conservation) | **0** |
| `jtOwnedYieldBearingAssets` | 25 |
| `fixedTermDurationSeconds` | **0** |
| `betaWAD` / `coverageWAD` | 0 / 0 |
| `jtNAVDustTolerance` / `stNAVDustTolerance` | 0 / 1 |
| Deposit amount | 7 assets |

### Results

| | First deposit | Second deposit |
|-|--------------|----------------|
| `effectiveNAVToMintAt` | **2** | **7** |
| Shares minted | **142** | **121** |
| Difference | 21 > 20 tolerance — **violation** | |

### Root Cause: Same Pattern, Realistic Numbers

The mechanism is identical to the main counterexample — a stale `lastJTRawNAV` checkpoint far above the actual current value — but with numbers that do not require near-zero oracle rates or astronomically large storage values.

The oracle rate is realistic (`14/21 ≈ 0.67`). With `jtOwnedYieldBearingAssets = 25`:
```
jtRawNAV = floor(25 × 14/21) = floor(16.67) = 16
```

The checkpoint `lastJTRawNAV = 74` is **4.6× larger** than the actual `jtRawNAV = 16`. The sync in `_previewSyncTrancheAccounting` sees a massive negative delta:

```
deltaJTRawNAV = 16 − 74 = −58
```

ST holds a 14-unit claim on JT's raw NAV (`stClaimOnJTRawNAV = 14`). Attributing the delta proportionally:
```
deltaSTClaimOnJTRawNAV = −floor(58 × 14 / 74) = −10
deltaJTEffectiveNAV   = (0 + −58) − (−10)    = −48
```

JT absorbs its 48-unit loss (`60 − 48 = 12`), then covers ST's 10-unit loss (`12 − 10 = 2`), so `lastJTEffectiveNAV` collapses from **60 → 2** (RoycoAccountant.sol:468–521). This is what the first deposit sees as `effectiveNAVToMintAt`, minting `71 × 4/2 = 142` shares.

After the deposit, the post-op sync with 32 assets recovers some NAV, and the YDM distributes ST appreciation to JT as a yield premium, lifting `lastJTEffectiveNAV` to **7** before the second deposit. The second depositor mints `213 × 4/7 = 121` shares — a difference of 21.

### Why FIXED_TERM Did Not Trigger Here

This counterexample uses a **different bypass mechanism** than the main scenario.

`fixedTermDurationSeconds = 0` in the initial state. The very first condition in the market state decision (`RoycoAccountant.sol:601`) is:
```solidity
if (fixedTermDurationSeconds == 0 || ...) {
    jtImpermanentLossErased = jtImpermanentLoss;
    jtImpermanentLoss = ZERO_NAV_UNITS;
    resultingMarketState = MarketState.PERPETUAL;   // always
```

When `fixedTermDurationSeconds = 0`, the market is **permanently perpetual** — FIXED_TERM is structurally impossible regardless of how large the impermanent loss is. The sync after the first deposit produces `jtImpermanentLoss = 11` (1 initial + 10 from covering ST's loss), but this is immediately erased to 0. The second deposit is never blocked.

Compare with the main scenario:

| | Main counterexample | Second counterexample |
|-|---------------------|----------------------|
| `fixedTermDurationSeconds` | 1 | **0** |
| Bypass mechanism | `jtNAVDustTolerance = 4` exactly equals resulting IL | Market is permanently perpetual |
| Resulting `jtImpermanentLoss` | 4 (≤ dust tolerance → PERPETUAL) | 11 (erased unconditionally) |
| Oracle rate | Near-zero (1/WAD) | Realistic (14/21) |
| NAV mismatch magnitude | ~`2^254`× | ~4.6× |

Both counterexamples share the same structural root cause — a stale `lastJTRawNAV` checkpoint that is much larger than the actual current raw NAV — but each uses a different initial-state parameter to prevent FIXED_TERM from blocking the second deposit.

### Recommendations

---

### Recommendations

1. **Add preconditions** to the rule that exclude unrealistic starting states (e.g., `require lastJTRawNAV < MAX_REASONABLE_VALUE`)
2. **Constrain `jtNAVDustTolerance`** in the rule (e.g., `require jtNAVDustTolerance <= SOME_SMALL_BOUND`) — a large dust tolerance bypasses the FIXED_TERM guard after a large impermanent loss event, keeping the market perpetual when it should not be
3. **Investigate impermanent loss recovery logic** to ensure it doesn't create unfair pricing between sequential depositors
4. **Consider adjusting the tolerance** if 20 shares is too strict given the protocol's impermanent loss mechanism
5. **Add invariants** to ensure NAV values remain within reasonable bounds during normal operation
