// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { Initializable } from "../../../../lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import { WAD_DECIMALS } from "../../../libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../../libraries/Units.sol";
import { RoycoKernel } from "../RoycoKernel.sol";

/**
 * @title InKindAssetsQuoter
 * @notice Quoter for markets where both tranches use the different unit precision and the NAV is expressed in tranche units with normalized precision
 * @dev Supported use-cases include:
 *      - ST and JT use in kind assets that have different precisions
 *        For example, USDC and USDS (USD pegged assets with 6 and 18 decimals of precision respectively)
 */
abstract contract InKindAssetsQuoter is Initializable, RoycoKernel {
    /// @notice Thrown when the senior or junior tranche asset has over WAD decimals of precision
    error UNSUPPORTED_DECIMALS();

    /// @dev Storage slot for InKindAssetsQuoterState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.InKindAssetsQuoterState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant INKIND_ASSETS_QUOTER_STORAGE_SLOT = 0x772ab8662186eb1a607ea316dd8b37fa0391c8f9f780762129706cf58c146e00;

    /// @notice Storage state for the Royco in kind assets quoter
    /// @custom:storage-location erc7201:Royco.storage.InKindAssetsQuoterState
    /// @custom:field stScaleFactorToWAD - Multiplier to scale ST asset units up to WAD precision
    /// @custom:field jtScaleFactorToWAD - Multiplier to scale JT asset units up to WAD precision
    struct InKindAssetsQuoterState {
        uint64 stScaleFactorToWAD;
        uint64 jtScaleFactorToWAD;
    }

    /**
     * @notice Initializes the quoter for inkind tranche assets
     * @dev Assumes that the two assets have identical values
     * @param _stAsset The address of the base asset of the senior tranche
     * @param _jtAsset The address of the base asset of the junior tranche
     */
    function __InKindAssetsQuoter_init_unchained(address _stAsset, address _jtAsset) internal onlyInitializing {
        // Get the decimals for each tranche's base asset and ensure they are less than or equal to WAD decimals of precision
        uint8 stDecimals = IERC20Metadata(_stAsset).decimals();
        uint8 jtDecimals = IERC20Metadata(_jtAsset).decimals();
        require(stDecimals <= WAD_DECIMALS && jtDecimals <= WAD_DECIMALS, UNSUPPORTED_DECIMALS());

        // Compute the scaling factor that will scale each tranche's asset quantities to WAD precision
        // The NAV unit of this quoter is the tranche
        uint64 stScaleFactorToWAD = uint64(10 ** (WAD_DECIMALS - stDecimals));
        uint64 jtScaleFactorToWAD = uint64(10 ** (WAD_DECIMALS - jtDecimals));

        // Persist the scaling factors
        InKindAssetsQuoterState storage $ = _getInKindAssetsQuoterStorage();
        $.stScaleFactorToWAD = stScaleFactorToWAD;
        $.jtScaleFactorToWAD = jtScaleFactorToWAD;
    }

    /// @inheritdoc RoycoKernel
    /// @dev Scale the ST asset quantity up to NAV units (WAD precision)
    function _stConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _stAssets) internal view override(RoycoKernel) returns (NAV_UNIT nav) {
        return toNAVUnits(toUint256(_stAssets) * _getInKindAssetsQuoterStorage().stScaleFactorToWAD);
    }

    /// @inheritdoc RoycoKernel
    /// @dev Scale the JT asset quantity up to NAV units (WAD precision)
    function _jtConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _jtAssets) internal view override(RoycoKernel) returns (NAV_UNIT nav) {
        return toNAVUnits(toUint256(_jtAssets) * _getInKindAssetsQuoterStorage().jtScaleFactorToWAD);
    }

    /// @inheritdoc RoycoKernel
    /// @dev Scale the NAV quantity (WAD precision) down to ST asset units, rounding down
    function _stConvertNAVUnitsToTrancheUnits(NAV_UNIT _nav) internal view override(RoycoKernel) returns (TRANCHE_UNIT stAssets) {
        return toTrancheUnits(toUint256(_nav) / _getInKindAssetsQuoterStorage().stScaleFactorToWAD);
    }

    /// @inheritdoc RoycoKernel
    /// @dev Scale the NAV quantity (WAD precision) down to JT asset units, rounding down
    function _jtConvertNAVUnitsToTrancheUnits(NAV_UNIT _nav) internal view override(RoycoKernel) returns (TRANCHE_UNIT jtAssets) {
        return toTrancheUnits(toUint256(_nav) / _getInKindAssetsQuoterStorage().jtScaleFactorToWAD);
    }

    /// @notice Returns a storage pointer to the InKindAssetsQuoterState storage
    /// @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
    /// @return $ Storage pointer to the in-kind assets quoter state
    function _getInKindAssetsQuoterStorage() internal pure returns (InKindAssetsQuoterState storage $) {
        assembly ("memory-safe") {
            $.slot := INKIND_ASSETS_QUOTER_STORAGE_SLOT
        }
    }
}
