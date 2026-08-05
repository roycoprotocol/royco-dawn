// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AssetClaims, IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { AggregatorV3Interface } from "../../interfaces/external/chainlink/AggregatorV3Interface.sol";
import { WAD, WAD_DECIMALS } from "../../libraries/Constants.sol";
import { toInt256 } from "../../libraries/Units.sol";

/**
 * @title RoycoTrancheChainlinkOracle
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice A Chainlink compatible oracle exposing the price of 1 share of a Royco tranche in its NAV units (USD, BTC, ETH, etc.)
 */
contract RoycoTrancheChainlinkOracle is AggregatorV3Interface {
    /// @dev Calldata for querying the asset claims (share price breakdown) of 1 Royco tranche share
    /// @dev 1 whole share for all Royco tranches == 1e18 == WAD
    bytes private constant SHARE_PRICE_QUERY = abi.encodeCall(IRoycoVaultTranche.convertToAssets, (WAD));

    /// @notice The address of the Royco tranche that this oracle prices 1 share for in NAV units (USD, BTC, ETH, etc.)
    address public immutable ROYCO_TRANCHE;

    /// @notice Constructs the share price oracle for the specified Royco tranche
    /// @param _roycoTranche The Royco tranche that this oracle will be configured for
    constructor(address _roycoTranche) {
        ROYCO_TRANCHE = _roycoTranche;
    }

    /// @inheritdoc AggregatorV3Interface
    /// @notice All Royco tranches use 18 (WAD) decimals of precision for their NAV units
    function decimals() external pure override(AggregatorV3Interface) returns (uint8) {
        return uint8(WAD_DECIMALS);
    }

    /// @inheritdoc AggregatorV3Interface
    function description() external view override(AggregatorV3Interface) returns (string memory) {
        return string(abi.encodePacked("Returns the price of 1 share of ", IRoycoVaultTranche(ROYCO_TRANCHE).name(), " in its NAV units (USD, BTC, ETH, etc.)"));
    }

    /// @inheritdoc AggregatorV3Interface
    function version() external pure override(AggregatorV3Interface) returns (uint256) {
        return 1;
    }

    /// @inheritdoc AggregatorV3Interface
    /// @notice The specified round ID must be 1 for this oracle
    function getRoundData(uint80 _roundId)
        external
        view
        override(AggregatorV3Interface)
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        // Revert if no data is available for the specified round ID
        require(_roundId == 1, "No data present");
        return latestRoundData();
    }

    /// @inheritdoc AggregatorV3Interface
    /// @notice The price returned is the price of 1 share of the Royco tranche in its NAV units (USD, BTC, ETH, etc.)
    function latestRoundData()
        public
        view
        override(AggregatorV3Interface)
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        // Get the asset claims tied to 1 tranche share (1e18 == WAD)
        (bool success, bytes memory returnData) = ROYCO_TRANCHE.staticcall(SHARE_PRICE_QUERY);
        // If the call reverts downstream, there is no price available in the latest round
        if (!success) revert("No data present");
        // Return the NAV of the asset claims for 1 tranche share
        return (1, toInt256(abi.decode(returnData, (AssetClaims)).nav), block.timestamp, block.timestamp, 1);
    }
}
