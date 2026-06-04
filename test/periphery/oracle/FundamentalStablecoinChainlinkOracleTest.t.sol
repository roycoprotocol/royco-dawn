// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";

import { AggregatorV3Interface } from "../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import { FundamentalStablecoinChainlinkOracle } from "../../../src/periphery/oracle/FundamentalStablecoinChainlinkOracle.sol";

/// @notice Configurable mock implementing AggregatorV3Interface for unit-testing the wrapper
/// @dev Mirrors the round-data shape of a Chainlink feed and exposes setters to drive the wrapper deterministically
contract MockChainlinkOracle is AggregatorV3Interface {
    uint8 private _decimals;
    string private _description;
    uint256 private _version = 1;

    uint80 private _roundId = 1;
    int256 private _answer;
    uint256 private _startedAt;
    uint256 private _updatedAt;
    uint80 private _answeredInRound = 1;

    constructor(uint8 _d, string memory _desc) {
        _decimals = _d;
        _description = _desc;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
    }

    function setAnswer(int256 _a) external {
        _answer = _a;
    }

    function setRound(uint80 _r) external {
        _roundId = _r;
        _answeredInRound = _r;
    }

    function setTimestamps(uint256 _s, uint256 _u) external {
        _startedAt = _s;
        _updatedAt = _u;
    }

    function setDescription(string calldata _d) external {
        _description = _d;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external view returns (string memory) {
        return _description;
    }

    function version() external view returns (uint256) {
        return _version;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }

    function getRoundData(uint80 _r) external view returns (uint80, int256, uint256, uint256, uint80) {
        // Mock simplification: forward the requested round ID with the currently configured answer/timestamps
        return (_r, _answer, _startedAt, _updatedAt, _r);
    }
}

/// @title FundamentalStablecoinChainlinkOracleTest
/// @notice Audit-grade unit tests for FundamentalStablecoinChainlinkOracle backed by a configurable Chainlink-compatible mock
/// @dev Validates the dual semantics of the wrapper: anchor-up (price ∈ [MIN_PEG_PRICE, ONE_QUOTE_ASSET]) and cap (price > ONE_QUOTE_ASSET) both resolve to ONE_QUOTE_ASSET; depegs (price < MIN_PEG_PRICE) pass through unchanged
contract FundamentalStablecoinChainlinkOracleTest is Test {
    /// =====================================================================
    /// STATE
    /// =====================================================================
    MockChainlinkOracle internal underlyingOracle8;
    MockChainlinkOracle internal underlyingOracle18;
    FundamentalStablecoinChainlinkOracle internal wrapper8;
    FundamentalStablecoinChainlinkOracle internal wrapper18;

    /// @dev 1.00 in 8-decimal precision (Chainlink standard)
    int256 internal constant ONE_8 = 1e8;
    /// @dev 0.999 in 8-decimal precision; the typical USDC/USD-style peg threshold
    int256 internal constant MIN_PEG_8 = 0.999e8;

    /// @dev 1.00 in 18-decimal precision (some non-Chainlink and Redstone-style feeds)
    int256 internal constant ONE_18 = 1e18;
    /// @dev 0.999 in 18-decimal precision
    int256 internal constant MIN_PEG_18 = 0.999e18;

    /// =====================================================================
    /// SETUP
    /// =====================================================================

    function setUp() public {
        underlyingOracle8 = new MockChainlinkOracle(8, "USDC / USD");
        underlyingOracle18 = new MockChainlinkOracle(18, "DAI / USD");

        wrapper8 = new FundamentalStablecoinChainlinkOracle(address(underlyingOracle8), MIN_PEG_8);
        wrapper18 = new FundamentalStablecoinChainlinkOracle(address(underlyingOracle18), MIN_PEG_18);
    }

    /// =====================================================================
    /// CONSTRUCTOR
    /// =====================================================================

    function test_constructor_setsImmutables() public view {
        assertEq(wrapper8.ORACLE(), address(underlyingOracle8));
        assertEq(wrapper8.MIN_PEG_PRICE(), MIN_PEG_8);
        assertEq(wrapper8.ONE_QUOTE_ASSET(), ONE_8);
    }

    function test_constructor_computesONEFromUnderlyingDecimals() public view {
        assertEq(wrapper8.ONE_QUOTE_ASSET(), int256(10 ** 8));
        assertEq(wrapper18.ONE_QUOTE_ASSET(), int256(10 ** 18));
    }

    function test_constructor_revertsOnZeroMinPegPrice() public {
        vm.expectRevert(FundamentalStablecoinChainlinkOracle.INVALID_MIN_PEG_PRICE.selector);
        new FundamentalStablecoinChainlinkOracle(address(underlyingOracle8), 0);
    }

    function test_constructor_revertsOnNegativeMinPegPrice() public {
        vm.expectRevert(FundamentalStablecoinChainlinkOracle.INVALID_MIN_PEG_PRICE.selector);
        new FundamentalStablecoinChainlinkOracle(address(underlyingOracle8), -1);
    }

    function test_constructor_revertsOnExtremeNegativeMinPegPrice() public {
        vm.expectRevert(FundamentalStablecoinChainlinkOracle.INVALID_MIN_PEG_PRICE.selector);
        new FundamentalStablecoinChainlinkOracle(address(underlyingOracle8), type(int256).min);
    }

    function test_constructor_revertsOnMinPegPriceEqualToONE() public {
        // The valid range is (0, ONE_QUOTE_ASSET) — strict on both sides; ONE_QUOTE_ASSET itself must revert.
        vm.expectRevert(FundamentalStablecoinChainlinkOracle.INVALID_MIN_PEG_PRICE.selector);
        new FundamentalStablecoinChainlinkOracle(address(underlyingOracle8), ONE_8);
    }

    function test_constructor_revertsOnMinPegPriceAboveONE() public {
        vm.expectRevert(FundamentalStablecoinChainlinkOracle.INVALID_MIN_PEG_PRICE.selector);
        new FundamentalStablecoinChainlinkOracle(address(underlyingOracle8), ONE_8 + 1);
    }

    function test_constructor_revertsOnExtremeMinPegPrice() public {
        vm.expectRevert(FundamentalStablecoinChainlinkOracle.INVALID_MIN_PEG_PRICE.selector);
        new FundamentalStablecoinChainlinkOracle(address(underlyingOracle8), type(int256).max);
    }

    function test_constructor_acceptsLowestValidMinPegPrice() public {
        FundamentalStablecoinChainlinkOracle wrapper = new FundamentalStablecoinChainlinkOracle(address(underlyingOracle8), 1);
        assertEq(wrapper.MIN_PEG_PRICE(), 1);
    }

    function test_constructor_acceptsHighestValidMinPegPrice() public {
        // Highest valid is ONE_QUOTE_ASSET − 1 wei (strictly less than ONE_QUOTE_ASSET).
        FundamentalStablecoinChainlinkOracle wrapper = new FundamentalStablecoinChainlinkOracle(address(underlyingOracle8), ONE_8 - 1);
        assertEq(wrapper.MIN_PEG_PRICE(), ONE_8 - 1);
    }

    function test_constructor_revertsWhenUnderlyingDecimalsReverts() public {
        // The constructor reads the underlying's decimals to compute ONE_QUOTE_ASSET; a failure must propagate.
        address brokenOracle = makeAddr("broken");
        vm.mockCallRevert(brokenOracle, abi.encodeWithSelector(AggregatorV3Interface.decimals.selector), "broken");
        vm.expectRevert();
        new FundamentalStablecoinChainlinkOracle(brokenOracle, 1);
    }

    function test_constructor_validForLargeDecimalUnderlying() public {
        // Some non-Chainlink oracles return decimals > 18. ONE_QUOTE_ASSET must scale accordingly.
        MockChainlinkOracle highDecOracle = new MockChainlinkOracle(24, "FOO / USD");
        int256 expectedOne = int256(10 ** 24);
        FundamentalStablecoinChainlinkOracle wrapper = new FundamentalStablecoinChainlinkOracle(address(highDecOracle), expectedOne - 1);
        assertEq(wrapper.ONE_QUOTE_ASSET(), expectedOne);
        assertEq(wrapper.MIN_PEG_PRICE(), expectedOne - 1);
    }

    /// =====================================================================
    /// METADATA: decimals / version / description
    /// =====================================================================

    function test_decimals_matchesUnderlying() public view {
        assertEq(wrapper8.decimals(), 8);
        assertEq(wrapper18.decimals(), 18);
    }

    function test_decimals_reflectsLiveUnderlyingValue() public view {
        // decimals() is forwarded at every call rather than cached; the immutable ONE_QUOTE_ASSET is the only fixed snapshot.
        assertEq(wrapper8.decimals(), underlyingOracle8.decimals());
    }

    function test_version_isOne() public view {
        assertEq(wrapper8.version(), 1);
        assertEq(wrapper18.version(), 1);
    }

    function test_description_8DecRendersFixedPointMinPegPrice() public view {
        // 0.999 in 8-decimal precision renders as "0.99900000" with full-precision trailing zeros.
        assertEq(wrapper8.description(), "USDC / USD (Royco fundamental stablecoin peg wrapper: prices at or above 0.99900000 are reported as 1 quote asset)");
    }

    function test_description_18DecRendersFixedPointMinPegPrice() public view {
        // 0.999 in 18-decimal precision renders with 18 fractional digits.
        assertEq(
            wrapper18.description(),
            "DAI / USD (Royco fundamental stablecoin peg wrapper: prices at or above 0.999000000000000000 are reported as 1 quote asset)"
        );
    }

    function test_description_reflectsLiveUnderlyingDescription() public {
        // description() is forwarded at every call; updates to the underlying surface in the wrapper output.
        underlyingOracle8.setDescription("USDT / USD");
        assertEq(wrapper8.description(), "USDT / USD (Royco fundamental stablecoin peg wrapper: prices at or above 0.99900000 are reported as 1 quote asset)");
    }

    function test_description_atOneWeiFormatsWithLeadingZeroes() public {
        // 1 wei in 8-dec precision renders as "0.00000001"; the formatter pads leading fractional zeros to fill _decimals digits.
        FundamentalStablecoinChainlinkOracle wrapper = new FundamentalStablecoinChainlinkOracle(address(underlyingOracle8), 1);
        assertEq(wrapper.description(), "USDC / USD (Royco fundamental stablecoin peg wrapper: prices at or above 0.00000001 are reported as 1 quote asset)");
    }

    function test_description_at18DecOneWeiFormatsWith17LeadingZeroes() public {
        FundamentalStablecoinChainlinkOracle wrapper = new FundamentalStablecoinChainlinkOracle(address(underlyingOracle18), 1);
        assertEq(
            wrapper.description(), "DAI / USD (Royco fundamental stablecoin peg wrapper: prices at or above 0.000000000000000001 are reported as 1 quote asset)"
        );
    }

    function test_description_atHighestValidMinPegPriceRendersOneWeiBelowOne() public {
        // The valid range is exclusive of ONE_QUOTE_ASSET, so the highest renderable threshold is ONE - 1 wei → "0.99999999".
        FundamentalStablecoinChainlinkOracle wrapper = new FundamentalStablecoinChainlinkOracle(address(underlyingOracle8), ONE_8 - 1);
        assertEq(wrapper.description(), "USDC / USD (Royco fundamental stablecoin peg wrapper: prices at or above 0.99999999 are reported as 1 quote asset)");
    }

    function test_description_propagatesUnderlyingDescriptionRevert() public {
        vm.mockCallRevert(address(underlyingOracle8), abi.encodeWithSelector(AggregatorV3Interface.description.selector), "desc failed");
        vm.expectRevert(bytes("desc failed"));
        wrapper8.description();
    }

    /// =====================================================================
    /// latestRoundData — anchoring semantics
    /// =====================================================================

    function test_latestRoundData_atMinPegPriceAnchorsToOne() public {
        underlyingOracle8.setAnswer(MIN_PEG_8);
        (, int256 answer,,,) = wrapper8.latestRoundData();
        assertEq(answer, ONE_8);
    }

    function test_latestRoundData_betweenMinPegAndOneAnchorsToOne() public {
        underlyingOracle8.setAnswer(0.9995e8);
        (, int256 answer,,,) = wrapper8.latestRoundData();
        assertEq(answer, ONE_8);
    }

    function test_latestRoundData_atExactlyOneAnchoredToOne() public {
        // No-op anchoring: ONE >= MIN_PEG_PRICE so it goes through the assignment with an unchanged result.
        underlyingOracle8.setAnswer(ONE_8);
        (, int256 answer,,,) = wrapper8.latestRoundData();
        assertEq(answer, ONE_8);
    }

    function test_latestRoundData_aboveOneCapsAtOne() public {
        // Stablecoin oracle reports 1.001 → wrapper caps at 1.00 (the same anchor rule subsumes the cap)
        underlyingOracle8.setAnswer(1.001e8);
        (, int256 answer,,,) = wrapper8.latestRoundData();
        assertEq(answer, ONE_8);
    }

    function test_latestRoundData_extremeAboveOneStillCapsAtOne() public {
        // Pathological reading from a malformed feed still caps to 1.00
        underlyingOracle8.setAnswer(type(int256).max);
        (, int256 answer,,,) = wrapper8.latestRoundData();
        assertEq(answer, ONE_8);
    }

    function test_latestRoundData_belowMinPegForwardsUnchanged() public {
        // Real depeg: 0.998 < 0.999 → forwarded unchanged
        underlyingOracle8.setAnswer(0.998e8);
        (, int256 answer,,,) = wrapper8.latestRoundData();
        assertEq(answer, 0.998e8);
    }

    function test_latestRoundData_oneWeiBelowMinPegForwardsUnchanged() public {
        // Boundary: MIN_PEG_PRICE − 1 wei is the first value below the peg threshold and must pass through.
        underlyingOracle8.setAnswer(MIN_PEG_8 - 1);
        (, int256 answer,,,) = wrapper8.latestRoundData();
        assertEq(answer, MIN_PEG_8 - 1);
    }

    function test_latestRoundData_zeroAnswerForwardsUnchanged() public {
        // Documents behavior: the wrapper does NOT clamp a zero reading to the peg.
        // Zero is well below MIN_PEG_PRICE and represents either a complete depeg or a malfunctioning feed; downstream consumers must handle it.
        underlyingOracle8.setAnswer(0);
        (, int256 answer,,,) = wrapper8.latestRoundData();
        assertEq(answer, 0);
    }

    function test_latestRoundData_negativeAnswerForwardsUnchanged() public {
        // Documents behavior: the wrapper does NOT reject negative readings.
        // The kernel's Chainlink quoter independently asserts `answer > 0` at consumption.
        underlyingOracle8.setAnswer(-1);
        (, int256 answer,,,) = wrapper8.latestRoundData();
        assertEq(answer, -1);
    }

    function test_latestRoundData_extremeNegativeForwardsUnchanged() public {
        underlyingOracle8.setAnswer(type(int256).min);
        (, int256 answer,,,) = wrapper8.latestRoundData();
        assertEq(answer, type(int256).min);
    }

    /// =====================================================================
    /// latestRoundData — metadata forwarding
    /// =====================================================================

    function test_latestRoundData_forwardsRoundId() public {
        underlyingOracle8.setRound(42);
        underlyingOracle8.setAnswer(0.998e8);
        (uint80 roundId,,,, uint80 answeredInRound) = wrapper8.latestRoundData();
        assertEq(roundId, 42);
        assertEq(answeredInRound, 42);
    }

    function test_latestRoundData_forwardsTimestamps() public {
        underlyingOracle8.setTimestamps(1000, 2000);
        (,, uint256 startedAt, uint256 updatedAt,) = wrapper8.latestRoundData();
        assertEq(startedAt, 1000);
        assertEq(updatedAt, 2000);
    }

    function test_latestRoundData_metadataIndependentOfAnchorPath() public {
        // Round-id and timestamp forwarding must work whether the answer is anchored or passed through.
        underlyingOracle8.setRound(7);
        underlyingOracle8.setTimestamps(500, 999);

        underlyingOracle8.setAnswer(MIN_PEG_8);
        (uint80 r1,, uint256 s1, uint256 u1, uint80 ar1) = wrapper8.latestRoundData();
        assertEq(r1, 7);
        assertEq(s1, 500);
        assertEq(u1, 999);
        assertEq(ar1, 7);

        underlyingOracle8.setAnswer(0.9e8);
        (uint80 r2,, uint256 s2, uint256 u2, uint80 ar2) = wrapper8.latestRoundData();
        assertEq(r2, 7);
        assertEq(s2, 500);
        assertEq(u2, 999);
        assertEq(ar2, 7);
    }

    function test_latestRoundData_propagatesUnderlyingRevert() public {
        vm.mockCallRevert(address(underlyingOracle8), abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector), "downstream");
        vm.expectRevert(bytes("downstream"));
        wrapper8.latestRoundData();
    }

    /// =====================================================================
    /// getRoundData — anchoring semantics
    /// =====================================================================

    function test_getRoundData_atMinPegPriceAnchorsToOne() public {
        underlyingOracle8.setAnswer(MIN_PEG_8);
        (, int256 answer,,,) = wrapper8.getRoundData(7);
        assertEq(answer, ONE_8);
    }

    function test_getRoundData_betweenMinPegAndOneAnchorsToOne() public {
        underlyingOracle8.setAnswer(0.9999e8);
        (, int256 answer,,,) = wrapper8.getRoundData(7);
        assertEq(answer, ONE_8);
    }

    function test_getRoundData_capsAboveOne() public {
        underlyingOracle8.setAnswer(1.5e8);
        (, int256 answer,,,) = wrapper8.getRoundData(7);
        assertEq(answer, ONE_8);
    }

    function test_getRoundData_forwardsBelowMinPegPrice() public {
        underlyingOracle8.setAnswer(0.95e8);
        (, int256 answer,,,) = wrapper8.getRoundData(7);
        assertEq(answer, 0.95e8);
    }

    function test_getRoundData_forwardsRequestedRoundIdToUnderlying() public {
        // The wrapper must forward the requested round ID without rewriting it; the mock echoes whatever it receives.
        underlyingOracle8.setAnswer(0.998e8);
        (uint80 roundId,,,, uint80 answeredInRound) = wrapper8.getRoundData(99);
        assertEq(roundId, 99);
        assertEq(answeredInRound, 99);
    }

    function test_getRoundData_forwardsTimestamps() public {
        underlyingOracle8.setTimestamps(1234, 5678);
        underlyingOracle8.setAnswer(MIN_PEG_8);
        (,, uint256 startedAt, uint256 updatedAt,) = wrapper8.getRoundData(11);
        assertEq(startedAt, 1234);
        assertEq(updatedAt, 5678);
    }

    function test_getRoundData_propagatesUnderlyingRevert() public {
        vm.mockCallRevert(address(underlyingOracle8), abi.encodeWithSelector(AggregatorV3Interface.getRoundData.selector, uint80(5)), "no data");
        vm.expectRevert(bytes("no data"));
        wrapper8.getRoundData(5);
    }

    /// =====================================================================
    /// 18-DECIMAL ORACLE PARITY
    /// =====================================================================

    function test_18DecOracle_anchorsAtMinPegPrice() public {
        underlyingOracle18.setAnswer(MIN_PEG_18);
        (, int256 answer,,,) = wrapper18.latestRoundData();
        assertEq(answer, ONE_18);
    }

    function test_18DecOracle_capsAboveOne() public {
        underlyingOracle18.setAnswer(1.05e18);
        (, int256 answer,,,) = wrapper18.latestRoundData();
        assertEq(answer, ONE_18);
    }

    function test_18DecOracle_forwardsDepeg() public {
        underlyingOracle18.setAnswer(0.99e18);
        (, int256 answer,,,) = wrapper18.latestRoundData();
        assertEq(answer, 0.99e18);
    }

    /// =====================================================================
    /// FUZZ
    /// =====================================================================

    /// @dev Anchoring is a pure function of the underlying answer's relation to MIN_PEG_PRICE.
    function testFuzz_latestRoundData_anchoringIsPureFunctionOfAnswerVsThreshold(int256 _answer) public {
        underlyingOracle8.setAnswer(_answer);
        (, int256 wrappedAnswer,,,) = wrapper8.latestRoundData();
        if (_answer >= MIN_PEG_8) {
            assertEq(wrappedAnswer, ONE_8);
        } else {
            assertEq(wrappedAnswer, _answer);
        }
    }

    /// @dev Same property holds for getRoundData over any round ID.
    function testFuzz_getRoundData_anchoringIsPureFunctionOfAnswerVsThreshold(int256 _answer, uint80 _roundId) public {
        underlyingOracle8.setAnswer(_answer);
        (, int256 wrappedAnswer,,,) = wrapper8.getRoundData(_roundId);
        if (_answer >= MIN_PEG_8) {
            assertEq(wrappedAnswer, ONE_8);
        } else {
            assertEq(wrappedAnswer, _answer);
        }
    }

    /// @dev Any minPegPrice in (0, ONE_QUOTE_ASSET) is accepted by the constructor and stored unchanged.
    function testFuzz_constructor_acceptsAnyValidMinPegPrice(int256 _minPegPrice) public {
        _minPegPrice = bound(_minPegPrice, 1, ONE_8 - 1);
        FundamentalStablecoinChainlinkOracle wrapper = new FundamentalStablecoinChainlinkOracle(address(underlyingOracle8), _minPegPrice);
        assertEq(wrapper.MIN_PEG_PRICE(), _minPegPrice);
        assertEq(wrapper.ONE_QUOTE_ASSET(), ONE_8);
    }

    /// @dev Any minPegPrice outside (0, ONE_QUOTE_ASSET) is rejected by the constructor.
    function testFuzz_constructor_rejectsOutOfRangeMinPegPrice(int256 _minPegPrice) public {
        vm.assume(_minPegPrice <= 0 || _minPegPrice >= ONE_8);
        vm.expectRevert(FundamentalStablecoinChainlinkOracle.INVALID_MIN_PEG_PRICE.selector);
        new FundamentalStablecoinChainlinkOracle(address(underlyingOracle8), _minPegPrice);
    }

    /// @dev Anchoring threshold tracks the configured minPegPrice across the full valid range.
    function testFuzz_anchoringThresholdTracksConfiguredMinPegPrice(int256 _minPegPrice, int256 _answer) public {
        _minPegPrice = bound(_minPegPrice, 1, ONE_8 - 1);
        FundamentalStablecoinChainlinkOracle wrapper = new FundamentalStablecoinChainlinkOracle(address(underlyingOracle8), _minPegPrice);

        underlyingOracle8.setAnswer(_answer);
        (, int256 wrappedAnswer,,,) = wrapper.latestRoundData();
        if (_answer >= _minPegPrice) {
            assertEq(wrappedAnswer, ONE_8);
        } else {
            assertEq(wrappedAnswer, _answer);
        }
    }

    /// @dev Calling latestRoundData twice in the same block with constant underlying state is a pure function.
    function testFuzz_latestRoundData_idempotentAcrossCallsUnderConstantState(int256 _answer) public {
        underlyingOracle8.setAnswer(_answer);
        (uint80 r1, int256 a1, uint256 s1, uint256 u1, uint80 ar1) = wrapper8.latestRoundData();
        (uint80 r2, int256 a2, uint256 s2, uint256 u2, uint80 ar2) = wrapper8.latestRoundData();

        assertEq(r1, r2);
        assertEq(a1, a2);
        assertEq(s1, s2);
        assertEq(u1, u2);
        assertEq(ar1, ar2);
    }
}
