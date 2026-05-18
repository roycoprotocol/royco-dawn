// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { Math } from "../../../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IMachine } from "../../../../../interfaces/external/makina/IMachine.sol";
import { WAD, WAD_DECIMALS } from "../../../../../libraries/Constants.sol";
import { SeniorAssetsAdminOracleQuoter, SeniorAssetsOracleQuoter } from "./base/SeniorAssetsAdminOracleQuoter.sol";

/**
 * @title SeniorMakinaSharesToAdminOracleQuoter
 * @notice Quoter to convert senior tranche units (Makina machine shares) to/from NAV units by converting the shares to accounting assets and converting accounting assets to NAV units using an admin set rate
 * @dev Mandates that the accounting asset to NAV units uses an admin controlled oracle
 * @dev The senior tranche unit must be a Makina machine share
 * @dev Use case: Convert DUSD (Senior tranche unit) to USDC (accounting assets) using the machine's convertToAssets and convert USDC to USD (NAV unit) using an admin set rate
 */
abstract contract SeniorMakinaSharesToAdminOracleQuoter is SeniorAssetsAdminOracleQuoter {
    using Math for uint256;

    /// @dev The address of the Makina machine for the senior tranche asset
    address public immutable SENIOR_MAKINA_MACHINE;

    /// @dev The share amount to pass to convertToAssets() such that the result is scaled to WAD precision
    uint256 internal immutable SENIOR_MACHINE_SHARES_TO_CONVERT_TO_ASSETS;

    /// @dev Thrown when the senior tranche asset is not the machine's share token
    error SENIOR_TRANCHE_ASSET_MUST_BE_MACHINE_SHARE();

    /// @notice Constructs the Makina machine shares oracle quoter for the senior tranche asset
    /// @param _makinaMachine The Makina machine for the Royco market's senior tranche token
    constructor(address _makinaMachine) {
        // Sanity checks on the Makina machine and Royco market configuration
        require(_makinaMachine != address(0), NULL_ADDRESS());
        require(IMachine(_makinaMachine).shareToken() == ST_ASSET, SENIOR_TRANCHE_ASSET_MUST_BE_MACHINE_SHARE());
        SENIOR_MAKINA_MACHINE = _makinaMachine;

        // Compute the share amount to pass to convertToAssets() such that the result is scaled to WAD precision
        // OUTPUT_DECIMALS = INPUT_DECIMALS + ACCOUNTING_ASSET_DECIMALS - SENIOR_TRANCHE_DECIMALS
        // For OUTPUT_DECIMALS to have WAD_DECIMALS of precision:
        // INPUT_DECIMALS = WAD_DECIMALS + SENIOR_TRANCHE_DECIMALS - ACCOUNTING_ASSET_DECIMALS
        // OUTPUT_DECIMALS = (WAD_DECIMALS + SENIOR_TRANCHE_DECIMALS - ACCOUNTING_ASSET_DECIMALS) + ACCOUNTING_ASSET_DECIMALS - SENIOR_TRANCHE_DECIMALS
        // OUTPUT_DECIMALS = WAD_DECIMALS
        SENIOR_MACHINE_SHARES_TO_CONVERT_TO_ASSETS =
            10 ** (WAD_DECIMALS + IERC20Metadata(ST_ASSET).decimals() - IERC20Metadata(IMachine(_makinaMachine).accountingToken()).decimals());
    }

    /**
     * @notice Initializes the senior assets Makina machine shares admin oracle quoter and the base senior assets oracle quoter
     * @param _initialSeniorAssetConversionRateWAD The initial conversion rate as defined by the oracle, scaled to WAD precision
     */
    function __SeniorMakinaSharesToAdminOracleQuoter_init(uint256 _initialSeniorAssetConversionRateWAD) internal onlyInitializing {
        __SeniorAssetsAdminOracleQuoter_init(_initialSeniorAssetConversionRateWAD);
    }

    /**
     * @notice Returns the conversion rate from senior tranche units to NAV units, scaled to WAD precision
     * @dev This function assumes that the senior tranche token is a Makina machine's share token
     * @dev The conversion rate is calculated as the value of the senior asset in accounting asset * value of accounting asset in NAV units
     * @return seniorTrancheToNAVUnitConversionRateWAD The conversion rate from senior tranche token units to NAV units, scaled to WAD precision
     */
    function getSeniorTrancheUnitToNAVUnitConversionRateWAD()
        public
        view
        virtual
        override(SeniorAssetsOracleQuoter)
        returns (uint256 seniorTrancheToNAVUnitConversionRateWAD)
    {
        // Fetch the conversion rate from the senior asset (Makina machine share) to its underlying asset, scaled to WAD precision
        uint256 seniorTrancheUnitToAccountingAssetsConversionRateWAD =
            IMachine(SENIOR_MAKINA_MACHINE).convertToAssets(SENIOR_MACHINE_SHARES_TO_CONVERT_TO_ASSETS);

        // Retrieve the machine's accounting asset to NAV unit conversion rate from the admin set oracle, scaled to WAD precision
        uint256 accountingAssetToNAVUnitConversionRateWAD = getStoredSeniorAssetConversionRateWAD();

        // Calculate the conversion rate from senior tranche to NAV units, scaled to WAD precision
        seniorTrancheToNAVUnitConversionRateWAD =
            seniorTrancheUnitToAccountingAssetsConversionRateWAD.mulDiv(accountingAssetToNAVUnitConversionRateWAD, WAD, Math.Rounding.Floor);
    }
}
