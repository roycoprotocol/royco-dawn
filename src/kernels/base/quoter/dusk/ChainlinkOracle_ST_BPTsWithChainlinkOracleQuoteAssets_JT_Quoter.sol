// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDawnKernel } from "../../../../interfaces/IRoycoDawnKernel.sol";
import { AssetClaims, ConversionRateCacheKey, KernelType } from "../../../../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../../../../libraries/Units.sol";
import { RoycoDawnKernel } from "../../RoycoDawnKernel.sol";
import { RoycoDuskKernel } from "../../RoycoDuskKernel.sol";
import { SeniorAssetsChainlinkOracleQuoter } from "../dawn/senior-assets/base/SeniorAssetsChainlinkOracleQuoter.sol";
import {
    JuniorAssetsBalancerV3PoolTokensWithChainlinkOracleQuoteAssetsQuoter
} from "./junior-assets/JuniorAssetsBalancerV3PoolTokensWithChainlinkOracleQuoteAssetsQuoter.sol";

/**
 * @title ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_Quoter
 * @notice Dusk quoter combining a Senior tranche side priced via a Chainlink (compatible) oracle with a Junior tranche side that is a Balancer V3 BPT for a pool whose constituent tokens are the senior tranche shares and a Chainlink-priced quote asset
 * @dev Senior side: SeniorAssetsChainlinkOracleQuoter
 * @dev Junior side: JuniorAssetsBalancerV3PoolTokensWithChainlinkOracleQuoteAssetsQuoter
 */
abstract contract ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_Quoter is
    SeniorAssetsChainlinkOracleQuoter,
    JuniorAssetsBalancerV3PoolTokensWithChainlinkOracleQuoteAssetsQuoter
{
    /**
     * @notice Initializes the combined Dusk quoter for both the senior and junior tranche asset models
     * @param _seniorAssetOracle The Chainlink (compatible) oracle pricing the senior tranche asset in NAV units
     * @param _seniorAssetStalenessThresholdSeconds The staleness threshold in seconds for the senior-side oracle
     * @param _quoteAssetOracle The Chainlink (compatible) oracle pricing the quote asset in NAV units
     * @param _quoteAssetStalenessThresholdSeconds The staleness threshold in seconds for the quote-side oracle
     */
    function __ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_Quoter_init(
        address _seniorAssetOracle,
        uint48 _seniorAssetStalenessThresholdSeconds,
        address _quoteAssetOracle,
        uint48 _quoteAssetStalenessThresholdSeconds
    )
        internal
        onlyInitializing
    {
        __SeniorAssetsChainlinkOracleQuoter_init_unchained(_seniorAssetOracle, _seniorAssetStalenessThresholdSeconds);
        __JuniorAssetsBalancerV3PoolTokensWithChainlinkOracleQuoteAssetsQuoter_init(_quoteAssetOracle, _quoteAssetStalenessThresholdSeconds);
    }

    /// @inheritdoc RoycoDuskKernel
    /// @dev Delegates cache initialization to the inherited overrides in SeniorAssetsChainlinkOracleQuoter and JuniorAssetsBalancerV3PoolTokensWithChainlinkOracleQuoteAssetsQuoter
    function _initializeQuoterCache()
        internal
        virtual
        override(SeniorAssetsChainlinkOracleQuoter, JuniorAssetsBalancerV3PoolTokensWithChainlinkOracleQuoteAssetsQuoter)
    {
        SeniorAssetsChainlinkOracleQuoter._initializeQuoterCache();
        JuniorAssetsBalancerV3PoolTokensWithChainlinkOracleQuoteAssetsQuoter._initializeQuoterCache();
    }

    /// @inheritdoc RoycoDuskKernel
    /// @dev Delegates cache teardown to the inherited overrides in SeniorAssetsChainlinkOracleQuoter and JuniorAssetsBalancerV3PoolTokensWithChainlinkOracleQuoteAssetsQuoter
    function _clearQuoterCache()
        internal
        virtual
        override(SeniorAssetsChainlinkOracleQuoter, JuniorAssetsBalancerV3PoolTokensWithChainlinkOracleQuoteAssetsQuoter)
    {
        SeniorAssetsChainlinkOracleQuoter._clearQuoterCache();
        JuniorAssetsBalancerV3PoolTokensWithChainlinkOracleQuoteAssetsQuoter._clearQuoterCache();
    }

    /// @inheritdoc IRoycoDawnKernel
    /// @dev Delegates to the senior tranche asset model
    function stConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _stAssets)
        public
        view
        override(IRoycoDawnKernel, RoycoDawnKernel, SeniorAssetsChainlinkOracleQuoter)
        returns (NAV_UNIT)
    {
        return SeniorAssetsChainlinkOracleQuoter.stConvertTrancheUnitsToNAVUnits(_stAssets);
    }

    /// @inheritdoc IRoycoDawnKernel
    /// @dev Delegates to the senior tranche asset model
    function stConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets)
        public
        view
        override(IRoycoDawnKernel, RoycoDawnKernel, SeniorAssetsChainlinkOracleQuoter)
        returns (TRANCHE_UNIT)
    {
        return SeniorAssetsChainlinkOracleQuoter.stConvertNAVUnitsToTrancheUnits(_navAssets);
    }

    /// @inheritdoc IRoycoDawnKernel
    /// @dev Diamond resolution: the junior tranche (BPT) NAV is sourced from the Balancer V3 pool tokens quoter
    function jtConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _jtAssets)
        public
        view
        override(RoycoDawnKernel, JuniorAssetsBalancerV3PoolTokensWithChainlinkOracleQuoteAssetsQuoter)
        returns (NAV_UNIT)
    {
        return JuniorAssetsBalancerV3PoolTokensWithChainlinkOracleQuoteAssetsQuoter.jtConvertTrancheUnitsToNAVUnits(_jtAssets);
    }

    /// @inheritdoc RoycoDuskKernel
    /// @dev Delegates to the Dusk junior tranche asset model
    function jtConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) public view override(RoycoDawnKernel, RoycoDuskKernel) returns (TRANCHE_UNIT) {
        return RoycoDuskKernel.jtConvertNAVUnitsToTrancheUnits(_navAssets);
    }

    /// @inheritdoc RoycoDuskKernel
    function KERNEL_TYPE() external pure override(RoycoDawnKernel, RoycoDuskKernel) returns (KernelType kernelType) {
        return KernelType.DUSK;
    }

    /// @inheritdoc RoycoDawnKernel
    /// @dev Diamond resolution: prefer Dusk's override which handles the QUOTE_UNIT key on top of Dawn's tranche-unit keys
    function _lookupCachedConversionRate(ConversionRateCacheKey _cacheKey)
        internal
        view
        virtual
        override(RoycoDawnKernel, RoycoDuskKernel)
        returns (bool cacheHit, uint256 conversionRateWAD)
    {
        return RoycoDuskKernel._lookupCachedConversionRate(_cacheKey);
    }

    /// @inheritdoc RoycoDuskKernel
    function _withdrawAssets(AssetClaims memory _claims, address _receiver) internal override(RoycoDawnKernel, RoycoDuskKernel) {
        RoycoDuskKernel._withdrawAssets(_claims, _receiver);
    }
}
