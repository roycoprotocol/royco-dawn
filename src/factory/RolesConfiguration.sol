// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title RolesConfiguration
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Abstract contract containing role configuration for the Royco protocol access control system
 * @dev This contract defines the role hierarchy, admin roles, guardian roles, and execution delays
 *      for each role in the system.
 */
abstract contract RolesConfiguration {
    /// ================================
    /// ROLE CONSTANTS
    /// ================================
    /// @notice Default admin role (OpenZeppelin AccessManager uses 0 for admin)
    /// @dev Named differently to avoid conflict with AccessManager.ADMIN_ROLE when inherited together
    uint64 internal constant _ADMIN_ROLE = 0;

    /// Common roles
    uint64 public constant ADMIN_PAUSER_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_PAUSER_ROLE"))));
    uint64 public constant ADMIN_UPGRADER_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_UPGRADER_ROLE"))));

    /// Tranche roles
    uint64 public constant ST_LP_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ST_LP_ROLE"))));
    uint64 public constant JT_LP_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_JT_LP_ROLE"))));
    uint64 public constant BURNER_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_BURNER_ROLE"))));

    /// Kernel roles
    uint64 public constant SYNC_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_SYNC_ROLE"))));
    uint64 public constant ADMIN_KERNEL_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_KERNEL_ROLE"))));
    uint64 public constant TRANSFER_AGENT_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_TRANSFER_AGENT_ROLE"))));

    /// Accountant roles
    uint64 public constant ADMIN_ACCOUNTANT_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_ACCOUNTANT_ROLE"))));
    uint64 public constant ADMIN_PROTOCOL_FEE_SETTER_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_PROTOCOL_FEE_SETTER_ROLE"))));

    /// Quoter roles
    uint64 public constant ADMIN_ORACLE_QUOTER_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_ORACLE_QUOTER_ROLE"))));

    /// Deployer role - can deploy new markets
    uint64 public constant DEPLOYER_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_DEPLOYER_ROLE"))));

    /// Meta Roles
    uint64 public constant LP_ROLE_ADMIN_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_LP_ROLE_ADMIN_ROLE"))));
    uint64 public constant DEPLOYER_ROLE_ADMIN_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_DEPLOYER_ROLE_ADMIN_ROLE"))));

    /// Guardian role - can cancel delayed operations for all roles
    uint64 public constant GUARDIAN_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_GUARDIAN_ROLE"))));

    /// @notice Configuration for a single role
    struct RoleConfig {
        uint64 adminRole; // The role that can grant/revoke this role (0 for ADMIN_ROLE)
        uint64 guardianRole; // The role that can cancel operations for this role
        uint32 executionDelay; // Delay in seconds before role operations take effect
    }

    /// @notice Error when an unknown role is requested
    error UNKNOWN_ROLE(uint64 role);

    /**
     * @notice Returns the configuration for a given role
     * @param role The role to get configuration for
     * @return config The role configuration
     */
    function getRoleConfig(uint64 role) public pure returns (RoleConfig memory config) {
        if (role == ADMIN_PAUSER_ROLE) {
            return RoleConfig({
                adminRole: _ADMIN_ROLE,
                guardianRole: GUARDIAN_ROLE,
                executionDelay: 0 // Pausing should be immediate
            });
        } else if (role == ADMIN_UPGRADER_ROLE) {
            return RoleConfig({ adminRole: _ADMIN_ROLE, guardianRole: GUARDIAN_ROLE, executionDelay: 2 days });
        } else if (role == ST_LP_ROLE || role == JT_LP_ROLE) {
            return RoleConfig({
                adminRole: LP_ROLE_ADMIN_ROLE, // LP admin can manage LP roles
                guardianRole: GUARDIAN_ROLE,
                executionDelay: 0 // LP operations should be immediate
            });
        } else if (role == LP_ROLE_ADMIN_ROLE) {
            return RoleConfig({
                adminRole: _ADMIN_ROLE,
                guardianRole: GUARDIAN_ROLE,
                executionDelay: 0 // LP admin operations should be immediate
            });
        } else if (role == SYNC_ROLE) {
            return RoleConfig({
                adminRole: _ADMIN_ROLE,
                guardianRole: GUARDIAN_ROLE,
                executionDelay: 0 // Sync operations should be immediate
            });
        } else if (role == ADMIN_KERNEL_ROLE) {
            return RoleConfig({
                adminRole: _ADMIN_ROLE,
                guardianRole: GUARDIAN_ROLE,
                executionDelay: 2 days // Kernel admin operations require delay
            });
        } else if (role == ADMIN_ACCOUNTANT_ROLE) {
            return RoleConfig({
                adminRole: _ADMIN_ROLE,
                guardianRole: GUARDIAN_ROLE,
                executionDelay: 2 days // Accountant admin operations require delay
            });
        } else if (role == ADMIN_PROTOCOL_FEE_SETTER_ROLE) {
            return RoleConfig({
                adminRole: _ADMIN_ROLE,
                guardianRole: GUARDIAN_ROLE,
                executionDelay: 2 days // Fee changes require delay
            });
        } else if (role == ADMIN_ORACLE_QUOTER_ROLE) {
            return RoleConfig({
                adminRole: _ADMIN_ROLE,
                guardianRole: GUARDIAN_ROLE,
                executionDelay: 0 // Oracle updates should be immediate
            });
        } else if (role == GUARDIAN_ROLE) {
            return RoleConfig({
                adminRole: _ADMIN_ROLE,
                guardianRole: _ADMIN_ROLE, // Only admin can cancel guardian operations
                executionDelay: 0 // Guardian operations should be immediate
            });
        } else if (role == DEPLOYER_ROLE) {
            return
                RoleConfig({
                    adminRole: DEPLOYER_ROLE_ADMIN_ROLE,
                    guardianRole: GUARDIAN_ROLE,
                    executionDelay: 0 // Deployer operations should be immediate
                });
        } else if (role == DEPLOYER_ROLE_ADMIN_ROLE) {
            return RoleConfig({
                adminRole: _ADMIN_ROLE,
                guardianRole: GUARDIAN_ROLE,
                executionDelay: 0 // Deployer admin operations should be immediate
            });
        } else if (role == TRANSFER_AGENT_ROLE) {
            return RoleConfig({
                adminRole: _ADMIN_ROLE,
                guardianRole: _ADMIN_ROLE, // Only admin can cancel transfer agent operations
                executionDelay: 0 // Seizures and freezes must be immediate
            });
        } else if (role == BURNER_ROLE) {
            return RoleConfig({
                adminRole: _ADMIN_ROLE,
                guardianRole: _ADMIN_ROLE, // Only admin can cancel burner operations
                executionDelay: 0 // Burner operations should be immediate
            });
        } else {
            revert UNKNOWN_ROLE(role);
        }
    }
}
