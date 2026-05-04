methods{
    function IdenticalERC4626SharesToChainlinkOracleQuoter.stConvertTrancheUnitsToNAVUnits(RoycoKernel.TRANCHE_UNIT _stAssets) internal returns (RoycoKernel.NAV_UNIT) => NONDET;
    function IdenticalERC4626SharesToChainlinkOracleQuoter.jtConvertTrancheUnitsToNAVUnits(RoycoKernel.TRANCHE_UNIT _jtAssets) internal returns (RoycoKernel.NAV_UNIT) => NONDET;
    function IdenticalERC4626SharesToChainlinkOracleQuoter.stConvertNAVUnitsToTrancheUnits(RoycoKernel.NAV_UNIT _navAssets) internal returns (RoycoKernel.TRANCHE_UNIT) => NONDET;
    function IdenticalERC4626SharesToChainlinkOracleQuoter.jtConvertNAVUnitsToTrancheUnits(RoycoKernel.NAV_UNIT _navAssets) internal returns (RoycoKernel.TRANCHE_UNIT) => NONDET;
}

// TODO: We may need axiomatic summaries instead of non-deterministic summaries.
// Maybe we even need the implementation as mulDiv with a non-deterministic price.
