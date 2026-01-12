// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;
import { NAV_UNIT, TRANCHE_UNIT } from "./Units.sol";

/// @dev Constant for 0 NAV units
NAV_UNIT constant ZERO_NAV_UNITS = NAV_UNIT.wrap(0);

/// @dev Constant for 0 tranche units
TRANCHE_UNIT constant ZERO_TRANCHE_UNITS = TRANCHE_UNIT.wrap(0);

/// @dev Constant for the max value expressable as tranche units
TRANCHE_UNIT constant MAX_TRANCHE_UNITS = TRANCHE_UNIT.wrap(type(uint256).max);

/// @dev Constant for the WAD scaling factor
uint256 constant WAD = 1e18;

/// @dev Constant for the WAD scaling factor as an integer
int256 constant WAD_INT = int256(WAD);

/// @dev Constant for the number of decimals of precision a WAD denominated quantity has
uint256 constant WAD_DECIMALS = 18;

/**
 * @dev Constant for the target utilization (kink) of the junior tranche's loss capital (90%)
 * @dev Utilization = ((ST_RAW_NAV + (JT_RAW_NAV * BETA_%)) * COV_%) / JT_EFFECTIVE_NAV
 * @dev If Utilization <= 1, the senior tranche exposure is collateralized as per the market's configured coverage requirement
 *      If Utilization > 1, the senior tranche exposure is undercollateralized as per the market's configured coverage requirement
 */
uint256 constant TARGET_UTILIZATION_WAD = 0.9e18;

/// @dev Constant for the target utilization (kink) of the junior tranche's loss capital (90%) as an integer
int256 constant TARGET_UTILIZATION_WAD_INT = 0.9e18;

/// @dev The minimum configurable coverage percentage, scaled to WAD precision
uint256 constant MIN_COVERAGE_WAD = 0.01e18;

/// @dev The max protocol fee percentage on tranche yields, scaled to WAD precision
uint256 constant MAX_PROTOCOL_FEE_WAD = 1e18;

/// @dev The request ID for a purely controller-discriminated request in ERC-7540
uint256 constant ERC_7540_CONTROLLER_DISCRIMINATED_REQUEST_ID = 0;
