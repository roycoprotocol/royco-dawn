ghost jtYieldShareCVL(RoycoAccountant.NAV_UNIT, RoycoAccountant.NAV_UNIT, uint256, uint256, RoycoAccountant.NAV_UNIT) returns uint256 {
    axiom (forall RoycoAccountant.NAV_UNIT stRawNAV. forall RoycoAccountant.NAV_UNIT jtRawNAV. forall uint256 beta. forall uint256 coverage. forall RoycoAccountant.NAV_UNIT jtEffectiveNAV.
        jtYieldShareCVL(stRawNAV, jtRawNAV, beta, coverage, jtEffectiveNAV) < WAD());
}
