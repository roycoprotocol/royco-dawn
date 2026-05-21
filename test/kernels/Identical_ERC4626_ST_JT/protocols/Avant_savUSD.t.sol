// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { WAD } from "../../../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../../../src/libraries/Units.sol";
import { DisabledChainlinkOracle_ERC4626_TestBase } from "../base/DisabledChainlinkOracle_ERC4626_TestBase.t.sol";

/// @title savUSD_savUSD_Test
/// @notice Tests Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel with sAVUSD (disabled oracle)
/// @dev Both ST and JT use sAVUSD as the tranche asset on Avalanche mainnet
///
/// sAVUSD is an ERC4626 vault where:
///   - Tranche Unit: sAVUSD shares
///   - Vault Asset: AVUSD (the underlying)
///   - NAV Unit: USD
/// The stored conversion rate is 1:1 (WAD), with the Chainlink oracle disabled (address(1)).
contract savUSD_savUSD_Test is DisabledChainlinkOracle_ERC4626_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // AVALANCHE MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice sAVUSD on Avalanche mainnet
    address internal constant SAVUSD = 0x06d47F3fb376649c3A9Dafe069B3D6E35572219E;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for sAVUSD
    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({
            forkBlock: 76_172_623,
            forkRpcUrlEnvVar: "AVALANCHE_RPC_URL",
            stAsset: SAVUSD,
            jtAsset: SAVUSD,
            initialFunding: 1_000_000e18 // 1M sAVUSD
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses MarketDeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the savUSD kernel + market via the chainlink-oracle template (oracle disabled).
    function _deployKernelAndMarket() internal override returns (MarketDeployment memory) {
        return _deployMarketFromConfig(DEPLOY_SCRIPT.SAVUSD());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for sAVUSD (18 decimals)
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e12)); // 0.000001 sAVUSD tolerance
    }

    /// @notice Returns max NAV delta for sAVUSD
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // sAVUSD-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies that the sAVUSD vault is correctly configured
    function test_sAVUSD_vaultConfiguration() external view {
        uint8 decimals = IERC4626(SAVUSD).decimals();
        assertEq(decimals, 18, "sAVUSD should have 18 decimals");

        uint256 sharePrice = IERC4626(SAVUSD).convertToAssets(1e18);
        assertGe(sharePrice, 1e18, "sAVUSD share price should be >= 1:1");
    }

    /// @notice Verifies initial stored conversion rate is WAD (1:1 for stablecoin)
    function test_sAVUSD_initialConversionRate() external view {
        uint256 storedRate = _getConversionRate();
        assertEq(storedRate, WAD, "Stored rate should be WAD (1:1 for stablecoin)");
    }

    /// @notice Test that simulated yield works correctly for sAVUSD
    function testFuzz_sAVUSD_simulatedYield_increasesNAV(uint256 _amount, uint256 _yieldBps) external {
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

    /// @notice Test loss simulation for sAVUSD
    function testFuzz_sAVUSD_simulatedLoss_decreasesNAV(uint256 _amount, uint256 _lossBps) external {
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
}
