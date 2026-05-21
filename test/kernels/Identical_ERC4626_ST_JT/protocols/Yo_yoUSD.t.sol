// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { WAD } from "../../../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../../../src/libraries/Units.sol";
import { DisabledChainlinkOracle_ERC4626_TestBase } from "../base/DisabledChainlinkOracle_ERC4626_TestBase.t.sol";

/// @title Yo_yoUSD_Test
/// @notice Tests Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel with Yo Protocol yoUSD (disabled oracle)
/// @dev Both ST and JT use yoUSD as the tranche asset on Base
///
/// yoUSD is Yo Protocol's ERC4626 vault where:
///   - Tranche Unit: yoUSD shares
///   - Vault Asset: underlying stablecoin
///   - NAV Unit: USD
/// The stored conversion rate is 1:1 (WAD), with the Chainlink oracle disabled (address(1)).
contract Yo_yoUSD_Test is DisabledChainlinkOracle_ERC4626_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // BASE ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice yoUSD on Base
    address internal constant YO_USD = 0x0000000f2eB9f69274678c76222B35eEc7588a65;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({ forkBlock: 43_024_657, forkRpcUrlEnvVar: "BASE_RPC_URL", stAsset: YO_USD, jtAsset: YO_USD, initialFunding: 1_000_000e18 });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses MarketDeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    function _deployKernelAndMarket() internal override returns (MarketDeployment memory) {
        return _deployMarketFromConfig(DEPLOY_SCRIPT.YO_USD());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e12)); // 0.000001 yoUSD tolerance
    }

    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // yoUSD-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_yoUSD_vaultConfiguration() external view {
        uint8 decimals = IERC4626(YO_USD).decimals();
        assertEq(decimals, 6, "yoUSD should have 18 decimals");

        uint256 sharePrice = IERC4626(YO_USD).convertToAssets(1e18);
        assertGt(sharePrice, 0, "yoUSD share price should be > 0");
    }

    function test_yoUSD_initialConversionRate() external view {
        uint256 storedRate = _getConversionRate();
        assertEq(storedRate, WAD, "Stored rate should be WAD (1:1 for stablecoin)");
    }

    function testFuzz_yoUSD_simulatedYield_increasesNAV(uint256 _amount, uint256 _yieldBps) external {
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

    function testFuzz_yoUSD_simulatedLoss_decreasesNAV(uint256 _amount, uint256 _lossBps) external {
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

    function testFuzz_yoUSD_vaultSharePriceYield(uint256 _jtAmount, uint256 _yieldPercentage) external {
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
