// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title RoycoRoles
/// @notice Library containing role constants for the Royco protocol access control system
abstract contract RoycoRoles {
    /// Common roles
    uint64 public constant PAUSER_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_PAUSER_ROLE"))));
    uint64 public constant UPGRADER_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_UPGRADER_ROLE"))));
    uint64 public constant SCHEDULER_MANAGER_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_SCHEDULER_MANAGER_ROLE"))));

    /// Tranche roles
    uint64 public constant DEPOSIT_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_DEPOSIT_ROLE"))));
    uint64 public constant REDEEM_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_REDEEM_ROLE"))));
    uint64 public constant CANCEL_DEPOSIT_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_CANCEL_DEPOSIT_ROLE"))));
    uint64 public constant CANCEL_REDEEM_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_CANCEL_REDEEM_ROLE"))));

    /// Kernel roles
    uint64 public constant SYNC_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_SYNC_ROLE"))));
    uint64 public constant KERNEL_ADMIN_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_KERNEL_ADMIN_ROLE"))));
}
