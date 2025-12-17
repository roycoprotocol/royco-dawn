// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

/// @notice Common unit of account for Royco NAV values (e.g., USD, BTC) used consistently across a market's tranches
/// @dev `NAV_UNIT` must be expressed in the same underlying unit and precision for both ST and JT within a market
type NAV_UNIT is uint256;

/// @notice Unit for tranche asset amounts (native token units for a specific tranche)
type TRANCHE_UNIT is uint256;

/// @title UnitsMathLib
/// @notice Typed math helpers for Royco units (NAV_UNIT and TRANCHE_UNIT)
/// @dev Wraps OpenZeppelin Math helpers and preserves unit typing on return values
library UnitsMathLib {
    /// @notice Returns the minimum of two NAV-denominated quantities.
    function min(NAV_UNIT _a, NAV_UNIT _b) internal pure returns (NAV_UNIT) {
        return toNAVUnits(Math.min(toUint256(_a), toUint256(_b)));
    }

    /// @notice Returns the minimum of two tranche-denominated quantities.
    function min(TRANCHE_UNIT _a, TRANCHE_UNIT _b) internal pure returns (TRANCHE_UNIT) {
        return toTrancheUnits(Math.min(toUint256(_a), toUint256(_b)));
    }

    /// @notice Returns the signed delta `_a - _b` for NAV-denominated quantities.
    function computeNAVDelta(NAV_UNIT _a, NAV_UNIT _b) internal pure returns (int256) {
        return (toInt256(_a) - toInt256(_b));
    }

    /// @notice Returns `max(_a - _b, 0)` for NAV-denominated quantities.
    function saturatingSub(NAV_UNIT _a, NAV_UNIT _b) internal pure returns (NAV_UNIT) {
        return toNAVUnits(Math.saturatingSub(toUint256(_a), toUint256(_b)));
    }

    /// @notice Returns `(_a * _b) / _c` for NAV-denominated quantities with explicit rounding.
    function mulDiv(NAV_UNIT _a, NAV_UNIT _b, NAV_UNIT _c, Math.Rounding _rounding) internal pure returns (NAV_UNIT) {
        return toNAVUnits(Math.mulDiv(toUint256(_a), toUint256(_b), toUint256(_c), _rounding));
    }

    /// @notice Returns `(_a * _b) / _c` where `_a` is NAV-denominated and `_b/_c` are scalars, with explicit rounding.
    function mulDiv(NAV_UNIT _a, uint256 _b, uint256 _c, Math.Rounding _rounding) internal pure returns (NAV_UNIT) {
        return toNAVUnits(Math.mulDiv(toUint256(_a), _b, _c, _rounding));
    }

    /// @notice Returns `(_a * _b) / _c` where `_a/_c` are NAV-denominated and `_b` is a scalar, with explicit rounding.
    function mulDiv(NAV_UNIT _a, uint256 _b, NAV_UNIT _c, Math.Rounding _rounding) internal pure returns (NAV_UNIT) {
        return toNAVUnits(Math.mulDiv(toUint256(_a), _b, toUint256(_c), _rounding));
    }

    /// @notice Returns `(_a * _b) / _c` for tranche-denominated quantities with explicit rounding.
    function mulDiv(TRANCHE_UNIT _a, TRANCHE_UNIT _b, TRANCHE_UNIT _c, Math.Rounding _rounding) internal pure returns (TRANCHE_UNIT) {
        return toTrancheUnits(Math.mulDiv(toUint256(_a), toUint256(_b), toUint256(_c), _rounding));
    }

    /// @notice Returns `(_a * _b) / _c` where `_a` is tranche-denominated and `_b/_c` are NAV-denominated, with explicit rounding.
    function mulDiv(TRANCHE_UNIT _a, NAV_UNIT _b, NAV_UNIT _c, Math.Rounding _rounding) internal pure returns (TRANCHE_UNIT) {
        return toTrancheUnits(Math.mulDiv(toUint256(_a), toUint256(_b), toUint256(_c), _rounding));
    }

    /// @notice Returns `(_a * _b) / _c` where `_a` is tranche-denominated and `_b/_c` are scalars, with explicit rounding.
    function mulDiv(TRANCHE_UNIT _a, uint256 _b, uint256 _c, Math.Rounding _rounding) internal pure returns (TRANCHE_UNIT) {
        return toTrancheUnits(Math.mulDiv(toUint256(_a), _b, _c, _rounding));
    }
}

/// -----------------------------------------------------------------------
/// Global NAV_UNIT Helpers
/// -----------------------------------------------------------------------

function toNAVUnits(uint256 _assets) pure returns (NAV_UNIT) {
    return NAV_UNIT.wrap(_assets);
}

function toNAVUnits(int256 _assets) pure returns (NAV_UNIT) {
    return NAV_UNIT.wrap(uint256(_assets));
}

function toUint256(NAV_UNIT _units) pure returns (uint256) {
    return NAV_UNIT.unwrap(_units);
}

function toInt256(NAV_UNIT _units) pure returns (int256) {
    return int256(NAV_UNIT.unwrap(_units));
}

function addNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (NAV_UNIT) {
    return NAV_UNIT.wrap(NAV_UNIT.unwrap(_a) + NAV_UNIT.unwrap(_b));
}

function subNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (NAV_UNIT) {
    return NAV_UNIT.wrap(NAV_UNIT.unwrap(_a) - NAV_UNIT.unwrap(_b));
}

function mulNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (NAV_UNIT) {
    return NAV_UNIT.wrap(NAV_UNIT.unwrap(_a) * NAV_UNIT.unwrap(_b));
}

function divNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (NAV_UNIT) {
    return NAV_UNIT.wrap(NAV_UNIT.unwrap(_a) / NAV_UNIT.unwrap(_b));
}

function lessThanNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (bool) {
    return NAV_UNIT.unwrap(_a) < NAV_UNIT.unwrap(_b);
}

function lessThanOrEqualToNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (bool) {
    return NAV_UNIT.unwrap(_a) <= NAV_UNIT.unwrap(_b);
}

function greaterThanNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (bool) {
    return NAV_UNIT.unwrap(_a) > NAV_UNIT.unwrap(_b);
}

function greaterThanOrEqualToNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (bool) {
    return NAV_UNIT.unwrap(_a) >= NAV_UNIT.unwrap(_b);
}

function equalsNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (bool) {
    return NAV_UNIT.unwrap(_a) == NAV_UNIT.unwrap(_b);
}

function notEqualsNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (bool) {
    return NAV_UNIT.unwrap(_a) != NAV_UNIT.unwrap(_b);
}

using {
    addNAVUnits as +,
    subNAVUnits as -,
    mulNAVUnits as *,
    divNAVUnits as /,
    lessThanNAVUnits as <,
    lessThanOrEqualToNAVUnits as <=,
    greaterThanNAVUnits as >,
    greaterThanOrEqualToNAVUnits as >=,
    equalsNAVUnits as ==,
    notEqualsNAVUnits as !=
} for NAV_UNIT global;

/// -----------------------------------------------------------------------
/// Global TRANCHE_UNIT Helpers
/// -----------------------------------------------------------------------

function toTrancheUnits(uint256 _assets) pure returns (TRANCHE_UNIT) {
    return TRANCHE_UNIT.wrap(_assets);
}

function toUint256(TRANCHE_UNIT _units) pure returns (uint256) {
    return TRANCHE_UNIT.unwrap(_units);
}

function addTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (TRANCHE_UNIT) {
    return TRANCHE_UNIT.wrap(TRANCHE_UNIT.unwrap(_a) + TRANCHE_UNIT.unwrap(_b));
}

function subTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (TRANCHE_UNIT) {
    return TRANCHE_UNIT.wrap(TRANCHE_UNIT.unwrap(_a) - TRANCHE_UNIT.unwrap(_b));
}

function mulTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (TRANCHE_UNIT) {
    return TRANCHE_UNIT.wrap(TRANCHE_UNIT.unwrap(_a) * TRANCHE_UNIT.unwrap(_b));
}

function divTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (TRANCHE_UNIT) {
    return TRANCHE_UNIT.wrap(TRANCHE_UNIT.unwrap(_a) / TRANCHE_UNIT.unwrap(_b));
}

function lessThanTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (bool) {
    return TRANCHE_UNIT.unwrap(_a) < TRANCHE_UNIT.unwrap(_b);
}

function lessThanOrEqualToTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (bool) {
    return TRANCHE_UNIT.unwrap(_a) <= TRANCHE_UNIT.unwrap(_b);
}

function greaterThanTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (bool) {
    return TRANCHE_UNIT.unwrap(_a) > TRANCHE_UNIT.unwrap(_b);
}

function greaterThanOrEqualToTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (bool) {
    return TRANCHE_UNIT.unwrap(_a) >= TRANCHE_UNIT.unwrap(_b);
}

function equalsTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (bool) {
    return TRANCHE_UNIT.unwrap(_a) == TRANCHE_UNIT.unwrap(_b);
}

function notEqualsTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (bool) {
    return TRANCHE_UNIT.unwrap(_a) != TRANCHE_UNIT.unwrap(_b);
}

using {
    addTrancheUnits as +,
    subTrancheUnits as -,
    mulTrancheUnits as *,
    divTrancheUnits as /,
    lessThanTrancheUnits as <,
    lessThanOrEqualToTrancheUnits as <=,
    greaterThanTrancheUnits as >,
    greaterThanOrEqualToTrancheUnits as >=,
    equalsTrancheUnits as ==,
    notEqualsTrancheUnits as !=
} for TRANCHE_UNIT global;
