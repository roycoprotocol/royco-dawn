/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title IERC7575
 * @notice ERC-7575: Multi-Asset ERC-4626 Vaults
 * @dev Specification: https://eips.ethereum.org/EIPS/eip-7575
 *
 * Extends ERC-4626 to support multiple assets or entry points sharing a common
 * share token, and enables externalization of the ERC-20 share via {share}.
 *
 * Notes:
 * - All ERC-7575 Vaults MUST implement ERC-4626 excluding ERC-20 methods/events.
 * - Vaults MUST implement ERC-165 and return true for interface ID 0x2f0a18c5.
 * - The share token SHOULD implement ERC-165 and return true for 0xf815c03d.
 * - Multi-Asset Vaults SHOULD NOT make each entry point ERC-20.
 */
interface IERC7575 {
    /// @notice Address of the ERC-20 share token for this Vault.
    /// @dev MAY equal address(this). MUST NOT revert.
    /// @return shareTokenAddress ERC-20 share representation of the Vault.
    function share() external view returns (address shareTokenAddress);

    /// @notice Optional share-to-vault lookup for a given asset.
    /// @dev SHOULD be implemented by the share token to map an asset to its entry Vault.
    /// @param _asset The asset token address.
    /// @return vaultAddress The Vault address for the given asset.
    function vault(address _asset) external view returns (address vaultAddress);
}
