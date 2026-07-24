// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { console2 } from "lib/forge-std/src/console2.sol";

import { RoycoMarketSyncer } from "../../../src/periphery/RoycoMarketSyncer.sol";

import { ParameterUpdateBase } from "../base/ParameterUpdateBase.sol";

/**
 * @title RemoveMarketKernels
 * @notice Deregisters obsolete market kernels from the RoycoMarketSyncer so the keeper's batch
 *         accounting sync stops covering them.
 *
 * @dev Current removal set (mainnet):
 *      - Piku USP kernel — market decommissioned, should never have been deployed
 *      - First-generation Tenbin stMXN/stBRL kernels — superseded by the beta==1 redeployments
 *      Kernels are listed by explicit address (not name-resolved) because removed markets are
 *      dropped from the UpdateConfig registry.
 *
 *      `removeMarketKernels` is gated by `SYNC_ROLE`, which `WAY_MULTISIG` holds with 0 execution
 *      delay — single atomic call. Writes one Safe JSON per chain at
 *      `output/update/syncer/{chainId}_remove_market_kernels.json`.
 */
contract RemoveMarketKernels is ParameterUpdateBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev RoycoMarketSyncer proxy on Ethereum mainnet
    address internal constant MAINNET_SYNCER = 0xc46367BBdbC62F1825a46549062a3A88D8668D52;

    string internal constant OUTPUT_SUBDIR = "syncer";
    string internal constant OUTPUT_PREFIX = "remove_market_kernels";
    string internal constant BATCH_DESCRIPTION = "Royco Market Syncer: deregister obsolete market kernels";

    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIG
    // ═══════════════════════════════════════════════════════════════════════════

    struct ChainSyncerConfig {
        uint256 chainId;
        address syncer;
        address[] kernels;
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
        // Piku USP (decommissioned)
        mainnet.kernels.push(0xC3B216EA46fa1DF32139cF40f748232c52bFFaBa);
        // First-generation Tenbin stMXN (superseded)
        mainnet.kernels.push(0x37B6dc33FEF1707254c91446070E2050351Afb86);
        // First-generation Tenbin stBRL (superseded)
        mainnet.kernels.push(0x07D556f8288Ef55cC06Dfb1328dFe2F0fc20a410);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ENTRY POINT
    // ═══════════════════════════════════════════════════════════════════════════

    function run() external {
        for (uint256 i = 0; i < _syncerConfigs.length; i++) {
            _processOneChain(_syncerConfigs[i]);
        }
    }

    /// @dev Forks the chain, encodes the batched `removeMarketKernels` call, and hands off to
    ///      `_processChainDirect` as WAY_MULTISIG.
    function _processOneChain(ChainSyncerConfig storage _cfg) internal {
        vm.createSelectFork(_getRpcUrl(_cfg.chainId));

        address[] memory kernels = new address[](_cfg.kernels.length);
        for (uint256 i = 0; i < _cfg.kernels.length; i++) {
            kernels[i] = _cfg.kernels[i];
            require(RoycoMarketSyncer(_cfg.syncer).isMarketKernelRegistered(kernels[i]), "kernel not registered");
        }

        UpdateParams[] memory updates = new UpdateParams[](1);
        updates[0] = UpdateParams({
            marketName: "",
            target: _cfg.syncer,
            callData: abi.encodeCall(RoycoMarketSyncer.removeMarketKernels, (kernels)),
            description: string.concat("Deregister ", vm.toString(kernels.length), " market kernels from the syncer")
        });

        _processChainDirect(_cfg.chainId, WAY_MULTISIG, updates, OUTPUT_SUBDIR, OUTPUT_PREFIX, BATCH_DESCRIPTION);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VERIFICATION (read back isMarketKernelRegistered for every kernel)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Decodes the batched calldata, then asserts every kernel is deregistered.
    function _verify(UpdateParams memory _params) internal view override {
        // Skip the 4-byte selector and decode (address[])
        bytes memory cd = _params.callData;
        bytes memory args = new bytes(cd.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = cd[i + 4];
        }
        address[] memory kernels = abi.decode(args, (address[]));

        for (uint256 i = 0; i < kernels.length; i++) {
            require(!RoycoMarketSyncer(_params.target).isMarketKernelRegistered(kernels[i]), VerificationFailed("kernel still registered"));
        }
        console2.log("    [OK] Post-state verified:", kernels.length, "kernels deregistered");
    }
}
