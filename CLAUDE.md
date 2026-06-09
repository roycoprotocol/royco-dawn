# Branch: new-accounting

This branch implements Royco Dusk. The formal spec lives in `spec/`, a git submodule tracking [roycoprotocol/royco-dusk-paper](https://github.com/roycoprotocol/royco-dusk-paper). The paper is the source of truth for this branch's design. Read the relevant LaTeX sections (prefer them over the compiled PDF) before changing accounting, NAV, valuation, or solver logic:

- `spec/sections/01-system-overview.tex` — tranches, raw vs effective NAV, the PnL waterfall, Dawn vs Dusk, the recursion
- `spec/sections/02-notation.tex` — symbols and units (everything is WAD except raw quote-asset amounts)
- `spec/sections/03-fixed-point-setup.tex` — the sync map `F`, the conservative BPT valuation `P_A`, the error function `E`
- `spec/sections/04-existence-and-uniqueness.tex` — proof that `E` has a unique root (monotonicity + bracketing)
- `spec/sections/05-solver.tex` — integer bisection, search bracket, implementation and rate-freshness obligations

If `spec/` is empty: `git submodule update --init spec`. To pull the latest spec: `git submodule update --remote spec`, then commit the new pin.

## What Dusk is

A Royco market splits an asset into a senior tranche (ST, protected, pays a risk premium) and a junior tranche (JT, levered, provides first-loss coverage). Each tranche has a raw NAV (mark-to-market of its own holdings) and an effective NAV (what it is entitled to after coverage and premium obligations settle). Every sync runs the accountant's map `F`: measure raw NAV deltas against the last checkpoint, attribute them across cross-tranche claims, then settle through the waterfall (loss → IL recovery → yield split via the YDM).

In Dawn, JT capital sits in any asset priced independently of the market. Dusk drops that restriction: JT's collateral is a Balancer V3 Gyro E-CLP pool token (BPT) over the senior tranche share and a stable quote asset. This gives senior holders an instant secondary market, but creates a recursion: valuing the BPT needs the senior rate `y = ST_eff / N`, and `ST_eff` is the output of `F`, whose input is the BPT value. The sync therefore solves the fixed point `x = F(P_A(x/N))` by integer bisection and publishes `y* = x*/N` to the pool.

Components: the Gyro E-CLP pool (prices the senior leg at the kernel's rate), the Dusk kernel (write path solves and commits, read path serves the cached `y*`), the Balancer V3 hook (forwards before-swap/add/remove callbacks into the sync so every operation executes at a fresh rate), and the accountant shared with Dawn (previewed repeatedly during the solve, committed once after convergence).

## Invariants the spec depends on (do not break)

- **NAV conservation:** `ST_raw + JT_raw = ST_eff + JT_eff` at wei precision. The two outputs must not be rounded independently. Bisection convergence and the `f = 1` plateau argument both rest on this.
- **`F` is non-decreasing and 1-Lipschitz in each input.** The waterfall must stay piecewise-affine with slopes in `[0, 1]`. No branch may amplify an input delta.
- **Frozen solve inputs:** `ST_raw`, `N`, `f`, the invariant `L`, the cached rate `y0`, and the checkpoint are read once at solve start and never re-read during bisection.
- **The demand clamp:** the valuation uses `V̂(y) = ∫ min(D, N)` in integral form. Capping the share count inside the point value instead breaks monotonicity (spec calls this out explicitly).
- **Live supply:** Dusk requires `N ≥ 1` for the life of the market by construction (the Dawn senior tranche alone can fall back to zero supply).
- **Senior-favoring rounding everywhere:** invariant `L` rounded down, floor inside `P_A`, published rate toward senior.
- **Senior independence:** `ST_raw` must be marked from sources that never read the pool, its BPT, or the published rate.
- **Failure semantics:** a failed sync reverts the operation and never overwrites the cached rate. `getRate` must not revert on staleness. A root outside the pool's expressible band `[Nα, Nβ]` reverts rather than clipping.
