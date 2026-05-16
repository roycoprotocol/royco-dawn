// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

/// @notice Standard unit of account for a Royco market (eg. USD, BTC, ETC, etc.)
/// @dev `NAV_UNIT` must be expressed in the same underlying unit with 18 decimals of precision for a given Royco market
type NAV_UNIT is uint256;

/// @notice Unit for tranche asset amounts (native token units for a specific tranche)
/// @dev `TRANCHE_UNIT` always has the same precision as the asset it represents (base asset of the tranche)
type TRANCHE_UNIT is uint256;

/// @notice Unit for quote asset amounts (quote asset against ST shares in an LP position held by a Dusk junior tranche)
/// @dev `QUOTE_UNIT` always has the same precision as the asset it represents
type QUOTE_UNIT is uint256;

/**
 * @title UnitsMathLib
 * @notice Typed math helpers for Royco units (NAV_UNIT, TRANCHE_UNIT, and QUOTE_UNIT)
 * @dev Wraps OpenZeppelin Math helpers and preserves unit typing on return values
 */
library UnitsMathLib {
    /**
     * @notice Returns the minimum of two NAV-denominated quantities
     * @param _a The first NAV_UNIT operand
     * @param _b The second NAV_UNIT operand
     * @return The smaller of `_a` and `_b`, NAV-denominated
     */
    function min(NAV_UNIT _a, NAV_UNIT _b) internal pure returns (NAV_UNIT) {
        return toNAVUnits(Math.min(toUint256(_a), toUint256(_b)));
    }

    /**
     * @notice Returns the minimum of two tranche-denominated quantities
     * @param _a The first TRANCHE_UNIT operand
     * @param _b The second TRANCHE_UNIT operand
     * @return The smaller of `_a` and `_b`, tranche-denominated
     */
    function min(TRANCHE_UNIT _a, TRANCHE_UNIT _b) internal pure returns (TRANCHE_UNIT) {
        return toTrancheUnits(Math.min(toUint256(_a), toUint256(_b)));
    }

    /**
     * @notice Returns the minimum of two quote-denominated quantities
     * @param _a The first QUOTE_UNIT operand
     * @param _b The second QUOTE_UNIT operand
     * @return The smaller of `_a` and `_b`, quote-denominated
     */
    function min(QUOTE_UNIT _a, QUOTE_UNIT _b) internal pure returns (QUOTE_UNIT) {
        return toQuoteUnits(Math.min(toUint256(_a), toUint256(_b)));
    }

    /**
     * @notice Returns the signed delta `_a - _b` for NAV-denominated quantities
     * @param _a The minuend, NAV-denominated
     * @param _b The subtrahend, NAV-denominated
     * @return The signed delta `_a - _b`, expressed as a 256-bit signed integer
     */
    function computeNAVDelta(NAV_UNIT _a, NAV_UNIT _b) internal pure returns (int256) {
        return (toInt256(_a) - toInt256(_b));
    }

    /**
     * @notice Returns the saturated subtraction `max(_a - _b, 0)` for NAV-denominated quantities
     * @dev Clamps the result at zero to prevent underflow when `_b > _a`
     * @param _a The minuend, NAV-denominated
     * @param _b The subtrahend, NAV-denominated
     * @return The NAV-denominated value `max(_a - _b, 0)`
     */
    function saturatingSub(NAV_UNIT _a, NAV_UNIT _b) internal pure returns (NAV_UNIT) {
        return toNAVUnits(Math.saturatingSub(toUint256(_a), toUint256(_b)));
    }

    /**
     * @notice Computes `(_a * _b) / _c` for NAV-denominated operands with explicit rounding
     * @param _a The multiplicand, NAV-denominated
     * @param _b The multiplier, NAV-denominated
     * @param _c The divisor, NAV-denominated
     * @param _rounding The rounding direction to apply to the division
     * @return The NAV-denominated quotient `(_a * _b) / _c`
     */
    function mulDiv(NAV_UNIT _a, NAV_UNIT _b, NAV_UNIT _c, Math.Rounding _rounding) internal pure returns (NAV_UNIT) {
        return toNAVUnits(Math.mulDiv(toUint256(_a), toUint256(_b), toUint256(_c), _rounding));
    }

    /**
     * @notice Computes `(_a * _b) / _c` where `_a` is NAV-denominated and `_b`/`_c` are scalars, with explicit rounding
     * @param _a The multiplicand, NAV-denominated
     * @param _b The scalar multiplier
     * @param _c The scalar divisor
     * @param _rounding The rounding direction to apply to the division
     * @return The NAV-denominated quotient `(_a * _b) / _c`
     */
    function mulDiv(NAV_UNIT _a, uint256 _b, uint256 _c, Math.Rounding _rounding) internal pure returns (NAV_UNIT) {
        return toNAVUnits(Math.mulDiv(toUint256(_a), _b, _c, _rounding));
    }

    /**
     * @notice Computes `(_a * _b) / _c` where `_a` and `_c` are NAV-denominated and `_b` is a scalar, with explicit rounding
     * @param _a The multiplicand, NAV-denominated
     * @param _b The scalar multiplier
     * @param _c The divisor, NAV-denominated
     * @param _rounding The rounding direction to apply to the division
     * @return The NAV-denominated quotient `(_a * _b) / _c`
     */
    function mulDiv(NAV_UNIT _a, uint256 _b, NAV_UNIT _c, Math.Rounding _rounding) internal pure returns (NAV_UNIT) {
        return toNAVUnits(Math.mulDiv(toUint256(_a), _b, toUint256(_c), _rounding));
    }

    /**
     * @notice Computes `(_a * _b) / _c` where `_a` is tranche-denominated and `_b`/`_c` are NAV-denominated, with explicit rounding
     * @param _a The multiplicand, tranche-denominated
     * @param _b The multiplier, NAV-denominated
     * @param _c The divisor, NAV-denominated
     * @param _rounding The rounding direction to apply to the division
     * @return The tranche-denominated quotient `(_a * _b) / _c`
     */
    function mulDiv(TRANCHE_UNIT _a, NAV_UNIT _b, NAV_UNIT _c, Math.Rounding _rounding) internal pure returns (TRANCHE_UNIT) {
        return toTrancheUnits(Math.mulDiv(toUint256(_a), toUint256(_b), toUint256(_c), _rounding));
    }

    /**
     * @notice Computes `(_a * _b) / _c` where `_a` is tranche-denominated and `_b`/`_c` are scalars, with explicit rounding
     * @param _a The multiplicand, tranche-denominated
     * @param _b The scalar multiplier
     * @param _c The scalar divisor
     * @param _rounding The rounding direction to apply to the division
     * @return The tranche-denominated quotient `(_a * _b) / _c`
     */
    function mulDiv(TRANCHE_UNIT _a, uint256 _b, uint256 _c, Math.Rounding _rounding) internal pure returns (TRANCHE_UNIT) {
        return toTrancheUnits(Math.mulDiv(toUint256(_a), _b, _c, _rounding));
    }

    /**
     * @notice Computes `(_a * _b) / _c` where `_b` is tranche-denominated and `_a`/`_c` are scalars, with explicit rounding
     * @param _a The scalar multiplicand
     * @param _b The multiplier, tranche-denominated
     * @param _c The scalar divisor
     * @param _rounding The rounding direction to apply to the division
     * @return The tranche-denominated quotient `(_a * _b) / _c`
     */
    function mulDiv(uint256 _a, TRANCHE_UNIT _b, uint256 _c, Math.Rounding _rounding) internal pure returns (TRANCHE_UNIT) {
        return toTrancheUnits(Math.mulDiv(_a, toUint256(_b), _c, _rounding));
    }

    /**
     * @notice Computes `(_a * _b) / _c` where `_a` is quote-denominated and `_b`/`_c` are NAV-denominated, with explicit rounding
     * @param _a The multiplicand, quote-denominated
     * @param _b The multiplier, NAV-denominated
     * @param _c The divisor, NAV-denominated
     * @param _rounding The rounding direction to apply to the division
     * @return The quote-denominated quotient `(_a * _b) / _c`
     */
    function mulDiv(QUOTE_UNIT _a, NAV_UNIT _b, NAV_UNIT _c, Math.Rounding _rounding) internal pure returns (QUOTE_UNIT) {
        return toQuoteUnits(Math.mulDiv(toUint256(_a), toUint256(_b), toUint256(_c), _rounding));
    }

    /**
     * @notice Computes `(_a * _b) / _c` where `_a` is quote-denominated and `_b`/`_c` are scalars, with explicit rounding
     * @param _a The multiplicand, quote-denominated
     * @param _b The scalar multiplier
     * @param _c The scalar divisor
     * @param _rounding The rounding direction to apply to the division
     * @return The quote-denominated quotient `(_a * _b) / _c`
     */
    function mulDiv(QUOTE_UNIT _a, uint256 _b, uint256 _c, Math.Rounding _rounding) internal pure returns (QUOTE_UNIT) {
        return toQuoteUnits(Math.mulDiv(toUint256(_a), _b, _c, _rounding));
    }

    /**
     * @notice Computes `(_a * _b) / _c` where `_a` is a scalar and `_b`/`_c` are NAV-denominated, with explicit rounding
     * @param _a The scalar multiplicand
     * @param _b The multiplier, NAV-denominated
     * @param _c The divisor, NAV-denominated
     * @param _rounding The rounding direction to apply to the division
     * @return The scalar quotient `(_a * _b) / _c`
     */
    function mulDiv(uint256 _a, NAV_UNIT _b, NAV_UNIT _c, Math.Rounding _rounding) internal pure returns (uint256) {
        return Math.mulDiv(_a, toUint256(_b), toUint256(_c), _rounding);
    }
}

/// -----------------------------------------------------------------------
/// Global NAV_UNIT Helpers
/// -----------------------------------------------------------------------

/**
 * @notice Wraps an unsigned integer as a NAV_UNIT
 * @param _assets The unsigned integer to wrap
 * @return The NAV_UNIT wrapping the specified unsigned integer
 */
function toNAVUnits(uint256 _assets) pure returns (NAV_UNIT) {
    return NAV_UNIT.wrap(_assets);
}

/// @notice Thrown when attempting to wrap a negative signed integer as a NAV_UNIT
error ASSETS_MUST_BE_NON_NEGATIVE();

/**
 * @notice Wraps a non-negative signed integer as a NAV_UNIT
 * @dev Reverts with `ASSETS_MUST_BE_NON_NEGATIVE` if `_assets` is negative
 * @param _assets The signed integer to wrap
 * @return The NAV_UNIT wrapping the specified signed integer
 */
function toNAVUnits(int256 _assets) pure returns (NAV_UNIT) {
    require(_assets >= 0, ASSETS_MUST_BE_NON_NEGATIVE());
    // forge-lint: disable-next-line(unsafe-typecast)
    return NAV_UNIT.wrap(uint256(_assets));
}

/**
 * @notice Unwraps a NAV_UNIT to its underlying unsigned integer representation
 * @param _units The NAV_UNIT to unwrap
 * @return The unsigned integer underlying the specified NAV_UNIT
 */
function toUint256(NAV_UNIT _units) pure returns (uint256) {
    return NAV_UNIT.unwrap(_units);
}

/**
 * @notice Unwraps a NAV_UNIT to a signed integer representation of its underlying value
 * @param _units The NAV_UNIT to unwrap
 * @return The signed integer representation of the specified NAV_UNIT's underlying value
 */
function toInt256(NAV_UNIT _units) pure returns (int256) {
    return int256(NAV_UNIT.unwrap(_units));
}

/**
 * @notice Returns the sum of two NAV-denominated quantities
 * @param _a The first NAV_UNIT operand
 * @param _b The second NAV_UNIT operand
 * @return The NAV-denominated sum `_a + _b`
 */
function addNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (NAV_UNIT) {
    return NAV_UNIT.wrap(NAV_UNIT.unwrap(_a) + NAV_UNIT.unwrap(_b));
}

/**
 * @notice Returns the difference of two NAV-denominated quantities
 * @param _a The minuend, NAV-denominated
 * @param _b The subtrahend, NAV-denominated
 * @return The NAV-denominated difference `_a - _b`
 */
function subNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (NAV_UNIT) {
    return NAV_UNIT.wrap(NAV_UNIT.unwrap(_a) - NAV_UNIT.unwrap(_b));
}

/**
 * @notice Returns the product of two NAV-denominated quantities
 * @param _a The first NAV_UNIT operand
 * @param _b The second NAV_UNIT operand
 * @return The NAV-denominated product `_a * _b`
 */
function mulNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (NAV_UNIT) {
    return NAV_UNIT.wrap(NAV_UNIT.unwrap(_a) * NAV_UNIT.unwrap(_b));
}

/**
 * @notice Returns the quotient of two NAV-denominated quantities, rounded toward zero
 * @param _a The dividend, NAV-denominated
 * @param _b The divisor, NAV-denominated
 * @return The NAV-denominated quotient `_a / _b`
 */
function divNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (NAV_UNIT) {
    return NAV_UNIT.wrap(NAV_UNIT.unwrap(_a) / NAV_UNIT.unwrap(_b));
}

/**
 * @notice Returns whether the first NAV-denominated quantity is strictly less than the second
 * @param _a The left-hand NAV_UNIT operand
 * @param _b The right-hand NAV_UNIT operand
 * @return True if `_a < _b`, false otherwise
 */
function lessThanNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (bool) {
    return NAV_UNIT.unwrap(_a) < NAV_UNIT.unwrap(_b);
}

/**
 * @notice Returns whether the first NAV-denominated quantity is less than or equal to the second
 * @param _a The left-hand NAV_UNIT operand
 * @param _b The right-hand NAV_UNIT operand
 * @return True if `_a <= _b`, false otherwise
 */
function lessThanOrEqualToNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (bool) {
    return NAV_UNIT.unwrap(_a) <= NAV_UNIT.unwrap(_b);
}

/**
 * @notice Returns whether the first NAV-denominated quantity is strictly greater than the second
 * @param _a The left-hand NAV_UNIT operand
 * @param _b The right-hand NAV_UNIT operand
 * @return True if `_a > _b`, false otherwise
 */
function greaterThanNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (bool) {
    return NAV_UNIT.unwrap(_a) > NAV_UNIT.unwrap(_b);
}

/**
 * @notice Returns whether the first NAV-denominated quantity is greater than or equal to the second
 * @param _a The left-hand NAV_UNIT operand
 * @param _b The right-hand NAV_UNIT operand
 * @return True if `_a >= _b`, false otherwise
 */
function greaterThanOrEqualToNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (bool) {
    return NAV_UNIT.unwrap(_a) >= NAV_UNIT.unwrap(_b);
}

/**
 * @notice Returns whether two NAV-denominated quantities are equal
 * @param _a The left-hand NAV_UNIT operand
 * @param _b The right-hand NAV_UNIT operand
 * @return True if `_a == _b`, false otherwise
 */
function equalsNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (bool) {
    return NAV_UNIT.unwrap(_a) == NAV_UNIT.unwrap(_b);
}

/**
 * @notice Returns whether two NAV-denominated quantities are not equal
 * @param _a The left-hand NAV_UNIT operand
 * @param _b The right-hand NAV_UNIT operand
 * @return True if `_a != _b`, false otherwise
 */
function notEqualsNAVUnits(NAV_UNIT _a, NAV_UNIT _b) pure returns (bool) {
    return NAV_UNIT.unwrap(_a) != NAV_UNIT.unwrap(_b);
}

/// @dev Globally enables `+`, `-`, `*`, `/`, `<`, `<=`, `>`, `>=`, `==`, `!=` on NAV_UNIT operands
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

/**
 * @notice Wraps an unsigned integer as a TRANCHE_UNIT
 * @param _assets The unsigned integer to wrap
 * @return The TRANCHE_UNIT wrapping the specified unsigned integer
 */
function toTrancheUnits(uint256 _assets) pure returns (TRANCHE_UNIT) {
    return TRANCHE_UNIT.wrap(_assets);
}

/**
 * @notice Unwraps a TRANCHE_UNIT to its underlying unsigned integer representation
 * @param _units The TRANCHE_UNIT to unwrap
 * @return The unsigned integer underlying the specified TRANCHE_UNIT
 */
function toUint256(TRANCHE_UNIT _units) pure returns (uint256) {
    return TRANCHE_UNIT.unwrap(_units);
}

/**
 * @notice Returns the sum of two tranche-denominated quantities
 * @param _a The first TRANCHE_UNIT operand
 * @param _b The second TRANCHE_UNIT operand
 * @return The tranche-denominated sum `_a + _b`
 */
function addTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (TRANCHE_UNIT) {
    return TRANCHE_UNIT.wrap(TRANCHE_UNIT.unwrap(_a) + TRANCHE_UNIT.unwrap(_b));
}

/**
 * @notice Returns the difference of two tranche-denominated quantities
 * @param _a The minuend, tranche-denominated
 * @param _b The subtrahend, tranche-denominated
 * @return The tranche-denominated difference `_a - _b`
 */
function subTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (TRANCHE_UNIT) {
    return TRANCHE_UNIT.wrap(TRANCHE_UNIT.unwrap(_a) - TRANCHE_UNIT.unwrap(_b));
}

/**
 * @notice Returns the product of two tranche-denominated quantities
 * @param _a The first TRANCHE_UNIT operand
 * @param _b The second TRANCHE_UNIT operand
 * @return The tranche-denominated product `_a * _b`
 */
function mulTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (TRANCHE_UNIT) {
    return TRANCHE_UNIT.wrap(TRANCHE_UNIT.unwrap(_a) * TRANCHE_UNIT.unwrap(_b));
}

/**
 * @notice Returns the quotient of two tranche-denominated quantities, rounded toward zero
 * @param _a The dividend, tranche-denominated
 * @param _b The divisor, tranche-denominated
 * @return The tranche-denominated quotient `_a / _b`
 */
function divTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (TRANCHE_UNIT) {
    return TRANCHE_UNIT.wrap(TRANCHE_UNIT.unwrap(_a) / TRANCHE_UNIT.unwrap(_b));
}

/**
 * @notice Returns whether the first tranche-denominated quantity is strictly less than the second
 * @param _a The left-hand TRANCHE_UNIT operand
 * @param _b The right-hand TRANCHE_UNIT operand
 * @return True if `_a < _b`, false otherwise
 */
function lessThanTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (bool) {
    return TRANCHE_UNIT.unwrap(_a) < TRANCHE_UNIT.unwrap(_b);
}

/**
 * @notice Returns whether the first tranche-denominated quantity is less than or equal to the second
 * @param _a The left-hand TRANCHE_UNIT operand
 * @param _b The right-hand TRANCHE_UNIT operand
 * @return True if `_a <= _b`, false otherwise
 */
function lessThanOrEqualToTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (bool) {
    return TRANCHE_UNIT.unwrap(_a) <= TRANCHE_UNIT.unwrap(_b);
}

/**
 * @notice Returns whether the first tranche-denominated quantity is strictly greater than the second
 * @param _a The left-hand TRANCHE_UNIT operand
 * @param _b The right-hand TRANCHE_UNIT operand
 * @return True if `_a > _b`, false otherwise
 */
function greaterThanTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (bool) {
    return TRANCHE_UNIT.unwrap(_a) > TRANCHE_UNIT.unwrap(_b);
}

/**
 * @notice Returns whether the first tranche-denominated quantity is greater than or equal to the second
 * @param _a The left-hand TRANCHE_UNIT operand
 * @param _b The right-hand TRANCHE_UNIT operand
 * @return True if `_a >= _b`, false otherwise
 */
function greaterThanOrEqualToTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (bool) {
    return TRANCHE_UNIT.unwrap(_a) >= TRANCHE_UNIT.unwrap(_b);
}

/**
 * @notice Returns whether two tranche-denominated quantities are equal
 * @param _a The left-hand TRANCHE_UNIT operand
 * @param _b The right-hand TRANCHE_UNIT operand
 * @return True if `_a == _b`, false otherwise
 */
function equalsTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (bool) {
    return TRANCHE_UNIT.unwrap(_a) == TRANCHE_UNIT.unwrap(_b);
}

/**
 * @notice Returns whether two tranche-denominated quantities are not equal
 * @param _a The left-hand TRANCHE_UNIT operand
 * @param _b The right-hand TRANCHE_UNIT operand
 * @return True if `_a != _b`, false otherwise
 */
function notEqualsTrancheUnits(TRANCHE_UNIT _a, TRANCHE_UNIT _b) pure returns (bool) {
    return TRANCHE_UNIT.unwrap(_a) != TRANCHE_UNIT.unwrap(_b);
}

/// @dev Globally enables `+`, `-`, `*`, `/`, `<`, `<=`, `>`, `>=`, `==`, `!=` on TRANCHE_UNIT operands
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

/// -----------------------------------------------------------------------
/// Global QUOTE_UNIT Helpers
/// -----------------------------------------------------------------------

/**
 * @notice Wraps an unsigned integer as a QUOTE_UNIT
 * @param _assets The unsigned integer to wrap
 * @return The QUOTE_UNIT wrapping the specified unsigned integer
 */
function toQuoteUnits(uint256 _assets) pure returns (QUOTE_UNIT) {
    return QUOTE_UNIT.wrap(_assets);
}

/**
 * @notice Unwraps a QUOTE_UNIT to its underlying unsigned integer representation
 * @param _units The QUOTE_UNIT to unwrap
 * @return The unsigned integer underlying the specified QUOTE_UNIT
 */
function toUint256(QUOTE_UNIT _units) pure returns (uint256) {
    return QUOTE_UNIT.unwrap(_units);
}

/**
 * @notice Returns the sum of two quote-denominated quantities
 * @param _a The first QUOTE_UNIT operand
 * @param _b The second QUOTE_UNIT operand
 * @return The quote-denominated sum `_a + _b`
 */
function addQuoteUnits(QUOTE_UNIT _a, QUOTE_UNIT _b) pure returns (QUOTE_UNIT) {
    return QUOTE_UNIT.wrap(QUOTE_UNIT.unwrap(_a) + QUOTE_UNIT.unwrap(_b));
}

/**
 * @notice Returns the difference of two quote-denominated quantities
 * @param _a The minuend, quote-denominated
 * @param _b The subtrahend, quote-denominated
 * @return The quote-denominated difference `_a - _b`
 */
function subQuoteUnits(QUOTE_UNIT _a, QUOTE_UNIT _b) pure returns (QUOTE_UNIT) {
    return QUOTE_UNIT.wrap(QUOTE_UNIT.unwrap(_a) - QUOTE_UNIT.unwrap(_b));
}

/**
 * @notice Returns the product of two quote-denominated quantities
 * @param _a The first QUOTE_UNIT operand
 * @param _b The second QUOTE_UNIT operand
 * @return The quote-denominated product `_a * _b`
 */
function mulQuoteUnits(QUOTE_UNIT _a, QUOTE_UNIT _b) pure returns (QUOTE_UNIT) {
    return QUOTE_UNIT.wrap(QUOTE_UNIT.unwrap(_a) * QUOTE_UNIT.unwrap(_b));
}

/**
 * @notice Returns the quotient of two quote-denominated quantities, rounded toward zero
 * @param _a The dividend, quote-denominated
 * @param _b The divisor, quote-denominated
 * @return The quote-denominated quotient `_a / _b`
 */
function divQuoteUnits(QUOTE_UNIT _a, QUOTE_UNIT _b) pure returns (QUOTE_UNIT) {
    return QUOTE_UNIT.wrap(QUOTE_UNIT.unwrap(_a) / QUOTE_UNIT.unwrap(_b));
}

/**
 * @notice Returns whether the first quote-denominated quantity is strictly less than the second
 * @param _a The left-hand QUOTE_UNIT operand
 * @param _b The right-hand QUOTE_UNIT operand
 * @return True if `_a < _b`, false otherwise
 */
function lessThanQuoteUnits(QUOTE_UNIT _a, QUOTE_UNIT _b) pure returns (bool) {
    return QUOTE_UNIT.unwrap(_a) < QUOTE_UNIT.unwrap(_b);
}

/**
 * @notice Returns whether the first quote-denominated quantity is less than or equal to the second
 * @param _a The left-hand QUOTE_UNIT operand
 * @param _b The right-hand QUOTE_UNIT operand
 * @return True if `_a <= _b`, false otherwise
 */
function lessThanOrEqualToQuoteUnits(QUOTE_UNIT _a, QUOTE_UNIT _b) pure returns (bool) {
    return QUOTE_UNIT.unwrap(_a) <= QUOTE_UNIT.unwrap(_b);
}

/**
 * @notice Returns whether the first quote-denominated quantity is strictly greater than the second
 * @param _a The left-hand QUOTE_UNIT operand
 * @param _b The right-hand QUOTE_UNIT operand
 * @return True if `_a > _b`, false otherwise
 */
function greaterThanQuoteUnits(QUOTE_UNIT _a, QUOTE_UNIT _b) pure returns (bool) {
    return QUOTE_UNIT.unwrap(_a) > QUOTE_UNIT.unwrap(_b);
}

/**
 * @notice Returns whether the first quote-denominated quantity is greater than or equal to the second
 * @param _a The left-hand QUOTE_UNIT operand
 * @param _b The right-hand QUOTE_UNIT operand
 * @return True if `_a >= _b`, false otherwise
 */
function greaterThanOrEqualToQuoteUnits(QUOTE_UNIT _a, QUOTE_UNIT _b) pure returns (bool) {
    return QUOTE_UNIT.unwrap(_a) >= QUOTE_UNIT.unwrap(_b);
}

/**
 * @notice Returns whether two quote-denominated quantities are equal
 * @param _a The left-hand QUOTE_UNIT operand
 * @param _b The right-hand QUOTE_UNIT operand
 * @return True if `_a == _b`, false otherwise
 */
function equalsQuoteUnits(QUOTE_UNIT _a, QUOTE_UNIT _b) pure returns (bool) {
    return QUOTE_UNIT.unwrap(_a) == QUOTE_UNIT.unwrap(_b);
}

/**
 * @notice Returns whether two quote-denominated quantities are not equal
 * @param _a The left-hand QUOTE_UNIT operand
 * @param _b The right-hand QUOTE_UNIT operand
 * @return True if `_a != _b`, false otherwise
 */
function notEqualsQuoteUnits(QUOTE_UNIT _a, QUOTE_UNIT _b) pure returns (bool) {
    return QUOTE_UNIT.unwrap(_a) != QUOTE_UNIT.unwrap(_b);
}

/// @dev Globally enables `+`, `-`, `*`, `/`, `<`, `<=`, `>`, `>=`, `==`, `!=` on QUOTE_UNIT operands
using {
    addQuoteUnits as +,
    subQuoteUnits as -,
    mulQuoteUnits as *,
    divQuoteUnits as /,
    lessThanQuoteUnits as <,
    lessThanOrEqualToQuoteUnits as <=,
    greaterThanQuoteUnits as >,
    greaterThanOrEqualToQuoteUnits as >=,
    equalsQuoteUnits as ==,
    notEqualsQuoteUnits as !=
} for QUOTE_UNIT global;
