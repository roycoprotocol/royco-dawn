// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title FundamentalStablecoinChainlinkOracleDeploymentConfig
 * @notice Single configuration contract for all FundamentalStablecoinChainlinkOracle deployment parameters
 * @dev Each named config specifies the underlying Chainlink (compatible) stablecoin oracle to wrap and
 *      the minimum peg price at or above which the wrapper anchors to 1 quote asset
 */
abstract contract FundamentalStablecoinChainlinkOracleDeploymentConfig {
    // ═══════════════════════════════════════════════════════════════════════════
    // CHAIN IDs
    // ═══════════════════════════════════════════════════════════════════════════

    uint256 internal constant MAINNET = 1;
    uint256 internal constant AVALANCHE = 43_114;

    // ═══════════════════════════════════════════════════════════════════════════
    // ORACLE CONFIG NAMES
    // ═══════════════════════════════════════════════════════════════════════════

    string public constant MAINNET_USDC_USD = "MAINNET_USDC_USD";
    string public constant MAINNET_CUSD_USD = "MAINNET_CUSD_USD";

    // ═══════════════════════════════════════════════════════════════════════════
    // ORACLE CONFIG STRUCT
    // ═══════════════════════════════════════════════════════════════════════════

    struct OracleConfig {
        uint256 chainId;
        /// @dev The underlying stablecoin Chainlink (compatible) oracle to wrap
        address underlyingOracle;
        /// @dev The minimum price at which the underlying stablecoin is considered pegged to 1 quote asset, denominated in the underlying oracle's precision
        int256 minPegPrice;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ORACLE CONFIG MAPPING
    // ═══════════════════════════════════════════════════════════════════════════

    mapping(string oracleName => OracleConfig) internal _oracleConfigs;

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error OracleConfigNotFound(string oracleName);
    error OracleChainIdMismatch(string oracleName, uint256 expectedChainId, uint256 actualChainId);

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor() {
        _initializeOracleConfigs();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ORACLE CONFIG GETTER
    // ═══════════════════════════════════════════════════════════════════════════

    function getOracleConfig(string memory oracleName) public view returns (OracleConfig memory config) {
        config = _oracleConfigs[oracleName];
        require(config.underlyingOracle != address(0), OracleConfigNotFound(oracleName));
        require(config.chainId == block.chainid, OracleChainIdMismatch(oracleName, config.chainId, block.chainid));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ORACLE CONFIG INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _initializeOracleConfigs() internal virtual {
        // ═══════════════════════════════════════════════════════════════════════════
        // MAINNET ORACLE CONFIGS
        // ═══════════════════════════════════════════════════════════════════════════

        // USDC / USD on Ethereum mainnet
        _oracleConfigs[MAINNET_USDC_USD] =
            OracleConfig({ chainId: MAINNET, underlyingOracle: 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6, minPegPrice: 0.999e8 });

        // CUSD / USD on Ethereum mainnet
        _oracleConfigs[MAINNET_CUSD_USD] =
            OracleConfig({ chainId: MAINNET, underlyingOracle: 0x9A5a3c3Ed0361505cC1D4e824B3854De5724434A, minPegPrice: 0.999e8 });
    }
}
