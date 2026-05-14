// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title ExtraRoles
 * @notice Contract containing extra roles for the Royco protocol
 */
contract ExtraRoles {
    uint64 public constant ADMIN_UNPAUSER_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_UNPAUSER_ROLE"))));
    uint64 public constant ADMIN_ENTRY_POINT_ROLE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_ENTRY_POINT_ROLE"))));
    uint64 public constant ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE = uint64(uint256(keccak256(abi.encode("ROYCO_ADMIN_ENTRY_POINT_ROLE_CLAIM_FEE"))));
}
