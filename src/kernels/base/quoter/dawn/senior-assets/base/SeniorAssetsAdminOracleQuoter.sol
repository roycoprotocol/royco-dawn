// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { SeniorAssetsOracleQuoter } from "./SeniorAssetsOracleQuoter.sol";

/**
 * @title SeniorAssetsAdminOracleQuoter
 * @notice Quoter to convert senior tranche units to/from NAV units using an admin controlled oracle for markets where the senior tranche asset is priced independently of the junior tranche asset
 * @dev The conversion rate is set purely by an admin
 */
abstract contract SeniorAssetsAdminOracleQuoter is SeniorAssetsOracleQuoter {
    /// @notice Thrown when trying to call the oracle querying helper
    error MUST_USE_ADMIN_SENIOR_ASSET_ORACLE_INPUT();

    /// @notice Thrown when trying to set the conversion rate to the sentinel value (0)
    error INVALID_SENIOR_ASSET_CONVERSION_RATE();

    /**
     * @notice Initializes the senior assets admin oracle quoter
     * @dev The conversion rate cannot be set to the sentinel value (0)
     * @param _initialSeniorAssetConversionRateWAD The initial reference asset to NAV unit conversion rate, scaled to WAD precision
     */
    function __SeniorAssetsAdminOracleQuoter_init(uint256 _initialSeniorAssetConversionRateWAD) internal onlyInitializing {
        // Validate the conversion rate
        require(_initialSeniorAssetConversionRateWAD != SENTINEL_CONVERSION_RATE, INVALID_SENIOR_ASSET_CONVERSION_RATE());
        // Initialize the oracle quoter with the initial admin set rate
        __SeniorAssetsOracleQuoter_init_unchained(_initialSeniorAssetConversionRateWAD);
    }

    /// @inheritdoc SeniorAssetsOracleQuoter
    /// @dev The conversion rate cannot be set to the sentinel value (0)
    function setSeniorAssetConversionRate(
        uint256 _seniorAssetConversionRateWAD,
        bool _syncBeforeUpdate
    )
        public
        virtual
        override(SeniorAssetsOracleQuoter)
        restricted
    {
        // Validate the conversion rate
        require(_seniorAssetConversionRateWAD != SENTINEL_CONVERSION_RATE, INVALID_SENIOR_ASSET_CONVERSION_RATE());
        // Update the oracle quoter with the admin set rate
        SeniorAssetsOracleQuoter.setSeniorAssetConversionRate(_seniorAssetConversionRateWAD, _syncBeforeUpdate);
    }

    /// @inheritdoc SeniorAssetsOracleQuoter
    function _getSeniorAssetConversionRateFromOracleWAD() internal pure override(SeniorAssetsOracleQuoter) returns (uint256) {
        revert MUST_USE_ADMIN_SENIOR_ASSET_ORACLE_INPUT();
    }
}
