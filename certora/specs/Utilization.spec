
/*
 * MODULE
 * @module RoycoKernel
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption The oracle price (getTrancheUnitToNAVUnitConversionRateWAD) is modeled as a constant per rule execution
 * @global_assumption The pre-state price is already synced to stored NAV values where explicitly required
 * @global_assumption canCall always returns true (authorization is tested separately in TrancheInvariants)
 *
 * PROPERTIES
 * @property KER01 marketstate = FIXED_TERM implies stRedeem and jtDeposit must revert
 * @property KER02 stImpermanentLoss > 0 implies stDeposit must revert
 * @property UTI02 stRedeem and jtDeposit always decrease or preserve utilization (coverage requirement remains satisfied)
 * @property UTI03 stDeposit and jtRedeem must not violate the coverage requirement (utilization must remain satisfied after)
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
    function Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.getTrancheUnitToNAVUnitConversionRateWAD() internal returns (uint256) => conversionRateCVL();
    function IdenticalAssetsOracleQuoter._getCachedTrancheUnitToNAVUnitConversionRateWAD() internal returns (uint256) => conversionRateCVL();
    function RoycoAccountant.isCoverageRequirementSatisfied() external returns bool envfree;
    function Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.TRANCHE_UNIT_SCALE_FACTOR() external returns (uint256) envfree;
}

ghost conversionRateCVL() returns uint256;
definition WAD() returns mathint = 10^18;
definition MIN_COVERAGE_WAD() returns mathint = 10^16;   // 1 %
definition MAX_COVERAGE_WAD() returns mathint = 10^18-1; // 99.9999999999999999 %

/**
 * @title ST deposit does not violate the coverage requirement
 * @description After an ST deposit, the coverage requirement (utilization ≤ 100%) must be satisfied; ST deposits increase the pool that needs to be covered but must not push utilization over the limit.
 * @link_property UTI03
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/8d90ae11511f423e9603e88e07415cd1/?anonymousKey=5c1f15b3dba2aec978a7913153bf7c1dfd3855e2
 */
rule stDepositEnsuresUtilization(env e) {
    address receiver;
    uint256 amount;

    seniorTranche.deposit(e, amount, receiver);

    assert roycoAccountant.isCoverageRequirementSatisfied(),  "stDeposit must not violate utilization";
}

/**
 * @title JT redeem does not violate the coverage requirement
 * @description After a JT redeem, the coverage requirement must be satisfied; the implementation must revert if redeeming JT would push utilization over the limit.
 * @link_property UTI03
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/8d90ae11511f423e9603e88e07415cd1/?anonymousKey=5c1f15b3dba2aec978a7913153bf7c1dfd3855e2
 */
rule jtRedeemEnsuresUtilization(env e) {
    address owner;
    address receiver;
    uint256 amount;

    juniorTranche.redeem(e, amount, receiver, owner);

    assert roycoAccountant.isCoverageRequirementSatisfied(),  "jtRedeem must not violate utilization";
}

/**
 * @title JT deposit decreases or preserves utilization
 * @description A JT deposit adds JT-side coverage and must not worsen (increase) utilization; if coverage was satisfied before, it remains satisfied after.
 * @link_property UTI02
 * @status VIOLATED
 */
rule jtDepositPreservesUtilization(env e) {
    address receiver;
    uint256 amount;

    uint256 cov = roycoAccountant.ext_Royco_storage_RoycoAccountantState.coverageWAD;
    uint256 beta = roycoAccountant.ext_Royco_storage_RoycoAccountantState.betaWAD;

    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV + roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV 
        == roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV + roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV, "INV01";

    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.coverageWAD *
        roycoAccountant.ext_Royco_storage_RoycoAccountantState.betaWAD < WAD()*WAD(), "cov*beta < 1";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.coverageWAD >= MIN_COVERAGE_WAD(), "cov >= MIN";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.coverageWAD <= MAX_COVERAGE_WAD(), "cov <= MAX";

    require roycoAccountant.isCoverageRequirementSatisfied(), "coverage enough in pre-state";
    // assume price is already synced
    uint256 price = kernel.getTrancheUnitToNAVUnitConversionRateWAD(e);
    uint256 priceDenom = kernel.TRANCHE_UNIT_SCALE_FACTOR();
    require priceDenom != 0, "TRANCHE_UNIT_SCALE_FACTOR initialized to non-zero value";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV == price * kernel.ext_Royco_storage_RoycoKernelState.stOwnedYieldBearingAssets / priceDenom, "price is synced";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV == price * kernel.ext_Royco_storage_RoycoKernelState.jtOwnedYieldBearingAssets / priceDenom, "price is synced";

    uint256 jtEffectiveNAVBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    uint256 jtRawNAVBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV;
    uint256 stRawNAVBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV;

    mathint toCoverBefore = (stRawNAVBefore + (jtRawNAVBefore * beta + WAD() - 1) / WAD()) * cov;

    juniorTranche.deposit(e, amount, receiver);

    uint256 jtEffectiveNAVAfter = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    uint256 jtRawNAVAfter = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV;
    uint256 stRawNAVAfter = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV;
    mathint toCoverAfter = (stRawNAVAfter + (jtRawNAVAfter * beta + WAD() - 1) / WAD()) * cov;

    assert stRawNAVAfter == stRawNAVBefore;
    assert jtEffectiveNAVAfter >= jtEffectiveNAVBefore;
    assert jtRawNAVAfter - jtRawNAVBefore == jtEffectiveNAVAfter - jtEffectiveNAVBefore;
    assert toCoverAfter - toCoverBefore <= WAD() * (jtEffectiveNAVAfter - jtEffectiveNAVBefore);
    
    assert roycoAccountant.isCoverageRequirementSatisfied(),  "jtRedeem must not violate utilization";
}

/**
 * @title ST redeem decreases or preserves utilization
 * @description An ST redeem removes ST-side exposure and must not worsen utilization; if coverage was satisfied before, it remains satisfied after.
 * @link_property UTI02
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/f4767624ac28415ca6079a79fe9501ea/?anonymousKey=11efda4184e0a844fc69b85699d548e5784aaa4f
 */
rule stRedeemPreservesUtilization(env e) {
    address receiver;
    address owner;
    uint256 amount;

    uint256 cov = roycoAccountant.ext_Royco_storage_RoycoAccountantState.coverageWAD;
    uint256 beta = roycoAccountant.ext_Royco_storage_RoycoAccountantState.betaWAD;

    // invariants proven in AccountantInvariants
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.coverageWAD *
        roycoAccountant.ext_Royco_storage_RoycoAccountantState.betaWAD < WAD()*WAD(), "cov*beta < 1";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.coverageWAD >= MIN_COVERAGE_WAD(), "cov >= MIN";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.coverageWAD <= MAX_COVERAGE_WAD(), "cov <= MAX";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.liquidationUtilizationWAD > WAD(), "liquidationUtilization > 1";

    require roycoAccountant.isCoverageRequirementSatisfied(), "coverage enough in pre-state";
    // assume price is already synced
    uint256 price = kernel.getTrancheUnitToNAVUnitConversionRateWAD(e);
    uint256 priceDenom = kernel.TRANCHE_UNIT_SCALE_FACTOR();
    require priceDenom != 0, "TRANCHE_UNIT_SCALE_FACTOR initialized to non-zero value";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV == price * kernel.ext_Royco_storage_RoycoKernelState.stOwnedYieldBearingAssets / priceDenom, "price is synced";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV == price * kernel.ext_Royco_storage_RoycoKernelState.jtOwnedYieldBearingAssets / priceDenom, "price is synced";

    uint256 jtEffectiveNAVBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    uint256 jtRawNAVBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV;
    uint256 stRawNAVBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV;

    mathint toCoverBefore = (stRawNAVBefore + (jtRawNAVBefore * beta + WAD() - 1) / WAD()) * cov;

    seniorTranche.redeem(e, amount, receiver, owner);

    uint256 jtEffectiveNAVAfter = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    uint256 jtRawNAVAfter = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV;
    uint256 stRawNAVAfter = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV;
    mathint toCoverAfter = (stRawNAVAfter + (jtRawNAVAfter * beta + WAD() - 1) / WAD()) * cov;

    assert stRawNAVAfter <= stRawNAVBefore;
    assert jtRawNAVAfter <= jtRawNAVBefore;
    assert jtEffectiveNAVAfter == jtEffectiveNAVBefore;
    assert toCoverAfter <= toCoverBefore;

    assert roycoAccountant.isCoverageRequirementSatisfied(),  "jtRedeem must not violate utilization";
}

/**
 * @title ST redeem reverts in FIXED_TERM market state
 * @description In a fixed-term market, ST holders cannot redeem; the call must revert if the market state is FIXED_TERM.
 * @link_property KER01
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/8d90ae11511f423e9603e88e07415cd1/?anonymousKey=5c1f15b3dba2aec978a7913153bf7c1dfd3855e2
 */
rule stRedeemRevertsInFixedTerm(env e) {
    uint256 amount;
    address receiver;
    address owner;
    seniorTranche.redeem(e, amount, receiver, owner);

    assert roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastMarketState != RoycoAccountant.MarketState.FIXED_TERM, "stRedeem reverts in fixe term";
}

/**
 * @title JT deposit reverts in FIXED_TERM market state
 * @description In a fixed-term market, new JT deposits are not allowed; the call must revert if the market state is FIXED_TERM.
 * @link_property KER01
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/8d90ae11511f423e9603e88e07415cd1/?anonymousKey=5c1f15b3dba2aec978a7913153bf7c1dfd3855e2
 */
rule jtDepositRevertsInFixedTerm(env e) {
    uint256 amount;
    address receiver;
    juniorTranche.deposit(e, amount, receiver);

    assert roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastMarketState != RoycoAccountant.MarketState.FIXED_TERM, "jtDeposit reverts in fixe term";
}

/**
 * @title ST deposit reverts when stImpermanentLoss > 0
 * @description When the ST tranche is in a distressed state (stImpermanentLoss > 0), new ST deposits must revert to prevent dilution of the loss.
 * @link_property KER02
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/8d90ae11511f423e9603e88e07415cd1/?anonymousKey=5c1f15b3dba2aec978a7913153bf7c1dfd3855e2
 */
rule stDepositRevertsWithImpermanentLoss(env e) {
    uint256 amount;
    address receiver;
    seniorTranche.deposit(e, amount, receiver);

    assert roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTImpermanentLoss == 0, "stDeposit reverts with impermanent loss";
}
