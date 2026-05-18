// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { JuniorAssetsBalancerV3PoolTokensQuoter } from "./liquidity-position/JuniorAssetsBalancerV3PoolTokensQuoter.sol";
import { QuoteAssetsERC4626ToChainlinkOracleQuoter } from "./quote-assets/QuoteAssetsERC4626ToChainlinkOracleQuoter.sol";
import { QuoteAssetsOracleQuoter } from "./quote-assets/base/QuoteAssetsOracleQuoter.sol";
import { RoycoDuskKernel } from "../../../RoycoDuskKernel.sol";

/**
 * @title JuniorAssetsBalancerV3PoolTokensWithERC4626ChainlinkQuoteAssetsQuoter
 * @notice Composes the Dusk junior-side asset model for kernels whose junior tranche unit is a Balancer V3 BPT for a pool with senior tranche shares and the kernel's quote asset as its constituent tokens, where the quote asset is an ERC4626 vault share
 * @dev JT (BPT) pricing comes from the Balancer V3 pool's pro-rata constituent claim via JuniorAssetsBalancerV3PoolTokensQuoter
 * @dev Quote asset pricing is a two-step conversion: ERC4626 share -> base asset via convertToAssets, base asset -> NAV via a Chainlink (compatible) oracle (with admin override)
 * @dev Use case: JT is the BPT for a Balancer V3 pool whose constituent tokens are the senior tranche shares and sNUSD (Quote unit), quote-side NAV via convertToAssets + Redstone fundamental price feed
 */
abstract contract JuniorAssetsBalancerV3PoolTokensWithERC4626ChainlinkQuoteAssetsQuoter is
    JuniorAssetsBalancerV3PoolTokensQuoter,
    QuoteAssetsERC4626ToChainlinkOracleQuoter
{
    /**
     * @notice Initializes the combined junior-side asset model
     * @dev The BPT side has no initializer; its configuration is set in JuniorAssetsBalancerV3PoolTokensQuoter's constructor
     * @param _initialQuoteAssetConversionRateWAD The initial ERC4626 base asset to NAV unit conversion rate, scaled to WAD precision (or the sentinel value to defer to the oracle)
     * @param _quoteBaseAssetToNAVOracle The Chainlink (compatible) oracle pricing the quote asset's ERC4626 base asset in NAV units
     * @param _stalenessThresholdSeconds The staleness threshold in seconds for the quote-side oracle
     */
    function __JuniorAssetsBalancerV3PoolTokensWithERC4626ChainlinkQuoteAssetsQuoter_init(
        uint256 _initialQuoteAssetConversionRateWAD,
        address _quoteBaseAssetToNAVOracle,
        uint48 _stalenessThresholdSeconds
    )
        internal
        onlyInitializing
    {
        __QuoteAssetsERC4626ToChainlinkOracleQuoter_init(
            _initialQuoteAssetConversionRateWAD,
            _quoteBaseAssetToNAVOracle,
            _stalenessThresholdSeconds
        );
    }

    /// @inheritdoc RoycoDuskKernel
    /// @dev Delegates cache initialization to the inherited overrides in QuoteAssetsOracleQuoter and RoycoDuskKernel
    function _initializeQuoterCache() internal virtual override(QuoteAssetsOracleQuoter, RoycoDuskKernel) {
        super._initializeQuoterCache();
    }

    /// @inheritdoc RoycoDuskKernel
    /// @dev Delegates cache teardown to the inherited overrides in QuoteAssetsOracleQuoter and RoycoDuskKernel
    function _clearQuoterCache() internal virtual override(QuoteAssetsOracleQuoter, RoycoDuskKernel) {
        super._clearQuoterCache();
    }
}
