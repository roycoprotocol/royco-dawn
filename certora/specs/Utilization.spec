
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
    function RoycoAccountant.isCoverageRequirementSatisfied() external returns bool envfree;
}

definition WAD() returns mathint = 10^18;

rule stDepositEnsuresUtilization(env e) {
    address receiver;
    uint256 amount;

    seniorTranche.deposit(e, amount, receiver);

    assert roycoAccountant.isCoverageRequirementSatisfied(),  "stDeposit must not violate utilization";
}

rule jtRedeemEnsuresUtilization(env e) {
    address owner;
    address receiver;
    uint256 amount;

    juniorTranche.redeem(e, amount, receiver, owner);

    assert roycoAccountant.isCoverageRequirementSatisfied(),  "jtRedeem must not violate utilization";
}

rule jtDepositPreservesUtilization(env e) {
    address receiver;
    uint256 amount;

    require roycoAccountant.isCoverageRequirementSatisfied(), "coverage enough in pre-state";

    juniorTranche.deposit(e, amount, receiver);

    assert roycoAccountant.isCoverageRequirementSatisfied(),  "jtRedeem must not violate utilization";
}

rule stRedeemRevertsInFixedTerm(env e) {
    uint256 amount;
    address receiver;
    address owner;
    seniorTranche.redeem(e, amount, receiver, owner);

    assert roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastMarketState != RoycoAccountant.MarketState.FIXED_TERM, "stRedeem reverts in fixe term";
}

rule jtDepositRevertsInFixedTerm(env e) {
    uint256 amount;
    address receiver;
    juniorTranche.deposit(e, amount, receiver);

    assert roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastMarketState != RoycoAccountant.MarketState.FIXED_TERM, "stRedeem reverts in fixe term";
}
