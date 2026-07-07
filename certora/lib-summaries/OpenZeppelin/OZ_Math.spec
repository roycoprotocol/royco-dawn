import "../Math.spec";

methods {
    function Math.mulDiv(uint256 x, uint256 y, uint256 denominator) internal returns (uint256) => mulDivDownSummary(x,y,denominator);
    function Math.mulDiv(uint256 x, uint256 y, uint256 denominator, Math.Rounding rounding) internal returns (uint256) => mulDivDirectionalSummary(x, y, denominator, rounding);
    function Math.average(uint256 a, uint256 b) internal returns (uint256) => averageSummary(a,b);
}

function mulDivDirectionalSummary(uint256 x, uint256 y, uint256 denominator, Math.Rounding rounding) returns uint256 {
    if (assert_uint256(rounding) % 2 == 1) {
        return mulDivUpSummary(x, y, denominator);
    } else {
        return mulDivDownSummary(x, y, denominator);
    }
}