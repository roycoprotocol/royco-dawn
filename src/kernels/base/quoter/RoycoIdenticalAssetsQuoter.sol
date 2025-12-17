// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { Initializable } from "../../../../lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

import { IRoycoQuoter } from "../../../interfaces/kernel/IRoycoQuoter.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../../libraries/Units.sol";

/**
 * @title RoycoIdenticalAssetsQuoter
 * @notice Quoter for markets where both tranches use the same unit precision and the NAV is expressed in tranche units
 * @dev Supported use-cases include:
 *      - ST and JT share the exact same tranche asset and the NAV is expressed in that asset
 *      - ST and JT use in kind assets that share the same precision and are treated as pegged to each other
 *        For example, USDC and USDT where NAV is expressed in USD with 6 decimals of precision
 */
abstract contract RoycoIdenticalAssetsQuoter is Initializable, IRoycoQuoter {
    /// @notice Thrown when the senior and junior tranche assets have the same precision
    error TRANCHE_ASSET_DECIMALS_MISMATCH();

    /**
     * @notice Initializes the quoter for identical tranche assets
     * @dev Assumes that the two assets have identical values
     * @dev Reverts if the two assets don't have identical precision
     * @param _stAsset The address of the base asset of the senior tranche
     * @param _jtAsset The address of the base asset of the junior tranche
     */
    function __RoycoIdenticalAssetQuoter_init_unchained(address _stAsset, address _jtAsset) internal view onlyInitializing {
        // This quoter stipulates that both tranche assets have identical precision
        require(IERC20Metadata(_stAsset).decimals() == IERC20Metadata(_jtAsset).decimals(), TRANCHE_ASSET_DECIMALS_MISMATCH());
    }

    /// @inheritdoc IRoycoQuoter
    /// @dev With identical precision, tranche units map 1:1 into NAV units
    function stConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _stAssets) public view virtual override(IRoycoQuoter) returns (NAV_UNIT nav) {
        return toNAVUnits(toUint256(_stAssets));
    }

    /// @inheritdoc IRoycoQuoter
    /// @dev With identical precision, tranche units map 1:1 into NAV units
    function jtConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _jtAssets) public view virtual override(IRoycoQuoter) returns (NAV_UNIT nav) {
        return toNAVUnits(toUint256(_jtAssets));
    }

    /// @inheritdoc IRoycoQuoter
    /// @dev With identical precision, NAV units map 1:1 into senior tranche units
    function stConvertNAVUnitsToTrancheUnits(NAV_UNIT _nav) public view virtual override(IRoycoQuoter) returns (TRANCHE_UNIT stAssets) {
        return toTrancheUnits(toUint256(_nav));
    }

    /// @inheritdoc IRoycoQuoter
    /// @dev With identical precision, NAV units map 1:1 into junior tranche units
    function jtConvertNAVUnitsToTrancheUnits(NAV_UNIT _nav) public view virtual override(IRoycoQuoter) returns (TRANCHE_UNIT jtAssets) {
        return toTrancheUnits(toUint256(_nav));
    }
}
