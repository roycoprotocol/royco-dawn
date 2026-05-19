// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata, IERC4626 } from "../../../../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { Math } from "../../../../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { WAD, WAD_DECIMALS } from "../../../../../../libraries/Constants.sol";
import { SeniorAssetsOracleQuoter } from "./SeniorAssetsOracleQuoter.sol";

/**
 * @title SeniorERC4626SharesOracleQuoter
 * @notice Quoter to convert senior tranche units (ERC4626 vault shares) to/from NAV units by converting the shares to base assets and converting base assets to NAV units using an admin or oracle set rate
 * @dev The senior tranche unit must be an ERC4626 vault share
 * @dev Use case: Convert sUSDe (Senior tranche unit) to USDe (base assets) using ERC4626's convertToAssets and convert USDe to USD (NAV unit) using an admin or oracle set rate
 */
abstract contract SeniorERC4626SharesOracleQuoter is SeniorAssetsOracleQuoter {
    using Math for uint256;

    /// @dev The share amount to pass to convertToAssets() such that the result is scaled to WAD precision
    uint256 internal immutable SENIOR_ERC4626_SHARES_TO_CONVERT_TO_ASSETS;

    constructor() {
        // Compute the share amount to pass to convertToAssets() such that the result is scaled to WAD precision
        // OUTPUT_DECIMALS = INPUT_DECIMALS + BASE_ASSET_DECIMALS - SENIOR_TRANCHE_DECIMALS
        // For OUTPUT_DECIMALS to have WAD_DECIMALS of precision:
        // INPUT_DECIMALS = WAD_DECIMALS + SENIOR_TRANCHE_DECIMALS - BASE_ASSET_DECIMALS
        // OUTPUT_DECIMALS = (WAD_DECIMALS + SENIOR_TRANCHE_DECIMALS - BASE_ASSET_DECIMALS) + BASE_ASSET_DECIMALS - SENIOR_TRANCHE_DECIMALS
        // OUTPUT_DECIMALS = WAD_DECIMALS
        SENIOR_ERC4626_SHARES_TO_CONVERT_TO_ASSETS =
            10 ** (WAD_DECIMALS + IERC4626(ST_ASSET).decimals() - IERC20Metadata(IERC4626(ST_ASSET).asset()).decimals());
    }

    /**
     * @notice Returns the conversion rate from senior tranche units to NAV units, scaled to WAD precision
     * @dev This function assumes that the senior tranche token is an ERC4626 compliant vault
     * @dev The conversion rate is calculated as the value of the senior asset in base asset * value of base asset in NAV units
     * @return seniorTrancheToNAVUnitConversionRateWAD The conversion rate from senior tranche token units to NAV units, scaled to WAD precision
     */
    function getSeniorTrancheUnitToNAVUnitConversionRateWAD()
        public
        view
        virtual
        override(SeniorAssetsOracleQuoter)
        returns (uint256 seniorTrancheToNAVUnitConversionRateWAD)
    {
        // Fetch the conversion rate from the senior asset (ERC4626 share) to its underlying asset, scaled to WAD precision
        uint256 seniorTrancheUnitToBaseAssetsConversionRateWAD = IERC4626(ST_ASSET).convertToAssets(SENIOR_ERC4626_SHARES_TO_CONVERT_TO_ASSETS);

        // Resolve the vault base asset to NAV unit conversion rate, scaled to WAD precision
        uint256 baseAssetToNAVUnitConversionRateWAD = getStoredSeniorAssetConversionRateWAD();
        // If the stored conversion rate is the sentinel value, query the oracle for the rate
        if (baseAssetToNAVUnitConversionRateWAD == SENTINEL_CONVERSION_RATE) baseAssetToNAVUnitConversionRateWAD = _getSeniorAssetConversionRateFromOracleWAD();

        // Calculate the conversion rate from senior tranche to NAV units, scaled to WAD precision
        seniorTrancheToNAVUnitConversionRateWAD =
            seniorTrancheUnitToBaseAssetsConversionRateWAD.mulDiv(baseAssetToNAVUnitConversionRateWAD, WAD, Math.Rounding.Floor);
    }
}
