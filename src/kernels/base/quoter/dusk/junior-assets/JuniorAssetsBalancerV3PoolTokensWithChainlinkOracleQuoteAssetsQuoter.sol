// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoDuskKernel } from "../../../RoycoDuskKernel.sol";
import { JuniorAssetsBalancerV3PoolTokensQuoter } from "./liquidity-position/balancer-v3/JuniorAssetsBalancerV3PoolTokensQuoter.sol";
import { QuoteAssetsChainlinkOracleQuoter } from "./quote-assets/base/QuoteAssetsChainlinkOracleQuoter.sol";

/**
 * @title JuniorAssetsBalancerV3PoolTokensWithChainlinkOracleQuoteAssetsQuoter
 * @notice Composes the Dusk junior-side asset model for kernels whose junior tranche unit is a Balancer V3 BPT for a pool whose constituent tokens are the senior tranche shares and a Chainlink-priced quote asset
 * @dev JT (BPT) pricing comes from the Balancer V3 pool's pro-rata constituent claim via JuniorAssetsBalancerV3PoolTokensQuoter
 * @dev Quote asset pricing is via a single Chainlink (compatible) oracle that prices the quote asset directly in NAV units
 */
abstract contract JuniorAssetsBalancerV3PoolTokensWithChainlinkOracleQuoteAssetsQuoter is
    JuniorAssetsBalancerV3PoolTokensQuoter,
    QuoteAssetsChainlinkOracleQuoter
{
    /**
     * @notice Initializes the combined junior-side asset model
     * @dev The BPT side has no initializer; its configuration is set in JuniorAssetsBalancerV3PoolTokensQuoter's constructor
     * @param _quoteAssetOracle The Chainlink (compatible) oracle pricing the quote asset in NAV units
     * @param _quoteAssetStalenessThresholdSeconds The staleness threshold in seconds for the quote-side oracle
     */
    function __JuniorAssetsBalancerV3PoolTokensWithChainlinkOracleQuoteAssetsQuoter_init(
        address _quoteAssetOracle,
        uint48 _quoteAssetStalenessThresholdSeconds
    )
        internal
        onlyInitializing
    {
        __QuoteAssetsChainlinkOracleQuoter_init_unchained(_quoteAssetOracle, _quoteAssetStalenessThresholdSeconds);
    }

    /// @inheritdoc RoycoDuskKernel
    /// @dev Delegates cache initialization to the inherited overrides in QuoteAssetsChainlinkOracleQuoter and RoycoDuskKernel
    function _initializeQuoterCache() internal virtual override(QuoteAssetsChainlinkOracleQuoter, RoycoDuskKernel) {
        super._initializeQuoterCache();
    }

    /// @inheritdoc RoycoDuskKernel
    /// @dev Delegates cache teardown to the inherited overrides in QuoteAssetsChainlinkOracleQuoter and RoycoDuskKernel
    function _clearQuoterCache() internal virtual override(QuoteAssetsChainlinkOracleQuoter, RoycoDuskKernel) {
        super._clearQuoterCache();
    }
}
