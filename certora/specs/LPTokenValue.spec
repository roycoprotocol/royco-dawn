
/*
 * MODULE
 * @module RoycoKernel
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption upgradeToAndCall and mintProtocolFeeShares are excluded — they change NAV or supply in ways outside the scope of these properties
 * @global_assumption The oracle price is modeled as a constant per rule execution and the pre-state price is already synced
 * @global_assumption totalSupply equals the sum of all balances (tracked via ghost)
 * @global_assumption jtYieldShare is bounded below WAD (modeled as an abstract function satisfying this axiom)
 *
 * PROPERTIES
 * @property KER07 One ST share value (stEffectiveNAV / stTotalSupply) must not decrease across any operation
 * @property KER08 One JT share value (jtEffectiveNAV / jtTotalSupply) must not decrease across any operation (except when self-liquidation bonus applies)
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
    function RoycoAccountant.isCoverageRequirementSatisfied() external returns bool envfree;
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
    function Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.getTrancheUnitToNAVUnitConversionRateWAD() internal returns (uint256) => conversionRateCVL();
    function IdenticalAssetsOracleQuoter._getCachedTrancheUnitToNAVUnitConversionRateWAD() internal returns (uint256) => conversionRateCVL();
    function Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.TRANCHE_UNIT_SCALE_FACTOR() external returns (uint256) envfree;
}

ghost conversionRateCVL() returns uint256;



function canCallCVL() returns (bool) {
    return true;
}

definition excludeUpgradeAndCall(method f) returns bool =
    f.selector != sig:seniorTranche.upgradeToAndCall(address,bytes).selector;
definition excludeMintFee(method f) returns bool =
    f.selector != sig:juniorTranche.mintProtocolFeeShares(RoycoKernel.NAV_UNIT, RoycoKernel.NAV_UNIT, address).selector;

definition isSTRedeem(method f) returns bool =
    (f.selector == sig:seniorTranche.redeem(uint256, address, address).selector ||
    f.selector == sig:seniorTranche.seizeAndRedeemShares(address, address, uint256).selector)
    && f.contract == seniorTranche;


ghost mapping(address => uint256) stBalances;
ghost mapping(address => uint256) jtBalances;

hook Sstore seniorTranche.ext_openzeppelin_storage_ERC20._balances[KEY address account] uint256 newBalance (uint256 oldBalance) {
    stBalances[account] = newBalance;
}
hook Sload uint256 balance seniorTranche.ext_openzeppelin_storage_ERC20._balances[KEY address account] {
    require balance == stBalances[account], "ghost mirror";
}

hook Sstore juniorTranche.ext_openzeppelin_storage_ERC20._balances[KEY address account] uint256 newBalance (uint256 oldBalance) {
    jtBalances[account] = newBalance;
}
hook Sload uint256 balance juniorTranche.ext_openzeppelin_storage_ERC20._balances[KEY address account] {
    require balance == jtBalances[account], "ghost mirror";
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

/**
 * @title JT share value does not decrease across any operation
 * @description The ratio jtEffectiveNAV / jtTotalSupply must not decrease after any operation (excluding upgradeToAndCall and mintProtocolFeeShares). The self-liquidation bonus is excluded when utilization is below 100%.
 * @link_property KER08
 */
rule jtTokenValueDoesNotWorsen(method f, env e, calldataarg args) filtered { f -> excludeUpgradeAndCall(f) && excludeMintFee(f) }
{
    // assume price is already synced
    uint256 price = kernel.getTrancheUnitToNAVUnitConversionRateWAD(e);
    uint256 priceDenom = kernel.TRANCHE_UNIT_SCALE_FACTOR();
    require priceDenom != 0, "TRANCHE_UNIT_SCALE_FACTOR initialized to non-zero value";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV == price * kernel.ext_Royco_storage_RoycoKernelState.stOwnedYieldBearingAssets / priceDenom, "price is synced";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV == price * kernel.ext_Royco_storage_RoycoKernelState.jtOwnedYieldBearingAssets / priceDenom, "price is synced";

    // totalSupply is sum of balances
    require (usum address user. stBalances[user]) == seniorTranche.totalSupply(), "totalSupply invariant";
    require (usum address user. jtBalances[user]) == juniorTranche.totalSupply(), "totalSupply invariant";

    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV + roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV 
        == roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV + roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV, "INV01";

    // get the current token value
    RoycoAccountant.NAV_UNIT jtEffectiveNAVBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    RoycoAccountant.NAV_UNIT stEffectiveNAVBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV;
    uint256 jtTotalBefore = juniorTranche.totalSupply();
    uint256 stTotalBefore = seniorTranche.totalSupply();

    if (isSTRedeem(f)) {
        // the property can be violated if there is liquidation bonus.  Here we restrict to states that don't apply the bonus
        require roycoAccountant.isCoverageRequirementSatisfied(), "utilization is less than 100%";
        require roycoAccountant.ext_Royco_storage_RoycoAccountantState.liquidationUtilizationWAD > WAD(), "invariant: liquidationUtilization > 100%";
    }

    f(e, args);

    // get the token value after
    RoycoAccountant.NAV_UNIT jtEffectiveNAVAfter = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    RoycoAccountant.NAV_UNIT stEffectiveNAVAfter = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV;
    uint256 jtTotalAfter = juniorTranche.totalSupply();
    uint256 stTotalAfter = seniorTranche.totalSupply();

    // someone must have skin in the game
    require jtTotalBefore > 0, "someone is invested";

    assert jtEffectiveNAVBefore * jtTotalAfter <= jtEffectiveNAVAfter * jtTotalBefore, "JT NAV per share increases";
}

/**
 * @title ST share value does not decrease across any operation
 * @description The ratio stEffectiveNAV / stTotalSupply must not decrease after any operation (excluding upgradeToAndCall and mintProtocolFeeShares).
 * @link_property KER07
 */
rule stTokenValueDoesNotWorsen(method f, env e, calldataarg args) filtered { f -> excludeUpgradeAndCall(f) && excludeMintFee(f) }
{
    // assume price is already synced
    uint256 price = kernel.getTrancheUnitToNAVUnitConversionRateWAD(e);
    uint256 priceDenom = kernel.TRANCHE_UNIT_SCALE_FACTOR();
    require priceDenom != 0, "TRANCHE_UNIT_SCALE_FACTOR initialized to non-zero value";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV == price * kernel.ext_Royco_storage_RoycoKernelState.stOwnedYieldBearingAssets / priceDenom, "price is synced";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV == price * kernel.ext_Royco_storage_RoycoKernelState.jtOwnedYieldBearingAssets / priceDenom, "price is synced";

    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV + roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV 
        == roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV + roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV, "INV01";

    // totalSupply is sum of balances
    require (usum address user. stBalances[user]) == seniorTranche.totalSupply(), "totalSupply invariant";
    require (usum address user. jtBalances[user]) == juniorTranche.totalSupply(), "totalSupply invariant";

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

    // someone must have skin in the game
    require stTotalBefore > 0, "someone is invested";

    assert stEffectiveNAVBefore * stTotalAfter <= stEffectiveNAVAfter * stTotalBefore, "ST NAV per share increases";
}



/**
 * @title JT share value does not decrease across any operation
 * @description The ratio jtEffectiveNAV / jtTotalSupply must not decrease after any operation (excluding upgradeToAndCall and mintProtocolFeeShares). The self-liquidation bonus is excluded when utilization is below 100%.
 * @link_property KER08
 */
rule jtTokenValueDoesNotWorsenTooMuch(method f, env e, calldataarg args) filtered { f -> excludeUpgradeAndCall(f) && excludeMintFee(f) }
{
    // assume price is already synced
    uint256 price = kernel.getTrancheUnitToNAVUnitConversionRateWAD(e);
    uint256 priceDenom = kernel.TRANCHE_UNIT_SCALE_FACTOR();
    require priceDenom != 0, "TRANCHE_UNIT_SCALE_FACTOR initialized to non-zero value";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV == price * kernel.ext_Royco_storage_RoycoKernelState.stOwnedYieldBearingAssets / priceDenom, "price is synced";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV == price * kernel.ext_Royco_storage_RoycoKernelState.jtOwnedYieldBearingAssets / priceDenom, "price is synced";

    // totalSupply is sum of balances
    require (usum address user. stBalances[user]) == seniorTranche.totalSupply(), "totalSupply invariant";
    require (usum address user. jtBalances[user]) == juniorTranche.totalSupply(), "totalSupply invariant";

     require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV + roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV 
        == roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV + roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV, "INV01";

    // get the current token value
    RoycoAccountant.NAV_UNIT jtEffectiveNAVBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    RoycoAccountant.NAV_UNIT stEffectiveNAVBefore = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV;
    uint256 jtTotalBefore = juniorTranche.totalSupply();
    uint256 stTotalBefore = seniorTranche.totalSupply();

    if (isSTRedeem(f)) {
        // the property can be violated if there is liquidation bonus.  Here we restrict to states that don't apply the bonus
        require roycoAccountant.isCoverageRequirementSatisfied(), "utilization is less than 100%";
        require roycoAccountant.ext_Royco_storage_RoycoAccountantState.liquidationUtilizationWAD > WAD(), "invariant: liquidationUtilization > 100%";
    }

    f(e, args);

    // get the token value after
    RoycoAccountant.NAV_UNIT jtEffectiveNAVAfter = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    RoycoAccountant.NAV_UNIT stEffectiveNAVAfter = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV;
    uint256 jtTotalAfter = juniorTranche.totalSupply();
    uint256 stTotalAfter = seniorTranche.totalSupply();

    // someone must have skin in the game
    require jtTotalBefore > 0, "someone is invested";

    // jtEffectiveNAVAfter is incremented by two to account for one unit of rounding per tranche.
    assert (jtEffectiveNAVBefore) * jtTotalAfter <= (jtEffectiveNAVAfter + 2) * jtTotalBefore, "JT NAV per share increases";
}

/**
 * @title ST share value does not decrease across any operation
 * @description The ratio stEffectiveNAV / stTotalSupply must not decrease after any operation (excluding upgradeToAndCall and mintProtocolFeeShares).
 * @link_property KER07
 */
rule stTokenValueDoesNotWorsenTooMuch(method f, env e, calldataarg args) filtered { f -> excludeUpgradeAndCall(f) && excludeMintFee(f) }
{
    // assume price is already synced
    uint256 price = kernel.getTrancheUnitToNAVUnitConversionRateWAD(e);
    uint256 priceDenom = kernel.TRANCHE_UNIT_SCALE_FACTOR();
    require priceDenom != 0, "TRANCHE_UNIT_SCALE_FACTOR initialized to non-zero value";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV == price * kernel.ext_Royco_storage_RoycoKernelState.stOwnedYieldBearingAssets / priceDenom, "price is synced";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV == price * kernel.ext_Royco_storage_RoycoKernelState.jtOwnedYieldBearingAssets / priceDenom, "price is synced";

    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV + roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV 
        == roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV + roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV, "INV01";

    // totalSupply is sum of balances
    require (usum address user. stBalances[user]) == seniorTranche.totalSupply(), "totalSupply invariant";
    require (usum address user. jtBalances[user]) == juniorTranche.totalSupply(), "totalSupply invariant";

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

    // someone must have skin in the game
    require stTotalBefore > 0, "someone is invested";

    // stEffectiveNAVAfter is incremented by two to account for one unit of rounding per tranche.
    assert (stEffectiveNAVBefore) * stTotalAfter <= (stEffectiveNAVAfter + 2) * stTotalBefore, "ST NAV per share increases";
}
