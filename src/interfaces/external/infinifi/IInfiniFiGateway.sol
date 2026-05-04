// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IInfiniFiGateway
/// @notice Abridged interface for the InfiniFi Gateway contract
interface IInfiniFiGateway {
    /// @notice Returns the address registered under a given name
    /// @param _name The string key for the address lookup
    /// @return The registered address, or address(0) if not set
    function getAddress(string memory _name) external view returns (address);
}
