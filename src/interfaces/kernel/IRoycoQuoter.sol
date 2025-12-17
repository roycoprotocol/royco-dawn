// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { NAV_UNIT, TRANCHE_UNIT } from "../../libraries/Units.sol";

interface IRoycoQuoter {
    /**
     * @notice Converts the specified ST assets denominated in its tranche units to the kernel's NAV units
     * @param _stAssets The ST assets denominated in tranche units to convert to the kernel's NAV units
     * @return nav The specified ST assets denominated in its tranche units converted to the kernel's NAV units
     */
    function stConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _stAssets) external view returns (NAV_UNIT nav);

    /**
     * @notice Converts the specified JT assets denominated in its tranche units to the kernel's NAV units
     * @param _jtAssets The JT assets denominated in tranche units to convert to the kernel's NAV units
     * @return nav The specified JT assets denominated in its tranche units converted to the kernel's NAV units
     */
    function jtConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _jtAssets) external view returns (NAV_UNIT nav);

    /**
     * @notice Converts the specified assets denominated in the kernel's NAV units to assets denominated in ST's tranche units
     * @param _navAssets The NAV of the assets denominated in the kernel's NAV units to convert to assets denominated in ST's tranche units
     * @return stAssets The specified NAV of the assets denominated in the kernel's NAV units converted to assets denominated in ST's tranche units
     */
    function stConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) external view returns (TRANCHE_UNIT stAssets);

    /**
     * @notice Converts the specified assets denominated in the kernel's NAV units to assets denominated in JT's tranche units
     * @param _navAssets The NAV of the assets denominated in the kernel's NAV units to convert to assets denominated in JT's tranche units
     * @return jtAssets The specified NAV of the assets denominated in the kernel's NAV units converted to assets denominated in JT's tranche units
     */
    function jtConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) external view returns (TRANCHE_UNIT jtAssets);
}
