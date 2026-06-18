# Royco Dusk — Design Summary and Viability Analysis

## What Dawn is (background)

Dawn tranches any yield-bearing asset into two ERC4626 shares with distinct risk/return profiles:

- **Senior Tranche (ST)**: Protected capital. Receives downside coverage from JT; pays a risk premium from its yield in return.
- **Junior Tranche (JT)**: First-loss capital. Earns the risk premium. Redemptions are constrained by a coverage requirement: `JT_eff ≥ (ST_raw + JT_raw × β) × coverage`.

The **Accountant** runs a sync function F on every operation: it reads raw NAVs, applies the PnL waterfall (JT absorbs losses first, ST IL recovered first from gains), distributes yield via the YDM, and writes back effective NAVs. This is the mathematical core shared with Dusk.

---

## What Dusk adds

Dawn transforms the *risk profile* of an asset but not its *liquidity profile* — senior holders can only exit via primary redemption. **Dusk extends Dawn by giving senior holders a secondary market.**

The JT's collateral is deployed into a **Balancer V3 Gyro E-CLP AMM pool** that pairs the senior tranche share against a stable quote asset (USDC, sUSDS, etc.). Seniors can now swap out on the open market at any time instead of waiting to redeem directly.

---

## The core problem: a circular dependency

To mark JT to market, you must value its BPT (Balancer Pool Token) position. To value the BPT, you need the price of the senior share `y = ST_eff / N`. But `ST_eff` is the *output* of F, and F *takes* `JT_raw` (the BPT value) as input. The dependency is circular:

```
JT_raw  →  needs y  →  needs ST_eff  →  needs JT_raw
```

There is no evaluation order that breaks this. The two unknowns (`JT_raw` and `ST_eff`) must be solved simultaneously.

---

## The solution: on-chain bisection over a fixed-point equation

The paper casts this as finding the largest zero of:

```
E(x) = F(P_A(x/N)) − x
```

where `x` is the candidate senior NAV, `P_A(y)` is a conservative BPT valuation (frozen pool curve, demand capped at N, floor rounding), and F is the Dawn accountant.

The paper proves two facts that together guarantee the solver works:

1. **Monotonicity**: E is non-increasing with steps in {−1, 0}. Follows from F being 1-Lipschitz in JT_raw and from capping the demand at supply N (loop gain g = f ≤ 1).

2. **Bracketing**: E(0) ≥ 0 and E(x_max) < 0 by construction, so a crossing always exists.

This gives a unique largest root x* that bisection finds in at most K steps (K is hardcoded per market). An optimisation (**probe value reuse**) replaces the midpoint with the full loop output G(m) = F(P_A(m/N)) as the new bracket endpoint — this gives 5–30× gas savings since G(m) is already closer to x* than m.

---

## Viability assessment

### Strong points

- The mathematical argument is clean and complete. Every assumption is stated explicitly (Section 4.3 of the paper) so an auditor can verify them per market.
- Constant gas (K hardcoded) is critical for on-chain safety — no data-dependent loops.
- Frozen-curve approach (L computed once per solve) prevents intra-block manipulation.
- Conservative rounding throughout (down for invariant, floor in P_A, rate rounded toward senior) systematically protects the protected tranche.
- Reusing the Dawn accountant means the most complex financial logic is shared and already audited.

### Potential issues

1. **N ≥ 1 is a new hard requirement.** Dawn allows total senior supply to reach zero; Dusk requires a permanently non-zero supply (the solve divides by N). The paper says this must be enforced "by construction" — either a non-redeemable seed position at creation or a virtual-share offset. If this is forgotten or circumvented, the solver divides by zero and every pool operation reverts.

2. **Price band revert = potential DoS.** If x* (the solved senior NAV) falls outside the pool's price band, the sync reverts. This is described as "a genuine economic signal" (a loss larger than the band can represent) but it means all pool operations — swaps, adds, and removes — revert during a large drawdown. Users can still read the stale cached rate via `getRate()` but cannot transact. This could last for an extended period.

3. **f = 1 plateau.** When the junior owns 100% of the pool, the plateau of self-consistent values is bounded only by the bracket (potentially large), not by `⌈1/(1−f)⌉`. The published value is the largest and JT's entitlement is invariant across the plateau, but the senior rate is non-unique across it. This edge case is acknowledged in the paper (Remark 4.3).

4. **Recovery-mode removes are carved out.** Balancer V3 recovery-mode removes bypass the hook entirely and are explicitly excluded from sync coverage. This means a remove during recovery mode executes against the potentially stale cached rate. Depending on how stale and how much has moved, this could be exploited.

5. **YDM yield share must stay ≤ WAD.** The 1-Lipschitz proof of F depends on the yield split fraction being in [0, 1]. If an adaptive YDM drifts or is misconfigured to produce a share > 100%, the monotonicity argument breaks and the bisection may not converge correctly.

6. **ST_raw must be independent of the pool.** The "senior independence" obligation (Section 5.6 of the paper) requires that the senior's own asset quoter never reads the pool's BPT price or spot rate. Violating this introduces a second circular dependency that the current proof does not cover.

7. **Gyro E-CLP specific.** The proofs rely on the E-CLP having a bounded price band (finite V_max) and monotone demand D. Any other pool type would require re-proving Section 4.3 from scratch.

8. **Recursive Dusk markets.** The README mentions recursive tranching (ST → new ST + new JT). If a Dusk market uses another Dusk tranche as its senior asset, the senior raw NAV quoter would read the inner market's cached rate — which itself depends on a solve. The outer solve then rests on a potentially stale inner rate, not an exogenous price. This isn't addressed by the paper.

---

## Elaboration on operational risks

"Operational" here means risks that arise not from flaws in the mathematical proof but from deployment decisions, wiring choices, and edge cases in the surrounding infrastructure that the proof takes for granted. The math is correct given its assumptions; the question is whether those assumptions can be maintained in practice.

### N ≥ 1: seeding and enforcement

The Dawn senior tranche was designed to allow a zero total supply — no virtual-share offset, no seed position at creation. Dusk divides by N in every probe, so N must never reach zero after the market is live.

The paper offers two routes: seed a non-redeemable minimum position at creation, or add a virtual-share offset to the senior's share-price conversion. Neither is automatic. A deploy script that forgets to seed, or a kernel that fails to block the last redemption, produces a market where every pool operation (swap, add, remove) reverts the moment the last senior share is burned. Because Balancer reads the rate from the kernel, and the kernel cannot compute it, the pool becomes permanently bricked — not just paused.

The enforcement also needs to be permanent. A governance action that burns the seed position (e.g., during a migration or upgrade) would have the same effect. This requires the constraint to be enforced at the contract level, not just at initialization.

### Price band sizing at deploy

The E-CLP pool is configured with a price band [α, β] that represents the range of senior share rates the pool can quote. The solver returns the largest fixed point x*; if x*/N falls outside this band, the sync reverts. The pool cannot transact until the rate is back inside the band.

The band must therefore be wide enough to absorb the worst realistic drawdown on the underlying asset. But the E-CLP is a concentrated liquidity pool — a wider band means thinner liquidity at the current price and worse execution for normal swaps. This creates a direct trade-off between capital efficiency and DoS resilience.

Getting this wrong at deploy has no runtime remedy: the band is set at pool initialization and changing it requires deploying a new pool. The iteration count K is also hardcoded at deploy based on the maximum bracket width `x_max ≈ ST_raw + f·V_max`. If the market grows much larger than anticipated (e.g., total senior supply multiplies by 10×), `x_max` grows proportionally and K may become insufficient — again requiring a redeploy.

The paper notes one additional subtlety: the band mapping between the pool's configured bounds and the rate bounds [α, β] depends on whether the senior share is token0 or token1 in the E-CLP, and explicitly states this mapping is "pending verification against the deployed pool's convention." This suggests the wiring is not yet finalized at the time of writing.

### Stale rate propagation

When the sync reverts (rate out of band, paused market, reverting oracle), the cached rate y* is left untouched. `getRate()` returns this stale value without error. Any DeFi integrations that consume the senior rate — lending market price feeds, other AMMs, downstream Dusk markets using this ST as their senior asset — continue reading the stale value silently for as long as the DoS persists.

The paper explicitly accepts this: "staleness is prevented from propagating through an operation, not from being read." This is a deliberate choice and appropriate given the constraints, but integrators must understand that `getRate()` returning a value does not imply that value is fresh.

### Recovery-mode removes

Balancer V3's recovery mode is a circuit breaker that allows LPs to exit pro-rata even when the pool is broken or paused, bypassing all hooks. The Dusk hook's `beforeRemoveLiquidity` callback is not called in recovery mode, so the remove executes at the last cached rate y* without triggering a sync.

If recovery mode is triggered precisely because the market is in distress (the most likely scenario), the cached rate is likely stale in the direction that favours exiting LPs. An LP who monitors the on-chain state can time a recovery-mode remove to exit at a rate that is higher than the true current rate, effectively extracting value from remaining LPs or the senior tranche. The paper acknowledges this: "Recovery-mode removes are a separate path, not bound by this contract."

### Non-reverting YDM view

The solve evaluates `E(x) = F(P_A(x/N))` at every probe, and F calls the YDM's view function each time. If the YDM view reverts under any conditions — an uninitialized state, an extreme input, an arithmetic overflow — the entire solve reverts with it. Since the solve runs on every swap, add, and remove, a YDM that can revert effectively bricks the pool.

The paper lists "the yield-model view is a non-reverting view function" as an implementation obligation (Section 5.6). This must be verified for all three YDM variants (StaticCurveYDM, AdaptiveCurveYDM_V1, AdaptiveCurveYDM_V2) and any future YDM, including at extreme inputs (zero NAVs, maximum utilization, overflow-adjacent values).

### Senior independence

The quoter for ST_raw must not read the pool in any way — not the BPT price, not the spot rate, not `getRate()` from the Dusk kernel. The proof has exactly one fixed-point variable (the senior NAV); if ST_raw also depends on the senior rate, the system has two coupled unknowns and the monotonicity argument no longer applies.

This is a wiring obligation (Section 5.6) with no enforcement in the proof itself. A developer integrating a new yield source who wires the ST quoter to a pool that internally prices senior shares creates a second loop that the bisection cannot handle. Unlike the mathematical risks, this is a silent failure: the solver still terminates, but converges to the wrong value.

---

## Closed-form analysis of the fixed point

The fixed-point equation is `x = F(P_A(x/N))`. Both F and P_A are piecewise-defined, so there is no single closed-form expression valid across all market states. But within each identifiable branch the equation reduces to something solvable analytically.

### Why no general closed form exists

F is piecewise-affine: the waterfall has distinct linear branches depending on whether the market is in the loss, IL-recovery, or yield regime, and the slopes differ between branches. P_A is also piecewise: linear below the E-CLP band (all-senior corner), E-CLP geometry inside the band, and constant above it (all-quote corner). The composition F(P_A(x/N)) therefore has many branch combinations, and the correct one to use depends on which interval x* falls in — which is exactly what the bisection determines. Knowing the branch is equivalent to solving the problem.

### Closed form within a branch

Within any single branch of F where the slope is a constant `s ∈ [0,1]` and the intercept is a constant `c` (both determined by the checkpoint and ST_raw):

```
F(j) = s·j + c
```

**Case 1: below the E-CLP band** (x/N < α, all-senior corner)

P_A is linear: `P_A(x/N) ≈ f · (x/N) · D(α)` where D(α) is the senior reserve at the band's lower edge (a constant frozen at solve start). Substituting:

```
x = s · f · D(α)/N · x + c
x · (1 − s·f·D(α)/N) = c

         c
x* = ─────────────────
      1 − s·f·D(α)/N
```

The denominator is `1 − g` where `g = s·f·D(α)/N` is the loop gain in this branch. Since `g ≤ f ≤ 1`, the denominator is non-negative — and equals zero exactly when `f = 1` and `D(α) = N` (the f = 1 plateau case the paper discusses).

**Case 2: above the E-CLP band** (x/N > β, all-quote corner)

P_A is constant: `P_A(x/N) = ⌊f·V_max⌋ = k`. Then `x* = F(k) = s·k + c`, computed directly with no equation to solve.

**Case 3: inside the E-CLP band**

D(y) is given by the Gyro E-CLP curve geometry. The E-CLP uses a quadratic invariant, so D(y) involves a square root — it is algebraic. V(y) = ∫D(u)du is therefore also algebraic (square-root expressions), and the fixed-point equation becomes a degree-2 polynomial in x, solvable with the quadratic formula. The relevant root is the larger one, consistent with the paper's "largest fixed point" selection.

### The most important special case: no IL, normal yield

When there is no outstanding impermanent loss and the market is in the yield regime, F has **slope zero** in JT_raw (ST's effective NAV does not depend on how much JT appreciates — JT keeps its own gains and pays a fixed w fraction of ST's appreciation, where w is frozen in the checkpoint). In this case:

```
F(j) = ST_eff_0 + (1−w)·(1−a)·(ST_raw − ST_raw_0)   [constant in j]
```

where `a` is the attribution fraction (JT's cross-claim on ST's raw holdings, also frozen at the checkpoint). The fixed-point equation is then `x = constant`, giving:

```
x* = ST_eff_0 + (1−w)·(1−a)·(ST_raw − ST_raw_0)
```

No bisection needed — this is why the paper says healthy markets solve in 2–3 probes. The first probe evaluates E at the midpoint, finds a large negative value (the constant is much less than the midpoint), and the probe value reuse immediately jumps to x*.

### Summary table

| Region of x* | Branch of F | Closed form |
|---|---|---|
| Below E-CLP band | Any affine branch | `x* = c / (1 − g)` where g = loop gain |
| Inside E-CLP band | Any affine branch | Quadratic formula (square-root expression) |
| Above E-CLP band | Any affine branch | `x* = s·k + c` directly |
| No IL, yield regime | Slope-0 branch | `x* = c` directly (degenerate fixed point) |

The bisection exists precisely because you cannot determine which row applies without knowing x* — the branch boundaries are themselves functions of x*.

---

## Overall verdict

The core design is mathematically sound and the paper is rigorous. The main practical risks are operational (N ≥ 1 enforcement, price band sizing at deploy, recovery-mode corner cases) rather than mathematical. The bisection approach is the right tool given F's piecewise-affine shape.

---

## Formal verification pain-points and developer recommendations

### Target properties

Before listing obstacles, it helps to be precise about what we would want to prove:

| Property | Informal statement |
|---|---|
| **Solvency** | After every sync, `JT_eff ≥ coverage × (ST_raw + β × JT_raw)` (utilization ≤ 100%) |
| **Share price monotonicity** | The senior share price `ST_eff / N_ST` can decrease only when a loss is reported (ST_raw falls or ST_IL increases) |
| **NAV conservation** | At all times `ST_raw + JT_raw = ST_eff + JT_eff` |
| **Fixed-point correctness** | The published rate y* satisfies `F(P_A(y* × N)) = y* × N` (or within 1 wei) |
| **Loop convergence** | After K bisection steps, `lo = hi = x*` |

Each has a different character and a different dominant pain-point.

---

### Pain-point 1: The bisection loop

The bisection runs K iterations, where K is hardcoded per market — typically 60–70 to cover a bracket of `2^64` or larger. The Certora Prover unrolls loops up to a configured `loop_iter` bound. At `loop_iter 64` the analysis becomes prohibitively slow (exponential state space). At a smaller bound it is unsound.

The right approach is to **prove a loop invariant about a single bisection step** rather than unrolling. Specifically, prove for one step:

```
pre:  lo ≤ x* ≤ hi  ∧  E(lo) ≥ 0  ∧  E(hi) < 0
post: lo' ≤ x* ≤ hi'  ∧  hi' − lo' < hi − lo
```

If both the invariant and progress are proved for one step, the K-step result follows by induction. The prover does not do induction natively, but the step can be proved as a standalone rule, and the loop itself can be modelled with `requireInvariant` at each iteration entry. This requires extracting the step logic into its own internal function.

**Developer action:** Refactor the bisection loop body into a named internal function `_bisectionStep(lo, hi, m) returns (lo', hi')`. This makes the step provable in isolation and gives the prover a clean call boundary. The loop wrapper calls it K times and can be left to bounded unrolling for a small number of steps to gain confidence.

---

### Pain-point 2: Nonlinear arithmetic in the financial core

The utilization formula is:

```
U = (ST_raw + β × JT_raw) × coverage / JT_eff
```

This involves multiplications of large WAD-scaled variables. The SMT solvers behind the Certora Prover (z3, cvc5) handle **linear arithmetic** efficiently but are in general undecidable for nonlinear integer arithmetic. Multiplying two symbolic 256-bit variables produces a query that may time out.

The YDM slope computations, the coverage check, and the attribution fraction all have similar products. The mulDiv summaries already in the Dawn specs (`mulDivDirectionalSummary`) are the right mitigation: replace the concrete mulDiv with a ghost that axiomatises monotonicity properties rather than the full arithmetic. The prover then reasons about the ghost, not the multiplication.

**Developer action:** Keep all high-level financial formulas (utilization, coverage, attribution fractions) in a small set of pure library functions with clean signatures. Document the key monotonicity property of each (e.g. "utilization is non-decreasing in ST_raw"). These become the axioms for the FV summaries. If the formula is written as a one-liner inside a large function, it is much harder to summarise cleanly.

---

### Pain-point 3: The E-CLP valuation P_A

P_A involves:
- A Gyro E-CLP pool invariant based on a quadratic form in rotated/scaled coordinates
- A square root to evaluate the invariant
- An integral V(y) = ∫D(u)du (computed in closed form, but via square-root expressions)
- A floor and a demand cap (min, division)

Square root is the dominant problem. Solidity sqrt implementations (Newton-Raphson iteration or Solady bit-twiddling) involve their own loops and nonlinear arithmetic. Proving that sqrt(x) satisfies `sqrt(x)^2 ≤ x < (sqrt(x)+1)^2` requires nonlinear reasoning about the integer implementation that the SMT backend usually cannot discharge automatically.

The correct FV approach is to **summarise the entire P_A function** as a CVL ghost with axioms encoding exactly the properties the bisection proof requires:
1. `P_A` is non-decreasing: `y ≥ y' → P_A(y) ≥ P_A(y')`
2. `P_A` has slope ≤ f: `P_A(y) − P_A(y') ≤ f × N × (y − y') / N = f × (y − y')` (scaled)
3. `P_A(0) = 0`
4. `P_A(y) ≤ floor(f × V_max)` for all y

These four axioms are exactly what the monotonicity and bracketing proofs consume. Properties 3 and 4 of P_A (E-CLP geometry, demand monotonicity) can be proved separately as a standalone mathematical verification of the pool contract — possibly outside the Certora Prover, using a pen-and-paper or Lean/Coq argument — and then loaded as trusted axioms.

**Developer action:** Isolate P_A in a single internal function `_valueBPT(y) returns uint256` that is called only from the bisection loop. Never inline the E-CLP valuation. Add NatSpec that states the four properties above explicitly as `@dev` invariants. This makes writing the CVL summary straightforward.

---

### Pain-point 4: Multiple cross-contract calls during the solve

Each bisection probe calls the accountant's `previewSync` (a view function) from the kernel. The Certora Prover models contract calls across the dispatcher boundary. With K = 64 calls to the same external function in one rule, the symbolic state accumulates K times, even for a view function. This is expensive even when the function is side-effect-free.

**Developer action:** If possible, inline the accountant preview into the kernel (by importing the accountant logic as an internal library) rather than calling it via an external interface. Alternatively, if the external call pattern must remain, mark the preview explicitly as `pure` so the prover can apply call-result caching. In CVL, the summary for `previewSync` can be written once as a CVL function and applied to all K calls simultaneously.

---

### Pain-point 5: The piecewise-affine waterfall F

F has at least six distinct linear branches (JT absorbs loss, JT capacity exceeded, ST IL recovery, JT IL recovery, yield split, combined recovery + yield). Each branch has different slope and intercept. For the prover, each branch is a separate path through the function, and branch conditions involve comparisons between accumulated ILs and current raw NAVs.

Proving solvency — that utilization ≤ 100% after F is applied — requires showing the property holds in all six branches. This is tractable in principle (it is linear arithmetic within each branch) but the case explosion is large. The prover will try to split on all branch conditions simultaneously, which can blow up.

**Developer action:** Write one function per waterfall branch (e.g., `_settleLoss`, `_settleSTILRecovery`, `_settleYield`) with tight pre/post conditions. This partitions the state space by construction and makes each branch provable in isolation. The orchestrating `sync` function then calls the right branch. The branch-dispatch condition is the only nonlinear part and can be proved separately as a lemma.

---

### Pain-point 6: Share price monotonicity needs a precise loss definition

The property "share price can only decrease if there is a loss reported" requires defining "loss" precisely. The share price is `ST_eff / totalSupply`. It can decrease in three ways:
1. ST_eff falls (a genuine loss or yield payment to JT)
2. totalSupply increases (fee shares minted, diluting existing holders)
3. Both simultaneously

"Yield payment to JT" is not a loss in the protocol's sense, but it does decrease the senior share price. "Fee minting" is also not a loss. So the property as stated above is false unless carefully scoped.

The provable version would be: **"If no operation has occurred and the only change is time passing (the YDM accrual advancing), the senior share price does not change."** And separately: **"If ST_raw decreases and there are no deposits or redeems, ST_eff / totalSupply is non-increasing."**

These scoped versions are tractable. The global version as informally stated is not directly provable without a precise definition of "loss."

**Developer action:** Add an event `LossRecorded(uint256 stILDelta, uint256 jtILDelta)` emitted whenever impermanent loss increases. This gives a clean on-chain signal that FV rules can reference. Rules can then be stated: "if `LossRecorded` was not emitted in this transaction, `stEffectiveNAV / totalSupply` is non-decreasing."

---

### Pain-point 7: NAV conservation across the fixed-point solve

NAV conservation (`ST_raw + JT_raw = ST_eff + JT_eff`) must hold at the committed checkpoint. During the bisection, it holds at each probe (F is conservation-preserving). But JT_raw in the committed state is `P_A(x*/N)`, not an independent variable. Proving the committed checkpoint conserves requires substituting the fixed-point condition back in.

This is the compositional challenge: the prover needs to reason about `F(P_A(x*/N))` as a whole, not just F or P_A individually. With P_A summarised as a ghost, this reduces to showing that F applied to a value in the range of P_A preserves conservation — which follows from Lemma 4.2. The ghost axioms must explicitly encode that F conserves NAV for any JT_raw ≥ 0.

---

### Summary of developer recommendations for prover-friendliness

| Recommendation | Benefit |
|---|---|
| Refactor the bisection step into a named internal function | Enables loop invariant proofs without full unrolling |
| Isolate P_A in a single named function | Clean summary boundary; four axioms suffice |
| Separate each waterfall branch into its own function | Eliminates case explosion; each branch provable in isolation |
| Inline the accountant preview into the kernel, or mark it pure | Reduces cross-contract call overhead |
| Keep financial formulas in pure library functions with documented monotonicity | Enables concise ghost summaries |
| Emit `LossRecorded` events when IL increases | Gives FV rules a precise "loss has occurred" signal |
| Add intermediate `assert` statements at key invariant points | Free hints to the prover that prune dead paths |
| Add a conservation check at every checkpoint write | Hardcodes the base case of the conservation induction |

The most important single action is isolating P_A and each branch of F into named pure functions. The Certora Prover's summary mechanism makes it straightforward to replace complex nonlinear code with axiomatised ghosts — but only if the code is structured so each piece has a clean function boundary to attach the summary to.

---

## Follow-up questions, unclear parts, and proposed improvements

### Questions about the design

**1. Attribution formula is underspecified.**
The paper describes attribution conceptually — "each side's raw NAV delta is split pro rata over the claims on it" — but never writes down the exact formula. In the case where JT has a cross-claim on ST (JT_eff_0 > JT_raw_0), the fraction of ST's raw delta that flows to JT is `(JT_eff_0 − JT_raw_0) / ST_raw_0`. But what happens when that fraction changes sign during the waterfall? And is the pro-rata split applied to the raw delta before or after the loss/recovery settlement? The ordering matters because it determines which branch of F is active and therefore which closed-form formula (if any) applies.

**2. Does YDM adaptation run inside the preview calls during bisection?**
The adaptive YDM adjusts the yield curve based on deviation from target utilization. The paper requires the yield split fraction to be fixed during the solve (it is part of the checkpoint). But does `previewJTYieldShare` also advance the adaptation state, or does it return a frozen value? If the preview mutates any state, the proof's assumption of a single fixed function E breaks. This needs to be an explicit contract-level invariant: the view function called during bisection must be purely stateless.

**3. Fee shares and the N lag.**
The paper says F returns ST_eff "gross of protocol fees" and that N must count fee shares. But fee shares are minted after the solve commits, not during it. So during the bisection, N is the supply before this sync's fees. After commit, N grows. The next solve will see the larger N. This creates a one-sync lag: the published rate y* = x*/N uses the pre-fee N, while the fee shares minted at the end of this sync will dilute all holders at a rate that was computed without accounting for them. Is this intentional? Is the lag bounded and negligible, or does it compound across multiple syncs in a block?

**4. Why is the largest fixed point economically correct?**
The paper selects x* as the largest self-consistent senior NAV, calling it "one more tie broken for the protected tranche." But this is a policy choice, not a mathematical necessity. A smaller fixed point would give juniors more and seniors less. Under what economic argument is "maximise the senior rate" the right default? In particular, if the plateau is large (f close to 1), the difference between the smallest and largest fixed points could be material to JT holders.

**5. What happens when ST_raw = 0?**
The lower bracket endpoint is E(0) = F(P_A(0)) = ST_eff. If ST_raw = 0 (the underlying asset has lost all value), then P_A(0) = 0 and F(0) should return ST_eff = 0 for a conserving checkpoint. So x* = 0 and y* = 0. This means the pool quotes a rate of zero for the senior share — which implies it is worthless. Does the E-CLP handle a rate of zero correctly? Does publishing y* = 0 trigger any downstream failures in Balancer's pool arithmetic?

**6. JT IL erasure and the pool position.**
In Dawn, JT IL is erased (JT forfeits its recovery claim) when the fixed-term period expires or the liquidation threshold is breached. In Dusk, JT's collateral IS the BPT. IL erasure changes the accounting state but not JT's physical pool position. Does this create a discontinuity? Before erasure, some of JT's effective NAV is a recovery claim on future ST appreciation. After erasure, that claim disappears and JT's effective NAV drops by the erased IL amount — but JT_raw (the BPT value) is unchanged. Does the senior rate y* jump discontinuously at the moment of IL erasure?

**7. Recursive Dusk markets and the outer solve.**
The README describes recursive tranching where a Dusk senior tranche can feed into a new market. A Dusk kernel reports its cached y* via `getRate()`. If an outer Dusk kernel's ST quoter reads the inner kernel's `getRate()`, ST_raw for the outer market depends on the inner market's last committed y*. The "senior independence" obligation says ST_raw must not read the pool directly — `getRate()` doesn't read the pool, it reads the cache. Does this satisfy the obligation? If so, the outer solve is consistent but rests on a rate that may be one-block stale. If not, recursive Dusk markets are explicitly unsupported and the paper should say so.

**8. Ceiling vs floor in bisection midpoint selection.**
The solver uses `m ← lo + ⌈(hi − lo)/2⌉` (ceiling), not floor. This biases the midpoint toward `hi`. The paper doesn't explain this choice. In the f = 1 plateau case, it ensures the final step always picks `m = hi` (when `hi − lo = 1`), forcing the loop to terminate with `lo = hi = x*` by moving `lo` up via the `v ≥ 0` branch. Is this the reason, or is there a subtler invariant being maintained?

---

### Unclear parts in the paper

**1. Section 5.3: token-sort rate-scaling is unresolved.**
The paper explicitly says "The exact rate-scaling factor in this mapping is pending verification against the deployed pool's convention." This is a gap in the current specification. The correctness of the search bracket [Nα, Nβ] — and therefore whether the out-of-band revert triggers at the right times — depends on this mapping being correct for the specific pool token sort. This should be resolved before deployment.

**2. The attribution step is described but not formalised.**
The paper defers the full attribution formula to the Dawn accountant implementation. But the 1-Lipschitz proof of F (Lemma 4.2) relies on all coefficients in the attribution and settlement steps lying in [0, 1]. If any coefficient can exceed 1 in an edge case (e.g., a very small JT_raw_0 making a fraction blow up), the proof breaks. The paper says "each tranche's claim on a leg is at most that leg's raw NAV, by conservation and non-negative effective NAVs, so a ≤ 1" — this argument should be made explicit with a case analysis rather than asserted.

**3. The "conserving checkpoint" assumption.**
Lemma 4.2 and the bracketing argument both assume the stored checkpoint conserves NAV (ST_raw_0 + JT_raw_0 = ST_eff_0 + JT_eff_0). The paper says this holds "because it is itself either the conserving genesis checkpoint or a prior output of F." This is an inductive argument. But what if the genesis checkpoint is misconfigured (e.g., by a buggy deployment script)? The correctness of every subsequent solve would be compromised. An on-chain check that enforces conservation at checkpoint write time would make this invariant explicit rather than relying on correctness of the genesis and all prior syncs.

---

### Proposed improvements

**1. Enforce N ≥ 1 at the contract level.**
Rather than relying on operational procedure, add a one-line check in the senior tranche's redemption path: `require(totalSupply() - amount >= MIN_SUPPLY)`. This is cheap and makes the N ≥ 1 invariant self-enforcing rather than deploy-time convention. `MIN_SUPPLY = 1` is sufficient; using a slightly larger value (e.g., 1e6) also mitigates share-inflation attacks on fresh markets.

**2. Short-circuit the solver for the common case.**
When ST_IL = 0 and JT_IL = 0 and the market is in the yield regime, F has slope 0 in JT_raw and x* is directly computable without bisection. The kernel could check this condition first and skip to the direct formula. This saves K evaluations of F(P_A(·)) on every swap in a healthy market, which is the hot path. The fallback to bisection handles all other states. This requires exposing the IL and regime state from the accountant to the kernel before the solve — currently it may run the full preview to determine the regime.

**3. Publish the active branch alongside the rate.**
When the kernel commits y*, also emit an event or store a flag indicating which regime F was in (loss / IL-recovery / yield) and which E-CLP region x* fell into (below-band / in-band / above-band). This makes off-chain monitoring and debugging dramatically easier. It also lets integrators detect when the published rate reflects a distressed state without parsing the full accountant state.

**4. Add a time-decay penalty to recovery-mode removes.**
Rather than leaving recovery-mode removes entirely unprotected from stale rates, add a staleness penalty: if the cache is older than T blocks, apply a discount `d(age)` to the published rate used during recovery-mode removes. This makes exploitation unprofitable when the cache is significantly stale while still allowing exits — the correct balance between safety and liquidity.

**5. Resolve the token-sort rate-scaling before deployment.**
Section 5.3 explicitly flags the rate-scaling for the token1 case as "pending verification." This should be resolved and hardcoded per market, with a test that verifies the bracket [Nα, Nβ] matches the pool's actual quotable range for both token orderings before any market goes live.

**6. Add a conservation check to checkpoint writes.**
Before writing a new checkpoint, assert `ST_raw + JT_raw == ST_eff + JT_eff`. This is a cheap wei-precision invariant check that catches implementation bugs in the accountant early rather than propagating them silently through all subsequent solves.

**7. Consider making the largest-fixed-point selection configurable.**
The choice to publish the largest x* is a policy decision, not a mathematical necessity. A market governance parameter `roundingPolicy ∈ {LARGEST, SMALLEST}` would let market deployers choose the trade-off. Senior-protective markets (RWA collateral) would use LARGEST; junior-incentive markets might prefer SMALLEST. The bisection algorithm is identical either way — only the final selection (`return lo` vs `return hi`) changes.
