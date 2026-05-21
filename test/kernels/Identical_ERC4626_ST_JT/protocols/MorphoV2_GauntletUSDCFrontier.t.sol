// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../../../src/libraries/Units.sol";
import { DisabledChainlinkOracle_ERC4626_TestBase } from "../base/DisabledChainlinkOracle_ERC4626_TestBase.t.sol";

/// @title Morpho_GauntletUSDCFrontier_Test
/// @notice Tests Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel with Morpho's GauntletUSDCFrontier (disabled oracle)
/// @dev Both ST and JT use GauntletUSDCFrontier vault shares as the tranche asset
///
/// GauntletUSDCFrontier is an ERC4626 vault where:
///   - Tranche Unit: GauntletUSDCFrontier shares
///   - Vault Asset: USDC (the underlying)
///   - NAV Unit: USD
/// The stored conversion rate is 1:1 (WAD), with the Chainlink oracle disabled (address(1)).
contract MorphoV2_GauntletUSDCFrontier is DisabledChainlinkOracle_ERC4626_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice GauntletUSDCFrontier on Ethereum mainnet
    address internal constant GAUNTLET_USDC_FRONTIER_ADDRESS = 0x9a1D6bd5b8642C41F25e0958129B85f8E1176F3e;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for GauntletUSDCFrontier
    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({
            forkBlock: 24_532_268,
            forkRpcUrlEnvVar: "MAINNET_RPC_URL",
            stAsset: GAUNTLET_USDC_FRONTIER_ADDRESS,
            jtAsset: GAUNTLET_USDC_FRONTIER_ADDRESS,
            initialFunding: 10_000_000e18 // 10m GauntletUSDCFrontier
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses MarketDeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the GauntletUSDCFrontier kernel and market using parameters from MarketDeploymentConfig
    function _deployKernelAndMarket() internal override returns (MarketDeployment memory) {
        return _deployMarketFromConfig(DEPLOY_SCRIPT.GAUNTLET_USDC_FRONTIER());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for GauntletUSDCFrontier (18 decimals)
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(3e12)); // 0.000003 GauntletUSDCFrontier tolerance
    }

    /// @notice Returns max NAV delta for GauntletUSDCFrontier
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }
}
