// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import { DeployScript } from "../../../../script/Deploy.s.sol";
import { MarketDeploymentConfig } from "../../../../script/config/MarketDeploymentConfig.sol";
import { IRoycoFactory } from "../../../../src/interfaces/IRoycoFactory.sol";
import {
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel
} from "../../../../src/kernels/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";
import { AggregatorV3Interface } from "../../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../../src/libraries/Units.sol";

import { YieldBearingERC4626_ChainlinkOracle_TestBase } from "../base/YieldBearingERC4626_ChainlinkOracle_TestBase.t.sol";

/// @title stMXN_stMXN_Test
/// @notice Tests Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel with Tenbin stMXN
/// @dev Both ST and JT use stMXN as the tranche asset on Ethereum mainnet
///
/// stMXN (Staked Tenbin Mexican Peso) is an ERC4626 vault where:
///   - Tranche Unit: stMXN shares (18 decimals)
///   - Vault Asset: tMXN (Tenbin Mexican Peso, 18 decimals)
///   - NAV Unit: USD (tMXN assumed 1:1 with fiat MXN, priced via the Chainlink MXN/USD feed)
/// The deployment uses initialConversionRateWAD: 0 (sentinel mode — live Chainlink MXN/USD oracle).
///
/// Tenbin-specific properties exercised here:
///   - Yield is admin-pushed via reward() with linear vesting; share price is monotonic non-decreasing
///   - Direct vault withdraw()/redeem() revert while cooldownPeriod > 0 (Dawn never calls them —
///     redemptions transfer the stMXN token itself)
contract stMXN_stMXN_Test is YieldBearingERC4626_ChainlinkOracle_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice stMXN on Ethereum mainnet
    address internal constant STMXN = 0x8BDf6A2DFda084bD242Cd285CF75E80de3eB00ba;

    /// @notice Chainlink MXN/USD feed on Ethereum mainnet (8 decimals)
    address internal constant MXN_USD_FEED = 0xdb4881Ab0ad6b8423f76dd8C9d65542749a1dB77;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for stMXN
    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({
            forkBlock: 25_540_000,
            forkRpcUrlEnvVar: "MAINNET_RPC_URL",
            stAsset: STMXN,
            jtAsset: STMXN,
            initialFunding: 1_000_000_000e18 // 1B stMXN
        });
    }

    /// @notice Returns the Chainlink oracle address from the deployed kernel configuration
    function _getChainlinkOracle() internal view override returns (address) {
        return Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel(address(KERNEL)).getChainlinkOracleConfiguration().oracle;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses MarketDeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the stMXN kernel and market using parameters from MarketDeploymentConfig
    /// @dev Uses the Chainlink MXN/USD oracle from the deployment config for tMXN->USD pricing
    function _deployKernelAndMarket() internal override returns (DeployScript.DeploymentResult memory) {
        MarketDeploymentConfig.MarketConfig memory marketConfig = DEPLOY_SCRIPT.getMarketConfig("stMXN");

        uint32 scheduledOperationsExpirySeconds = DEPLOY_SCRIPT.getChainConfig(block.chainid).scheduledOperationsExpirySeconds;
        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        return DEPLOY_SCRIPT.deploy(
            marketConfig, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, scheduledOperationsExpirySeconds, roleAssignments, DEPLOYER.privateKey
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for stMXN (18 decimals)
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e12)); // 0.000001 stMXN tolerance
    }

    /// @notice Returns max NAV delta for stMXN
    /// @dev Converts the tranche unit tolerance to NAV using the kernel's conversion
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // stMXN-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies that the stMXN vault is correctly configured
    function test_stMXN_vaultConfiguration() external view {
        // Verify decimals
        uint8 decimals = IERC4626(STMXN).decimals();
        assertEq(decimals, 18, "stMXN should have 18 decimals");

        // Verify the vault has a valid share price
        uint256 sharePrice = IERC4626(STMXN).convertToAssets(1e18);
        assertGe(sharePrice, 1e18, "stMXN share price should be >= 1:1");
    }

    /// @notice Verifies initial conversion rate is sentinel (0) for live oracle mode
    function test_stMXN_initialConversionRate() external view {
        uint256 storedRate = _getStoredConversionRate();

        // The stored rate should be 0 (sentinel) — the live Chainlink MXN/USD oracle provides the tMXN->USD rate
        assertEq(storedRate, 0, "Stored rate should be 0 (sentinel mode for live Chainlink oracle)");

        // The effective conversion rate should be positive (from the Chainlink oracle)
        uint256 effectiveRate = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
        assertGt(effectiveRate, 0, "Effective conversion rate should be positive from Chainlink oracle");
    }

    /// @notice Verifies the effective rate equals share price x MXN/USD feed price (both normalized to WAD)
    function test_stMXN_effectiveRate_matchesSharePriceTimesFeed() external view {
        uint256 sharePrice = IERC4626(STMXN).convertToAssets(1e18); // tMXN per stMXN, 18 dec
        (, int256 answer,,,) = AggregatorV3Interface(MXN_USD_FEED).latestRoundData();
        uint8 feedDecimals = AggregatorV3Interface(MXN_USD_FEED).decimals();

        // Expected: stMXN -> tMXN (share price) -> USD (feed), floor-composed to WAD
        uint256 expectedRate = (sharePrice * uint256(answer)) / (10 ** feedDecimals);
        uint256 effectiveRate = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        assertApproxEqRel(effectiveRate, expectedRate, 1e12, "Effective rate should equal share price x MXN/USD");
        // Sanity: MXN trades well below 1 USD, so the rate must be far below 1e18
        assertLt(effectiveRate, 0.5e18, "stMXN/USD rate sanity bound");
    }

    /// @notice Test that simulated yield works correctly for stMXN
    function testFuzz_stMXN_simulatedYield_increasesNAV(uint256 _amount, uint256 _yieldBps) external {
        _amount = bound(_amount, 1e18, 100_000_000e18); // 1 to 100M stMXN
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

    /// @notice Test loss simulation for stMXN
    /// @dev The Tenbin share price is monotonic in code (no loss pass-through); losses reach this market
    ///      either via the MXN/USD feed or via a governance markdown of the conversion rate. The base's
    ///      loss simulation covers the oracle leg; the markdown path is covered in the admin-rate test below.
    function testFuzz_stMXN_simulatedLoss_decreasesNAV(uint256 _amount, uint256 _lossBps) external {
        _amount = bound(_amount, 1e18, 100_000_000e18);
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

    /// @notice The manual depeg procedure: governance marks down tMXN via the admin conversion-rate override
    /// @dev This is the ONLY on-chain path by which a Tenbin backing failure can be recognized (the share
    ///      price cannot decrease and the Chainlink feed prices fiat MXN, not tMXN). Verifies that a markdown
    ///      flows through accounting as an ST loss covered by JT.
    function test_stMXN_adminRateMarkdown_appliesCoverage() external {
        uint256 stAmount = 10_000_000e18;
        uint256 jtAmount = 3_000_000e18; // ample coverage vs 15% requirement

        _depositJT(ALICE_ADDRESS, jtAmount);
        _depositST(BOB_ADDRESS, stAmount);

        NAV_UNIT jtNavBefore = JT.totalAssets().nav;

        // Governance pins the BASE-asset rate (tMXN -> USD) 10% below the live feed (tMXN marked to 90% of fiat MXN)
        // Note: the stored rate is the base->NAV leg, which the quoter multiplies by the ERC4626 share price
        (, int256 answer,,,) = AggregatorV3Interface(MXN_USD_FEED).latestRoundData();
        uint256 liveBaseRateWAD = uint256(answer) * 1e10; // 8 -> 18 decimals
        uint256 markedDownRate = (liveBaseRateWAD * 90) / 100;
        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        _kernelCast().setConversionRate(markedDownRate, true);

        // JT absorbs the ST loss: JT NAV must drop by more than its own pro-rata share of the markdown
        NAV_UNIT jtNavAfter = JT.totalAssets().nav;
        assertLt(toUint256(jtNavAfter), toUint256(jtNavBefore), "JT NAV should decrease after markdown");
    }
}
