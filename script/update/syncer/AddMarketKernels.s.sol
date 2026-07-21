// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { console2 } from "lib/forge-std/src/console2.sol";

import { RoycoMarketSyncer } from "../../../src/periphery/RoycoMarketSyncer.sol";

import { ParameterUpdateBase } from "../base/ParameterUpdateBase.sol";

/**
 * @title AddMarketKernels
 * @notice Registers newly deployed market kernels with the RoycoMarketSyncer so the keeper's
 *         batch accounting sync covers them.
 *
 * @dev Hooks into `ParameterUpdateBase`'s direct-call harness:
 *      - `addMarketKernels` is gated by `SYNC_ROLE`, which `WAY_MULTISIG` holds with 0 execution
 *        delay — so this is a single atomic call, no schedule/execute split.
 *      - The syncer itself validates each kernel against the factory registry
 *        (`_validateMarketKernel`: senior tranche pairing + kernel back-reference).
 *      - Writes one Safe JSON per chain at
 *        `output/update/syncer/{chainId}_add_market_kernels.json`.
 */
contract AddMarketKernels is ParameterUpdateBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev RoycoMarketSyncer proxy on Ethereum mainnet
    address internal constant MAINNET_SYNCER = 0xc46367BBdbC62F1825a46549062a3A88D8668D52;

    string internal constant OUTPUT_SUBDIR = "syncer";
    string internal constant OUTPUT_PREFIX = "add_market_kernels";
    string internal constant BATCH_DESCRIPTION = "Royco Market Syncer: register market kernels";

    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIG
    // ═══════════════════════════════════════════════════════════════════════════

    struct ChainSyncerConfig {
        uint256 chainId;
        address syncer;
        string[] markets;
    }

    ChainSyncerConfig[] internal _syncerConfigs;

    constructor() {
        _initializeConfigs();
    }

    function _initializeConfigs() internal {
        // ── Mainnet ──────────────────────────────────────────────────────────
        ChainSyncerConfig storage mainnet = _syncerConfigs.push();
        mainnet.chainId = MAINNET;
        mainnet.syncer = MAINNET_SYNCER;
        mainnet.markets.push(STMXN);
        mainnet.markets.push(STBRL);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ENTRY POINT
    // ═══════════════════════════════════════════════════════════════════════════

    function run() external {
        for (uint256 i = 0; i < _syncerConfigs.length; i++) {
            _processOneChain(_syncerConfigs[i]);
        }
    }

    /// @dev Forks the chain, resolves kernels from the market registry, encodes the batched
    ///      `addMarketKernels` call, and hands off to `_processChainDirect` as WAY_MULTISIG.
    function _processOneChain(ChainSyncerConfig storage _cfg) internal {
        // Fork once up front so `getMarketAddresses` (which reads the kernel) works.
        vm.createSelectFork(_getRpcUrl(_cfg.chainId));

        address[] memory kernels = new address[](_cfg.markets.length);
        for (uint256 i = 0; i < _cfg.markets.length; i++) {
            kernels[i] = getMarketAddresses(_cfg.markets[i]).kernel;
            require(!RoycoMarketSyncer(_cfg.syncer).isMarketKernelRegistered(kernels[i]), "kernel already registered");
        }

        UpdateParams[] memory updates = new UpdateParams[](1);
        updates[0] = UpdateParams({
            marketName: "",
            target: _cfg.syncer,
            callData: abi.encodeCall(RoycoMarketSyncer.addMarketKernels, (kernels)),
            description: string.concat("Register ", vm.toString(kernels.length), " market kernels with the syncer")
        });

        _processChainDirect(_cfg.chainId, WAY_MULTISIG, updates, OUTPUT_SUBDIR, OUTPUT_PREFIX, BATCH_DESCRIPTION);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VERIFICATION (read back isMarketKernelRegistered for every kernel)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Decodes the batched calldata, then asserts every kernel is registered.
    function _verify(UpdateParams memory _params) internal view override {
        // Skip the 4-byte selector and decode (address[])
        bytes memory cd = _params.callData;
        bytes memory args = new bytes(cd.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = cd[i + 4];
        }
        address[] memory kernels = abi.decode(args, (address[]));

        for (uint256 i = 0; i < kernels.length; i++) {
            require(RoycoMarketSyncer(_params.target).isMarketKernelRegistered(kernels[i]), VerificationFailed("kernel not registered"));
        }
        console2.log("    [OK] Post-state verified for", kernels.length, "kernels");
    }
}
