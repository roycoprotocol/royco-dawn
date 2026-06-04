// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoEntryPoint } from "../../src/interfaces/IRoycoEntryPoint.sol";

/**
 * @title EntryPointDeploymentConfig
 * @notice Multi-chain configuration for RoycoEntryPoint deployments
 * @dev Configures every deployment by populating `_entryPointConfigs[chainId]` in
 *      `_initializeEntryPointConfigs()`. At runtime, `getEntryPointConfig()` resolves the
 *      config for the current `block.chainid`, so the same script works on any chain.
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
    address internal constant WCE_MULTISIG = 0x84d37A25e46029CE161111420E07cEb78880119e;

    // ═══════════════════════════════════════════════════════════════════════════
    // DEFAULT DELAYS
    // ═══════════════════════════════════════════════════════════════════════════

    uint24 internal constant DEFAULT_DEPOSIT_DELAY = 5 minutes;
    uint24 internal constant DEFAULT_REDEMPTION_DELAY = 5 minutes;

    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice A single tranche + its entry point configuration
    struct TrancheInitConfig {
        address tranche;
        IRoycoEntryPoint.TrancheConfig config;
    }

    /// @notice Full deployment configuration for an entry point on a single chain
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

    /// @dev Per-chain deployment configs (populated in constructor)
    mapping(uint256 chainId => EntryPointConfig) internal _entryPointConfigs;

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error EntryPointConfigNotFound(uint256 chainId);

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor() {
        _initializeEntryPointConfigs();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GETTER
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the entry point config for the current chain
    function getEntryPointConfig() public view returns (EntryPointConfig memory) {
        return _getEntryPointConfig(block.chainid);
    }

    /// @notice Returns the entry point config for the specified chain
    function _getEntryPointConfig(uint256 _chainId) internal view returns (EntryPointConfig memory cfg) {
        EntryPointConfig storage stored = _entryPointConfigs[_chainId];
        require(stored.roycoFactory != address(0), EntryPointConfigNotFound(_chainId));
        cfg.chainId = stored.chainId;
        cfg.roycoFactory = stored.roycoFactory;
        cfg.tranches = new TrancheInitConfig[](stored.tranches.length);
        for (uint256 i = 0; i < stored.tranches.length; i++) {
            cfg.tranches[i] = stored.tranches[i];
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Populate `_entryPointConfigs[chainId]` for every chain you intend to deploy on.
     * @dev Use `_addTrancheWithDefaultDelays` to push (ST, JT) entries with the standard
     *      `5 minutes` deposit/redemption delays. Override this in deploy scripts.
     */
    function _initializeEntryPointConfigs() internal virtual;

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Pushes a tranche with the default 5-minute deposit/redemption delays and
    ///      `REMAINING_LPS` as the yield recipient.
    function _addTrancheWithDefaultDelays(EntryPointConfig storage _cfg, address _tranche) internal {
        _cfg.tranches
            .push(
                TrancheInitConfig({
                    tranche: _tranche,
                    config: IRoycoEntryPoint.TrancheConfig({
                        enabled: true,
                        yieldRecipient: IRoycoEntryPoint.AccruedYieldRecipient.PROTOCOL,
                        depositDelaySeconds: DEFAULT_DEPOSIT_DELAY,
                        redemptionDelaySeconds: DEFAULT_REDEMPTION_DELAY
                    })
                })
            );
    }
}
