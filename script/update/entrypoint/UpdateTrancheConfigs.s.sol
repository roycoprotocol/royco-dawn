// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { console2 } from "lib/forge-std/src/console2.sol";

import { IRoycoEntryPoint } from "../../../src/interfaces/IRoycoEntryPoint.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { TrancheType } from "../../../src/libraries/Types.sol";

import { ParameterUpdateBase } from "../base/ParameterUpdateBase.sol";

/**
 * @title UpdateTrancheConfigs
 * @notice Registers/updates entry-point tranche configs for the configured markets' ST and JT.
 *         Already-registered tranches keep their current config with only `redemptionDelaySeconds`
 *         overridden; unregistered (new-market) tranches get the standard initial config:
 *         enabled, PROTOCOL yield recipient, 5-minute deposit delay, 24h redemption delay.
 *
 * @dev Hooks into `ParameterUpdateBase`'s scheduled (timelocked) harness:
 *      - Resolves ST/JT addresses per market via `getMarketAddresses(name)`.
 *      - Encodes a single batched `modifyTrancheConfigs(tranches, configs)` call to the
 *        entry point per chain.
 *      - `WAY_MULTISIG` holds `ADMIN_ENTRY_POINT_ROLE` with a 1-day execution delay, so the
 *        harness simulates schedule → warp(1 day + 1) → execute pranking WAY, and writes
 *        schedule/execute/cancel Safe JSONs at
 *        `output/update/entrypoint/{chainId}_update_tranche_configs_{schedule,execute,cancel}.json`.
 *        Both the schedule and execute batches are submitted from the WAY Safe, one day apart.
 */
contract UpdateTrancheConfigs is ParameterUpdateBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev CREATE3-deterministic entry-point proxy address (same on every chain).
    address internal constant ENTRY_POINT = 0x63dA1229be88Fb4D20210147954a1a3e05f2581B;

    /// @dev Execution delay on WAY_MULTISIG's ADMIN_ENTRY_POINT_ROLE; simulation warps past it.
    uint256 internal constant ENTRY_POINT_ROLE_DELAY = 1 days;

    uint24 internal constant NEW_REDEMPTION_DELAY = 24 hours;

    /// @dev Standard deposit delay for newly registered tranches (mainnet convention)
    uint24 internal constant INITIAL_DEPOSIT_DELAY = 5 minutes;

    string internal constant OUTPUT_SUBDIR = "entrypoint";
    string internal constant OUTPUT_PREFIX = "update_tranche_configs";
    string internal constant BATCH_DESCRIPTION = "Royco Entry Point: register/update ST/JT tranche configs";

    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIG
    // ═══════════════════════════════════════════════════════════════════════════

    struct ChainEntryPointConfig {
        uint256 chainId;
        string[] markets;
    }

    ChainEntryPointConfig[] internal _entryPointConfigs;

    constructor() {
        _initializeConfigs();
    }

    function _initializeConfigs() internal {
        // ── Mainnet ──────────────────────────────────────────────────────────
        ChainEntryPointConfig storage mainnet = _entryPointConfigs.push();
        mainnet.chainId = MAINNET;
        // stMXN/stBRL pending redeploy (fixed term -> 0) and the Morini market pending deploy —
        // re-add them here once live. USP was decommissioned and must not be configured.
        mainnet.markets.push(STRUSD);

        // ── Base ─────────────────────────────────────────────────────────────
        // Applied on-chain (SUSN ST/JT: enabled, PROTOCOL, 300s deposit, 24h redemption).
        // ChainEntryPointConfig storage base = _entryPointConfigs.push();
        // base.chainId = BASE;
        // base.markets.push(SUSN);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ENTRY POINT
    // ═══════════════════════════════════════════════════════════════════════════

    function run() external {
        for (uint256 i = 0; i < _entryPointConfigs.length; i++) {
            _processOneChain(_entryPointConfigs[i]);
        }
    }

    /// @dev Forks the chain, resolves tranche addresses, encodes the batched call, and hands off
    ///      to the scheduled `_processChain` flow (WAY schedules, waits 1 day, executes).
    function _processOneChain(ChainEntryPointConfig storage _cfg) internal {
        // Fork once up front so `getMarketAddresses` (which reads the kernel) works.
        // `_processChain` re-forks the same chain — that's fine; calldata is in memory.
        vm.createSelectFork(_getRpcUrl(_cfg.chainId));

        uint256 nMarkets = _cfg.markets.length;
        uint256 nTranches = nMarkets * 2;

        address[] memory tranches = new address[](nTranches);
        IRoycoEntryPoint.TrancheConfig[] memory configs = new IRoycoEntryPoint.TrancheConfig[](nTranches);

        for (uint256 i = 0; i < nMarkets; i++) {
            MarketAddresses memory addrs = getMarketAddresses(_cfg.markets[i]);

            tranches[2 * i] = addrs.seniorTranche;
            configs[2 * i] = _buildTrancheConfig(addrs.seniorTranche);

            tranches[2 * i + 1] = addrs.juniorTranche;
            configs[2 * i + 1] = _buildTrancheConfig(addrs.juniorTranche);
        }

        // Defensive: the registered ST/JT slots must actually be SENIOR/JUNIOR per the
        // tranche contract's TRANCHE_TYPE getter.
        for (uint256 i = 0; i < nTranches; i++) {
            TrancheType tt = IRoycoVaultTranche(tranches[i]).TRANCHE_TYPE();
            require((i % 2 == 0 && tt == TrancheType.SENIOR) || (i % 2 == 1 && tt == TrancheType.JUNIOR), "ST/JT slot mismatch");
        }

        UpdateParams[] memory updates = new UpdateParams[](1);
        updates[0] = UpdateParams({
            marketName: "",
            target: ENTRY_POINT,
            callData: abi.encodeCall(IRoycoEntryPoint.modifyTrancheConfigs, (tranches, configs)),
            description: string.concat("Register/update entry-point tranche configs (", vm.toString(nTranches), " tranches)")
        });

        _processChain(_cfg.chainId, WAY_MULTISIG, ENTRY_POINT_ROLE_DELAY + 1, updates, OUTPUT_SUBDIR, OUTPUT_PREFIX, BATCH_DESCRIPTION);
    }

    /// @dev Builds the target config for a tranche:
    ///      - Already registered (asset set on-chain): echo the current config, overriding only
    ///        `redemptionDelaySeconds` (modifyTrancheConfigs overwrites the whole config).
    ///      - Unregistered (new market): standard initial config — enabled, PROTOCOL yield
    ///        recipient, 5-minute deposit delay, 24h redemption delay.
    function _buildTrancheConfig(address _tranche) internal view returns (IRoycoEntryPoint.TrancheConfig memory config) {
        IRoycoEntryPoint.EnrichedTrancheConfig memory enriched = IRoycoEntryPoint(ENTRY_POINT).getTrancheConfig(_tranche);

        if (enriched.asset == address(0)) {
            // New market — full initial config
            config = IRoycoEntryPoint.TrancheConfig({
                enabled: true,
                yieldRecipient: IRoycoEntryPoint.AccruedYieldRecipient.PROTOCOL,
                depositDelaySeconds: INITIAL_DEPOSIT_DELAY,
                redemptionDelaySeconds: NEW_REDEMPTION_DELAY
            });
        } else {
            // Existing registration — preserve all fields except the redemption delay
            config = enriched.baseConfig;
            config.redemptionDelaySeconds = NEW_REDEMPTION_DELAY;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VERIFICATION (read back getTrancheConfig for every tranche)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Decodes the batched calldata, then asserts every tranche's on-chain config matches.
    function _verify(UpdateParams memory _params) internal view override {
        // Skip the 4-byte selector and decode (address[], TrancheConfig[])
        bytes memory cd = _params.callData;
        bytes memory args = new bytes(cd.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = cd[i + 4];
        }
        (address[] memory tranches, IRoycoEntryPoint.TrancheConfig[] memory configs) = abi.decode(args, (address[], IRoycoEntryPoint.TrancheConfig[]));

        for (uint256 i = 0; i < tranches.length; i++) {
            IRoycoEntryPoint.EnrichedTrancheConfig memory ec = IRoycoEntryPoint(_params.target).getTrancheConfig(tranches[i]);
            require(ec.asset != address(0), VerificationFailed("asset not registered"));
            require(ec.baseConfig.enabled == configs[i].enabled, VerificationFailed("enabled mismatch"));
            require(ec.baseConfig.yieldRecipient == configs[i].yieldRecipient, VerificationFailed("yieldRecipient mismatch"));
            require(ec.baseConfig.depositDelaySeconds == configs[i].depositDelaySeconds, VerificationFailed("depositDelay mismatch"));
            require(ec.baseConfig.redemptionDelaySeconds == configs[i].redemptionDelaySeconds, VerificationFailed("redemptionDelay mismatch"));
            require(ec.baseConfig.redemptionDelaySeconds == NEW_REDEMPTION_DELAY, VerificationFailed("redemptionDelay not 24h"));
        }
        console2.log("    [OK] Post-state verified for", tranches.length, "tranches");
    }
}
