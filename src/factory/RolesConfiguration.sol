// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// =============================================================================
// RolesConfiguration — canonical registry of Royco protocol role IDs.
// =============================================================================

// ═══════════════════════════════════════════════════════════════════════════════
// COMMON ROLES
// ═══════════════════════════════════════════════════════════════════════════════

uint64 constant ADMIN_ROLE = type(uint64).min; // From AccessManager.sol
uint64 constant PUBLIC_ROLE = type(uint64).max; // From AccessManager.sol
uint64 constant ADMIN_PAUSER_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_PAUSER_ROLE"))));
uint64 constant ADMIN_UNPAUSER_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_UNPAUSER_ROLE"))));
uint64 constant ADMIN_UPGRADER_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_UPGRADER_ROLE"))));

// ═══════════════════════════════════════════════════════════════════════════════
// TRANCHE ROLES
// ═══════════════════════════════════════════════════════════════════════════════

uint64 constant ST_LP_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ST_LP_ROLE"))));
uint64 constant JT_LP_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_JT_LP_ROLE"))));
uint64 constant BURNER_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_BURNER_ROLE"))));
uint64 constant TRANSFER_AGENT_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_TRANSFER_AGENT_ROLE"))));

// ═══════════════════════════════════════════════════════════════════════════════
// KERNEL ROLES
// ═══════════════════════════════════════════════════════════════════════════════

uint64 constant SYNC_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_SYNC_ROLE"))));
uint64 constant ADMIN_KERNEL_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_KERNEL_ROLE"))));

// ═══════════════════════════════════════════════════════════════════════════════
// ACCOUNTANT ROLES
// ═══════════════════════════════════════════════════════════════════════════════

uint64 constant ADMIN_ACCOUNTANT_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_ACCOUNTANT_ROLE"))));
uint64 constant ADMIN_PROTOCOL_FEE_SETTER_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_PROTOCOL_FEE_SETTER_ROLE"))));

// ═══════════════════════════════════════════════════════════════════════════════
// QUOTER ROLES
// ═══════════════════════════════════════════════════════════════════════════════

uint64 constant ADMIN_ORACLE_QUOTER_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_ORACLE_QUOTER_ROLE"))));

// ═══════════════════════════════════════════════════════════════════════════════
// ENTRY POINT ROLES
// ═══════════════════════════════════════════════════════════════════════════════

uint64 constant ADMIN_ENTRY_POINT_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_ENTRY_POINT_ROLE"))));
uint64 constant ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE"))));

// ═══════════════════════════════════════════════════════════════════════════════
// BALANCER V3 POOL MANAGER ROLE
// Gates the non-pauser surface of Balancer V3 PoolRoleAccounts: static-swap-fee + pool-creator
// fee settings + pool-creator fee withdrawals. Pause / unpause stay on the standard
// pauser/unpauser roles.
// ═══════════════════════════════════════════════════════════════════════════════

uint64 constant ADMIN_BALANCER_POOL_MANAGER_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_BALANCER_POOL_MANAGER_ROLE"))));

// ═══════════════════════════════════════════════════════════════════════════════
// FACTORY ROLES
// ═══════════════════════════════════════════════════════════════════════════════

uint64 constant ADMIN_FACTORY_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_FACTORY_ROLE"))));
uint64 constant DEPLOYER_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_DEPLOYER_ROLE"))));

// ═══════════════════════════════════════════════════════════════════════════════
// META ROLES
// ═══════════════════════════════════════════════════════════════════════════════

uint64 constant LP_ROLE_ADMIN_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_LP_ROLE_ADMIN_ROLE"))));

// ═══════════════════════════════════════════════════════════════════════════════
// GUARDIAN ROLE
// ═══════════════════════════════════════════════════════════════════════════════

uint64 constant GUARDIAN_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_GUARDIAN_ROLE"))));
