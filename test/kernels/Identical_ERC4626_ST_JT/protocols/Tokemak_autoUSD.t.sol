// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import { WAD } from "../../../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../../../src/libraries/Units.sol";

import { DisabledChainlinkOracle_ERC4626_TestBase } from "../base/DisabledChainlinkOracle_ERC4626_TestBase.t.sol";

import { COMPONENT_ID_KERNEL_IDENTICAL_ERC4626_CHAINLINK_ORACLE } from "../../../../src/factory/templates/Components.sol";
import {
    IdenticalERC4626ChainlinkOracleDeploymentTemplate
} from "../../../../src/factory/templates/dawn/IdenticalERC4626ChainlinkOracleDeploymentTemplate.sol";
import {
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel
} from "../../../../src/kernels/dawn/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";

/// @title Tokemak_autoUSD_Test
/// @notice Tests Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel with Tokemak autoUSD (disabled oracle)
/// @dev Both ST and JT use autoUSD as the tranche asset on Ethereum mainnet
///
/// autoUSD is Tokemak's ERC4626 autopool vault where:
///   - Tranche Unit: autoUSD shares
///   - Vault Asset: USDC (the underlying)
///   - NAV Unit: USD
/// The stored conversion rate is 1:1 (WAD), with the Chainlink oracle disabled (address(1)).
contract Tokemak_autoUSD_Test is DisabledChainlinkOracle_ERC4626_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tokemak autoUSD on Ethereum mainnet
    address internal constant AUTO_USD = 0xa7569A44f348d3D70d8ad5889e50F78E33d80D35;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for autoUSD
    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({
            forkBlock: 24_261_516,
            forkRpcUrlEnvVar: "MAINNET_RPC_URL",
            stAsset: AUTO_USD,
            jtAsset: AUTO_USD,
            initialFunding: 1_000_000e18 // 1M autoUSD
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses MarketDeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the autoUSD kernel and market using parameters from MarketDeploymentConfig
    function _deployKernelAndMarket() internal override returns (MarketDeployment memory) {
        IdenticalERC4626ChainlinkOracleDeploymentTemplate template = new IdenticalERC4626ChainlinkOracleDeploymentTemplate(FACTORY);
        DawnDeploymentParams memory p;
        p.marketId = keccak256("AUTOUSD_TEST");
        p.template = address(template);
        p.kernelComponentId = COMPONENT_ID_KERNEL_IDENTICAL_ERC4626_CHAINLINK_ORACLE;
        p.kernelCreationCode = type(Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel).creationCode;
        p.stAsset = config.stAsset;
        p.jtAsset = config.jtAsset;
        p.kernelSpecificParams = abi.encode(
            IdenticalERC4626ChainlinkOracleDeploymentTemplate.KernelParams({
                initialConversionRateWAD: WAD, baseAssetToNavAssetOracle: address(1), stalenessThresholdSeconds: 86_400
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

    /// @notice Returns max tranche unit delta for autoUSD (18 decimals)
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e12)); // 0.000001 autoUSD tolerance
    }

    /// @notice Returns max NAV delta for autoUSD
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // autoUSD-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies that the autoUSD vault is correctly configured
    function test_autoUSD_vaultConfiguration() external view {
        uint8 decimals = IERC4626(AUTO_USD).decimals();
        assertEq(decimals, 18, "autoUSD should have 18 decimals");

        uint256 sharePrice = IERC4626(AUTO_USD).convertToAssets(1e18);
        assertGt(sharePrice, 0, "autoUSD share price should be > 0");
    }

    /// @notice Verifies initial stored conversion rate is WAD (1:1 for stablecoin)
    function test_autoUSD_initialConversionRate() external view {
        uint256 storedRate = _getConversionRate();
        assertEq(storedRate, WAD, "Stored rate should be WAD (1:1 for stablecoin)");
    }

    /// @notice Test that simulated yield works correctly for autoUSD
    function testFuzz_autoUSD_simulatedYield_increasesNAV(uint256 _amount, uint256 _yieldBps) external {
        _amount = bound(_amount, 1e18, 100_000e18);
        _yieldBps = bound(_yieldBps, 10, 1000);

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        uint256 yieldWAD = _yieldBps * 1e14;
        simulateJTYield(yieldWAD);

        uint256 rateAfter = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
        assertGt(rateAfter, rateBefore, "Rate should increase after yield");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after yield");
    }

    /// @notice Test loss simulation for autoUSD
    function testFuzz_autoUSD_simulatedLoss_decreasesNAV(uint256 _amount, uint256 _lossBps) external {
        _amount = bound(_amount, 1e18, 100_000e18);
        _lossBps = bound(_lossBps, 10, 500);

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        uint256 lossWAD = _lossBps * 1e14;
        simulateJTLoss(lossWAD);

        uint256 rateAfter = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
        assertLt(rateAfter, rateBefore, "Rate should decrease after loss");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after loss");
    }

    /// @notice Test that autoUSD vault share price changes affect NAV correctly
    function testFuzz_autoUSD_vaultSharePriceYield(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 1, 20);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        simulateVaultSharePriceYield(_yieldPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after vault share price yield");
    }
}
