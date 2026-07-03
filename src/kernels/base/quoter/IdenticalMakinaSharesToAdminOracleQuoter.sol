// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { Math } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IMachine } from "../../../interfaces/external/makina/IMachine.sol";
import { WAD, WAD_DECIMALS } from "../../../libraries/Constants.sol";
import { IdenticalAssetsAdminOracleQuoter, IdenticalAssetsOracleQuoter } from "./base/IdenticalAssetsAdminOracleQuoter.sol";

/**
 * @title IdenticalMakinaSharesToAdminOracleQuoter
 * @notice Quoter to convert tranche units (Makina machine shares) to/from NAV units by converting the shares to accounting assets and converting accounting assets to NAV units using an admin set rate
 * @dev Mandates that the accounting asset to NAV units uses an admin controlled oracle
 * @dev The senior and junior tranches must have the same Makina machine share as their tranche unit
 * @dev Use case: Convert DUSD (Tranche unit) to USDC (accounting assets) using the machine's convertToAssets and convert USDC to USD (NAV unit) using an admin set rate
 */
abstract contract IdenticalMakinaSharesToAdminOracleQuoter is IdenticalAssetsAdminOracleQuoter {
    using Math for uint256;

    /// @dev The address of the Makina machine for the ST and JT asset
    address public immutable MAKINA_MACHINE;

    /// @dev The share amount to pass to convertToAssets() such that the result is scaled to WAD precision
    uint256 internal immutable MACHINE_SHARES_TO_CONVERT_TO_ASSETS;

    /// @dev Thrown when the tranche asset is not the machine's share token
    error TRANCHE_ASSET_MUST_BE_MACHINE_SHARE();

    /// @notice Constructs the Makina machine shares oracle quoter
    /// @param _makinaMachine The Makina machine for the Royco market's tranche tokens
    constructor(address _makinaMachine) {
        // Sanity checks on the Makina machine and Royco market configuration
        require(_makinaMachine != address(0), NULL_ADDRESS());
        // We only need to check equality against one tranche asset since the parent contract asserts equality of the tranche assets
        require(IMachine(_makinaMachine).shareToken() == ST_ASSET, TRANCHE_ASSET_MUST_BE_MACHINE_SHARE());
        MAKINA_MACHINE = _makinaMachine;

        // NOTE: Both tranche assets are identical Makina machine shares
        // Compute the share amount to pass to convertToAssets() such that the result is scaled to WAD precision
        // OUTPUT_DECIMALS = INPUT_DECIMALS + ACCOUNTING_ASSET_DECIMALS - TRANCHE_DECIMALS
        // For OUTPUT_DECIMALS to have WAD_DECIMALS of precision:
        // INPUT_DECIMALS = WAD_DECIMALS + TRANCHE_DECIMALS - ACCOUNTING_ASSET_DECIMALS
        // OUTPUT_DECIMALS = (WAD_DECIMALS + TRANCHE_DECIMALS - ACCOUNTING_ASSET_DECIMALS) + ACCOUNTING_ASSET_DECIMALS - TRANCHE_DECIMALS
        // OUTPUT_DECIMALS = WAD_DECIMALS
        MACHINE_SHARES_TO_CONVERT_TO_ASSETS =
            10 ** (WAD_DECIMALS + IERC20Metadata(ST_ASSET).decimals() - IERC20Metadata(IMachine(_makinaMachine).accountingToken()).decimals());
    }

    /**
     * @notice Initializes the identical Makina machine shares admin oracle quoter and the base identical assets oracle quoter
     * @param _initialConversionRateWAD The initial conversion rate as defined by the oracle, scaled to WAD precision
     */
    function __IdenticalMakinaSharesToAdminOracleQuoter_init(uint256 _initialConversionRateWAD) internal onlyInitializing {
        __IdenticalAssetsAdminOracleQuoter_init(_initialConversionRateWAD);
    }

    /**
     * @notice Returns the conversion rate from tranche units to NAV units, scaled to WAD precision
     * @dev This function assumes that the tranche token is a Makina machine's share token
     * @dev The conversion rate is calculated as the value of tranche asset in accounting asset * value of accounting asset in NAV units
     * @return trancheToNAVUnitConversionRateWAD The conversion rate from tranche token units to NAV units, scaled to WAD precision
     */
    function getTrancheUnitToNAVUnitConversionRateWAD()
        public
        view
        virtual
        override(IdenticalAssetsOracleQuoter)
        returns (uint256 trancheToNAVUnitConversionRateWAD)
    {
        // Fetch the conversion rate from the tranche asset (Makina machine share) to its underlying asset, scaled to WAD precision
        uint256 trancheUnitToAccountingAssetsConversionRateWAD = IMachine(MAKINA_MACHINE).convertToAssets(MACHINE_SHARES_TO_CONVERT_TO_ASSETS);

        // Retrieve the machine's accounting asset to NAV unit conversion rate from the admin set oracle, scaled to WAD precision
        uint256 accountingAssetToNAVUnitConversionRateWAD = getStoredConversionRateWAD();

        // Calculate the conversion rate from tranche to NAV units, scaled to WAD precision
        trancheToNAVUnitConversionRateWAD =
            trancheUnitToAccountingAssetsConversionRateWAD.mulDiv(accountingAssetToNAVUnitConversionRateWAD, WAD, Math.Rounding.Floor);
    }
}
