// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDawnKernel } from "../../../../interfaces/IRoycoDawnKernel.sol";
import { KernelType } from "../../../../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../../../../libraries/Units.sol";
import { RoycoDawnKernel } from "../../RoycoDawnKernel.sol";
import { RoycoDuskKernel } from "../../RoycoDuskKernel.sol";
import { SeniorAssetsOracleQuoter } from "../dawn/senior-assets/base/SeniorAssetsOracleQuoter.sol";
import { SeniorERC4626SharesToChainlinkOracleQuoter } from "../dawn/senior-assets/SeniorERC4626SharesToChainlinkOracleQuoter.sol";
import { JuniorAssetsBalancerV3PoolTokensWithERC4626ChainlinkQuoteAssetsQuoter } from
    "./junior-assets/JuniorAssetsBalancerV3PoolTokensWithERC4626ChainlinkQuoteAssetsQuoter.sol";

/**
 * @title ERC4626SharesToChainlinkOracle_ST_BPTsWithERC4626ChainlinkQuoteAssets_JT_Quoter
 * @notice Dusk quoter combining a Senior tranche side priced via ERC4626 shares + Chainlink (admin overridable) with a Junior tranche side that is a Balancer V3 BPT for a pool whose constituent tokens are the senior tranche shares and an ERC4626 quote asset (priced via Chainlink + admin overridable)
 * @dev Senior side: SeniorERC4626SharesToChainlinkOracleQuoter
 * @dev Junior side: JuniorAssetsBalancerV3PoolTokensWithERC4626ChainlinkQuoteAssetsQuoter
 */
abstract contract ERC4626SharesToChainlinkOracle_ST_BPTsWithERC4626ChainlinkQuoteAssets_JT_Quoter is
    SeniorERC4626SharesToChainlinkOracleQuoter,
    JuniorAssetsBalancerV3PoolTokensWithERC4626ChainlinkQuoteAssetsQuoter
{
    /**
     * @notice Initializes the combined Dusk quoter for both the senior and junior tranche asset models
     * @param _initialSeniorAssetConversionRateWAD The initial senior side conversion rate as defined by the oracle, scaled to WAD precision
     * @param _seniorBaseAssetToNAVOracle The Chainlink (compatible) oracle pricing the senior ERC4626 base asset in NAV units
     * @param _seniorStalenessThresholdSeconds The staleness threshold in seconds for the senior-side oracle
     * @param _initialQuoteAssetConversionRateWAD The initial quote side conversion rate as defined by the oracle, scaled to WAD precision
     * @param _quoteBaseAssetToNAVOracle The Chainlink (compatible) oracle pricing the quote ERC4626 base asset in NAV units
     * @param _quoteStalenessThresholdSeconds The staleness threshold in seconds for the quote-side oracle
     */
    function __ERC4626SharesToChainlinkOracle_ST_BPTsWithERC4626ChainlinkQuoteAssets_JT_Quoter_init(
        uint256 _initialSeniorAssetConversionRateWAD,
        address _seniorBaseAssetToNAVOracle,
        uint48 _seniorStalenessThresholdSeconds,
        uint256 _initialQuoteAssetConversionRateWAD,
        address _quoteBaseAssetToNAVOracle,
        uint48 _quoteStalenessThresholdSeconds
    )
        internal
        onlyInitializing
    {
        __SeniorERC4626SharesToChainlinkOracleQuoter_init(
            _initialSeniorAssetConversionRateWAD, _seniorBaseAssetToNAVOracle, _seniorStalenessThresholdSeconds
        );
        __JuniorAssetsBalancerV3PoolTokensWithERC4626ChainlinkQuoteAssetsQuoter_init(
            _initialQuoteAssetConversionRateWAD, _quoteBaseAssetToNAVOracle, _quoteStalenessThresholdSeconds
        );
    }

    /// @inheritdoc RoycoDuskKernel
    /// @dev Delegates cache initialization to the inherited overrides in SeniorAssetsOracleQuoter and JuniorAssetsBalancerV3PoolTokensWithERC4626ChainlinkQuoteAssetsQuoter
    function _initializeQuoterCache()
        internal
        virtual
        override(SeniorAssetsOracleQuoter, JuniorAssetsBalancerV3PoolTokensWithERC4626ChainlinkQuoteAssetsQuoter)
    {
        SeniorAssetsOracleQuoter._initializeQuoterCache();
        JuniorAssetsBalancerV3PoolTokensWithERC4626ChainlinkQuoteAssetsQuoter._initializeQuoterCache();
    }

    /// @inheritdoc RoycoDuskKernel
    /// @dev Delegates cache teardown to the inherited overrides in SeniorAssetsOracleQuoter and JuniorAssetsBalancerV3PoolTokensWithERC4626ChainlinkQuoteAssetsQuoter
    function _clearQuoterCache()
        internal
        virtual
        override(SeniorAssetsOracleQuoter, JuniorAssetsBalancerV3PoolTokensWithERC4626ChainlinkQuoteAssetsQuoter)
    {
        SeniorAssetsOracleQuoter._clearQuoterCache();
        JuniorAssetsBalancerV3PoolTokensWithERC4626ChainlinkQuoteAssetsQuoter._clearQuoterCache();
    }

    /// @inheritdoc IRoycoDawnKernel
    /// @dev Delegates to the senior tranche asset model
    function stConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _stAssets)
        public
        view
        override(IRoycoDawnKernel, RoycoDawnKernel, SeniorAssetsOracleQuoter)
        returns (NAV_UNIT)
    {
        return SeniorAssetsOracleQuoter.stConvertTrancheUnitsToNAVUnits(_stAssets);
    }

    /// @inheritdoc IRoycoDawnKernel
    /// @dev Delegates to the senior tranche asset model
    function stConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets)
        public
        view
        override(IRoycoDawnKernel, RoycoDawnKernel, SeniorAssetsOracleQuoter)
        returns (TRANCHE_UNIT)
    {
        return SeniorAssetsOracleQuoter.stConvertNAVUnitsToTrancheUnits(_navAssets);
    }

    /// @inheritdoc RoycoDuskKernel
    /// @dev Delegates to the Dusk junior tranche asset model
    function jtConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _jtAssets)
        public
        view
        override(RoycoDawnKernel, RoycoDuskKernel)
        returns (NAV_UNIT)
    {
        return RoycoDuskKernel.jtConvertTrancheUnitsToNAVUnits(_jtAssets);
    }

    /// @inheritdoc RoycoDuskKernel
    /// @dev Delegates to the Dusk junior tranche asset model
    function jtConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets)
        public
        view
        override(RoycoDawnKernel, RoycoDuskKernel)
        returns (TRANCHE_UNIT)
    {
        return RoycoDuskKernel.jtConvertNAVUnitsToTrancheUnits(_navAssets);
    }

    /// @inheritdoc RoycoDuskKernel
    /// @dev Delegates to the Dusk recomposed senior tranche raw NAV
    function _getSeniorTrancheRawNAV()
        internal
        view
        override(RoycoDawnKernel, RoycoDuskKernel)
        returns (NAV_UNIT stRawNAV)
    {
        return RoycoDuskKernel._getSeniorTrancheRawNAV();
    }

    /// @inheritdoc RoycoDuskKernel
    /// @dev Delegates to the Dusk junior tranche raw NAV
    function _getJuniorTrancheRawNAV()
        internal
        view
        override(RoycoDawnKernel, RoycoDuskKernel)
        returns (NAV_UNIT jtRawNAV)
    {
        return RoycoDuskKernel._getJuniorTrancheRawNAV();
    }

    /// @inheritdoc RoycoDuskKernel
    function KERNEL_TYPE() external pure override(RoycoDawnKernel, RoycoDuskKernel) returns (KernelType kernelType) {
        return KernelType.DUSK;
    }
}
