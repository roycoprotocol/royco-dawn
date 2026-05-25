
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

    uint256 cov = roycoAccountant.ext_Royco_storage_RoycoAccountantState.coverageWAD;
    uint256 beta = roycoAccountant.ext_Royco_storage_RoycoAccountantState.betaWAD;

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

    mathint toCoverBefore = (stRawNAVBefore + (jtRawNAVBefore * beta / WAD())) * cov;

    juniorTranche.deposit(e, amount, receiver);

    uint256 jtEffectiveNAVAfter = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    uint256 jtRawNAVAfter = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV;
    uint256 stRawNAVAfter = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV;
    mathint toCoverAfter = (stRawNAVAfter + (jtRawNAVAfter * beta / WAD())) * cov;

    assert stRawNAVAfter == stRawNAVBefore;
    assert jtEffectiveNAVAfter >= jtEffectiveNAVBefore;
    assert jtRawNAVAfter - jtRawNAVBefore == jtEffectiveNAVAfter - jtEffectiveNAVBefore;
    assert toCoverAfter - toCoverBefore <= jtEffectiveNAVAfter - jtEffectiveNAVBefore;
    
    assert roycoAccountant.isCoverageRequirementSatisfied(),  "jtRedeem must not violate utilization";
}

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

    mathint toCoverBefore = (stRawNAVBefore + (jtRawNAVBefore * beta / WAD())) * cov;

    seniorTranche.redeem(e, amount, receiver, owner);

    uint256 jtEffectiveNAVAfter = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    uint256 jtRawNAVAfter = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV;
    uint256 stRawNAVAfter = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV;
    mathint toCoverAfter = (stRawNAVAfter + (jtRawNAVAfter * beta / WAD())) * cov;

    assert stRawNAVAfter <= stRawNAVBefore;
    assert jtRawNAVAfter <= jtRawNAVBefore;
    assert jtEffectiveNAVAfter == jtEffectiveNAVBefore;
    assert toCoverAfter <= toCoverBefore;

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

    assert roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastMarketState != RoycoAccountant.MarketState.FIXED_TERM, "jtDeposit reverts in fixe term";
}

rule stDepositRevertsWithImpermanentLoss(env e) {
    uint256 amount;
    address receiver;
    seniorTranche.deposit(e, amount, receiver);

    assert roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTImpermanentLoss == 0, "stDeposit reverts with impermanent loss";
}
