// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import { DeployScript } from "../../../../script/Deploy.s.sol";
import { MarketDeploymentConfig } from "../../../../script/config/MarketDeploymentConfig.sol";
import { IRoycoFactory } from "../../../../src/interfaces/IRoycoFactory.sol";
import { WAD } from "../../../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../../../src/libraries/Units.sol";

import { DisabledChainlinkOracle_ERC4626_TestBase } from "../base/DisabledChainlinkOracle_ERC4626_TestBase.t.sol";

/// @title Ember_eEARN_Test
/// @notice Tests Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel with Ember Earn (disabled oracle)
/// @dev Both ST and JT use eEARN as the tranche asset on Ethereum mainnet
///
/// Ember Earn is a USDC-denominated ERC4626 yield vault where:
///   - Tranche Unit: eEARN shares (6 decimals)
///   - Vault Asset: USDC (6 decimals)
///   - NAV Unit: USD
/// The stored conversion rate is 1:1 (WAD), with the Chainlink oracle disabled (address(1)).
contract Ember_eEARN_Test is DisabledChainlinkOracle_ERC4626_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Ember Earn vault on Ethereum mainnet
    address internal constant EEARN_ADDRESS = 0x9be9294722f8AAd37b11a9792Be2C782182caFA2;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for eEARN
    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({
            forkBlock: 24_996_700,
            forkRpcUrlEnvVar: "MAINNET_RPC_URL",
            stAsset: EEARN_ADDRESS,
            jtAsset: EEARN_ADDRESS,
            initialFunding: 1_000_000_000e6 // 1B eEARN (6 decimals)
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses MarketDeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the eEARN kernel and market using parameters from MarketDeploymentConfig
    function _deployKernelAndMarket() internal override returns (DeployScript.DeploymentResult memory) {
        MarketDeploymentConfig.MarketConfig memory marketConfig = DEPLOY_SCRIPT.getMarketConfig("eEARN");

        uint32 scheduledOperationsExpirySeconds = DEPLOY_SCRIPT.getChainConfig(block.chainid).scheduledOperationsExpirySeconds;
        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        return DEPLOY_SCRIPT.deploy(
            marketConfig, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, scheduledOperationsExpirySeconds, roleAssignments, DEPLOYER.privateKey
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for eEARN (6 decimals)
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e3)); // 0.001 eEARN tolerance
    }

    /// @notice Returns max NAV delta for eEARN
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // eEARN-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies that the eEARN vault is correctly configured
    function test_eEARN_vaultConfiguration() external view {
        uint8 decimals = IERC4626(EEARN_ADDRESS).decimals();
        assertEq(decimals, 6, "eEARN should have 6 decimals");

        uint256 sharePrice = IERC4626(EEARN_ADDRESS).convertToAssets(1e6);
        assertGt(sharePrice, 0, "eEARN share price should be > 0");
    }

    /// @notice Verifies initial stored conversion rate is WAD (1:1, USDC pegged at $1)
    function test_eEARN_initialConversionRate() external view {
        uint256 storedRate = _getConversionRate();
        assertEq(storedRate, WAD, "Stored rate should be WAD (1:1 for USDC)");
    }

    /// @notice Test that simulated yield works correctly for eEARN
    function testFuzz_eEARN_simulatedYield_increasesNAV(uint256 _amount, uint256 _yieldBps) external {
        _amount = bound(_amount, 1e6, 100_000e6);
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

    /// @notice Test loss simulation for eEARN
    function testFuzz_eEARN_simulatedLoss_decreasesNAV(uint256 _amount, uint256 _lossBps) external {
        _amount = bound(_amount, 1e6, 100_000e6);
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

    /// @notice Test that eEARN vault share price changes affect NAV correctly
    function testFuzz_eEARN_vaultSharePriceYield(uint256 _jtAmount, uint256 _yieldPercentage) external {
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
