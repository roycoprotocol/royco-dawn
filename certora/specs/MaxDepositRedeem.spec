
/*
 * MODULE
 * @module OldMaxDepositRedeem -> new in AccountantMaxDepositRedeem
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption canCall always returns true (authorization tested separately)
 * @global_assumption The oracle price is modeled as a constant
 * @global_assumption mulDiv is summarized with monotonicity axioms (directional summary)
 * @global_assumption jtYieldShare is bounded below WAD
 * @global_assumption Reasonable NAV bounds (stOwnedYieldBearingAssets and jtOwnedYieldBearingAssets < 2^200) are assumed to avoid overflow
 *
 * PROPERTIES
 * @property KER09 redeem(maxRedeem()) must not revert (unless blacklisted, paused, etc.)
 * @property KER10 deposit(maxDeposit()) must not revert (unless blacklisted, paused, etc.)
 */

import "../summaries/using-Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.spec";
//import "../summaries/summaries-RoycoAccountant.spec";
//import "../external/external-nondet.spec";
//import "../lib-summaries/OpenZeppelin/OZ_SafeERC20.spec";
//import "../lib-summaries/OpenZeppelin/OZ_Math.spec";
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
    function Math.mulDiv(uint256 x, uint256 y, uint256 denominator) internal returns (uint256) => mulDivDirectionalSummary(x,y,denominator, Math.Rounding.Floor);
    function Math.mulDiv(uint256 x, uint256 y, uint256 denominator, Math.Rounding rounding) internal returns (uint256) => mulDivDirectionalSummary(x, y, denominator, rounding);
    // SafeERC20 internal functions summarized as direct token calls
    function _.safeTransfer(address token, address to, uint256 value) internal => NONDET;
    function _.safeTransferFrom(address token, address from, address to, uint256 value) internal => NONDET;
    function Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.getTrancheUnitToNAVUnitConversionRateWAD() internal returns (uint256) => CONSTANT;
}

definition WAD() returns mathint = 10^18;

function canCallCVL() returns (bool) {
    return true;
}

ghost mulDivDirectionalSummary(uint256, uint256, uint256, Math.Rounding) returns uint256
{
    axiom forall uint256 a. forall uint256 d. forall Math.Rounding rnd.
        mulDivDirectionalSummary(a,0, d, rnd) == 0;
    axiom forall uint256 a1. forall uint256 a2. forall uint256 b. forall uint256 d. forall Math.Rounding rnd.
        a1 <= a2 => mulDivDirectionalSummary(a1, b, d, rnd) <= mulDivDirectionalSummary(a2,b,d,rnd);
//    axiom forall uint256 a. forall uint256 b1. forall uint256 b2. forall uint256 d. forall Math.Rounding rnd.
//        b1 <= b2 => mulDivDirectionalSummary(a, b1, d, rnd) <= mulDivDirectionalSummary(a,b2,d,rnd);
//    axiom forall uint256 a. forall uint256 b. forall uint256 d1. forall uint256 d2. forall Math.Rounding rnd.
//        d1 >= d2 => mulDivDirectionalSummary(a, b, d1, rnd) <= mulDivDirectionalSummary(a,b,d2,rnd);
}

ghost jtYieldShareCVL(RoycoAccountant.NAV_UNIT, RoycoAccountant.NAV_UNIT, uint256, uint256, RoycoAccountant.NAV_UNIT) returns uint256 {  
    axiom (forall RoycoAccountant.NAV_UNIT stRawNAV. forall RoycoAccountant.NAV_UNIT jtRawNAV. forall uint256 beta. forall uint256 coverage. forall RoycoAccountant.NAV_UNIT jtEffectiveNAV.
        jtYieldShareCVL(stRawNAV, jtRawNAV, beta, coverage, jtEffectiveNAV) < WAD());
}

/**
 * @title deposit(maxDeposit()) for ST does not revert
 * @description If maxDeposit() returns a positive amount, depositing exactly that amount must succeed; the max deposit function must return a tight and accurate upper bound.
 * @link_property KER10
 * @status WIP
 */
rule stDepositMaxDoesNotRevert(env e) {
    uint256 someAmount;
    address receiver;

    require e.msg.value == 0, "Not payable";
//    require !seniorTranche.paused(e);
//    require !kernel.paused(e);
//    require receiver != 0;
//    require !kernel.ext_openzeppelin_storage_ReentrancyGuard == 0;
//    require !kernel.isBlacklisted(e, e.msg.sender);
//    require !kernel.exttload

    require kernel.ext_Royco_storage_RoycoKernelState.stOwnedYieldBearingAssets < 2^200;
    require kernel.ext_Royco_storage_RoycoKernelState.jtOwnedYieldBearingAssets < 2^200;

    storage initstate = lastStorage;
    seniorTranche.deposit(e, someAmount, receiver);

    uint256 maxAmount = seniorTranche.maxDeposit(e, receiver) at initstate;
    require maxAmount > 0;
    require maxAmount < 2^200;
    seniorTranche.deposit@withrevert(e, maxAmount, receiver);

    assert !lastReverted, "No revert when depositing max amount";
}



/**
 * @title deposit(maxDeposit()) for JT does not revert
 * @description If maxDeposit() returns a positive amount for JT, depositing exactly that amount must succeed; the max deposit function must return a tight and accurate upper bound.
 * @link_property KER10
 * @status WIP
 */
rule jtDepositMaxDoesNotRevert(env e) {
    uint256 someAmount;
    address receiver;

    require e.msg.value == 0, "Not payable";
//    require !seniorTranche.paused(e);
//    require !kernel.paused(e);
//    require receiver != 0;
//    require !kernel.ext_openzeppelin_storage_ReentrancyGuard == 0;
//    require !kernel.isBlacklisted(e, e.msg.sender);
//    require !kernel.exttload

    //require kernel.ext_Royco_storage_RoycoKernelState.stOwnedYieldBearingAssets < 2^200;
    //require kernel.ext_Royco_storage_RoycoKernelState.jtOwnedYieldBearingAssets < 2^200;

    storage initstate = lastStorage;
    juniorTranche.deposit(e, someAmount, receiver);

    uint256 maxAmount = juniorTranche.maxDeposit(e, receiver) at initstate;
    //require maxAmount > 0;
    //require maxAmount < 2^200;
    juniorTranche.deposit@withrevert(e, maxAmount, receiver);

    assert !lastReverted, "No revert when depositing max amount";
}


/**
 * @title redeem(maxRedeem()) for ST does not revert
 * @description If maxRedeem() returns a positive amount for ST, redeeming exactly that amount (with sufficient allowance) must succeed; the max redeem function must return a tight and accurate upper bound.
 * @link_property KER09
 * @status WIP
 */
rule stRedeemMaxDoesNotRevert(env e) {
    uint256 someAmount;
    address receiver;
    address owner;

    require e.msg.value == 0, "Not payable";

    require kernel.ext_Royco_storage_RoycoKernelState.stOwnedYieldBearingAssets < 2^200;
    require kernel.ext_Royco_storage_RoycoKernelState.jtOwnedYieldBearingAssets < 2^200;

    storage initstate = lastStorage;
    seniorTranche.redeem(e, someAmount, receiver, owner);

    uint256 maxAmount = seniorTranche.maxRedeem(e, owner) at initstate;
    require maxAmount > 0;
    require maxAmount < 2^200;
    require seniorTranche.allowance(owner, e.msg.sender) >= maxAmount;
    seniorTranche.redeem@withrevert(e, maxAmount, receiver, owner);

    assert !lastReverted, "No revert when depositing max amount";
}

/**
 * @title redeem(maxRedeem()) for JT does not revert
 * @description If maxRedeem() returns a positive amount for JT, redeeming exactly that amount (with sufficient allowance) must succeed; the max redeem function must return a tight and accurate upper bound.
 * @link_property KER09
 * @status WIP
 */
rule jtRedeemMaxDoesNotRevert(env e) {
    uint256 someAmount;
    address receiver;
    address owner;

    require e.msg.value == 0, "Not payable";

    require kernel.ext_Royco_storage_RoycoKernelState.stOwnedYieldBearingAssets < 2^200;
    require kernel.ext_Royco_storage_RoycoKernelState.jtOwnedYieldBearingAssets < 2^200;

    storage initstate = lastStorage;
    juniorTranche.redeem(e, someAmount, receiver, owner);

    uint256 maxAmount = juniorTranche.maxRedeem(e, owner) at initstate;
    require maxAmount > 0;
    require maxAmount < 2^200;
    require juniorTranche.allowance(owner, e.msg.sender) >= maxAmount;
    juniorTranche.redeem@withrevert(e, maxAmount, receiver, owner);

    assert !lastReverted, "No revert when depositing max amount";
}
