# Parameter Update Scripts

Scripts for generating Safe transaction batches to update timelocked parameters on Royco protocol contracts.

## How It Works

All Royco parameter updates are gated by the AccessManager (factory) with a 2-day execution delay for admin roles. The flow is:

1. **Schedule** — The root Safe calls `factory.schedule(target, data, 0)` to queue the operation
2. **Wait** — 2-day execution delay elapses
3. **Execute** — The root Safe calls `factory.execute(target, data)` to apply the change
4. **Cancel** (optional) — The guardian Safe calls `factory.cancel(caller, target, data)` to abort

Each script generates three Safe Transaction Builder JSON files per chain for these phases.

## Usage

### 1. Configure the update

Edit the `_initializeConfigs()` function in the relevant script. Add entries for all markets that need updating — they can span multiple chains:

```solidity
// In script/update/accountant/SetCoverage.s.sol
function _initializeConfigs() internal {
    _configs.push(SetCoverageConfig({ chainId: MAINNET, marketName: SNUSD, newCoverageWAD: 0.15e18 }));
    _configs.push(SetCoverageConfig({ chainId: MAINNET, marketName: AUTOUSD, newCoverageWAD: 0.12e18 }));
    _configs.push(SetCoverageConfig({ chainId: AVALANCHE, marketName: SAVUSD, newCoverageWAD: 0.1e18 }));
}
```

### 2. Run the script

```bash
forge script script/update/accountant/SetCoverage.s.sol
```

The script will automatically:
- Group updates by chain
- Fork each chain and resolve market addresses from the kernel
- Simulate each update (schedule → warp → execute → verify) in isolation
- Write one batched JSON per chain per phase to `output/update/`

RPC URLs are read from environment variables (`MAINNET_RPC_URL`, `AVALANCHE_RPC_URL`, `ARBITRUM_RPC_URL`, `BASE_RPC_URL`).

### 3. Import into Safe

Import the generated JSON files into [Safe Transaction Builder](https://app.safe.global):

1. Import `*_schedule.json` → sign and execute with the root Safe
2. Wait for the 2-day delay
3. Import `*_execute.json` → sign and execute with the root Safe

If you need to cancel a pending operation, import `*_cancel.json` and execute with the guardian Safe.

## Directory Structure

```
script/update/
├── README.md                          # This file
├── base/
│   ├── ParameterUpdateBase.sol        # Base: multi-chain forking, simulation, batched JSON output
│   └── UpdateConfig.sol               # Market name → deployed kernel addresses per chain
├── accountant/
│   ├── SetCoverage.s.sol              # Coverage ratio
│   ├── SetBeta.s.sol                  # Beta sensitivity parameter
│   ├── SetLiquidationUtilization.s.sol
│   ├── SetCoverageConfiguration.s.sol # Combined: coverage + beta + liquidation
│   ├── SetSeniorTrancheProtocolFee.s.sol
│   ├── SetJuniorTrancheProtocolFee.s.sol
│   ├── SetYieldShareProtocolFee.s.sol
│   ├── SetFixedTermDuration.s.sol
│   ├── SetSeniorTrancheDustTolerance.s.sol
│   ├── SetJuniorTrancheDustTolerance.s.sol
│   └── SetYDM.s.sol                   # Yield Distribution Model address
├── kernel/
│   ├── SetProtocolFeeRecipient.s.sol
│   ├── SetSeniorTrancheSelfLiquidationBonus.s.sol
│   ├── SetBlacklistStatus.s.sol
│   ├── BlacklistAccounts.s.sol
│   └── UnblacklistAccounts.s.sol
└── factory/
    └── SetScheduledOperationsExpiry.s.sol
```

Output files — one batched JSON per chain per phase:

```
output/update/
├── accountant/
│   ├── 1_set_coverage_schedule.json       # Mainnet: all coverage updates batched
│   ├── 1_set_coverage_execute.json
│   ├── 1_set_coverage_cancel.json
│   ├── 43114_set_coverage_schedule.json   # Avalanche: all coverage updates batched
│   ├── 43114_set_coverage_execute.json
│   └── 43114_set_coverage_cancel.json
├── kernel/
│   └── ...
└── factory/
    └── ...
```

## Adding a New Parameter Update Script

1. Create a new `.s.sol` file in the appropriate subdirectory (`accountant/`, `kernel/`, or `factory/`)
2. Inherit from `ParameterUpdateBase`
3. Define a config struct with `chainId`, `marketName`, and the new value(s)
4. Implement `_initializeConfigs()` to populate the config array
5. Implement `run()` to group configs by chain and call `_processChain()` for each
6. Override `_verify()` to read back the parameter and assert correctness

Example template:

```solidity
contract SetMyParam is ParameterUpdateBase {
    struct SetMyParamConfig {
        uint256 chainId;
        string marketName;
        uint64 newValue;
    }

    SetMyParamConfig[] internal _configs;

    constructor() { _initializeConfigs(); }

    function _initializeConfigs() internal {
        _configs.push(SetMyParamConfig({ chainId: MAINNET, marketName: SNUSD, newValue: 42 }));
    }

    function run() external {
        uint256[] memory chainIds = _getUniqueChainIds();
        for (uint256 c = 0; c < chainIds.length; c++) {
            uint256 chainId = chainIds[c];

            // Count and collect updates for this chain
            vm.createSelectFork(_getRpcUrl(chainId));
            UpdateParams[] memory updates = ...; // build from _configs filtered by chainId

            _processChain(chainId, updates, "accountant", "set_my_param", "Set myParam");
        }
    }

    function _verify(UpdateParams memory _params) internal view override {
        IRoycoAccountant.RoycoAccountantState memory state = IRoycoAccountant(_params.target).getState();
        // Assert the parameter matches expected value
    }
}
```

## Adding a New Market

Add the kernel address to `UpdateConfig._initializeDeployedMarkets()`:

```solidity
_deployedKernels[MAINNET]["newMarket"] = 0x...;
```

All other addresses (accountant, tranches) are resolved from the kernel at runtime.

## Oracle Staleness During Simulation

The simulation warps 2 days forward to test the execute phase. For markets with strict oracle freshness checks (e.g. Chainlink), this warp can cause the oracle data to become stale, making the execute phase revert. When this happens:

- The **schedule phase** still validates authorization (proves the caller has the correct role)
- The **execute revert** is logged as a warning, not an error
- **JSON batches are still generated** since the authorization was validated
- In production, the oracle will have fresh data when execute is called after the real 2-day delay

## Key Addresses

| Name | Address | Notes |
|------|---------|-------|
| Royco Factory | `0x7cC6fB28eC7b5e7afC3cB3986141797ffc27253C` | Same on all chains (CREATE2) |
| Root Multisig | `0x7c405bbD131e42af506d14e752f2e59B19D49997` | Holds admin roles, schedules + executes |
| Executor Multisig | `0x84d37A25e46029CE161111420E07cEb78880119e` | Guardian — can cancel pending operations |

## Roles & Delays

| Role | Delay | Controls |
|------|-------|----------|
| `ADMIN_ACCOUNTANT_ROLE` | 2 days | Coverage, beta, liquidation, dust tolerances, YDM, fixed term |
| `ADMIN_PROTOCOL_FEE_SETTER_ROLE` | 2 days | ST/JT protocol fees, yield share fee |
| `ADMIN_KERNEL_ROLE` | 2 days | Fee recipient, self-liquidation bonus, blacklist |
| `GUARDIAN_ROLE` | 0 | Can cancel any pending timelocked operation |
