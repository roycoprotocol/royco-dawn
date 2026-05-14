// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IUpgradeVerifier, UpgradeBase } from "../base/UpgradeBase.sol";

/**
 * @title UpgradeModuleBase
 * @notice Abstract base for per-contract-type upgrade modules.
 * @dev Each concrete module owns one contract type (tranche, kernel, accountant, factory).
 *      The orchestrator (`UpgradeBatch.s.sol`) calls `prepare(...)` during setup, then right
 *      before each execute it calls `snapshotState(...)` and right after it calls `verify(...)`.
 *
 *      `snapshotState` intentionally runs AFTER the 2-day warp so that any time-dependent view
 *      (e.g. `RoycoVaultTranche.totalAssets`, `RoycoAccountant.previewSyncTrancheAccounting`)
 *      uses the same `block.timestamp` in both the pre- and post-upgrade reads — making the
 *      continuity checks time-invariant.
 */
abstract contract UpgradeModuleBase is UpgradeBase, IUpgradeVerifier {
    /**
     * @notice Decode the payload, verify the proxy is the expected contract type, predict the new
     *         implementation address (CREATE2), and build the upgrade `UpgradeCall`.
     * @param chainId The chain currently being processed (forwarded for modules that need it)
     * @param saltVersion The user-supplied version suffix folded into the CREATE2 salt
     * @param payload Module-specific ABI-encoded data — see each module's natspec for the schema
     */
    function prepare(uint256 chainId, string memory saltVersion, bytes memory payload) external view virtual returns (PreparedUpgrade memory prepared);

    /**
     * @notice Captures pre-upgrade state for later continuity verification.
     *         Runs AFTER the 2-day warp and BEFORE the upgrade execute, so time-dependent views
     *         are evaluated at the same `block.timestamp` as in `verify()`.
     * @return snapshot Module-specific ABI-encoded bytes; only this module's `verify()` decodes it.
     */
    function snapshotState(address proxy) external view virtual returns (bytes memory snapshot);

    /**
     * @notice Re-reads post-upgrade state and asserts continuity vs the snapshot from `snapshotState`.
     *         Reverts on mismatch. Called by `_simulateBatchedUpgrades` after each successful execute.
     */
    function verify(address proxy, bytes memory preStateSnapshot) external view virtual override;
}
