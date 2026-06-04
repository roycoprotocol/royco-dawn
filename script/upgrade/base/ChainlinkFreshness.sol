// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Vm } from "lib/forge-std/src/Vm.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

import { AggregatorV3Interface } from "../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";

/**
 * @title ChainlinkFreshness
 * @notice Library for keeping Chainlink-style aggregators (`latestRoundData()`) "fresh" across the
 *         simulated 2-day warp inside the upgrade scripts.
 * @dev Usage:
 *        bytes[] memory pre = ChainlinkFreshness.capture(oracles);
 *        vm.warp(...);
 *        ChainlinkFreshness.mockFresh(oracles, pre);
 *
 *      `capture` reads `latestRoundData()` for each oracle. `mockFresh` replays the captured
 *      `answer` (and round IDs) but rewrites `updatedAt` to `block.timestamp` so any downstream
 *      staleness check passes.
 *
 *      Lives in a library to avoid loading the chainlink helpers into the main inheritance
 *      hierarchy of `UpgradeBase`, which was tipping the via-IR stack-too-deep budget.
 */
library ChainlinkFreshness {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function capture(address[] memory oracles) internal view returns (bytes[] memory captured) {
        captured = new bytes[](oracles.length);
        for (uint256 i = 0; i < oracles.length; i++) {
            captured[i] = _captureOne(oracles[i]);
        }
    }

    function mockFresh(address[] memory oracles, bytes[] memory captured) internal {
        for (uint256 i = 0; i < oracles.length; i++) {
            _mockOne(oracles[i], captured[i]);
        }
    }

    function _captureOne(address oracle) private view returns (bytes memory) {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = AggregatorV3Interface(oracle).latestRoundData();
        return abi.encode(roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    function _mockOne(address oracle, bytes memory captured) private {
        (uint80 roundId, int256 answer, uint256 startedAt,, uint80 answeredInRound) = abi.decode(captured, (uint80, int256, uint256, uint256, uint80));
        vm.mockCall(
            oracle, abi.encodeCall(AggregatorV3Interface.latestRoundData, ()), abi.encode(roundId, answer, startedAt, vm.getBlockTimestamp(), answeredInRound)
        );
        console2.log("  [MOCK] Refreshed Chainlink oracle:", oracle);
    }
}
