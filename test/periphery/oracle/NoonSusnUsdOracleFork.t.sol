// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AggregatorV3Interface } from "../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import { Test } from "lib/forge-std/src/Test.sol";

/// @dev Minimal view of Compound's `MultiplicativePriceFeed`, extending the Chainlink read surface with the
///      public immutables the contract exposes. Used to validate an already-deployed instance.
interface IMultiplicativePriceFeed {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function priceFeedA() external view returns (address);
    function priceFeedB() external view returns (address);
    function combinedScale() external view returns (int256);
    function priceFeedScale() external view returns (int256);
    function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/**
 * @title NoonSusnUsdOracleForkTest
 * @notice Heavy fuzz + fork tests for the Noon **sUSN / USD** composite oracle on Base.
 *
 * @dev The oracle is Compound's audited `MultiplicativePriceFeed` composing two Base Chainlink-compatible
 *      (Stork-powered) feeds:  price(sUSN/USD) = price(sUSN/USN) * price(USN/USD).
 *
 *      This suite targets an **externally deployed** instance — comet is intentionally NOT part of this
 *      repo's build. Provide the deployed address and (optionally) a pinned fork block via env:
 *
 *          SUSN_USD_ORACLE=0x...  BASE_RPC_URL=<url>  [BASE_FORK_BLOCK=<n>]  \
 *              forge test --match-path test/periphery/oracle/NoonSusnUsdOracleFork.t.sol
 *
 *      or hard-code {DEPLOYED_ORACLE} below. Until an address is supplied the suite skips itself.
 *
 *      Expected deployment parameters (asserted by test_Live_Wiring):
 *          priceFeedA = sUSN/USN feed, priceFeedB = USN/USD feed, output decimals = 18, description "sUSN / USD".
 *      The A/B ordering matters because `latestRoundData` propagates round metadata from feed B only; the
 *      fuzz tests read the actual A/B/scales off the deployed contract so they stay correct either way.
 */
contract NoonSusnUsdOracleForkTest is Test {
    /// @dev Base Stork-powered Chainlink aggregator ports (both 18 decimals).
    address internal constant SUSN_USN_FEED = 0x907fb22C2DA56642F89702b0970a03ed13EbF136; // expected priceFeedA
    address internal constant USN_USD_FEED = 0x0e658Ea83d19e540a5b4cf6BC2A6093a55525561; // expected priceFeedB

    /// @dev The underlying feeds are 18-decimal; the deployed composite outputs 8 decimals.
    uint8 internal constant FEED_DECIMALS = 18;
    uint8 internal constant EXPECTED_DECIMALS = 8;
    string internal constant EXPECTED_DESCRIPTION = "snUSD / USD price feed";

    /// @dev The deployed MultiplicativePriceFeed on Base (8-decimal output). Override with env SUSN_USD_ORACLE.
    address internal constant DEPLOYED_ORACLE = 0x92B7E06b2C78Ac1dB619980D9a1448428112a376;

    /// @dev Fork block pinned at/after the oracle's deployment block (feeds live and fresh here).
    uint256 internal constant PINNED_FORK_BLOCK = 48_106_000;

    IMultiplicativePriceFeed internal oracle;
    address internal feedA;
    address internal feedB;
    int256 internal combinedScale;
    int256 internal priceFeedScale;

    function setUp() public {
        address deployed = vm.envOr("SUSN_USD_ORACLE", DEPLOYED_ORACLE);
        if (deployed == address(0)) {
            emit log("SUSN_USD_ORACLE not set and DEPLOYED_ORACLE unfilled - skipping. Deploy the oracle and provide its address.");
            vm.skip(true);
            return;
        }

        _forkBase();
        require(deployed.code.length > 0, "no code at oracle address on this fork block");

        oracle = IMultiplicativePriceFeed(deployed);
        // Read wiring off the deployed contract so the fuzz math stays correct regardless of A/B ordering.
        feedA = oracle.priceFeedA();
        feedB = oracle.priceFeedB();
        combinedScale = oracle.combinedScale();
        priceFeedScale = oracle.priceFeedScale();
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Deployment wiring
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice The externally-deployed instance matches the intended Noon configuration.
    function test_Live_Wiring() public view {
        assertEq(oracle.decimals(), EXPECTED_DECIMALS, "decimals");
        assertEq(oracle.description(), EXPECTED_DESCRIPTION, "description");
        assertEq(feedA, SUSN_USN_FEED, "priceFeedA = sUSN/USN");
        assertEq(feedB, USN_USD_FEED, "priceFeedB = USN/USD");
        // Both legs are 18-decimal => combinedScale 1e36; output 8 => priceFeedScale 1e8.
        assertEq(combinedScale, int256(10 ** uint256(FEED_DECIMALS + FEED_DECIMALS)), "combinedScale = 1e36");
        assertEq(priceFeedScale, int256(10 ** uint256(EXPECTED_DECIMALS)), "priceFeedScale = 1e8");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Live (un-mocked) fork behaviour
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Against the real on-chain feeds the composite equals the product of the two legs, sits in a
    ///         sane band (sUSN is yield-bearing, so > 1 USD), and inherits feed B's round metadata.
    function test_Live_ComposesTwoFeeds() public view {
        (, int256 aPrice,,,) = AggregatorV3Interface(feedA).latestRoundData();
        (uint80 bRound, int256 bPrice, uint256 bStarted, uint256 bUpdated, uint80 bAnswered) = AggregatorV3Interface(feedB).latestRoundData();

        int256 expected = aPrice * bPrice * priceFeedScale / combinedScale;

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = oracle.latestRoundData();

        assertEq(answer, expected, "composite == a*b scaled");
        // Decimal-agnostic sane band: sUSN is yield-bearing (> $1), so answer sits in ~[0.9, 5] * priceFeedScale.
        assertGt(answer, priceFeedScale * 9 / 10, "sUSN/USD implausibly low");
        assertLt(answer, priceFeedScale * 5, "sUSN/USD implausibly high");

        assertEq(roundId, bRound, "roundId from B");
        assertEq(startedAt, bStarted, "startedAt from B");
        assertEq(updatedAt, bUpdated, "updatedAt from B");
        assertEq(answeredInRound, bAnswered, "answeredInRound from B");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Fuzz: composition math against the deployed contract (feeds mocked)
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice For any positive fuzzed leg prices, the composite is the exact integer product/scale, and all
    ///         round metadata is propagated from feed B.
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_Composition(int256 aPrice, int256 bPrice, uint80 roundId, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) public {
        // Bound to positive, realistic ranges. Upper bound keeps a*b*priceFeedScale well within int256.
        aPrice = bound(aPrice, 1, 1e27);
        bPrice = bound(bPrice, 1, 1e27);

        _mockRound(feedA, 1, aPrice, 1, 1, 1);
        _mockRound(feedB, roundId, bPrice, startedAt, updatedAt, answeredInRound);

        int256 expected = aPrice * bPrice * priceFeedScale / combinedScale;

        (uint80 rId, int256 answer, uint256 sAt, uint256 uAt, uint80 aInRound) = oracle.latestRoundData();

        assertEq(answer, expected, "answer");
        assertEq(rId, roundId, "roundId from B");
        assertEq(sAt, startedAt, "startedAt from B");
        assertEq(uAt, updatedAt, "updatedAt from B");
        assertEq(aInRound, answeredInRound, "answeredInRound from B");
    }

    /// @notice If either leg is non-positive the composite answer is 0, but B's metadata is still returned.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_NonPositiveLegReturnsZero(int256 aPrice, int256 bPrice, bool killA) public {
        if (killA) {
            aPrice = bound(aPrice, type(int256).min / 1e18, 0); // <= 0
            bPrice = bound(bPrice, 1, 1e27);
        } else {
            aPrice = bound(aPrice, 1, 1e27);
            bPrice = bound(bPrice, type(int256).min / 1e18, 0); // <= 0
        }

        _mockRound(feedA, 1, aPrice, 1, 1, 1);
        _mockRound(feedB, 7, bPrice, 2, 3, 7);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = oracle.latestRoundData();

        assertEq(answer, 0, "non-positive leg => 0");
        assertEq(roundId, 7, "roundId from B");
        assertEq(startedAt, 2, "startedAt from B");
        assertEq(updatedAt, 3, "updatedAt from B");
        assertEq(answeredInRound, 7, "answeredInRound from B");
    }

    /// @notice The feed performs NO staleness check: a wildly stale `updatedAt` still yields a non-zero price
    ///         with the stale timestamp passed through. Documents that staleness gating must live in the
    ///         consumer (Royco's quoter), not the oracle, and guards against a silent-revert regression.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_NoStalenessGating(uint256 ageSeconds, int256 aPrice, int256 bPrice) public {
        // Realistic 18-decimal price band ($0.01 - $100) so the scaled product is non-zero.
        aPrice = bound(aPrice, 1e16, 1e20);
        bPrice = bound(bPrice, 1e16, 1e20);
        uint256 staleTs = block.timestamp - bound(ageSeconds, 1, block.timestamp - 1);

        _mockRound(feedA, 1, aPrice, staleTs, staleTs, 1);
        _mockRound(feedB, 1, bPrice, staleTs, staleTs, 1);

        (, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();
        assertGt(answer, 0, "stale-but-positive still priced");
        assertEq(updatedAt, staleTs, "stale timestamp passed through unchanged");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────────

    function _forkBase() internal {
        string memory rpc = vm.envString("BASE_RPC_URL");
        // Defaults to a pinned block at/after the oracle's deployment; override with BASE_FORK_BLOCK, or set it
        // to 0 to fork at latest.
        uint256 forkBlock = vm.envOr("BASE_FORK_BLOCK", PINNED_FORK_BLOCK);
        if (forkBlock == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, forkBlock);
        }
    }

    function _mockRound(address feed, uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) internal {
        vm.mockCall(
            feed, abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector), abi.encode(roundId, answer, startedAt, updatedAt, answeredInRound)
        );
    }
}
