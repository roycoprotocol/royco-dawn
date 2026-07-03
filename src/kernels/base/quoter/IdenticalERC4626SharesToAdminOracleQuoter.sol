// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IdenticalAssetsAdminOracleQuoter } from "./base/IdenticalAssetsAdminOracleQuoter.sol";
import { IdenticalAssetsOracleQuoter } from "./base/IdenticalAssetsOracleQuoter.sol";
import { IdenticalERC4626SharesOracleQuoter } from "./base/IdenticalERC4626SharesOracleQuoter.sol";

/**
 * @title IdenticalERC4626SharesToAdminOracleQuoter
 * @dev Mandates that the base asset to NAV units uses an admin controlled oracle
 * @dev The senior and junior tranches must have the same ERC4626 vault share as its tranche unit
 * @dev Use case: Convert sUSDe (Tranche unit) to USDe (base assets) using ERC4626's convertToAssets and convert USDe to USD (NAV unit) using an admin set rate
 */
abstract contract IdenticalERC4626SharesToAdminOracleQuoter is IdenticalERC4626SharesOracleQuoter, IdenticalAssetsAdminOracleQuoter {
    /**
     * @notice Initializes the identical ERC4626 shares admin oracle quoter and the base identical assets oracle quoter
     * @param _initialConversionRateWAD The initial conversion rate as defined by the oracle, scaled to WAD precision
     */
    function __IdenticalERC4626SharesToAdminOracleQuoter_init(uint256 _initialConversionRateWAD) internal onlyInitializing {
        __IdenticalAssetsAdminOracleQuoter_init(_initialConversionRateWAD);
    }

    /// @inheritdoc IdenticalAssetsAdminOracleQuoter
    function setConversionRate(
        uint256 _conversionRateWAD,
        bool _syncBeforeUpdate
    )
        public
        override(IdenticalAssetsOracleQuoter, IdenticalAssetsAdminOracleQuoter)
        restricted
    {
        IdenticalAssetsAdminOracleQuoter.setConversionRate(_conversionRateWAD, _syncBeforeUpdate);
    }

    /// @inheritdoc IdenticalERC4626SharesOracleQuoter
    function getTrancheUnitToNAVUnitConversionRateWAD()
        public
        view
        override(IdenticalAssetsOracleQuoter, IdenticalERC4626SharesOracleQuoter)
        returns (uint256 trancheToNAVUnitConversionRateWAD)
    {
        return IdenticalERC4626SharesOracleQuoter.getTrancheUnitToNAVUnitConversionRateWAD();
    }
}
