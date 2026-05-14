# Royco Implementation Upgrade System

Generates Safe transaction batches that upgrade UUPS proxies (tranches, kernels, accountant, factory) through the AccessManager (RoycoFactory) timelock — across any number of chains, mixing any number of contract types in a single per-chain batch.

## How it works

All upgradeable Royco contracts use UUPS, with `_authorizeUpgrade` gated by `ADMIN_UPGRADER_ROLE` on the AccessManager (RoycoFactory). This role has a 2-day execution delay, so every upgrade goes through:

```
Script pre-deploys impl  →  Safe "schedule" batch  →  2-day delay  →  Safe "execute" batch
                                                                    ↘  optional "cancel" batch
```

The orchestrator emits three JSONs per chain — `schedule`, `execute`, `cancel`. Each is a Safe Transaction Builder file ready to import.

## Architecture

One orchestrator drives a heterogeneous list of upgrades. Per-contract-type logic lives in modules:

```
script/upgrade/
├── README.md                            -- this file
├── base/
│   ├── UpgradeConfig.sol                -- deployed addresses registry (factory / market addresses)
│   └── UpgradeBase.sol                  -- ERC1967 reads, CREATE2 predict, pre-deploy, simulation, JSON output
├── modules/
│   ├── UpgradeModuleBase.sol            -- abstract module interface (prepare / snapshotState / verify)
│   ├── UpgradeTrancheModule.sol         -- ST + JT tranches
│   ├── UpgradeAccountantModule.sol      -- accountant
│   ├── UpgradeFactoryModule.sol         -- factory (AccessManager)
│   -- UpgradeKernelModule.sol           -- TODO
└── UpgradeBatch.s.sol                   -- single orchestrator: list of UpgradeConfigEntry, dispatches per-chain
```

`UpgradeConfig` is fully self-contained. It does **not** depend on `script/update/` for address resolution — all ST / JT / accountant / kernel addresses are hardcoded per (chainId, market). This means upgrades do not rely on the live kernel being intact, which matters when the kernel itself is the thing being upgraded. YDM is not tracked here because it is non-upgradeable.

Factory is stored as a singleton **per chain**, not per market. All markets on a chain share a single factory entry.

## Config schema

```solidity
enum UpgradeKind { TRANCHE, KERNEL, ACCOUNTANT, FACTORY }

struct UpgradeConfigEntry {
    uint256 chainId;
    UpgradeKind kind;
    string saltVersion;   // version suffix folded into the CREATE2 salt (e.g. "V3")
    bytes payload;        // ABI-encoded; format depends on `kind`
}
```

Per-kind payload formats (decoded by the matching module):

| `kind`       | Payload encoding                                         | Status |
| ------------ | -------------------------------------------------------- | ------ |
| `TRANCHE`    | `abi.encode(string marketName, TrancheType trancheType)` | ready  |
| `ACCOUNTANT` | `abi.encode(string marketName)`                          | ready  |
| `FACTORY`    | `abi.encode()` (empty — factory address is the per-chain entry in `UpgradeConfig`) | ready |
| `KERNEL`     | `abi.encode(string marketName, string kernelContractName)` | TODO |

`TrancheType` is the same enum the protocol uses (`src/libraries/Types.sol`) — `SENIOR` or `JUNIOR`.

`marketName` strings are the constants from `UpgradeConfig` (`SNUSD`, `SAVUSD`, `SUSDAI`, `AUTOUSD`, `SMOKEHOUSE_USDC`, `SYRUP_USDC`). Modules resolve the proxy via `getMarketAddresses(chainId, marketName)`.

## CREATE2 salt convention

The user owns the salt — they set `saltVersion` per upgrade entry (typically bumped each time, e.g. `V2 → V3`). Modules combine it with a per-kind prefix matching `script/Deploy.s.sol`'s convention:

| Kind                | Salt formula                                                                                  |
| ------------------- | --------------------------------------------------------------------------------------------- |
| `TRANCHE` (SENIOR)  | `keccak256(abi.encodePacked("ROYCO_ST_TRANCHE_IMPLEMENTATION_", saltVersion))`                |
| `TRANCHE` (JUNIOR)  | `keccak256(abi.encodePacked("ROYCO_JT_TRANCHE_IMPLEMENTATION_", saltVersion))`                |
| `KERNEL`            | `keccak256(abi.encodePacked("ROYCO_KERNEL_", kernelContractName, "_IMPLEMENTATION_", saltVersion))` |
| `ACCOUNTANT`        | `keccak256(abi.encodePacked("ROYCO_ACCOUNTANT_IMPLEMENTATION_", saltVersion))`                |
| `FACTORY`           | `keccak256(abi.encodePacked("ROYCO_FACTORY_IMPLEMENTATION_", saltVersion))`                   |

Tranche / accountant / kernel constructor args differ per market, so the resulting CREATE2 address still differs per market even though the salt does not — `keccak256(creationCode)` differs and the CREATE2 address depends on it.

If the impl already exists at the predicted address, `_deployImpls` skips it. Re-running with the same `saltVersion` is idempotent.

## Constructor parameter assumption

The system assumes constructor parameters do **not** change between old and new impl. Each module reads the existing impl's immutables off the proxy (e.g. `proxy.asset()`, `proxy.KERNEL()`) and reuses them verbatim when encoding the new impl's creation code. If you ever need to change a constructor arg, update the module to source the new value explicitly.

## Workflow

1. Edit `_initializeConfigs()` in `script/upgrade/UpgradeBatch.s.sol` to list the upgrades you want.
2. Set envs:
   - RPCs for the chains you target: `MAINNET_RPC_URL`, `ARBITRUM_RPC_URL`, `AVALANCHE_RPC_URL`, `BASE_RPC_URL`.
   - `DEPLOYER_PRIVATE_KEY` — the key used by `vm.startBroadcast` for the impl deployments. Required for both dry-run and real-run (the script reads it from env).
3. **Dry-run** to validate everything (fork-only, no on-chain txs):
   ```sh
   forge script script/upgrade/UpgradeBatch.s.sol
   ```
4. **Real run** to actually deploy the new implementations on each chain:
   ```sh
   forge script script/upgrade/UpgradeBatch.s.sol --broadcast
   ```
   `--broadcast` sends the deploy txs from the address corresponding to `DEPLOYER_PRIVATE_KEY`.
   For each chain in the config it will:
   - Fork the chain
   - For each upgrade: dispatch to the module → module predicts the CREATE2 address, snapshots pre-state, builds the upgrade calldata
   - **Pre-deploy** every new impl (`vm.broadcast` — sent as a real tx when run with `--broadcast`). Skipped for impls already deployed at the predicted address (idempotent).
   - Simulate: schedule everything → warp 2 days → execute everything → call `module.verify()` after each execute. Any revert fails the run.
   - Write `output/upgrade/{chainId}_{schedule,execute,cancel}.json`
5. Import the per-chain JSONs into the Safe Transaction Builder. **Importantly, schedule and execute go to a different multisig than cancel:**
   - `{chainId}_schedule.json` and `{chainId}_execute.json` → **`ROOT_MULTISIG`** (`0x7c405bbD131e42af506d14e752f2e59B19D49997`). This multisig holds `ADMIN_UPGRADER_ROLE`, which authorizes scheduling and executing the upgrade.
   - `{chainId}_cancel.json` → **`EXECUTOR_MULTISIG`** (`0x84d37A25e46029CE161111420E07cEb78880119e`). This multisig holds `GUARDIAN_ROLE`. Importing the cancel JSON into the ROOT multisig will revert with `AccessManagerUnauthorizedCall` because guardians are the only role allowed to cancel scheduled operations. The cancel calldata internally references `ROOT_MULTISIG` as the original scheduler — that's correct; the *sender* of the cancel tx must be the guardian.

> ⚠️ The Safe execute batch references the new impl address directly. If you generate JSONs without `--broadcast` and then send them on-chain, the execute will revert because the impl does not exist there. Always `--broadcast` before importing into Safe.

## Per-batch tx layout

- **`schedule.json`** — `[ factory.schedule(proxy_i, upgradeToAndCall(newImpl_i, ""), 0) for each upgrade ]`
- **`execute.json`** — `[ factory.execute(proxy_i, upgradeToAndCall(newImpl_i, "")) for each upgrade ]`. Implementations are pre-deployed by the script (step 4 above), not by the Safe.
- **`cancel.json`** — `[ factory.cancel(ROOT_MULTISIG, proxy_i, upgradeToAndCall(newImpl_i, "")) for each upgrade ]`

All txs target the per-chain factory from `UpgradeConfig.getFactory(chainId)`.

## Verification

Each module defines `snapshotState(proxy)` (captured AFTER the 2-day warp, right before the upgrade
execute) and `verify(proxy, preStateSnapshot)` (called right after). Both reads happen at the same
`block.timestamp`, so time-dependent views compare apples-to-apples.

- **Tranche**: `name`, `symbol`, `totalSupply`, `asset`, `KERNEL`, `TRANCHE_TYPE`, and `totalAssets()` (all three claim fields: `stAssets`, `jtAssets`, `nav`).
- **Accountant**: `KERNEL` immutable, full `getState()` (every storage field — fees, coverage, beta, ydm, last*NAV, last*ImpermanentLoss, accrual/distribution timestamps, dust tolerances), and `previewSyncTrancheAccounting(stRawNAV, jtRawNAV)` using the raw NAVs snapshotted pre-upgrade (so the sync preview is a pure function of (storage, `block.timestamp`, inputs) and comparable across the upgrade).
- **Factory**: `expiration()`, and for every role in `RolesConfiguration` (plus the AccessManager `ADMIN_ROLE` id 0): role admin, role guardian, role grant-delay, and `hasRole(role, account)` for `ROOT_MULTISIG` and `EXECUTOR_MULTISIG` (both `isMember` and `executionDelay`).

If any check fails the script reverts before writing JSONs — you do not get a half-good batch. `schedule` and `execute` are both hard-failing during simulation; any revert from either is surfaced.

## Adding a new module (kernel / accountant / factory)

1. Create `script/upgrade/modules/UpgradeXxxModule.sol`.
2. Inherit `UpgradeModuleBase`.
3. Implement `prepare(chainId, saltVersion, payload)`:
   - Decode the payload.
   - Resolve the proxy (use `getMarketAddresses(chainId, marketName)` for market-scoped contracts; use `getFactory(chainId)` for the factory).
   - Validate the proxy is the expected type (e.g. for kernel, require `SENIOR_TRANCHE()`, `JUNIOR_TRANCHE()`, `ACCOUNTANT()` are non-zero).
   - Read the constructor immutables off the proxy.
   - Build `creationCode = abi.encodePacked(type(NewImplContract).creationCode, abi.encode(constructor args))`.
   - Compute `salt` per the convention above.
   - Call `_predictImpl(salt, creationCode)` to get the deterministic address.
   - Return `PreparedUpgrade`. (Do NOT snapshot pre-state here.)
4. Implement `snapshotState(proxy) returns (bytes)`:
   - Read whatever continuity surface you want to assert — immutables, stored state, and representative time-dependent views.
   - ABI-encode it as `bytes`. Only this module's `verify()` decodes it, so any layout is fine.
5. Implement `verify(proxy, preStateSnapshot)`:
   - Decode the snapshot.
   - Re-read post-upgrade state at the SAME block.timestamp (the orchestrator calls `snapshotState` right before `execute` and `verify` right after).
   - Revert on mismatch.
6. Wire it into `UpgradeBatch.s.sol`:
   - Instantiate it in the constructor and `vm.makePersistent` it.
   - Add the `UpgradeKind` branch in `_moduleFor(...)`.
7. Document the payload schema in this README.

## Adding a new market or chain

Extend `_initializeConfig()` in `script/upgrade/base/UpgradeConfig.sol`:
- Add a chainId constant if the chain is new.
- Add a factory entry in `_factories[newChainId]`.
- Add market addresses in `_markets[chainId][marketName]`.
- Add a market-name constant if needed.

## Key addresses

- **Factory (AccessManager)**: `0x7cC6fB28eC7b5e7afC3cB3986141797ffc27253C` — same on every chain (CREATE2)
- **Root multisig** (holds admin roles incl. `ADMIN_UPGRADER_ROLE`): `0x7c405bbD131e42af506d14e752f2e59B19D49997`
- **Executor multisig** (holds `GUARDIAN_ROLE`, can cancel pending operations): `0x84d37A25e46029CE161111420E07cEb78880119e`
- **CREATE2 deployer** (singleton, same address every chain): `0x4e59b44847b379578588920cA78FbF26c0B4956C`

## Roles & delays

| Role                    | Holder              | Delay  |
| ----------------------- | ------------------- | ------ |
| `ADMIN_UPGRADER_ROLE`   | `ROOT_MULTISIG`     | 2 days |
| `GUARDIAN_ROLE`         | `EXECUTOR_MULTISIG` | 0      |
