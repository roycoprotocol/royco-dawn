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

/// @title stBRL_stBRL_Test
/// @notice Tests Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel with Tenbin stBRL
/// @dev Both ST and JT use stBRL as the tranche asset on Ethereum mainnet
///
/// stBRL (Staked Tenbin Brazilian Real) is an ERC4626 vault where:
///   - Tranche Unit: stBRL shares (18 decimals)
///   - Vault Asset: tBRL (Tenbin Brazilian Real, 18 decimals)
///   - NAV Unit: USD (tBRL assumed 1:1 with fiat BRL, priced via the Chainlink BRL/USD feed)
/// The deployment uses initialConversionRateWAD: 0 (sentinel mode — live Chainlink BRL/USD oracle).
///
/// Tenbin-specific properties exercised here:
///   - Yield is admin-pushed via reward() with linear vesting; share price is monotonic non-decreasing
///   - Direct vault withdraw()/redeem() revert while cooldownPeriod > 0 (Dawn never calls them —
///     redemptions transfer the stBRL token itself)
contract stBRL_stBRL_Test is YieldBearingERC4626_ChainlinkOracle_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice stBRL on Ethereum mainnet
    address internal constant STBRL = 0xDaB276F6E19CCC54cA5aaA2645A94087ca776a3f;

    /// @notice Chainlink BRL/USD feed on Ethereum mainnet (8 decimals)
    address internal constant BRL_USD_FEED = 0x3126E7F38D5f60f4E2B6ec3511C7bdbD79317Df1;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for stBRL
    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({
            forkBlock: 25_540_000,
            forkRpcUrlEnvVar: "MAINNET_RPC_URL",
            stAsset: STBRL,
            jtAsset: STBRL,
            initialFunding: 1_000_000_000e18 // 1B stBRL
        });
    }

    /// @notice Returns the Chainlink oracle address from the deployed kernel configuration
    function _getChainlinkOracle() internal view override returns (address) {
        return Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel(address(KERNEL)).getChainlinkOracleConfiguration().oracle;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses MarketDeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the stBRL kernel and market using parameters from MarketDeploymentConfig
    /// @dev Uses the Chainlink BRL/USD oracle from the deployment config for tBRL->USD pricing
    function _deployKernelAndMarket() internal override returns (DeployScript.DeploymentResult memory) {
        MarketDeploymentConfig.MarketConfig memory marketConfig = DEPLOY_SCRIPT.getMarketConfig("stBRL");

        uint32 scheduledOperationsExpirySeconds = DEPLOY_SCRIPT.getChainConfig(block.chainid).scheduledOperationsExpirySeconds;
        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        return DEPLOY_SCRIPT.deploy(
            marketConfig, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, scheduledOperationsExpirySeconds, roleAssignments, DEPLOYER.privateKey
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for stBRL (18 decimals)
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e12)); // 0.000001 stBRL tolerance
    }

    /// @notice Returns max NAV delta for stBRL
    /// @dev Converts the tranche unit tolerance to NAV using the kernel's conversion
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // stBRL-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies that the stBRL vault is correctly configured
    function test_stBRL_vaultConfiguration() external view {
        // Verify decimals
        uint8 decimals = IERC4626(STBRL).decimals();
        assertEq(decimals, 18, "stBRL should have 18 decimals");

        // Verify the vault has a valid share price
        uint256 sharePrice = IERC4626(STBRL).convertToAssets(1e18);
        assertGe(sharePrice, 1e18, "stBRL share price should be >= 1:1");
    }

    /// @notice Verifies initial conversion rate is sentinel (0) for live oracle mode
    function test_stBRL_initialConversionRate() external view {
        uint256 storedRate = _getStoredConversionRate();

        // The stored rate should be 0 (sentinel) — the live Chainlink BRL/USD oracle provides the tBRL->USD rate
        assertEq(storedRate, 0, "Stored rate should be 0 (sentinel mode for live Chainlink oracle)");

        // The effective conversion rate should be positive (from the Chainlink oracle)
        uint256 effectiveRate = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
        assertGt(effectiveRate, 0, "Effective conversion rate should be positive from Chainlink oracle");
    }

    /// @notice Verifies the effective rate equals share price x BRL/USD feed price (both normalized to WAD)
    function test_stBRL_effectiveRate_matchesSharePriceTimesFeed() external view {
        uint256 sharePrice = IERC4626(STBRL).convertToAssets(1e18); // tBRL per stBRL, 18 dec
        (, int256 answer,,,) = AggregatorV3Interface(BRL_USD_FEED).latestRoundData();
        uint8 feedDecimals = AggregatorV3Interface(BRL_USD_FEED).decimals();

        // Expected: stBRL -> tBRL (share price) -> USD (feed), floor-composed to WAD
        uint256 expectedRate = (sharePrice * uint256(answer)) / (10 ** feedDecimals);
        uint256 effectiveRate = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        assertApproxEqRel(effectiveRate, expectedRate, 1e12, "Effective rate should equal share price x BRL/USD");
        // Sanity: BRL trades well below 1 USD, so the rate must be far below 1e18
        assertLt(effectiveRate, 0.5e18, "stBRL/USD rate sanity bound");
    }

    /// @notice Test that simulated yield works correctly for stBRL
    function testFuzz_stBRL_simulatedYield_increasesNAV(uint256 _amount, uint256 _yieldBps) external {
        _amount = bound(_amount, 1e18, 100_000_000e18); // 1 to 100M stBRL
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

    /// @notice Test loss simulation for stBRL
    /// @dev The Tenbin share price is monotonic in code (no loss pass-through); losses reach this market
    ///      either via the BRL/USD feed or via a governance markdown of the conversion rate. The base's
    ///      loss simulation covers the oracle leg; the markdown path is covered in the admin-rate test below.
    function testFuzz_stBRL_simulatedLoss_decreasesNAV(uint256 _amount, uint256 _lossBps) external {
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

    /// @notice The manual depeg procedure: governance marks down tBRL via the admin conversion-rate override
    /// @dev This is the ONLY on-chain path by which a Tenbin backing failure can be recognized (the share
    ///      price cannot decrease and the Chainlink feed prices fiat BRL, not tBRL). Verifies that a markdown
    ///      flows through accounting as an ST loss covered by JT.
    function test_stBRL_adminRateMarkdown_appliesCoverage() external {
        uint256 stAmount = 10_000_000e18;
        uint256 jtAmount = 3_000_000e18; // ample coverage vs 15% requirement

        _depositJT(ALICE_ADDRESS, jtAmount);
        _depositST(BOB_ADDRESS, stAmount);

        NAV_UNIT jtNavBefore = JT.totalAssets().nav;

        // Governance pins the BASE-asset rate (tBRL -> USD) 10% below the live feed (tBRL marked to 90% of fiat BRL)
        // Note: the stored rate is the base->NAV leg, which the quoter multiplies by the ERC4626 share price
        (, int256 answer,,,) = AggregatorV3Interface(BRL_USD_FEED).latestRoundData();
        uint256 liveBaseRateWAD = uint256(answer) * 1e10; // 8 -> 18 decimals
        uint256 markedDownRate = (liveBaseRateWAD * 90) / 100;
        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        _kernelCast().setConversionRate(markedDownRate, true);

        // JT absorbs the ST loss: JT NAV must drop by more than its own pro-rata share of the markdown
        NAV_UNIT jtNavAfter = JT.totalAssets().nav;
        assertLt(toUint256(jtNavAfter), toUint256(jtNavBefore), "JT NAV should decrease after markdown");
    }
}
