// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata, IERC4626 } from "../../../../../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { Math } from "../../../../../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { WAD, WAD_DECIMALS } from "../../../../../../../libraries/Constants.sol";
import { QuoteAssetsOracleQuoter } from "./QuoteAssetsOracleQuoter.sol";

/**
 * @title QuoteAssetsERC4626OracleQuoter
 * @notice Quoter to convert quote units (ERC4626 vault shares) to NAV units by converting the shares to base assets and converting base assets to NAV units using an admin or oracle set rate
 * @dev The quote asset must be an ERC4626 vault share
 * @dev Use case: Convert sUSDS (Quote unit) to USDS (base assets) using ERC4626's convertToAssets and convert USDS to USD (NAV unit) using an admin or oracle set rate
 */
abstract contract QuoteAssetsERC4626OracleQuoter is QuoteAssetsOracleQuoter {
    using Math for uint256;

    /// @dev The share amount to pass to convertToAssets() such that the result is scaled to WAD precision
    uint256 internal immutable ERC4626_QUOTE_ASSET_SHARES_TO_CONVERT_TO_ASSETS;

    constructor() {
        // NOTE: The quote asset is an ERC4626 share
        // Compute the share amount to pass to convertToAssets() such that the result is scaled to WAD precision
        // OUTPUT_DECIMALS = INPUT_DECIMALS + BASE_ASSET_DECIMALS - QUOTE_DECIMALS
        // For OUTPUT_DECIMALS to have WAD_DECIMALS of precision:
        // INPUT_DECIMALS = WAD_DECIMALS + QUOTE_DECIMALS - BASE_ASSET_DECIMALS
        // OUTPUT_DECIMALS = (WAD_DECIMALS + QUOTE_DECIMALS - BASE_ASSET_DECIMALS) + BASE_ASSET_DECIMALS - QUOTE_DECIMALS
        // OUTPUT_DECIMALS = WAD_DECIMALS
        ERC4626_QUOTE_ASSET_SHARES_TO_CONVERT_TO_ASSETS =
            10 ** (WAD_DECIMALS + IERC4626(QUOTE_ASSET).decimals() - IERC20Metadata(IERC4626(QUOTE_ASSET).asset()).decimals());
    }

    /**
     * @notice Returns the conversion rate from quote units to NAV units, scaled to WAD precision
     * @dev This function assumes that the quote asset is an ERC4626 compliant vault
     * @dev The conversion rate is calculated as the value of quote asset in base asset * value of base asset in NAV units
     * @return quoteAssetToNAVUnitConversionRateWAD The conversion rate from quote units to NAV units, scaled to WAD precision
     */
    function getQuoteAssetToNAVUnitConversionRateWAD()
        public
        view
        virtual
        override(QuoteAssetsOracleQuoter)
        returns (uint256 quoteAssetToNAVUnitConversionRateWAD)
    {
        // Fetch the conversion rate from the quote asset (ERC4626 share) to its underlying asset, scaled to WAD precision
        uint256 quoteAssetToBaseAssetsConversionRateWAD = IERC4626(QUOTE_ASSET).convertToAssets(ERC4626_QUOTE_ASSET_SHARES_TO_CONVERT_TO_ASSETS);

        // Resolve the vault base asset to NAV unit conversion rate, scaled to WAD precision
        uint256 baseAssetToNAVUnitConversionRateWAD = getStoredQuoteAssetConversionRateWAD();
        // If the stored conversion rate is the sentinel value, query the oracle for the rate
        if (baseAssetToNAVUnitConversionRateWAD == SENTINEL_CONVERSION_RATE) baseAssetToNAVUnitConversionRateWAD = _getQuoteAssetConversionRateFromOracleWAD();

        // Calculate the conversion rate from quote to NAV units, scaled to WAD precision
        quoteAssetToNAVUnitConversionRateWAD = quoteAssetToBaseAssetsConversionRateWAD.mulDiv(baseAssetToNAVUnitConversionRateWAD, WAD, Math.Rounding.Floor);
    }
}
