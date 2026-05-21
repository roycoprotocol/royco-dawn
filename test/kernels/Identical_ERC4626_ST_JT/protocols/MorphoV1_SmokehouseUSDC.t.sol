// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../../../src/libraries/Units.sol";
import { DisabledChainlinkOracle_ERC4626_TestBase } from "../base/DisabledChainlinkOracle_ERC4626_TestBase.t.sol";

/// @title Morpho_SmokehouseUSDC_Test
/// @notice Tests Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel with Morpho's SmokehouseUSDC (disabled oracle)
/// @dev Both ST and JT use SmokehouseUSDC vault shares as the tranche asset
///
/// SmokehouseUSDC is an ERC4626 vault where:
///   - Tranche Unit: SmokehouseUSDC shares
///   - Vault Asset: USDC (the underlying)
///   - NAV Unit: USD
/// The stored conversion rate is 1:1 (WAD), with the Chainlink oracle disabled (address(1)).
contract MorphoV1_SmokehouseUSDC is DisabledChainlinkOracle_ERC4626_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice SmokehouseUSDC on Ethereum mainnet
    address internal constant SMOKEHOUSE_USDC_ADDRESS = 0xBEeFFF209270748ddd194831b3fa287a5386f5bC;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for SmokehouseUSDC
    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({
            forkBlock: 24_532_268,
            forkRpcUrlEnvVar: "MAINNET_RPC_URL",
            stAsset: SMOKEHOUSE_USDC_ADDRESS,
            jtAsset: SMOKEHOUSE_USDC_ADDRESS,
            initialFunding: 1_000_000_000e18 // 1B SmokehouseUSDC
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses MarketDeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the SmokehouseUSDC kernel and market using parameters from MarketDeploymentConfig
    function _deployKernelAndMarket() internal override returns (MarketDeployment memory) {
        return _deployMarketFromConfig(DEPLOY_SCRIPT.SMOKEHOUSE_USDC());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for SmokehouseUSDC (18 decimals)
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(3e12)); // 0.000003 SmokehouseUSDC tolerance
    }

    /// @notice Returns max NAV delta for SmokehouseUSDC
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }
}
