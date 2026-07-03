// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IdenticalAssetsOracleQuoter } from "./IdenticalAssetsOracleQuoter.sol";

/**
 * @title IdenticalAssetsAdminOracleQuoter
 * @notice Quoter to convert tranche units to/from NAV units using an admin controlled oracle for markets where both tranches use the same tranche units
 * @dev The conversion rate is set purely by an admin
 */
abstract contract IdenticalAssetsAdminOracleQuoter is IdenticalAssetsOracleQuoter {
    /// @notice Thrown when trying to call the oracle querying helper
    error MUST_USE_ADMIN_ORACLE_INPUT();

    /// @notice Thrown when trying to set the conversion rate to the sentinel value (0)
    error INVALID_CONVERSION_RATE();

    /**
     * @notice Initializes the identical assets admin oracle quoter
     * @dev The conversion rate cannot be set to the sentinel value (0)
     * @param _initialConversionRateWAD The initial reference asset to NAV unit conversion rate, scaled to WAD precision
     */
    function __IdenticalAssetsAdminOracleQuoter_init(uint256 _initialConversionRateWAD) internal onlyInitializing {
        // Validate the conversion rate
        require(_initialConversionRateWAD != SENTINEL_CONVERSION_RATE, INVALID_CONVERSION_RATE());
        // Initialize the oracle quoter with the initial admin set rate
        __IdenticalAssetsOracleQuoter_init_unchained(_initialConversionRateWAD);
    }

    /// @inheritdoc IdenticalAssetsOracleQuoter
    /// @dev The conversion rate cannot be set to the sentinel value (0)
    function setConversionRate(uint256 _conversionRateWAD, bool _syncBeforeUpdate) public virtual override(IdenticalAssetsOracleQuoter) restricted {
        // Validate the conversion rate
        require(_conversionRateWAD != SENTINEL_CONVERSION_RATE, INVALID_CONVERSION_RATE());
        // Update the oracle quoter with the initial admin set rate
        IdenticalAssetsOracleQuoter.setConversionRate(_conversionRateWAD, _syncBeforeUpdate);
    }

    /// @inheritdoc IdenticalAssetsOracleQuoter
    function _getConversionRateFromOracleWAD() internal pure override(IdenticalAssetsOracleQuoter) returns (uint256) {
        revert MUST_USE_ADMIN_ORACLE_INPUT();
    }
}
