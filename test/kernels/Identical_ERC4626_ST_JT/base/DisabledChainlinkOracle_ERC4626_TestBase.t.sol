// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;
import {
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel
} from "../../../../src/kernels/dawn/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";
import { YieldBearingERC4626_ChainlinkOracle_TestBase } from "./YieldBearingERC4626_ChainlinkOracle_TestBase.t.sol";

/// @title DisabledChainlinkOracle_ERC4626_TestBase
/// @notice Base for ERC4626+Chainlink kernel tests where the oracle is disabled (address(1))
/// @dev Used when initialConversionRateWAD = 1e18 (non-sentinel) and oracle = address(1).
///      The Chainlink oracle leg is effectively bypassed — only the ERC4626 share price leg
///      and stored conversion rate are active.
///
///      Sentinel-dependent tests (Chainlink price, combined legs, sentinel mode) are skipped
///      because the oracle at address(1) has no code and is never queried in non-sentinel mode.
abstract contract DisabledChainlinkOracle_ERC4626_TestBase is YieldBearingERC4626_ChainlinkOracle_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIGURATION OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the oracle address from the deployed kernel configuration
    function _getChainlinkOracle() internal view override returns (address) {
        return Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel(address(KERNEL)).getChainlinkOracleConfiguration().oracle;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ORACLE HANDLING OVERRIDES (disabled oracle at address(1))
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice No-op: oracle is disabled (address(1)), no Chainlink mocking needed
    function _ensureChainlinkOracleMocked() internal override { }

    /// @notice Only refresh ERC4626 mock after warp — skip Chainlink (disabled)
    function _refreshOraclesAfterWarp() internal override {
        if (mockedSharePriceWAD != 0) {
            _mockConvertToAssets(mockedSharePriceWAD);
        }
    }

    /// @notice Pre-mocks the oracle when switching to sentinel mode so the post-sync can query it
    /// @dev When transitioning from non-sentinel (stored rate != 0) to sentinel (stored rate == 0),
    ///      the post-sync inside setConversionRate queries the oracle. Since address(1) has no code,
    ///      we must mock latestRoundData() before the transition.
    function _setStoredConversionRate(uint256 _newRateWAD) internal override {
        if (_newRateWAD == 0 && _getStoredConversionRate() != 0) {
            _mockChainlinkPrice(int256(1e8));
        }
        super._setStoredConversionRate(_newRateWAD);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT HELPER
    // ═══════════════════════════════════════════════════════════════════════════

    // ═══════════════════════════════════════════════════════════════════════════
    // SKIPPED TESTS: Sentinel/Chainlink-specific (not applicable for disabled oracle)
    // ═══════════════════════════════════════════════════════════════════════════

    // Section B: Chainlink price tests require sentinel mode with a live oracle
    function testFuzz_chainlinkPrice_yield_updatesNAV(uint256, uint256) public override {
        vm.skip(true);
    }

    function testFuzz_chainlinkPrice_loss_updatesNAV(uint256, uint256) public override {
        vm.skip(true);
    }

    function testFuzz_chainlinkPrice_yield_distributesToJT(uint256, uint256, uint256) public override {
        vm.skip(true);
    }

    function testFuzz_chainlinkPrice_NAVConservation(uint256, uint256) public override {
        vm.skip(true);
    }

    // Section D: Combined tests require sentinel mode for the Chainlink leg
    function testFuzz_combined_bothLegsYield_verifiesMultiplicativeFormula(uint256, uint256, uint256) public override {
        vm.skip(true);
    }

    function testFuzz_combined_sharePriceUp_chainlinkDown(uint256, uint256, uint256) public override {
        vm.skip(true);
    }

    function testFuzz_combined_sharePriceDown_chainlinkUp(uint256, uint256, uint256) public override {
        vm.skip(true);
    }

    // Section G: Sentinel-start tests require the kernel to begin in sentinel mode
    function test_sentinelMode_usesChainlinkOracle() public override {
        vm.skip(true);
    }

    function testFuzz_sentinelToNonSentinel_transition(uint256) public override {
        vm.skip(true);
    }

    function testFuzz_nonSentinelToSentinel_transition(uint256) external override {
        vm.skip(true);
    }

    // Section F: Oracle validation tests require sentinel mode and clear all mocks (including decimals)
    function test_oracleValidation_revertsOnStalePrice() external override {
        vm.skip(true);
    }

    function test_oracleValidation_revertsOnZeroPrice() external override {
        vm.skip(true);
    }

    function test_oracleValidation_revertsOnNegativePrice() external override {
        vm.skip(true);
    }

    function test_oracleValidation_revertsOnIncompleteRound() external override {
        vm.skip(true);
    }

    function test_oracleValidation_passesWithValidData() external override {
        vm.skip(true);
    }
}
