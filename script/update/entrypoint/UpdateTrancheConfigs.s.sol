// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { console2 } from "lib/forge-std/src/console2.sol";

import { IRoycoEntryPoint } from "../../../src/interfaces/IRoycoEntryPoint.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { TrancheType } from "../../../src/libraries/Types.sol";

import { ParameterUpdateBase } from "../base/ParameterUpdateBase.sol";

/**
 * @title UpdateTrancheConfigs
 * @notice Bumps every market's entry-point delays to 24h and switches all senior tranches
 *         to REDEEMING_LP yield routing. Junior tranches keep PROTOCOL routing.
 *
 * @dev Hooks into `ParameterUpdateBase`'s direct-call harness:
 *      - Resolves ST/JT addresses per market via `getMarketAddresses(name)`.
 *      - Auto-classifies each tranche via `TRANCHE_TYPE()` to pick the yield recipient.
 *      - Encodes a single batched `modifyTrancheConfigs(tranches, configs)` call to the
 *        entry point per chain.
 *      - Runs the call via `_processChainDirect` pranking `WCE_MULTISIG` (immediate role).
 *      - Writes one Safe JSON per chain at
 *        `output/update/entrypoint/{chainId}_update_tranche_configs.json`.
 *
 *      No schedule/execute split: WCE holds `ADMIN_ENTRY_POINT_ROLE` with delay 0.
 */
contract UpdateTrancheConfigs is ParameterUpdateBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev CREATE3-deterministic entry-point proxy address (same on every chain).
    address internal constant ENTRY_POINT = 0x63dA1229be88Fb4D20210147954a1a3e05f2581B;

    uint24 internal constant NEW_DEPOSIT_DELAY = 5 minutes;
    uint24 internal constant NEW_REDEMPTION_DELAY = 24 hours;

    string internal constant OUTPUT_SUBDIR = "entrypoint";
    string internal constant OUTPUT_PREFIX = "update_tranche_configs";
    string internal constant BATCH_DESCRIPTION = "Royco Entry Point: bump delays to 24h and route ST yield to REDEEMING_LP";

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
        // mainnet.markets.push(SNUSD);
        // mainnet.markets.push(AUTOUSD);
        // mainnet.markets.push(SMOKEHOUSE_USDC);
        // mainnet.markets.push(SYRUP_USDC);
        // mainnet.markets.push(STCUSD);
        // mainnet.markets.push(PARETO_FALCONX);
        // mainnet.markets.push(APYUSD);
        mainnet.markets.push(eEARN);

        // ── Avalanche ────────────────────────────────────────────────────────
        // ChainEntryPointConfig storage avalanche = _entryPointConfigs.push();
        // avalanche.chainId = AVALANCHE;
        // avalanche.markets.push(SAVUSD);

        // ── Arbitrum ─────────────────────────────────────────────────────────
        // ChainEntryPointConfig storage arbitrum = _entryPointConfigs.push();
        // arbitrum.chainId = ARBITRUM;
        // arbitrum.markets.push(SUSDAI);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ENTRY POINT
    // ═══════════════════════════════════════════════════════════════════════════

    function run() external {
        for (uint256 i = 0; i < _entryPointConfigs.length; i++) {
            _processOneChain(_entryPointConfigs[i]);
        }
    }

    /// @dev Forks the chain, resolves tranche addresses, encodes the batched call, and
    ///      hands off to `_processChainDirect` for simulation + JSON write.
    function _processOneChain(ChainEntryPointConfig storage _cfg) internal {
        // Fork once up front so `getMarketAddresses` (which reads the kernel) works.
        // `_processChainDirect` re-forks the same chain — that's fine; calldata is in memory.
        vm.createSelectFork(_getRpcUrl(_cfg.chainId));

        uint256 nMarkets = _cfg.markets.length;
        uint256 nTranches = nMarkets * 2;

        address[] memory tranches = new address[](nTranches);
        IRoycoEntryPoint.TrancheConfig[] memory configs = new IRoycoEntryPoint.TrancheConfig[](nTranches);

        for (uint256 i = 0; i < nMarkets; i++) {
            MarketAddresses memory addrs = getMarketAddresses(_cfg.markets[i]);

            // Senior tranche → REDEEMING_LP
            tranches[2 * i] = addrs.seniorTranche;
            configs[2 * i] = IRoycoEntryPoint.TrancheConfig({
                enabled: true,
                yieldRecipient: IRoycoEntryPoint.AccruedYieldRecipient.PROTOCOL,
                depositDelaySeconds: NEW_DEPOSIT_DELAY,
                redemptionDelaySeconds: NEW_REDEMPTION_DELAY
            });

            // Junior tranche → PROTOCOL (unchanged)
            tranches[2 * i + 1] = addrs.juniorTranche;
            configs[2 * i + 1] = IRoycoEntryPoint.TrancheConfig({
                enabled: true,
                yieldRecipient: IRoycoEntryPoint.AccruedYieldRecipient.PROTOCOL,
                depositDelaySeconds: NEW_DEPOSIT_DELAY,
                redemptionDelaySeconds: NEW_REDEMPTION_DELAY
            });
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
            description: string.concat("Update entry-point tranche configs (", vm.toString(nTranches), " tranches)")
        });

        _processChainDirect(_cfg.chainId, WCE_MULTISIG, updates, OUTPUT_SUBDIR, OUTPUT_PREFIX, BATCH_DESCRIPTION);
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
            require(ec.baseConfig.enabled == configs[i].enabled, VerificationFailed("enabled mismatch"));
            require(ec.baseConfig.yieldRecipient == configs[i].yieldRecipient, VerificationFailed("yieldRecipient mismatch"));
            require(ec.baseConfig.depositDelaySeconds == configs[i].depositDelaySeconds, VerificationFailed("depositDelay mismatch"));
            require(ec.baseConfig.redemptionDelaySeconds == configs[i].redemptionDelaySeconds, VerificationFailed("redemptionDelay mismatch"));
        }
        console2.log("    [OK] Post-state verified for", tranches.length, "tranches");
    }
}
