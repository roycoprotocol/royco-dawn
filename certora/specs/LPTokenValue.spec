
import "../summaries/using-Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.spec";
//import "../summaries/summaries-RoycoAccountant.spec";
//import "../external/external-nondet.spec";
//import "../lib-summaries/OpenZeppelin/OZ_SafeERC20.spec";
import "../lib-summaries/OpenZeppelin/OZ_Math.spec";
//import "../summaries/summaries-KernelConversions.spec";
using RoycoAccountant as roycoAccountant;

using DummyERC20A as erc20a;
using DummyERC20B as erc20b;

using RoycoJuniorTranche as juniorTranche;
using RoycoSeniorTranche as seniorTranche;

links {
    // Important: Note that the kernel is imported via import "using-Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel.spec".
    kernel.JT_ASSET => erc20b;
    kernel.ST_ASSET => erc20a;

    kernel.JUNIOR_TRANCHE => juniorTranche;
    kernel.SENIOR_TRANCHE => seniorTranche;
    kernel.ACCOUNTANT => roycoAccountant;

    seniorTranche.KERNEL => kernel;
    juniorTranche.KERNEL => kernel;
}

methods {
    function seniorTranche.allowance(address owner, address spender) external returns (uint256) envfree;
    function juniorTranche.allowance(address owner, address spender) external returns (uint256) envfree;
    function seniorTranche.totalSupply() external returns (uint256) envfree;
    function juniorTranche.totalSupply() external returns (uint256) envfree;
    function _.canCall(address,address,bytes4) external => canCallCVL() expect bool;
    function _.consumeScheduledOp(address,bytes) external => NONDET;
    function _.syncTrancheAccounting() external => DISPATCHER(true);
    function _.previewJTYieldShare(StaticCurveYDM.MarketState,StaticCurveYDM.NAV_UNIT,StaticCurveYDM.NAV_UNIT,uint256,uint256,StaticCurveYDM.NAV_UNIT) external => DISPATCHER(true);
    //function _.jtYieldShare(StaticCurveYDM.MarketState,StaticCurveYDM.NAV_UNIT,StaticCurveYDM.NAV_UNIT,uint256,uint256,StaticCurveYDM.NAV_UNIT) external => DISPATCHER(true);
    function _.jtYieldShare(
        RoycoAccountant.MarketState,
        RoycoAccountant.NAV_UNIT _stRawNAV,
        RoycoAccountant.NAV_UNIT _jtRawNAV,
        uint256 _betaWAD,
        uint256 _coverageWAD,
        RoycoAccountant.NAV_UNIT _jtEffectiveNAV
    ) external => jtYieldShareCVL(_stRawNAV, _jtRawNAV, _betaWAD, _coverageWAD, _jtEffectiveNAV) expect (uint256);
    // function Math.mulDiv(uint256 x, uint256 y, uint256 denominator) internal returns (uint256) => mulDivDirectionalSummary(x,y,denominator, Math.Rounding.Floor);
    // function Math.mulDiv(uint256 x, uint256 y, uint256 denominator, Math.Rounding rounding) internal returns (uint256) => mulDivDirectionalSummary(x, y, denominator, rounding);
    // SafeERC20 internal functions summarized as direct token calls
    function _.safeTransfer(address token, address to, uint256 value) internal => NONDET;
    function _.safeTransferFrom(address token, address from, address to, uint256 value) internal => NONDET;
    function Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.getTrancheUnitToNAVUnitConversionRateWAD() internal returns (uint256) => CONSTANT;
}

definition WAD() returns mathint = 10^18;

function canCallCVL() returns (bool) {
    return true;
}

// ghost mulDivDirectionalSummary(uint256, uint256, uint256, Math.Rounding) returns uint256
// {
//     axiom forall uint256 a. forall uint256 d. forall Math.Rounding rnd.
//         mulDivDirectionalSummary(a,0, d, rnd) == 0;
//     axiom forall uint256 a1. forall uint256 a2. forall uint256 b. forall uint256 d. forall Math.Rounding rnd.
//         a1 <= a2 => mulDivDirectionalSummary(a1, b, d, rnd) <= mulDivDirectionalSummary(a2,b,d,rnd);
//     axiom forall uint256 a. forall uint256 b1. forall uint256 b2. forall uint256 d. forall Math.Rounding rnd.
//         b1 <= b2 => mulDivDirectionalSummary(a, b1, d, rnd) <= mulDivDirectionalSummary(a,b2,d,rnd);
//     axiom forall uint256 a. forall uint256 b. forall uint256 d1. forall uint256 d2. forall Math.Rounding rnd.
//         d1 >= d2 => mulDivDirectionalSummary(a, b, d1, rnd) <= mulDivDirectionalSummary(a,b,d2,rnd);
// }

ghost jtYieldShareCVL(RoycoAccountant.NAV_UNIT, RoycoAccountant.NAV_UNIT, uint256, uint256, RoycoAccountant.NAV_UNIT) returns uint256 {  
    axiom (forall RoycoAccountant.NAV_UNIT stRawNAV. forall RoycoAccountant.NAV_UNIT jtRawNAV. forall uint256 beta. forall uint256 coverage. forall RoycoAccountant.NAV_UNIT jtEffectiveNAV.
        jtYieldShareCVL(stRawNAV, jtRawNAV, beta, coverage, jtEffectiveNAV) < WAD());
}

rule jtTokenValueDoesNotWorsen(env e) {
    uint256 someAmount;
    address receiver;
    method f;
    calldataarg args;

    // assume price is already synced
    uint256 price = kernel.getTrancheUnitToNAVUnitConversionRateWAD(e);
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV == price * kernel.ext_Royco_storage_RoycoKernelState.stOwnedYieldBearingAssets / WAD(), "price is synced";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV == price * kernel.ext_Royco_storage_RoycoKernelState.jtOwnedYieldBearingAssets / WAD(), "price is synced";

    // get the current token value
    RoycoAccountant.NAV_UNIT jtEffectiveNAVBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    RoycoAccountant.NAV_UNIT stEffectiveNAVBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV;
    uint256 jtTotalBefore = juniorTranche.totalSupply();
    uint256 stTotalBefore = seniorTranche.totalSupply();

    f(e, args);

    // get the token value after
    RoycoAccountant.NAV_UNIT jtEffectiveNAVAfter = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    RoycoAccountant.NAV_UNIT stEffectiveNAVAfter = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV;
    uint256 jtTotalAfter = juniorTranche.totalSupply();
    uint256 stTotalAfter = seniorTranche.totalSupply();

    assert jtEffectiveNAVBefore * jtTotalAfter <= jtEffectiveNAVAfter * jtTotalBefore;
}

rule stTokenValueDoesNotWorsen(env e) {
    uint256 someAmount;
    address receiver;
    method f;
    calldataarg args;

    // assume price is already synced
    uint256 price = kernel.getTrancheUnitToNAVUnitConversionRateWAD(e);
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV == price * kernel.ext_Royco_storage_RoycoKernelState.stOwnedYieldBearingAssets / WAD(), "price is synced";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV == price * kernel.ext_Royco_storage_RoycoKernelState.jtOwnedYieldBearingAssets / WAD(), "price is synced";

    // get the current token value
    RoycoAccountant.NAV_UNIT jtEffectiveNAVBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    RoycoAccountant.NAV_UNIT stEffectiveNAVBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV;
    uint256 jtTotalBefore = juniorTranche.totalSupply();
    uint256 stTotalBefore = seniorTranche.totalSupply();

    f(e, args);

    // get the token value after
    RoycoAccountant.NAV_UNIT jtEffectiveNAVAfter = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    RoycoAccountant.NAV_UNIT stEffectiveNAVAfter = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV;
    uint256 jtTotalAfter = juniorTranche.totalSupply();
    uint256 stTotalAfter = seniorTranche.totalSupply();

    assert stEffectiveNAVBefore * stTotalAfter <= stEffectiveNAVAfter * stTotalBefore;
}
