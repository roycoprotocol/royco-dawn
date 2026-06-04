// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AggregatorV3Interface } from "../../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import { IdenticalAssetsChainlinkOracleQuoter } from "../../../../src/kernels/base/quoter/base/IdenticalAssetsChainlinkOracleQuoter.sol";
import { NAV_UNIT } from "../../../../src/libraries/Units.sol";
import { FundamentalStablecoinChainlinkOracle } from "../../../../src/periphery/oracle/FundamentalStablecoinChainlinkOracle.sol";

import { YieldBearingERC4626_ChainlinkOracle_TestBase } from "./YieldBearingERC4626_ChainlinkOracle_TestBase.t.sol";

/// @title FundamentalStablecoinPeg_ERC4626_ChainlinkOracle_TestBase
/// @notice Extends YieldBearingERC4626_ChainlinkOracle_TestBase with fork-level integration tests
///         specific to the FundamentalStablecoinChainlinkOracle peg wrapper.
/// @dev The wrapper anchors any underlying answer at or above MIN_PEG_PRICE to ONE_QUOTE_ASSET,
///      and forwards anything below MIN_PEG_PRICE unchanged so depegs surface. These tests assert
///      that anchoring/forwarding flows through the deployed kernel correctly by mocking the
///      *underlying* feed (not the wrapper) so the wrapper's logic is exercised end-to-end.
abstract contract FundamentalStablecoinPeg_ERC4626_ChainlinkOracle_TestBase is YieldBearingERC4626_ChainlinkOracle_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the deployed FundamentalStablecoinChainlinkOracle the kernel is wired to
    function _wrapperOracle() internal view returns (FundamentalStablecoinChainlinkOracle) {
        return FundamentalStablecoinChainlinkOracle(_getChainlinkOracle());
    }

    /// @notice Returns the underlying Chainlink (compatible) oracle the wrapper composes
    function _underlyingOracle() internal view returns (AggregatorV3Interface) {
        return AggregatorV3Interface(_wrapperOracle().ORACLE());
    }

    /// @notice Mocks the underlying oracle's latestRoundData to report `_answer` with a fresh timestamp
    /// @dev Preserves roundId and answeredInRound from the live underlying so the kernel's
    ///      validation (which runs against the wrapper, which forwards both unchanged) passes.
    function _mockUnderlyingPrice(int256 _answer) internal {
        _mockUnderlyingRound(_answer, block.timestamp);
    }

    /// @notice Mocks the underlying oracle's latestRoundData with an explicit `updatedAt`
    /// @dev The wrapper forwards updatedAt unchanged, so this is how a stale-underlying scenario
    ///      surfaces to the kernel's STALE_PRICE check.
    function _mockUnderlyingRound(int256 _answer, uint256 _updatedAt) internal {
        AggregatorV3Interface underlying = _underlyingOracle();
        (uint80 roundId,,,, uint80 answeredInRound) = underlying.latestRoundData();
        vm.mockCall(
            address(underlying),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(roundId, _answer, _updatedAt, _updatedAt, answeredInRound)
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // WRAPPER CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies the deployed wrapper's immutables are internally consistent with the underlying
    function test_fundamentalPeg_immutables() external view {
        FundamentalStablecoinChainlinkOracle wrapper = _wrapperOracle();
        AggregatorV3Interface underlying = _underlyingOracle();

        assertEq(wrapper.decimals(), underlying.decimals(), "wrapper.decimals should mirror underlying");
        assertEq(wrapper.ONE_QUOTE_ASSET(), int256(10 ** uint256(underlying.decimals())), "ONE_QUOTE_ASSET should be 10**decimals");
        assertGt(wrapper.MIN_PEG_PRICE(), 0, "MIN_PEG_PRICE should be > 0");
        assertLt(wrapper.MIN_PEG_PRICE(), wrapper.ONE_QUOTE_ASSET(), "MIN_PEG_PRICE should be < ONE_QUOTE_ASSET");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ANCHORING (underlying ≥ MIN_PEG_PRICE → wrapper reports ONE_QUOTE_ASSET)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice At the boundary (underlying == MIN_PEG_PRICE) the kernel rate is anchored
    /// @dev The kernel rate at MIN_PEG_PRICE must equal the rate at ONE_QUOTE_ASSET because
    ///      the wrapper reports both as ONE_QUOTE_ASSET. We compare to the at-ONE baseline
    ///      to avoid having to reproduce the kernel's share-price math here.
    function test_fundamentalPeg_atMinPegPriceAnchorsKernelRate() external {
        int256 minPeg = _wrapperOracle().MIN_PEG_PRICE();

        _mockUnderlyingPrice(minPeg);
        uint256 rateAtMin = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        vm.clearMockedCalls();
        _mockUnderlyingPrice(_wrapperOracle().ONE_QUOTE_ASSET());
        uint256 rateAtOne = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        assertEq(rateAtMin, rateAtOne, "Anchoring at MIN_PEG_PRICE should give the same rate as at ONE_QUOTE_ASSET");
    }

    /// @notice Strictly between MIN_PEG_PRICE and ONE_QUOTE_ASSET the kernel rate is anchored
    function test_fundamentalPeg_betweenMinPegAndOneAnchorsKernelRate() external {
        int256 minPeg = _wrapperOracle().MIN_PEG_PRICE();
        int256 one = _wrapperOracle().ONE_QUOTE_ASSET();
        int256 between = minPeg + (one - minPeg) / 2;

        _mockUnderlyingPrice(between);
        uint256 rateAtBetween = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        vm.clearMockedCalls();
        _mockUnderlyingPrice(one);
        uint256 rateAtOne = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        assertEq(rateAtBetween, rateAtOne, "Anchoring inside the peg band should give the same rate as at ONE_QUOTE_ASSET");
    }

    /// @notice Underlying above ONE_QUOTE_ASSET still caps at the kernel layer
    function test_fundamentalPeg_aboveOneCapsKernelRate() external {
        int256 one = _wrapperOracle().ONE_QUOTE_ASSET();

        _mockUnderlyingPrice(one);
        uint256 rateAtOne = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        vm.clearMockedCalls();
        _mockUnderlyingPrice(one * 2);
        uint256 rateAt2x = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        assertEq(rateAt2x, rateAtOne, "Capping above ONE_QUOTE_ASSET should leave the kernel rate at the at-ONE value");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPEG (underlying < MIN_PEG_PRICE → wrapper forwards unchanged)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice At one wei below MIN_PEG_PRICE the wrapper forwards unchanged; the kernel rate drops
    function test_fundamentalPeg_oneWeiBelowMinPegSurfacesDepeg() external {
        int256 minPeg = _wrapperOracle().MIN_PEG_PRICE();
        int256 one = _wrapperOracle().ONE_QUOTE_ASSET();

        _mockUnderlyingPrice(one);
        uint256 rateAtOne = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        vm.clearMockedCalls();
        _mockUnderlyingPrice(minPeg - 1);
        uint256 rateBelow = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        assertLt(rateBelow, rateAtOne, "Crossing MIN_PEG_PRICE downward should drop the kernel rate");

        // The kernel rate scales linearly with the wrapper's answer (see IdenticalAssetsChainlinkOracleQuoter._queryChainlinkOracle).
        // Expect rateBelow ~= rateAtOne * (minPeg - 1) / one.
        uint256 expected = rateAtOne * uint256(minPeg - 1) / uint256(one);
        assertApproxEqAbs(rateBelow, expected, 1, "Depeg should scale kernel rate proportionally to the forwarded answer");
    }

    /// @notice A material depeg (50% of par) scales the kernel rate by the same factor
    function test_fundamentalPeg_materialDepegScalesKernelRate() external {
        int256 one = _wrapperOracle().ONE_QUOTE_ASSET();

        _mockUnderlyingPrice(one);
        uint256 rateAtOne = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        vm.clearMockedCalls();
        int256 depegged = one / 2;
        _mockUnderlyingPrice(depegged);
        uint256 rateDepegged = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        uint256 expected = rateAtOne * uint256(depegged) / uint256(one);
        assertApproxEqAbs(rateDepegged, expected, 1, "50% depeg should halve the kernel rate (within rounding)");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUZZ: anchoring/forwarding rule holds for any underlying answer
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice For any non-negative underlying answer, the kernel rate matches the rule:
    ///         anchored to ONE_QUOTE_ASSET above the peg, forwarded unchanged below
    function testFuzz_fundamentalPeg_anchoringRuleFlowsThroughKernel(int256 _underlyingAnswer) public {
        int256 one = _wrapperOracle().ONE_QUOTE_ASSET();
        int256 minPeg = _wrapperOracle().MIN_PEG_PRICE();
        // Non-negative answers only — Chainlink validation in the kernel rejects ≤ 0 separately.
        _underlyingAnswer = bound(_underlyingAnswer, 1, type(int128).max);

        _mockUnderlyingPrice(one);
        uint256 rateAtOne = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        vm.clearMockedCalls();
        _mockUnderlyingPrice(_underlyingAnswer);
        uint256 rate = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        if (_underlyingAnswer >= minPeg) {
            assertEq(rate, rateAtOne, "Above-peg should anchor to the at-ONE rate");
        } else {
            uint256 expected = rateAtOne * uint256(_underlyingAnswer) / uint256(one);
            assertApproxEqAbs(rate, expected, 1, "Below-peg should forward unchanged into the kernel rate");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BOUNDARY: at exactly ONE_QUOTE_ASSET
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Underlying at exactly ONE_QUOTE_ASSET is anchored (boundary case of the ≥ MIN_PEG rule)
    function test_fundamentalPeg_atOneQuoteAssetAnchorsKernelRate() external {
        int256 one = _wrapperOracle().ONE_QUOTE_ASSET();

        _mockUnderlyingPrice(one);
        uint256 rateAtOne = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        // Sanity: the at-ONE rate equals the kernel's read with the wrapper returning ONE.
        // The wrapper anchors anything in [MIN_PEG, ∞) to ONE, so this read is the canonical anchored value.
        assertGt(rateAtOne, 0, "Kernel rate at ONE_QUOTE_ASSET should be positive");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INVALID UNDERLYING ANSWERS: wrapper forwards, kernel rejects
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Zero underlying answer is forwarded by the wrapper and rejected by the kernel
    function test_fundamentalPeg_zeroUnderlyingRejectedByKernel() external {
        _mockUnderlyingPrice(0);
        vm.expectRevert(IdenticalAssetsChainlinkOracleQuoter.INVALID_PRICE.selector);
        _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
    }

    /// @notice Negative underlying answer is forwarded by the wrapper and rejected by the kernel
    function test_fundamentalPeg_negativeUnderlyingRejectedByKernel() external {
        _mockUnderlyingPrice(-1);
        vm.expectRevert(IdenticalAssetsChainlinkOracleQuoter.INVALID_PRICE.selector);
        _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STALENESS: underlying updatedAt propagates through the wrapper
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Stale underlying timestamp surfaces as STALE_PRICE at the kernel
    /// @dev The wrapper forwards updatedAt unchanged, so a stale underlying must trip
    ///      the kernel's `updatedAt + staleness >= block.timestamp` check.
    function test_fundamentalPeg_staleUnderlyingRejectedByKernel() external {
        uint48 staleness = _getStalenessThreshold();
        uint256 staleUpdatedAt = block.timestamp - uint256(staleness) - 1;

        _mockUnderlyingRound(_wrapperOracle().ONE_QUOTE_ASSET(), staleUpdatedAt);
        vm.expectRevert(IdenticalAssetsChainlinkOracleQuoter.STALE_PRICE.selector);
        _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // END-TO-END: depeg → sync → NAV reflects the depeg
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice After a deposit, an underlying depeg flowed through the wrapper must reduce JT NAV on sync
    /// @dev Catches a class of bugs where the rate read changes but the accountant doesn't pick it up.
    function test_fundamentalPeg_depegReducesJTNAVOnSync() external {
        uint256 amount = _minDepositAmount() * 1000;
        if (amount > config.initialFunding / 10) amount = config.initialFunding / 10;
        _depositJT(ALICE_ADDRESS, amount);

        // Establish the anchored baseline so syncTrancheAccounting captures NAV at the wrapper's ONE.
        _mockUnderlyingPrice(_wrapperOracle().ONE_QUOTE_ASSET());
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();
        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Mock a 50% depeg (well below MIN_PEG_PRICE so the wrapper forwards unchanged).
        vm.clearMockedCalls();
        _mockUnderlyingPrice(_wrapperOracle().ONE_QUOTE_ASSET() / 2);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();
        NAV_UNIT navAfter = JT.totalAssets().nav;

        assertLt(navAfter, navBefore, "Depeg of the underlying should reduce JT NAV after sync");
    }
}
