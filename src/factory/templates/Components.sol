// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// =============================================================================
// Components — canonical namespace of SSTORE2 component IDs used by Royco
// market deployment templates.
//
// Component IDs are `bytes32` hashes derived via `keccak256(bytes("ROYCO_COMPONENT_*"))`.
// Using hashes (instead of small integers) prevents accidental collisions when
// templates evolve independently and lets new templates introduce new components
// without coordinating an ID-space allocation with this file's authors.
// =============================================================================

// ─── Standardized (shared by every template) ────────────────────────────────

bytes32 constant COMPONENT_ID_SENIOR_TRANCHE_IMPL = keccak256("ROYCO_COMPONENT_SENIOR_TRANCHE_IMPL");
bytes32 constant COMPONENT_ID_JUNIOR_TRANCHE_IMPL = keccak256("ROYCO_COMPONENT_JUNIOR_TRANCHE_IMPL");
bytes32 constant COMPONENT_ID_ACCOUNTANT_IMPL = keccak256("ROYCO_COMPONENT_ACCOUNTANT_IMPL");
bytes32 constant COMPONENT_ID_YDM = keccak256("ROYCO_COMPONENT_YDM");

// ─── Dawn kernel variants ────────────────────────────────────────────────────

bytes32 constant COMPONENT_ID_KERNEL_REUSD = keccak256("ROYCO_COMPONENT_KERNEL_REUSD");
bytes32 constant COMPONENT_ID_KERNEL_IDENTICAL_ERC20_CHAINLINK = keccak256("ROYCO_COMPONENT_KERNEL_IDENTICAL_ERC20_CHAINLINK");
bytes32 constant COMPONENT_ID_KERNEL_IDENTICAL_ERC4626_ADMIN_ORACLE = keccak256("ROYCO_COMPONENT_KERNEL_IDENTICAL_ERC4626_ADMIN_ORACLE");
bytes32 constant COMPONENT_ID_KERNEL_IDENTICAL_ERC4626_CHAINLINK_ORACLE = keccak256("ROYCO_COMPONENT_KERNEL_IDENTICAL_ERC4626_CHAINLINK_ORACLE");
bytes32 constant COMPONENT_ID_KERNEL_IDLECDOAA = keccak256("ROYCO_COMPONENT_KERNEL_IDLECDOAA");
bytes32 constant COMPONENT_ID_KERNEL_IDENTICAL_ERC20_CHAINLINK_SBT = keccak256("ROYCO_COMPONENT_KERNEL_IDENTICAL_ERC20_CHAINLINK_SBT");
bytes32 constant COMPONENT_ID_KERNEL_IDENTICAL_MAKINA = keccak256("ROYCO_COMPONENT_KERNEL_IDENTICAL_MAKINA");
bytes32 constant COMPONENT_ID_KERNEL_SUSDAI = keccak256("ROYCO_COMPONENT_KERNEL_SUSDAI");
bytes32 constant COMPONENT_ID_KERNEL_MAPLE_V2 = keccak256("ROYCO_COMPONENT_KERNEL_MAPLE_V2");
bytes32 constant COMPONENT_ID_KERNEL_APYUSD = keccak256("ROYCO_COMPONENT_KERNEL_APYUSD");
bytes32 constant COMPONENT_ID_KERNEL_LOCKED_IUSD = keccak256("ROYCO_COMPONENT_KERNEL_LOCKED_IUSD");
bytes32 constant COMPONENT_ID_KERNEL_SUSDAT = keccak256("ROYCO_COMPONENT_KERNEL_SUSDAT");

// ─── Dusk-Balancer ───────────────────────────────────────────────────────────

bytes32 constant COMPONENT_ID_DUSK_BALANCER_HOOKS = keccak256("ROYCO_COMPONENT_DUSK_BALANCER_HOOKS");
bytes32 constant COMPONENT_ID_DUSK_BALANCER_KERNEL = keccak256("ROYCO_COMPONENT_DUSK_BALANCER_KERNEL");
