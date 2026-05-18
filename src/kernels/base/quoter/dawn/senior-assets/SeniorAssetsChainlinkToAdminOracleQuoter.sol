// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { SeniorAssetsAdminOracleQuoter } from "./base/SeniorAssetsAdminOracleQuoter.sol";
import { SeniorAssetsChainlinkOracleQuoter } from "./base/SeniorAssetsChainlinkOracleQuoter.sol";
import { SeniorAssetsOracleQuoter } from "./base/SeniorAssetsOracleQuoter.sol";

/**
 * @title SeniorAssetsChainlinkToAdminOracleQuoter
 * @dev Mandates that the reference asset to NAV units uses an admin controlled oracle
 * @dev Use case: Convert ACRED (Senior tranche unit) to USDC (Reference asset) using a Chainlink (compatible) oracle and convert USDC to USD (NAV unit) using an admin set rate
 */
abstract contract SeniorAssetsChainlinkToAdminOracleQuoter is SeniorAssetsChainlinkOracleQuoter, SeniorAssetsAdminOracleQuoter {
    /**
     * @notice Initializes the senior assets chainlink oracle quoter and the base senior assets oracle quoter
     * @param _initialSeniorAssetConversionRateWAD The initial conversion rate as defined by the oracle, scaled to WAD precision
     * @param _seniorAssetToReferenceAssetOracle The senior asset to reference asset oracle
     * @param _stalenessThresholdSeconds The staleness threshold in seconds
     */
    function __SeniorAssetsChainlinkToAdminOracleQuoter_init(
        uint256 _initialSeniorAssetConversionRateWAD,
        address _seniorAssetToReferenceAssetOracle,
        uint48 _stalenessThresholdSeconds
    )
        internal
        onlyInitializing
    {
        __SeniorAssetsAdminOracleQuoter_init(_initialSeniorAssetConversionRateWAD);
        __SeniorAssetsChainlinkOracleQuoter_init_unchained(_seniorAssetToReferenceAssetOracle, _stalenessThresholdSeconds);
    }

    /// @inheritdoc SeniorAssetsAdminOracleQuoter
    function setSeniorAssetConversionRate(
        uint256 _seniorAssetConversionRateWAD,
        bool _syncBeforeUpdate
    )
        public
        override(SeniorAssetsOracleQuoter, SeniorAssetsAdminOracleQuoter)
        restricted
    {
        SeniorAssetsAdminOracleQuoter.setSeniorAssetConversionRate(_seniorAssetConversionRateWAD, _syncBeforeUpdate);
    }

    /// @inheritdoc SeniorAssetsChainlinkOracleQuoter
    function getSeniorTrancheUnitToNAVUnitConversionRateWAD()
        public
        view
        override(SeniorAssetsOracleQuoter, SeniorAssetsChainlinkOracleQuoter)
        returns (uint256 seniorTrancheToNAVUnitConversionRateWAD)
    {
        return SeniorAssetsChainlinkOracleQuoter.getSeniorTrancheUnitToNAVUnitConversionRateWAD();
    }
}
