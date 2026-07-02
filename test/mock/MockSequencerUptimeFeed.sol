// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AggregatorV3Interface } from "../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";

/// @title MockSequencerUptimeFeed
/// @notice Minimal mock of a Chainlink L2 sequencer uptime feed for tests
/// @dev An answer of 0 indicates the sequencer is up, and 1 indicates it is down. `startedAt` is the timestamp at which
///      the sequencer status last changed (i.e. when it was last restored).
contract MockSequencerUptimeFeed is AggregatorV3Interface {
    /// @dev The current sequencer status (0 = up, 1 = down)
    int256 internal status;

    /// @dev The timestamp at which the sequencer status last changed
    uint256 internal statusStartedAt;

    /// @notice Constructs the mock sequencer uptime feed
    /// @param _status The initial sequencer status (0 = up, 1 = down)
    /// @param _startedAt The timestamp at which the sequencer status last changed
    constructor(int256 _status, uint256 _startedAt) {
        status = _status;
        statusStartedAt = _startedAt;
    }

    /// @notice Sets the sequencer status and the timestamp at which it last changed
    /// @param _status The new sequencer status (0 = up, 1 = down)
    /// @param _startedAt The timestamp at which the sequencer status last changed
    function setStatus(int256 _status, uint256 _startedAt) external {
        status = _status;
        statusStartedAt = _startedAt;
    }

    /// @inheritdoc AggregatorV3Interface
    function decimals() external pure override(AggregatorV3Interface) returns (uint8) {
        return 0;
    }

    /// @inheritdoc AggregatorV3Interface
    function description() external pure override(AggregatorV3Interface) returns (string memory) {
        return "Mock L2 Sequencer Uptime Feed";
    }

    /// @inheritdoc AggregatorV3Interface
    function version() external pure override(AggregatorV3Interface) returns (uint256) {
        return 1;
    }

    /// @inheritdoc AggregatorV3Interface
    function getRoundData(uint80)
        external
        view
        override(AggregatorV3Interface)
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, status, statusStartedAt, statusStartedAt, 1);
    }

    /// @inheritdoc AggregatorV3Interface
    function latestRoundData()
        external
        view
        override(AggregatorV3Interface)
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, status, statusStartedAt, statusStartedAt, 1);
    }
}
