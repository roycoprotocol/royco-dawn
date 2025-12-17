// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ERC4626ST_AaveV3JT_IdenticalAssets_Kernel } from "../../src/kernels/ERC4626ST_AaveV3JT_IdenticalAssets_Kernel.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../src/libraries/Units.sol";

contract USDC_ERC4626_AaveV3JT_Kernel is ERC4626ST_AaveV3JT_IdenticalAssets_Kernel { }
