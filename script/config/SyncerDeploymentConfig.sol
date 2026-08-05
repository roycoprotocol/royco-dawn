// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title SyncerDeploymentConfig
 * @notice Single configuration contract for all syncer deployment parameters
 */
abstract contract SyncerDeploymentConfig {
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

    /// @dev Deployed using CREATE2 on each chain
    address internal constant ROYCO_FACTORY = 0x7cC6fB28eC7b5e7afC3cB3986141797ffc27253C;
    address internal constant ROYCO_FACTORY_BASE = 0x568c9709DaA2f7B7cc66AbC3E41DA0f0A339551A;

    // ═══════════════════════════════════════════════════════════════════════════
    // SYNCER NAMES
    // ═══════════════════════════════════════════════════════════════════════════

    string public constant MAINNET_SYNCER = "MAINNET_SYNCER";
    string public constant AVALANCHE_SYNCER = "AVALANCHE_SYNCER";
    string public constant ARBITRUM_SYNCER = "ARBITRUM_SYNCER";
    string public constant BASE_SYNCER = "BASE_SYNCER";

    // ═══════════════════════════════════════════════════════════════════════════
    // SYNCER CONFIG STRUCT
    // ═══════════════════════════════════════════════════════════════════════════

    struct SyncerConfig {
        uint256 chainId;
        address roycoFactory;
        address[] marketKernels;
        address[] configSpecificSyncOperators;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SYNCER CONFIG MAPPING
    // ═══════════════════════════════════════════════════════════════════════════

    mapping(string syncerName => SyncerConfig) internal _syncerConfigs;

    // ═══════════════════════════════════════════════════════════════════════════
    // BASE SYNC OPERATORS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Base sync operators that are granted SYNC_ROLE for all syncers
    /// @dev First address is the Royco backend keeper
    address[] internal _baseSyncOperators = [0x806836249FEbbF6ca3008BFF6C3257110f435480];

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error SyncerConfigNotFound(string syncerName);
    error SyncerChainIdMismatch(string syncerName, uint256 expectedChainId, uint256 actualChainId);

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor() {
        _initializeSyncerConfigs();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SYNCER CONFIG GETTER
    // ═══════════════════════════════════════════════════════════════════════════

    function getSyncerConfig(string memory syncerName) public view returns (SyncerConfig memory) {
        SyncerConfig storage storedConfig = _syncerConfigs[syncerName];
        if (storedConfig.roycoFactory == address(0)) {
            revert SyncerConfigNotFound(syncerName);
        }
        if (storedConfig.chainId != block.chainid) {
            revert SyncerChainIdMismatch(syncerName, storedConfig.chainId, block.chainid);
        }

        // Build config with combined sync operators (base + config-specific)
        SyncerConfig memory config;
        config.chainId = storedConfig.chainId;
        config.roycoFactory = storedConfig.roycoFactory;
        config.marketKernels = storedConfig.marketKernels;
        config.configSpecificSyncOperators = _combineArrays(_baseSyncOperators, storedConfig.configSpecificSyncOperators);

        return config;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SYNCER CONFIG INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _initializeSyncerConfigs() internal {
        // ═══════════════════════════════════════════════════════════════════════════
        // MAINNET SYNCER CONFIG
        // ═══════════════════════════════════════════════════════════════════════════

        SyncerConfig storage config = _syncerConfigs[MAINNET_SYNCER];
        config.chainId = MAINNET;
        config.roycoFactory = ROYCO_FACTORY;

        // Market kernels to add to the syncer:
        // - Neutrl sNUSD
        config.marketKernels.push(0x0aE0978B868804929fd4C06B3B22D9197B8cd3c6);
        // - Tokemak autoUSD
        config.marketKernels.push(0x8748D1c21CC550B435487F473d9Aaf6C84dA46A6);
        // - Smokehouse USDC Morpho
        config.marketKernels.push(0x6dBdf6EBdF02F50ec6a7d6F782850996928176F9);
        // - Maple syrupUSDC
        config.marketKernels.push(0xde1Ce2cF64808e50d000F93058784270E412B3A4);
        // - Tenbin stMXN
        config.marketKernels.push(0x90F114A99a439b1C2808A17198E3B764eaF63d1B);
        // - Tenbin stBRL
        config.marketKernels.push(0xB9BD7b477872D428E3C38EE71ed8F739E8AEc0dB);
        // - Tori strUSD
        config.marketKernels.push(0x3c40CB4354582005e55370B7e3a1b190DEe8eB0b);
        // - Morini StockMarketTRBasisTrade
        config.marketKernels.push(0x48fE2F6A0168C49F5a7aF6E2e6884F6b2531D634);

        // ═══════════════════════════════════════════════════════════════════════════
        // AVALANCHE SYNCER CONFIG
        // ═══════════════════════════════════════════════════════════════════════════

        config = _syncerConfigs[AVALANCHE_SYNCER];
        config.chainId = AVALANCHE;
        config.roycoFactory = ROYCO_FACTORY;

        // Market kernels to add to the syncer:
        // - Avant savUSD
        config.marketKernels.push(0x7240FF91b471217FF93349184ABE9f102Ca1955C);

        // ═══════════════════════════════════════════════════════════════════════════
        // ARBITRUM SYNCER CONFIG
        // ═══════════════════════════════════════════════════════════════════════════

        config = _syncerConfigs[ARBITRUM_SYNCER];
        config.chainId = ARBITRUM;
        config.roycoFactory = ROYCO_FACTORY;

        // Market kernels to add to the syncer:
        // - Metastreet sUSDai
        config.marketKernels.push(0xFdb17E53eA5d342124b8473188BCB9F05F1949CA);

        // ═══════════════════════════════════════════════════════════════════════════
        // BASE SYNCER CONFIG
        // ═══════════════════════════════════════════════════════════════════════════

        config = _syncerConfigs[BASE_SYNCER];
        config.chainId = BASE;
        config.roycoFactory = ROYCO_FACTORY_BASE;

        // Market kernels to add to the syncer:
        // - Noon sUSN
        config.marketKernels.push(0x3FBC599C113923439Ca6878B7A9b5433Cc3F4116); // sUSN
    }

    /// @notice Combines two address arrays into one
    function _combineArrays(address[] storage _base, address[] storage _additional) internal view returns (address[] memory combined) {
        combined = new address[](_base.length + _additional.length);
        for (uint256 i = 0; i < _base.length; i++) {
            combined[i] = _base[i];
        }
        for (uint256 i = 0; i < _additional.length; i++) {
            combined[_base.length + i] = _additional[i];
        }
    }
}
