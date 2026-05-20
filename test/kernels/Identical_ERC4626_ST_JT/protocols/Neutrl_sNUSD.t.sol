// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import {
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel
} from "../../../../src/kernels/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../../../src/libraries/Units.sol";

import { YieldBearingERC4626_ChainlinkOracle_TestBase } from "../base/YieldBearingERC4626_ChainlinkOracle_TestBase.t.sol";

import { COMPONENT_ID_KERNEL_IDENTICAL_ERC4626_CHAINLINK_ORACLE } from "../../../../src/factory/templates/Components.sol";
import {
    IdenticalERC4626ChainlinkOracleDeploymentTemplate
} from "../../../../src/factory/templates/dawn/IdenticalERC4626ChainlinkOracleDeploymentTemplate.sol";
import {
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel
} from "../../../../src/kernels/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";

/// @title sNUSD_sNUSD_Test
/// @notice Tests Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel with sNUSD
/// @dev Both ST and JT use sNUSD as the tranche asset on Ethereum mainnet
///
/// sNUSD is an ERC4626 vault where:
///   - Tranche Unit: sNUSD shares
///   - Vault Asset: NUSD (the underlying)
///   - NAV Unit: USD
/// The deployment uses initialConversionRateWAD: 0 (sentinel mode — live Chainlink oracle for NUSD->USD).
contract sNUSD_sNUSD_Test is YieldBearingERC4626_ChainlinkOracle_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice sNUSD on Ethereum mainnet
    address internal constant SNUSD = 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for sNUSD
    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({
            forkBlock: 24_623_821,
            forkRpcUrlEnvVar: "MAINNET_RPC_URL",
            stAsset: SNUSD,
            jtAsset: SNUSD,
            initialFunding: 1_000_000_000e18 // 1B sNUSD
        });
    }

    /// @notice Returns the Chainlink oracle address from the deployed kernel configuration
    function _getChainlinkOracle() internal view override returns (address) {
        return Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel(address(KERNEL)).getChainlinkOracleConfiguration().oracle;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses MarketDeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the sNUSD kernel and market using parameters from MarketDeploymentConfig
    /// @dev Uses the Chainlink oracle from the deployment config for NUSD->USD pricing
    function _deployKernelAndMarket() internal override returns (MarketDeployment memory) {
        IdenticalERC4626ChainlinkOracleDeploymentTemplate template = new IdenticalERC4626ChainlinkOracleDeploymentTemplate(FACTORY);
        DawnDeploymentParams memory p;
        p.marketId = keccak256("SNUSD_TEST");
        p.template = address(template);
        p.kernelComponentId = COMPONENT_ID_KERNEL_IDENTICAL_ERC4626_CHAINLINK_ORACLE;
        p.kernelCreationCode = type(Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel).creationCode;
        p.stAsset = config.stAsset;
        p.jtAsset = config.jtAsset;
        p.kernelSpecificParams = abi.encode(
            IdenticalERC4626ChainlinkOracleDeploymentTemplate.KernelParams({
                initialConversionRateWAD: 0, baseAssetToNavAssetOracle: 0x5e7281f74e74D76347f0b8f4a36Fd3cb29c19d95, stalenessThresholdSeconds: 48 hours
            })
        );
        p.stProtocolFeeWAD = ST_PROTOCOL_FEE_WAD;
        p.jtProtocolFeeWAD = JT_PROTOCOL_FEE_WAD;
        p.yieldShareProtocolFeeWAD = 0;
        p.coverageWAD = COVERAGE_WAD;
        p.betaWAD = BETA_WAD;
        p.liquidationUtilizationWAD = LIQUIDATION_UTILIZATION_WAD;
        p.fixedTermDurationSeconds = FIXED_TERM_DURATION_SECONDS;
        p.stNAVDustTolerance = DUST_TOLERANCE;
        p.jtNAVDustTolerance = DUST_TOLERANCE;
        p.enforceVaultSharesTransferWhitelist = false;
        p.stSelfLiquidationBonusWAD = 0;
        return _deployDawnMarket(p);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for sNUSD (18 decimals)
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e12)); // 0.000001 sNUSD tolerance
    }

    /// @notice Returns max NAV delta for sNUSD
    /// @dev Converts the tranche unit tolerance to NAV using the kernel's conversion
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // sNUSD-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies that the sNUSD vault is correctly configured
    function test_sNUSD_vaultConfiguration() external view {
        // Verify decimals
        uint8 decimals = IERC4626(SNUSD).decimals();
        assertEq(decimals, 18, "sNUSD should have 18 decimals");

        // Verify the vault has a valid share price
        uint256 sharePrice = IERC4626(SNUSD).convertToAssets(1e18);
        assertGe(sharePrice, 1e18, "sNUSD share price should be >= 1:1");
    }

    /// @notice Verifies initial conversion rate is sentinel (0) for live oracle mode
    function test_sNUSD_initialConversionRate() external view {
        uint256 storedRate = _getStoredConversionRate();

        // The stored rate should be 0 (sentinel) — the live Chainlink oracle provides the NUSD->USD rate
        assertEq(storedRate, 0, "Stored rate should be 0 (sentinel mode for live Chainlink oracle)");

        // The effective conversion rate should be positive (from the Chainlink oracle)
        uint256 effectiveRate = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
        assertGt(effectiveRate, 0, "Effective conversion rate should be positive from Chainlink oracle");
    }

    /// @notice Test that simulated yield works correctly for sNUSD
    function testFuzz_sNUSD_simulatedYield_increasesNAV(uint256 _amount, uint256 _yieldBps) external {
        _amount = bound(_amount, 1e18, 100_000e18); // 1 to 100k sNUSD
        _yieldBps = bound(_yieldBps, 10, 1000); // 0.1% to 10% yield

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        // Simulate yield (randomly picks Leg 1 or Leg 2)
        uint256 yieldWAD = _yieldBps * 1e14;
        simulateJTYield(yieldWAD);

        uint256 rateAfter = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
        assertGt(rateAfter, rateBefore, "Effective rate should increase after yield");

        // Sync accounting
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after yield");
    }

    /// @notice Test loss simulation for sNUSD
    function testFuzz_sNUSD_simulatedLoss_decreasesNAV(uint256 _amount, uint256 _lossBps) external {
        _amount = bound(_amount, 1e18, 100_000e18);
        _lossBps = bound(_lossBps, 10, 500); // 0.1% to 5% loss

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        // Simulate loss (randomly picks Leg 1 or Leg 2)
        uint256 lossWAD = _lossBps * 1e14;
        simulateJTLoss(lossWAD);

        uint256 rateAfter = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
        assertLt(rateAfter, rateBefore, "Effective rate should decrease after loss");

        // Sync accounting
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after loss");
    }
}
