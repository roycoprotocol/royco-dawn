// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Strings } from "../../../lib/openzeppelin-contracts/contracts/utils/Strings.sol";
import { AggregatorV3Interface } from "../../interfaces/external/chainlink/AggregatorV3Interface.sol";

/**
 * @title FundamentalStablecoinChainlinkOracle
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice A Chainlink compatible oracle that wraps an underlying stablecoin Chainlink (compatible) oracle and anchors its price to the fundamental peg of 1 quote asset
 * @dev Any reported price at or above the configured minimum peg price is anchored to exactly 1 quote asset in the underlying oracle's precision
 * @dev Any reported price below the configured minimum peg price is forwarded unchanged, surfacing real depeg events
 */
contract FundamentalStablecoinChainlinkOracle is AggregatorV3Interface {
    /// @notice The address of the underlying stablecoin's Chainlink (compatible) oracle that this oracle wraps
    address public immutable ORACLE;

    /// @notice The minimum price at which the underlying stablecoin is considered pegged to 1 quote asset, denominated in the underlying oracle's precision
    int256 public immutable MIN_PEG_PRICE;

    /// @notice The representation of 1 quote asset in the underlying oracle's precision
    int256 public immutable ONE_QUOTE_ASSET;

    /// @notice Thrown when the configured minimum peg price is outside the valid range (0, ONE_QUOTE_ASSET)
    error INVALID_MIN_PEG_PRICE();

    /// @notice Constructs the fundamental peg oracle for the specified stablecoin Chainlink (compatible) oracle
    /// @param _oracle The underlying stablecoin Chainlink (compatible) oracle to wrap
    /// @param _minPegPrice The minimum price at which the underlying stablecoin is considered pegged to 1 quote asset, denominated in the underlying oracle's precision
    constructor(address _oracle, int256 _minPegPrice) {
        // Resolve the underlying oracle's representation of 1 quote asset from its decimals
        ONE_QUOTE_ASSET = int256(10 ** AggregatorV3Interface(_oracle).decimals());
        // The minimum peg price must be a valid threshold in (0, ONE_QUOTE_ASSET)
        require(_minPegPrice > 0 && _minPegPrice < ONE_QUOTE_ASSET, INVALID_MIN_PEG_PRICE());

        // Set the rest of the immutable state
        ORACLE = _oracle;
        MIN_PEG_PRICE = _minPegPrice;
    }

    /// @inheritdoc AggregatorV3Interface
    /// @notice The number of decimals matches the precision of the underlying oracle
    function decimals() external view override(AggregatorV3Interface) returns (uint8) {
        return AggregatorV3Interface(ORACLE).decimals();
    }

    /// @inheritdoc AggregatorV3Interface
    /// @notice Composes the underlying oracle's description with a Royco-specific suffix indicating the fundamental peg anchoring behavior and the configured minimum peg price
    function description() external view override(AggregatorV3Interface) returns (string memory) {
        return string(
            abi.encodePacked(
                AggregatorV3Interface(ORACLE).description(),
                " (Royco fundamental stablecoin peg wrapper: prices at or above ",
                _formatFixedPoint(uint256(MIN_PEG_PRICE), AggregatorV3Interface(ORACLE).decimals()),
                " are reported as 1 quote asset)"
            )
        );
    }

    /// @inheritdoc AggregatorV3Interface
    /// @notice The version matches the version of the underlying oracle
    function version() external view override(AggregatorV3Interface) returns (uint256) {
        return AggregatorV3Interface(ORACLE).version();
    }

    /// @inheritdoc AggregatorV3Interface
    /// @notice The price returned is the underlying oracle's historical price for the specified round, anchored to 1 quote asset if at or above the minimum peg price
    function getRoundData(uint80 _roundId)
        external
        view
        override(AggregatorV3Interface)
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        // Forward the historical round query to the underlying oracle
        (roundId, answer, startedAt, updatedAt, answeredInRound) = AggregatorV3Interface(ORACLE).getRoundData(_roundId);
        // Anchor any price at or above the minimum peg price to exactly 1 quote asset
        if (answer >= MIN_PEG_PRICE) answer = ONE_QUOTE_ASSET;
    }

    /// @inheritdoc AggregatorV3Interface
    /// @notice The price returned is the underlying oracle's latest price, anchored to 1 quote asset if at or above the minimum peg price
    function latestRoundData()
        external
        view
        override(AggregatorV3Interface)
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        // Forward the latest round query to the underlying oracle
        (roundId, answer, startedAt, updatedAt, answeredInRound) = AggregatorV3Interface(ORACLE).latestRoundData();
        // Anchor any price at or above the minimum peg price to exactly 1 quote asset
        if (answer >= MIN_PEG_PRICE) answer = ONE_QUOTE_ASSET;
    }

    /**
     * @notice Formats an unsigned integer as a fixed-point decimal string with the specified number of fractional digits
     * @param _value The unsigned integer value to format
     * @param _decimals The number of fractional digits to render after the decimal point
     * @return The fixed-point decimal string representation of `_value`
     */
    function _formatFixedPoint(uint256 _value, uint8 _decimals) private pure returns (string memory) {
        // Decompose the value into integer and fractional parts at the specified precision
        uint256 one = 10 ** _decimals;
        uint256 integerPart = _value / one;
        uint256 fractionalPart = _value % one;

        // Build the fractional component with leading zeros to fill the specified number of digits
        bytes memory fractionalDigits = new bytes(_decimals);
        for (uint8 i = _decimals; i > 0; --i) {
            fractionalDigits[i - 1] = bytes1(uint8(48 + (fractionalPart % 10)));
            fractionalPart /= 10;
        }

        // Compose the integer and fractional components separated by a decimal point
        return string(abi.encodePacked(Strings.toString(integerPart), ".", fractionalDigits));
    }
}
