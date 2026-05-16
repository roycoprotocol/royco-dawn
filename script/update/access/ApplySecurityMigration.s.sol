// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IAccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

import { RolesConfiguration } from "../../../src/factory/RolesConfiguration.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoDawnKernel } from "../../../src/interfaces/IRoycoDawnKernel.sol";

import { ExtraRoles } from "../../config/ExtraRoles.sol";
import { AccessManagerConfigUtils } from "../../utils/AccessManagerConfigUtils.sol";
import { UpdateConfig } from "../base/UpdateConfig.sol";

/**
 * @title ApplySecurityMigration
 * @notice Migrates already-deployed Royco factories to the new role / delay model on the
 *         tranches surface (Dawn Markets).
 *
 * Per chain, this script generates ONE Safe transaction batch (no schedule/execute split is
 * needed because the current `ADMIN_ROLE` holder has a 0-second execution delay, so every
 * migration call goes through the factory immediately).
 *
 * The batch performs, in this order:
 *
 *   1. **Set every FNDN-held role's delay explicitly** — including ones whose value does
 *      not change. This makes the post-batch on-chain configuration self-evident from the
 *      Safe JSON alone, with no implicit "left at the previous value" semantics.
 *
 *      Standard (24h):       ADMIN_KERNEL_ROLE, ADMIN_ACCOUNTANT_ROLE,
 *                            ADMIN_PROTOCOL_FEE_SETTER_ROLE, DEPLOYER_ROLE_ADMIN_ROLE,
 *                            ADMIN_UNPAUSER_ROLE (new)
 *      Critical (48h):       ADMIN_UPGRADER_ROLE
 *      Immediate (0):        ADMIN_PAUSER_ROLE, LP_ROLE_ADMIN_ROLE, SYNC_ROLE,
 *                            ADMIN_ORACLE_QUOTER_ROLE, DEPLOYER_ROLE
 *      Immediate (0)*:       GUARDIAN_ROLE @ EXECUTOR_MULTISIG (separate holder; see notes)
 *
 *   2. Wire `ADMIN_UNPAUSER_ROLE` into the protocol:
 *        - setRoleGuardian(ADMIN_UNPAUSER_ROLE, GUARDIAN_ROLE)
 *        - For every pausable target on this chain (each market's kernel/accountant/ST/JT
 *          plus the chain's syncer), re-bind the `unpause()` selector from
 *          ADMIN_PAUSER_ROLE → ADMIN_UNPAUSER_ROLE.
 *
 *   3. Apply the Critical (48h) execution delay to the admin holder (LAST):
 *        - grantRole(ADMIN_ROLE, FNDN, 2 days)
 *
 *      After this step, every subsequent role-0-gated call (grantRole/revokeRole/
 *      setRoleAdmin/setRoleGuardian/setTargetFunctionRole/setTargetClosed/etc.) requires
 *      schedule + 48h wait + execute. This closes the "timelock-the-timelock" gap.
 *
 * Notes:
 * - FNDN address: assumed equal to the existing on-chain ROOT_MULTISIG (which already holds
 *   ADMIN_ROLE and the role admin slots). Multisig signer migration is out of scope.
 * - GUARDIAN_ROLE stays on the existing on-chain holder (EXECUTOR_MULTISIG); WAY proposer
 *   migration is out of scope.
 * - ST_LP_ROLE / JT_LP_ROLE are user-facing roles with many holders; not re-granted here.
 * - TRANSFER_AGENT_ROLE delay is still TBD in the security model and is not touched.
 * - BURNER_ROLE (entry-point yield-forfeiture) is not part of this migration's scope.
 *
 * Output: `output/update/access/{chainId}_apply_security_migration.json`
 *         (single Safe Transaction Builder JSON — no schedule/cancel files since these
 *         calls are not delayed under the current configuration).
 */
contract ApplySecurityMigration is AccessManagerConfigUtils, UpdateConfig, RolesConfiguration, ExtraRoles {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev FNDN holds privileged roles in the new model. Currently the same address
    ///      as ROOT_MULTISIG (which already holds ADMIN_ROLE on every deployed factory).
    address internal constant FNDN = ROOT_MULTISIG;

    /// @dev GUARDIAN_ROLE holder. Currently EXECUTOR_MULTISIG; WAY migration out of scope.
    address internal constant GUARDIAN_HOLDER = EXECUTOR_MULTISIG;

    /// @dev Delay tier durations from the security model.
    uint32 internal constant IMMEDIATE_DELAY = 0;
    uint32 internal constant STANDARD_DELAY = 1 days;
    uint32 internal constant CRITICAL_DELAY = 2 days;

    /// @dev Output base directory for access-control batches
    string internal constant ACCESS_OUTPUT_DIRECTORY = "output/update/access/";

    // ═══════════════════════════════════════════════════════════════════════════
    // CHAIN CONFIG
    // ═══════════════════════════════════════════════════════════════════════════

    struct ChainConfig {
        uint256 chainId;
        /// @dev Market names whose targets (kernel/accountant/ST/JT) are remapped for the unpause split.
        ///      Pulled from UpdateConfig._deployedKernels.
        string[] markets;
        /// @dev Per-chain syncer proxy address (also pausable).
        address syncer;
    }

    ChainConfig[] internal _chainConfigs;

    constructor() {
        _initializeChainConfigs();
    }

    function _initializeChainConfigs() internal {
        // ── Mainnet ──────────────────────────────────────────────────────────
        ChainConfig storage mainnet = _chainConfigs.push();
        mainnet.chainId = MAINNET;
        mainnet.markets.push(STCUSD);
        mainnet.markets.push(SNUSD);
        mainnet.markets.push(AUTOUSD);
        mainnet.markets.push(SMOKEHOUSE_USDC);
        mainnet.markets.push(SYRUP_USDC);
        mainnet.syncer = 0xc46367BBdbC62F1825a46549062a3A88D8668D52;

        // ── Avalanche ────────────────────────────────────────────────────────
        ChainConfig storage avalanche = _chainConfigs.push();
        avalanche.chainId = AVALANCHE;
        avalanche.markets.push(SAVUSD);
        avalanche.syncer = 0x2E9fCb5Ea139d2fDb5CcDc5BdF16357Da68d872C;

        // ── Arbitrum ─────────────────────────────────────────────────────────
        ChainConfig storage arbitrum = _chainConfigs.push();
        arbitrum.chainId = ARBITRUM;
        arbitrum.markets.push(SUSDAI);
        arbitrum.syncer = 0x8DCC7107e3AD82B60144bE68bE9C4809c84b9E06;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ENTRY POINT
    // ═══════════════════════════════════════════════════════════════════════════

    function run() external {
        for (uint256 c = 0; c < _chainConfigs.length; c++) {
            _processChain(_chainConfigs[c]);
        }
    }

    function _processChain(ChainConfig storage _cfg) internal {
        vm.createSelectFork(_getRpcUrl(_cfg.chainId));

        console2.log("");
        console2.log("========================================");
        console2.log("Security migration | chain:", _cfg.chainId);
        console2.log("  Markets:", _cfg.markets.length);
        console2.log("========================================");

        // ── 1. Build the batch ───────────────────────────────────────────────
        SafeTransaction[] memory txs = _buildBatch(_cfg);

        // ── 2. Simulate the batch (sequential, single prank chain) ───────────
        _simulateBatch(_cfg, txs);

        // ── 3. Write the Safe JSON ───────────────────────────────────────────
        string memory fileName = string.concat("access/", vm.toString(_cfg.chainId), "_apply_security_migration");
        _writeMigrationJson(txs, fileName);

        console2.log("");
        console2.log("  Output:", string.concat("output/update/", fileName, ".json"));
        console2.log("  Done.");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BATCH BUILDER
    // ═══════════════════════════════════════════════════════════════════════════

    function _buildBatch(ChainConfig storage _cfg) internal returns (SafeTransaction[] memory txs) {
        // Enumerate all pausable targets on this chain: 4 per market + 1 syncer
        uint256 marketCount = _cfg.markets.length;
        address[] memory pausableTargets = new address[](4 * marketCount + 1);
        uint256 idx = 0;
        for (uint256 i = 0; i < marketCount; i++) {
            MarketAddresses memory addrs = getMarketAddresses(_cfg.markets[i]);
            pausableTargets[idx++] = addrs.kernel;
            pausableTargets[idx++] = addrs.accountant;
            pausableTargets[idx++] = addrs.seniorTranche;
            pausableTargets[idx++] = addrs.juniorTranche;
        }
        pausableTargets[idx++] = _cfg.syncer;

        // Total tx count:
        //   12 grantRole (explicit delays for every FNDN-held role + GUARDIAN_ROLE)
        // +  1 setRoleGuardian (ADMIN_UNPAUSER_ROLE)
        // +  N setTargetFunctionRole (one per pausable target, for the unpause split)
        // +  1 grantRole (Critical delay on ADMIN_ROLE — LAST)
        uint256 total = 12 + 1 + pausableTargets.length + 1;
        txs = new SafeTransaction[](total);
        uint256 t = 0;

        // ── Step 1: explicit grants for every FNDN-held role (and GUARDIAN_ROLE) ─
        //
        // Ordering note: `DEPLOYER_ROLE` is gated by `DEPLOYER_ROLE_ADMIN_ROLE` (not by
        // ADMIN_ROLE), so once we increase FNDN's delay on `DEPLOYER_ROLE_ADMIN_ROLE`
        // from 0 → 1 day, FNDN can no longer grant `DEPLOYER_ROLE` atomically. Therefore
        // the `DEPLOYER_ROLE` grant must run BEFORE the `DEPLOYER_ROLE_ADMIN_ROLE`
        // delay change. All other grants are gated by ADMIN_ROLE which stays at 0
        // delay until step 3, so their order doesn't matter.
        //
        // Immediate (0) — granted first so ordering is irrelevant for the rest
        txs[t++] = buildGrantRole(ROYCO_FACTORY, DEPLOYER_ROLE, FNDN, IMMEDIATE_DELAY);
        txs[t++] = buildGrantRole(ROYCO_FACTORY, ADMIN_PAUSER_ROLE, FNDN, IMMEDIATE_DELAY);
        txs[t++] = buildGrantRole(ROYCO_FACTORY, LP_ROLE_ADMIN_ROLE, FNDN, IMMEDIATE_DELAY);
        txs[t++] = buildGrantRole(ROYCO_FACTORY, SYNC_ROLE, FNDN, IMMEDIATE_DELAY);
        txs[t++] = buildGrantRole(ROYCO_FACTORY, ADMIN_ORACLE_QUOTER_ROLE, FNDN, IMMEDIATE_DELAY);
        txs[t++] = buildGrantRole(ROYCO_FACTORY, GUARDIAN_ROLE, GUARDIAN_HOLDER, IMMEDIATE_DELAY);
        // Standard (24h)
        txs[t++] = buildGrantRole(ROYCO_FACTORY, ADMIN_KERNEL_ROLE, FNDN, STANDARD_DELAY);
        txs[t++] = buildGrantRole(ROYCO_FACTORY, ADMIN_ACCOUNTANT_ROLE, FNDN, STANDARD_DELAY);
        txs[t++] = buildGrantRole(ROYCO_FACTORY, ADMIN_PROTOCOL_FEE_SETTER_ROLE, FNDN, STANDARD_DELAY);
        txs[t++] = buildGrantRole(ROYCO_FACTORY, DEPLOYER_ROLE_ADMIN_ROLE, FNDN, STANDARD_DELAY);
        txs[t++] = buildGrantRole(ROYCO_FACTORY, ADMIN_UNPAUSER_ROLE, FNDN, STANDARD_DELAY);
        // Critical (48h) — non-admin role; ADMIN_ROLE delay is set last in step 3
        txs[t++] = buildGrantRole(ROYCO_FACTORY, ADMIN_UPGRADER_ROLE, FNDN, CRITICAL_DELAY);

        // ── Step 2: wire ADMIN_UNPAUSER_ROLE into the protocol ───────────────
        txs[t++] = _buildSetRoleGuardian(ROYCO_FACTORY, ADMIN_UNPAUSER_ROLE, GUARDIAN_ROLE);
        bytes4[] memory unpauseSelectors = new bytes4[](1);
        unpauseSelectors[0] = IRoycoAuth.unpause.selector;
        for (uint256 i = 0; i < pausableTargets.length; i++) {
            txs[t++] = buildSetTargetFunctionRole(ROYCO_FACTORY, pausableTargets[i], unpauseSelectors, ADMIN_UNPAUSER_ROLE);
        }

        // ── Step 3: apply Critical delay on ADMIN_ROLE holder (LAST) ─────────
        txs[t++] = buildGrantRole(ROYCO_FACTORY, _ADMIN_ROLE, FNDN, CRITICAL_DELAY);

        require(t == total, "tx count mismatch");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SIMULATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Simulates the batch by pranking ROOT_MULTISIG and replaying each tx in order.
    ///      Reverts if any call fails. After the batch executes successfully, also asserts
    ///      that the new Critical delay on ADMIN_ROLE actually took effect by attempting
    ///      a follow-up role-0 call (must now require schedule + warp).
    function _simulateBatch(ChainConfig storage _cfg, SafeTransaction[] memory _txs) internal {
        IAccessManager factory = IAccessManager(ROYCO_FACTORY);

        for (uint256 i = 0; i < _txs.length; i++) {
            vm.prank(FNDN);
            (bool ok, bytes memory ret) = _txs[i].to.call{ value: _txs[i].value }(_txs[i].data);
            require(ok, _decodeRevert(ret, i));
        }
        console2.log("  [OK] All", _txs.length, "txs replayed successfully");

        // OZ AccessManager applies a grace period equal to (oldDelay - newDelay) when an
        // execution delay is REDUCED — so the 2d → 1d reductions take effect 1 day after
        // the call. Increases (e.g. 0 → 2d on ADMIN_ROLE) take effect immediately. Warp
        // past the longest pending grace period so the post-state checks see the new values.
        vm.warp(vm.getBlockTimestamp() + 86_401);

        // Spot-checks on Standard-delay roles
        _assertRoleDelay(factory, ADMIN_KERNEL_ROLE, FNDN, STANDARD_DELAY, "ADMIN_KERNEL_ROLE");
        _assertRoleDelay(factory, ADMIN_ACCOUNTANT_ROLE, FNDN, STANDARD_DELAY, "ADMIN_ACCOUNTANT_ROLE");
        _assertRoleDelay(factory, ADMIN_PROTOCOL_FEE_SETTER_ROLE, FNDN, STANDARD_DELAY, "ADMIN_PROTOCOL_FEE_SETTER_ROLE");
        _assertRoleDelay(factory, DEPLOYER_ROLE_ADMIN_ROLE, FNDN, STANDARD_DELAY, "DEPLOYER_ROLE_ADMIN_ROLE");
        _assertRoleDelay(factory, ADMIN_UNPAUSER_ROLE, FNDN, STANDARD_DELAY, "ADMIN_UNPAUSER_ROLE");
        // Critical-delay role
        _assertRoleDelay(factory, ADMIN_UPGRADER_ROLE, FNDN, CRITICAL_DELAY, "ADMIN_UPGRADER_ROLE");
        // Immediate-delay roles
        _assertRoleDelay(factory, ADMIN_PAUSER_ROLE, FNDN, IMMEDIATE_DELAY, "ADMIN_PAUSER_ROLE");
        _assertRoleDelay(factory, LP_ROLE_ADMIN_ROLE, FNDN, IMMEDIATE_DELAY, "LP_ROLE_ADMIN_ROLE");
        _assertRoleDelay(factory, SYNC_ROLE, FNDN, IMMEDIATE_DELAY, "SYNC_ROLE");
        _assertRoleDelay(factory, ADMIN_ORACLE_QUOTER_ROLE, FNDN, IMMEDIATE_DELAY, "ADMIN_ORACLE_QUOTER_ROLE");
        _assertRoleDelay(factory, DEPLOYER_ROLE, FNDN, IMMEDIATE_DELAY, "DEPLOYER_ROLE");
        _assertRoleDelay(factory, GUARDIAN_ROLE, GUARDIAN_HOLDER, IMMEDIATE_DELAY, "GUARDIAN_ROLE");

        // unpause selector on every pausable target now points at ADMIN_UNPAUSER_ROLE
        bytes4 unpauseSelector = IRoycoAuth.unpause.selector;
        for (uint256 i = 0; i < _cfg.markets.length; i++) {
            MarketAddresses memory addrs = getMarketAddresses(_cfg.markets[i]);
            require(factory.getTargetFunctionRole(addrs.kernel, unpauseSelector) == ADMIN_UNPAUSER_ROLE, "kernel unpause role mismatch");
            require(factory.getTargetFunctionRole(addrs.accountant, unpauseSelector) == ADMIN_UNPAUSER_ROLE, "accountant unpause role mismatch");
            require(factory.getTargetFunctionRole(addrs.seniorTranche, unpauseSelector) == ADMIN_UNPAUSER_ROLE, "ST unpause role mismatch");
            require(factory.getTargetFunctionRole(addrs.juniorTranche, unpauseSelector) == ADMIN_UNPAUSER_ROLE, "JT unpause role mismatch");
        }
        require(factory.getTargetFunctionRole(_cfg.syncer, unpauseSelector) == ADMIN_UNPAUSER_ROLE, "syncer unpause role mismatch");

        // ADMIN_ROLE holder now has Critical (48h) execution delay
        _assertRoleDelay(factory, _ADMIN_ROLE, FNDN, CRITICAL_DELAY, "ADMIN_ROLE");

        console2.log("  [OK] Post-state verified");

        // Negative test: a fresh role-0 call from FNDN must now require scheduling
        // (delay > 0). Direct `factory.grantRole(...)` should revert with
        // AccessManagerUnauthorizedCall because setback != 0 and no schedule exists.
        vm.prank(FNDN);
        (bool directOk,) = address(factory).call(abi.encodeCall(IAccessManager.grantRole, (ADMIN_KERNEL_ROLE, address(0xDEAD), 0)));
        require(!directOk, "Critical delay not enforced: direct role-0 call should have reverted");

        console2.log("  [OK] 48h delay enforced on subsequent role-0 calls");
    }

    function _assertRoleDelay(IAccessManager _factory, uint64 _role, address _holder, uint32 _expectedDelay, string memory _label) internal view {
        (bool isMember, uint32 delay) = _factory.hasRole(_role, _holder);
        require(isMember, string.concat(_label, ": holder is not a member"));
        require(delay == _expectedDelay, string.concat(_label, ": delay mismatch"));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _buildSetRoleGuardian(address _factory, uint64 _role, uint64 _guardianRole) internal pure returns (SafeTransaction memory) {
        return SafeTransaction({ to: _factory, value: 0, data: abi.encodeCall(IAccessManager.setRoleGuardian, (_role, _guardianRole)) });
    }

    function _getRpcUrl(uint256 _chainId) internal view returns (string memory) {
        if (_chainId == MAINNET) return vm.envString("MAINNET_RPC_URL");
        if (_chainId == AVALANCHE) return vm.envString("AVALANCHE_RPC_URL");
        if (_chainId == ARBITRUM) return vm.envString("ARBITRUM_RPC_URL");
        if (_chainId == BASE) return vm.envString("BASE_RPC_URL");
        revert("Unknown chain");
    }

    function _decodeRevert(bytes memory _ret, uint256 _i) internal pure returns (string memory) {
        if (_ret.length >= 4) {
            return string.concat("Migration tx ", vm.toString(_i), " reverted; selector=0x", _bytes4ToHex(bytes4(_ret)));
        }
        return string.concat("Migration tx ", vm.toString(_i), " reverted");
    }

    function _bytes4ToHex(bytes4 _b) internal pure returns (string memory) {
        bytes memory hexAlphabet = "0123456789abcdef";
        bytes memory out = new bytes(8);
        for (uint256 i = 0; i < 4; i++) {
            uint8 b = uint8(_b[i]);
            out[2 * i] = hexAlphabet[b >> 4];
            out[2 * i + 1] = hexAlphabet[b & 0x0f];
        }
        return string(out);
    }

    function _writeMigrationJson(SafeTransaction[] memory _transactions, string memory _outputFileName) internal {
        string[] memory txJsons = new string[](_transactions.length);
        for (uint256 i = 0; i < _transactions.length; i++) {
            string memory key = string.concat("tx", vm.toString(i));
            vm.serializeAddress(key, "to", _transactions[i].to);
            vm.serializeString(key, "value", vm.toString(_transactions[i].value));
            txJsons[i] = vm.serializeBytes(key, "data", _transactions[i].data);
        }

        string memory root = "root";
        vm.serializeString(root, "version", "1.0");
        vm.serializeString(root, "chainId", vm.toString(block.chainid));
        vm.serializeUint(root, "createdAt", block.timestamp);

        string memory meta = "meta";
        vm.serializeString(meta, "name", "Royco security migration (tranches)");
        string memory metaJson = vm.serializeString(
            meta,
            "description",
            "Set every FNDN-held role's delay explicitly; introduce ADMIN_UNPAUSER_ROLE and remap unpause; apply 48h Critical delay on ADMIN_ROLE."
        );
        vm.serializeString(root, "meta", metaJson);

        string memory finalJson = vm.serializeString(root, "transactions", txJsons);
        vm.writeJson(finalJson, string(abi.encodePacked("output/update/", _outputFileName, ".json")));
    }
}
