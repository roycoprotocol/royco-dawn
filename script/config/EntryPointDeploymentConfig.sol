// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoEntryPoint } from "../../src/interfaces/IRoycoEntryPoint.sol";

/**
 * @title EntryPointDeploymentConfig
 * @notice Configuration for RoycoEntryPoint deployments
 * @dev Configure each deployment by adding entries in `_initializeEntryPointConfigs()`.
 *      Each config specifies the initial tranches and their parameters.
 */
abstract contract EntryPointDeploymentConfig {
    // ═══════════════════════════════════════════════════════════════════════════
    // CHAIN IDs
    // ═══════════════════════════════════════════════════════════════════════════

    uint256 internal constant MAINNET = 1;
    uint256 internal constant AVALANCHE = 43_114;
    uint256 internal constant ARBITRUM = 42_161;
    uint256 internal constant BASE = 8453;

    // ═══════════════════════════════════════════════════════════════════════════
    // FACTORY ADDRESS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Deployed using CREATE2 - same address on every chain
    address internal constant ROYCO_FACTORY = 0x7cC6fB28eC7b5e7afC3cB3986141797ffc27253C;

    // ═══════════════════════════════════════════════════════════════════════════
    // MULTISIG ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    address internal constant ROOT_MULTISIG = 0x7c405bbD131e42af506d14e752f2e59B19D49997;

    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice A single tranche + its entry point configuration
    struct TrancheInitConfig {
        address tranche;
        IRoycoEntryPoint.TrancheConfig config;
    }

    /// @notice Full deployment configuration for an entry point
    struct EntryPointConfig {
        uint256 chainId;
        /// @dev The Royco factory to use as the access manager
        address roycoFactory;
        /// @dev Initial tranches and their configurations
        TrancheInitConfig[] tranches;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Stores the active deployment config (populated in constructor)
    EntryPointConfig internal _entryPointConfig;

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error EntryPointConfigNotFound();
    error EntryPointChainIdMismatch(uint256 expectedChainId, uint256 actualChainId);

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor() {
        _initializeEntryPointConfig();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GETTER
    // ═══════════════════════════════════════════════════════════════════════════

    function getEntryPointConfig() public view returns (EntryPointConfig memory) {
        require(_entryPointConfig.roycoFactory != address(0), EntryPointConfigNotFound());
        require(_entryPointConfig.chainId == block.chainid, EntryPointChainIdMismatch(_entryPointConfig.chainId, block.chainid));
        return _entryPointConfig;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Configure the entry point deployment here
     * @dev Set `_entryPointConfig` with the target chain, factory, and tranche configs.
     *
     * Example:
     *   _entryPointConfig.chainId = MAINNET;
     *   _entryPointConfig.roycoFactory = ROYCO_FACTORY;
     *   _entryPointConfig.tranches.push(TrancheInitConfig({
     *       tranche: 0x...,
     *       config: IRoycoEntryPoint.TrancheConfig({
     *           enabled: true,
     *           yieldRecipient: IRoycoEntryPoint.AccruedYieldRecipient.REMAINING_LPS,
     *           depositDelaySeconds: 1 days,
     *           redemptionDelaySeconds: 1 days
     *       })
     *   }));
     */
    function _initializeEntryPointConfig() internal virtual;
}
