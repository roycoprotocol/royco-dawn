// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDuskKernel } from "../../interfaces/IRoycoDuskKernel.sol";
import { RoycoDuskKernel } from "../base/RoycoDuskKernel.sol";
import {
    ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_Quoter
} from "../base/quoter/dusk/ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_Quoter.sol";

/**
 * @title ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_Kernel
 * @author Waymont
 * @notice Dusk kernel where the senior tranche transfers in an asset priced via a Chainlink oracle, and the junior tranche transfers in Balancer V3 BPTs for a pool whose constituent tokens are the senior tranche shares and a Chainlink-priced quote asset
 * @dev Senior side: a single Chainlink (compatible) oracle prices the senior tranche unit directly into NAV units (admin override permitted)
 * @dev Junior side: BPT pro-rata claim on the pool's constituent tokens (ST shares + quote asset), with the quote asset priced via a single Chainlink (compatible) oracle
 */
contract ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_Kernel is ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_Quoter {
    /// @notice Constructs the kernel state
    /// @param _params The standard construction parameters for the Royco Dusk kernel
    constructor(RoycoDuskKernelConstructionParams memory _params) RoycoDuskKernel(_params) { }

    /**
     * @notice Initializes the Royco Kernel
     * @param _params The standard initialization parameters for the Royco Dusk Kernel
     * @param _seniorAssetOracle The Chainlink (compatible) oracle pricing the senior tranche asset in NAV units
     * @param _seniorAssetStalenessThresholdSeconds The staleness threshold in seconds for the senior-side oracle
     * @param _quoteAssetOracle The Chainlink (compatible) oracle pricing the quote asset in NAV units
     * @param _quoteAssetStalenessThresholdSeconds The staleness threshold in seconds for the quote-side oracle
     */
    function initialize(
        IRoycoDuskKernel.RoycoDuskKernelInitParams calldata _params,
        address _seniorAssetOracle,
        uint48 _seniorAssetStalenessThresholdSeconds,
        address _quoteAssetOracle,
        uint48 _quoteAssetStalenessThresholdSeconds
    )
        external
        initializer
    {
        // Initialize the base Dusk kernel state
        __RoycoDuskKernel_init(_params);
        // Initialize the combined Dusk quoter for both the senior and junior tranche asset models
        __ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_Quoter_init(
            _seniorAssetOracle, _seniorAssetStalenessThresholdSeconds, _quoteAssetOracle, _quoteAssetStalenessThresholdSeconds
        );
    }
}
