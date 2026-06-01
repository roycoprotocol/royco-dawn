
/*
 * MODULE
 * @module RoycoKernel
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption postOpSyncTrancheAccounting is summarized as postOpUsageCheck to intercept and verify the call arguments
 * @global_assumption The oracle price is modeled as a constant
 * @global_assumption safeTransfer and safeTransferFrom are modeled as NONDET
 *
 * PROPERTIES
 * @property POST02 The kernel calls postOpSyncTrancheAccounting with arguments consistent with the operation type: deposits increase NAV, redeems decrease NAV, no cross-tranche NAV changes on deposit, no self-liquidation bonus on deposit or JT_REDEEM
 */

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
    function _.canCall(address,address,bytes4) external => NONDET;
    function _.consumeScheduledOp(address,bytes) external => NONDET;
    function _.syncTrancheAccounting() external => DISPATCHER(true);
    function _.previewJTYieldShare(StaticCurveYDM.MarketState,StaticCurveYDM.NAV_UNIT,StaticCurveYDM.NAV_UNIT,uint256,uint256,StaticCurveYDM.NAV_UNIT) external => DISPATCHER(true);
    function _.jtYieldShare(StaticCurveYDM.MarketState,StaticCurveYDM.NAV_UNIT,StaticCurveYDM.NAV_UNIT,uint256,uint256,StaticCurveYDM.NAV_UNIT) external => DISPATCHER(true);
    // function Math.mulDiv(uint256 x, uint256 y, uint256 denominator) internal returns (uint256) => mulDivDirectionalSummary(x,y,denominator, Math.Rounding.Floor);
    // function Math.mulDiv(uint256 x, uint256 y, uint256 denominator, Math.Rounding rounding) internal returns (uint256) => mulDivDirectionalSummary(x, y, denominator, rounding);
    // SafeERC20 internal functions summarized as direct token calls
    function _.safeTransfer(address token, address to, uint256 value) internal => NONDET;
    function _.safeTransferFrom(address token, address from, address to, uint256 value) internal => NONDET;
    function Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.getTrancheUnitToNAVUnitConversionRateWAD() internal returns (uint256) => CONSTANT;
    function RoycoAccountant.postOpSyncTrancheAccounting(RoycoAccountant.Operation op, RoycoAccountant.NAV_UNIT stRawNAV, RoycoAccountant.NAV_UNIT jtRawNAV, RoycoAccountant.NAV_UNIT stSelfLiquidationBonusNAV) internal returns (RoycoAccountant.SyncedAccountingState memory) => postOpUsageCheck(op, stRawNAV, jtRawNAV, stSelfLiquidationBonusNAV);
}

definition WAD() returns mathint = 10^18;

function postOpUsageCheck(RoycoAccountant.Operation op, RoycoAccountant.NAV_UNIT stRawNAV, RoycoAccountant.NAV_UNIT jtRawNAV, RoycoAccountant.NAV_UNIT stSelfLiquidationBonusNAV) returns (RoycoAccountant.SyncedAccountingState) {
    RoycoAccountant.SyncedAccountingState state;

    mathint deltaST = stRawNAV - roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV;
    mathint deltaJT = jtRawNAV - roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV;

    assert op == RoycoAccountant.Operation.ST_DEPOSIT => deltaST >= 0 && deltaJT == 0 && stSelfLiquidationBonusNAV == 0;
    assert op == RoycoAccountant.Operation.JT_DEPOSIT => deltaST == 0 && deltaJT >= 0 && stSelfLiquidationBonusNAV == 0;
    assert op == RoycoAccountant.Operation.ST_REDEEM => deltaST <= 0 && deltaJT <= 0;
    assert op == RoycoAccountant.Operation.JT_REDEEM => deltaST <= 0 && deltaJT <= 0 && stSelfLiquidationBonusNAV == 0;

    return state;
}


/**
 * @title Kernel calls postOpSyncTrancheAccounting with correct arguments per operation
 * @description For every kernel operation, the arguments passed to postOpSyncTrancheAccounting must be consistent with the operation type: deposits increase NAV (not decrease), redeems decrease NAV (not increase), deposits carry no self-liquidation bonus, JT operations do not cross-affect ST NAV.
 * @link_property POST02
 * @status WIP
 */
rule checkPostOpUsage(method f, env e, calldataarg args) {
    f(e,args);

    // The checks are in postOpUsageCheck
    assert true;
}
