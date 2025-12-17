// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { NAV_UNIT, TRANCHE_UNIT } from "./Units.sol";

/// @dev Constant for 0 NAV units
NAV_UNIT constant ZERO_NAV_UNITS = NAV_UNIT.wrap(0);

/// @dev Constant for 0 tranche units
TRANCHE_UNIT constant ZERO_TRANCHE_UNITS = TRANCHE_UNIT.wrap(0);

/// @dev Constant for the WAD scaling factor
uint256 constant WAD = 1e18;

/// @dev Constant for the number of decimals of precision a WAD denominated quantity has
uint256 constant WAD_DECIMALS = 18;

/// @dev Constant for the RAY scaling factor
uint256 constant RAY = 1e27;

/// @dev The minimum configurable coverage percentage, scaled to WAD precision
uint256 constant MIN_COVERAGE_WAD = 0.01e18;

/// @dev The max protocol fee percentage on tranche yields, scaled to WAD precision
uint256 constant MAX_PROTOCOL_FEE_WAD = 1e18;

/// @dev The request ID for a purely controller-discriminated request in ERC-7540
uint256 constant ERC_7540_CONTROLLER_DISCRIMINATED_REQUEST_ID = 0;
