# Royco Dawn [![CI](https://github.com/roycoprotocol/royco-dawn/actions/workflows/test.yml/badge.svg)](https://github.com/roycoprotocol/royco-dawn/actions/workflows/test.yml)

Dawn enables structured risk tranching for any yield source by splitting it into two distinct risk and return profiles: a junior and senior tranche. The junior tranche serves as first-loss capital in exchange for a risk premium paid by the senior tranche.

## Status: Legacy Deployment

Royco Dawn is a legacy Royco protocol deployment. The deployed contracts remain active and may continue to accept deposits, process withdrawals, accrue yield, and otherwise operate according to their deployed logic. However, Dawn is no longer under active protocol development and no upgrades to the deployed contracts are currently planned.

This repository documents the behavior of the deployed Dawn contracts and is maintained for transparency and reference. Users interacting with existing Dawn markets should review the known behavioral limitations described below.

## Known Junior Recovery Behavior

Dawn tracks coverage provided by the Junior tranche to Senior as Junior impermanent loss (“JT IL”). During a recovery, subsequent appreciation is used to repay tracked JT IL.

A market may treat JT IL as fully recovered once this accounting balance reaches zero. This does not necessarily imply that Junior tranche share value has returned to its level immediately before the relevant observation period. Changes in tranche NAV during the observation period can result in Junior share value remaining below its prior level even after the tracked JT IL balance has been fully repaid.

This behavior is part of the currently deployed accounting logic.

## Core Concepts

### NAV Types

Each market tracks two types of NAVs (Net Asset Value) per tranche:

**Raw NAV**: The pure asset value of the tranche based on underlying prices, excluding any coverage adjustments or yield share (risk premium). This represents the actual market value of the tranche's holdings.

**Effective NAV**: The NAV after applying coverage obligations and yield share (risk premium). The effective NAV determines the actual redemption value for tranche LPs.

### Coverage and Utilization

Each market enforces a minimum coverage requirement, ensuring that senior capital always retains guaranteed downside protection. Utilization measures how much of the junior buffer is currently "used" by senior exposure:

```
                (ST_RAW_NAV + (JT_RAW_NAV × β)) × COVERAGE
Utilization =   ───────────────────────────────────────────
                            JT_EFFECTIVE_NAV
```

**Parameters:**
- `COVERAGE`: The minimum required coverage percentage (eg. 20% means JT must be able to cover 20% of ST losses at all times)
- `β`: Beta is JT's sensitivity to the same downside stress that affects ST (eg. 0 if JT is in a risk-free investment, 1 if JT and ST are in the same underlying investment)

Intuitively, when utilization is less than or equal to 100%, the market is fully collateralized from a coverage lens. Consequently, when utilization breaches 100%, the market has suffered sufficient losses such that the minimum coverage requirement is violated.

Markets target a slight excess of junior capital above the minimum coverage requirement (90% utilization) to keep the junior tranche perpetually liquid. To maintain this target, the risk premium paid by seniors to juniors adapts to supply and demand signals. As utilization approaches 100%, the junior's risk premium increases to attract more junior capital.

Each market also defines a **liquidation utilization threshold**. When utilization exceeds this threshold, the market is deemed unhealthy and ST redeemers receive a self-liquidation bonus funded by JT assets, incentivizing seniors to exit to restore the market into a healthy state. This threshold must be greater than 100% to ensure that the market is only considered unhealthy when the minimum coverage requirement is violated. A threshold of 150% means the market enters liquidation mode when JT's remaining buffer can only cover two-thirds of the required coverage relative to senior exposure.

## Architecture

### Factory

The **RoycoFactory** is a singleton contract that deploys and manages all Dawn markets. Each market deployment creates four interconnected contracts (senior and junior tranche, kernel, and accountant) via CREATE3 for deterministic addresses. The Factory also serves as the global access manager for all deployed markets, administering role-based permissions across the protocol.

### Tranches

Each market has two ERC4626-style vault contracts representing the two tranches:

**Senior Tranche (ST)**: The capital-protected tier. Senior LPs receive downside protection from the junior tranche when the underlying yield source experiences losses, the junior tranche absorbs them first. In exchange for this protection, senior LPs pay a risk premium (portion of their yield) to junior LPs. Senior has first claim on any recoveries after a loss event.

**Junior Tranche (JT)**: The first-loss capital tier. Junior LPs provide a coverage buffer that protects senior capital from losses. In return, they earn a risk premium from senior yield. The size of this premium is determined by the market's Yield Distribution Model (YDM).

Both tranches are ERC20Permit enabled, pausable, and support standard preview and deposit/redeem operations.

Royco tranches are natively composable across DeFi. Senior tranches transform high-risk vault tokens into leverage-eligible collateral for lending markets, unlocking net-new capital that wasn't accessible before.

Beyond lending, tranches can be paired on AMMs/CLOBs, split on Pendle for fixed or variable rate exposure, and recursively tranched into layered risk structures.

### Kernel

The **Kernel** is the operational core of each market. It orchestrates all deposits and redemptions, routing assets between tranches and enforcing market constraints. Each Kernel includes a pluggable **Quoter** module that handles tranche asset to NAV conversions using protocol-specific pricing logic (e.g., ERC4626 share prices, Chainlink oracles, or custom oracle integrations).

The Kernel enforces coverage requirements: it will block operations that would leave the senior tranche undercollateralized or junior tranche LPs realizing unwarranted losses. It also manages blacklist functionality for compliance requirements.

### Accountant

The **Accountant** maintains the financial state of each market. Before and after every operation, it synchronizes tranche accounting by:

1. Reconciling any unrealized PnL since the last accounting sync via the deltas between the current and last checkpointed raw NAVs of each tranche
2. Applying coverage obligations on losses
3. Tracking impermanent losses (temporary losses that may recover)
4. Distributing yield from senior to junior (risk premium) as instructed by the market's YDM
5. Accruing protocol fees

### Yield Distribution Model (YDM)

The **YDM** determines what percentage of senior yield flows to junior as compensation for providing coverage.

Dawn supports multiple YDM implementations:

**Static Curve YDM**: A fixed piecewise curve that remains eternally static. The curve is defined by three anchor points: JT yield share at 0%, 90%, and 100% utilization. Higher utilization means JT earns more of the senior yield. Setting all three of these parameters at the same JT yield share results in a fixed yield share market.

**Adaptive Curve YDM V1**: The curve shifts up or down over time based on how far utilization deviates from target. When the curve adapts, the entire shape scales proportionally: the steeper the curve, the more aggressively JT yield share changes with utilization.

**Adaptive Curve YDM V2**: Similar to V1, but the entire curve translates vertically rather than scaling. The slopes remain constant because the fixed discount (reduction from target yield share at 0% utilization) and fixed premium (addition to target yield share at 100% utilization) are set at initialization. V2 also allows each market to configure its own adaptation speed.

## Market Dynamics

### Market States

Markets operate as perpetual instruments with full liquidity for both tranches under normal conditions. If senior capital incurs a loss, junior coverage is immediately applied and the market enters a fixed-term regime. This gives the underlying position time to recover before junior LPs realize any losses. If the protocol’s tracked recovery conditions are satisfied, including repayment of tracked JT IL, the market can shift back to a perpetual state. Repayment of JT IL does not necessarily mean that Junior share value has returned to its pre-observation-period level. In the event that losses persist and coverage runs thin, seniors can exit early with their guaranteed protection intact.

The two states are:

**PERPETUAL**: Normal operation. All deposits and redemptions are enabled (subject to coverage constraints), the YDM actively adapts, and protocol fees accrue.

**FIXED_TERM**: Recovery state entered when JT provides coverage for ST losses. ST redemptions and JT deposits are blocked to protect JT's claim on future recovery. ST deposits and JT redemptions remain enabled. The YDM is frozen and no protocol fees are taken.

**Transitions back to PERPETUAL** occur when: (1) losses fully recover, (2) the fixed term duration expires, (3) liquidation threshold is breached (unhealthy), or (4) ST IL exists (distressed). In all cases besides (1), the market is forced into a PERPETUAL state to restore liquidity, and JT IL is erased (JT forfeits its recovery claim).

### Impermanent Loss

When losses occur, they are handled differently based on which tranche experiences them:

**ST Losses**: JT provides coverage from its buffer up to its available capacity. The coverage provided is tracked as JT IL (a JT claim on future ST appreciation). Any ST loss exceeding JT's coverage capacity is absorbed by ST and tracked as ST IL.

**JT Losses**: First reduce JT effective NAV. If JT effective NAV is depleted, excess losses spill over to ST and are tracked as ST IL.

**Recovery**: When appreciation occurs, ST IL is recovered first (senior priority), then JT IL is repaid. JT IL represents the protocol’s tracked accounting claim; its repayment is distinct from restoration of Junior’s historical share value. Remaining gains are distributed as yield via the YDM.

**JT IL Erasure**: JT IL is erased (JT forfeits its claim) when the market transitions to PERPETUAL state. This occurs when the fixed-term period expires, utilization exceeds the liquidation threshold, or ST IL exists (distressed state).

## Supported Yield Sources

Dawn's pluggable quoter architecture enables integration with any yield-bearing asset. Each Kernel implementation defines how tranche assets are priced in NAV terms.

**ERC4626 Vaults**: Any ERC4626-compliant vault with socialized losses (Morpho v1 and v2, Yearn Finance, etc.) using share price for tranche asset to base asset conversion, with either an admin-set or Chainlink-compatible oracle for base asset to NAV conversion.

**ERC20 Tokens**: Generic yield-bearing ERC20s (mf-ONE, ACRED, etc.) priced via Chainlink-compatible oracles.

**Protocol-Specific**:
- **Maple Finance (Pool V2)**: Pool V2 tokens (syrupUSDC, Maple Institutional, etc.) using exit share price
- **Pareto/Idle (AA CDO)**: Pareto's CDO AA tranches (AA-FalconXUSDC, etc.) using virtual price
- **Metastreet (sUSDai)**: Staked USDai using redemption share price
- **Re (reUSD)**: reUSD using Insurance Capital Layer oracle
- **Makina (machines)**: Machine shares (DUSD, DBIT, etc.) using machine exchange rate

## Extended Capabilities

**Flexible Deployment**: Senior and junior capital within the same market can be deployed into identical or disparate yield sources.

For example, seniors might be invested in Ethena while juniors are invested in Aave.

**Depeg Protection**: Markets backed by synthetic assets use oracles that value the underlying based on actual backing rather than secondary market prices.

If a depeg occurs, the loss is absorbed by junior coverage rather than passed through at stale valuations.

**Recursive Tranching**: Tranches can be used as inputs into new markets, enabling layered risk structures.

Tranching a yield source produces Senior A and Junior A. Retranching Senior A produces Senior B and Junior B:

```
Senior:    Senior B
Mezzanine: Junior B
Equity:    Junior A
```

This process can be repeated indefinitely to create arbitrarily deep capital structures.
