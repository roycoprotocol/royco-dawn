// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ERC4626ST_AaveV3JT_Kernel } from "../../src/kernels/ERC4626ST_AaveV3JT_Kernel.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../src/libraries/Units.sol";

contract USDC_ERC4626_AaveV3JT_Kernel is ERC4626ST_AaveV3JT_Kernel {
    /// @inheritdoc ERC4626ST_AaveV3JT_Kernel
    function stConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _stAssets) public view virtual override(ERC4626ST_AaveV3JT_Kernel) returns (NAV_UNIT) {
        return toNAVUnits(toUint256(_stAssets) * 10 ** 21);
    }

    /// @inheritdoc ERC4626ST_AaveV3JT_Kernel
    function jtConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _jtAssets) public view virtual override(ERC4626ST_AaveV3JT_Kernel) returns (NAV_UNIT) {
        return toNAVUnits(toUint256(_jtAssets) * 10 ** 21);
    }

    /// @inheritdoc ERC4626ST_AaveV3JT_Kernel
    function stConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) public view virtual override(ERC4626ST_AaveV3JT_Kernel) returns (TRANCHE_UNIT) {
        return toTrancheUnits(toUint256(_navAssets) / 10 ** 21);
    }

    /// @inheritdoc ERC4626ST_AaveV3JT_Kernel
    function jtConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) public view virtual override(ERC4626ST_AaveV3JT_Kernel) returns (TRANCHE_UNIT) {
        return toTrancheUnits(toUint256(_navAssets) / 10 ** 21);
    }
}
