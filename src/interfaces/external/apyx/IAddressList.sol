// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title IAddressList
 * @notice Abridged interface for central address list management in the Apyx protocol
 * @dev Provides a single source of truth for blocked/allowed addresses across all Apyx contracts
 */
interface IAddressList {
    /**
     * @notice Checks if an address is in the list
     * @param user Address to check
     * @return True if address is in the list, false otherwise
     */
    function contains(address user) external view returns (bool);
}
