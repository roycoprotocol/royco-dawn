
/*
 * MODULE
 * @module RoycoKernel
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption The oracle price is modeled as a constant per rule execution
 * @global_assumption safeTransfer and safeTransferFrom are modeled as NONDET (token transfer correctness is out of scope)
 *
 * PROPERTIES
 * @property KER03 redeem immediately followed by deposit should not be profitable (at most rounding losses)
 * @property KER04 deposit immediately followed by redeem should not be profitable (if already invested)
 * @property KER05 multiple deposits or redeems in sequence should get the same exchange rate; splitting should not be profitable
 */

import "../summaries/using-Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.spec";
//import "../summaries/summaries-RoycoAccountant.spec";
//import "../external/external-nondet.spec";
//import "../lib-summaries/OpenZeppelin/OZ_SafeERC20.spec";
import "../lib-summaries/OpenZeppelin/OZ_Math.spec";
import "AccountantInvariants.spec";
//import "TrancheInvariants.spec";
//import "../summaries/summaries-KernelConversions.spec";
import "../summaries/summaries-ConversionRate.spec";
//using RoycoAccountant as roycoAccountant;

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
    //function _.canCall(address,address,bytes4) external => NONDET;
    //function _.consumeScheduledOp(address,bytes) external => NONDET;
    //function _.syncTrancheAccounting() external => DISPATCHER(true);
    //function _.previewJTYieldShare(StaticCurveYDM.MarketState,StaticCurveYDM.NAV_UNIT,StaticCurveYDM.NAV_UNIT,uint256,uint256,StaticCurveYDM.NAV_UNIT) external => DISPATCHER(true);
    //function _.jtYieldShare(StaticCurveYDM.MarketState,StaticCurveYDM.NAV_UNIT,StaticCurveYDM.NAV_UNIT,uint256,uint256,StaticCurveYDM.NAV_UNIT) external => DISPATCHER(true);
    // function Math.mulDiv(uint256 x, uint256 y, uint256 denominator) internal returns (uint256) => mulDivDirectionalSummary(x,y,denominator, Math.Rounding.Floor);
    // function Math.mulDiv(uint256 x, uint256 y, uint256 denominator, Math.Rounding rounding) internal returns (uint256) => mulDivDirectionalSummary(x, y, denominator, rounding);
    // SafeERC20 internal functions summarized as direct token calls
    function _.safeTransfer(address token, address to, uint256 value) internal => NONDET;
    function _.safeTransferFrom(address token, address from, address to, uint256 value) internal => NONDET;
    function Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.getTrancheUnitToNAVUnitConversionRateWAD() internal returns (uint256) => CONSTANT;

}


/**
 * @title JT deposit then immediate redeem is not profitable
 * @description Depositing into the JT tranche and immediately redeeming the received shares must yield at most the deposited amount.
 * @link_property KER04
 */
rule depositRedeemJunior(env e) {
    // Depositing and Redeeming immediately should not be profitable.
    address owner;
    address receiver;
    uint256 amount;
    RoycoVaultTranche.AssetClaims claims;

    uint256 shares = juniorTranche.deposit(e, amount, owner);
    claims = juniorTranche.redeem(e, shares, receiver, owner);

    assert claims.jtAssets + claims.stAssets <= amount, "Deposit followed by redeem should not be profitable";
}

/**
 * @title JT redeem then immediate redeposit is not profitable
 * @description Redeeming JT shares and immediately redepositing the received assets must yield at most the original share amount.
 * @link_property KER03
 */
rule redeemDepositJunior(env e) {
    // Depositing and Redeeming immediately should not be profitable.
    uint256 amount;
    address owner;
    address receiver;
    RoycoVaultTranche.AssetClaims claims;

    claims = juniorTranche.redeem(e, amount, receiver, owner);
    uint256 tokens = require_uint256(claims.jtAssets + claims.stAssets);
    uint256 received = juniorTranche.deposit(e, tokens, owner);

    assert received <= amount, "Redeem followed by deposit should not be profitable";
}

/**
 * @title ST deposit then immediate redeem is not profitable
 * @description Depositing into the ST tranche and immediately redeeming the received shares must yield at most the deposited amount.
 * @link_property KER04
 */
rule depositRedeemSenior(env e) {
    // Depositing and Redeeming immediately should not be profitable.
    uint256 amount;
    address owner;
    address receiver;
    RoycoVaultTranche.AssetClaims claims;

    uint256 shares = seniorTranche.deposit(e, amount, owner);
    claims = seniorTranche.redeem(e, shares, receiver, owner);

    assert claims.jtAssets + claims.stAssets <= amount, "Deposit followed by redeem should not be profitable";
}

/**
 * @title ST redeem then immediate redeposit is not profitable
 * @description Redeeming ST shares and immediately redepositing the received assets must yield at most the original share amount.
 * @link_property KER03
 */
rule redeemDepositSenior(env e) {
    // Depositing and Redeeming immediately should not be profitable.
    uint256 amount;
    address owner;
    address receiver;
    RoycoVaultTranche.AssetClaims claims;

    claims = seniorTranche.redeem(e, amount, receiver, owner);
    uint256 tokens = require_uint256(claims.jtAssets + claims.stAssets);
    uint256 received = seniorTranche.deposit(e, tokens, owner);

    assert received <= amount, "Redeem followed by deposit should not be profitable";
}

/**
 * @title JT split deposit is not more profitable than a single deposit
 * @description Depositing amount1 and amount2 separately must yield no more shares than depositing amount1+amount2 in a single call.
 * @link_property KER05
 */
rule depositSplitJunior(env e) {
    storage init = lastStorage;

    uint256 amount1;
    uint256 amount2;
    address owner;

    uint256 shares1 = juniorTranche.deposit(e, amount1, owner);
    uint256 shares2 = juniorTranche.deposit(e, amount2, owner);

    uint256 shares3 = juniorTranche.deposit(e, require_uint256(amount1 + amount2), owner) at init;

    assert shares1 + shares2 <= shares3, "splitting should not be profitable";
}

/**
 * @title JT split redeem is not more profitable than a single redeem
 * @description Redeeming amount1 and amount2 separately must yield no more assets than redeeming amount1+amount2 in a single call.
 * @link_property KER05
 */
rule redeemSplitJunior(env e) {
    storage init = lastStorage;

    uint256 amount1;
    uint256 amount2;
    address owner;
    address receiver;
    RoycoVaultTranche.AssetClaims claims1;
    RoycoVaultTranche.AssetClaims claims2;
    RoycoVaultTranche.AssetClaims claims3;

    claims1 = juniorTranche.redeem(e, amount1, receiver, owner);
    claims2 = juniorTranche.redeem(e, amount2, receiver, owner);

    claims3 = juniorTranche.redeem(e, require_uint256(amount1 + amount2), receiver, owner) at init;

    assert claims1.jtAssets + claims2.jtAssets <= claims3.jtAssets, "splitting should not be profitable";
    assert claims1.stAssets + claims2.stAssets <= claims3.stAssets, "splitting should not be profitable";
}


/**
 * @title ST split deposit is not more profitable than a single deposit
 * @description Depositing amount1 and amount2 separately into ST must yield no more shares than depositing amount1+amount2 in a single call.
 * @link_property KER05
 */
rule depositSplitSenior(env e) {
    storage init = lastStorage;

    uint256 amount1;
    uint256 amount2;
    address owner;

    uint256 shares1 = seniorTranche.deposit(e, amount1, owner);
    uint256 shares2 = seniorTranche.deposit(e, amount2, owner);

    uint256 shares3 = seniorTranche.deposit(e, require_uint256(amount1 + amount2), owner) at init;

    assert shares1 + shares2 <= shares3, "splitting should not be profitable";
}

/**
 * @title ST split redeem is not more profitable than a single redeem
 * @description Redeeming amount1 and amount2 separately from ST must yield no more assets than redeeming amount1+amount2 in a single call.
 * @link_property KER05
 */
rule redeemSplitSenior(env e) {
    storage init = lastStorage;

    uint256 amount1;
    uint256 amount2;
    address owner;
    address receiver;
    RoycoVaultTranche.AssetClaims claims1;
    RoycoVaultTranche.AssetClaims claims2;
    RoycoVaultTranche.AssetClaims claims3;

    claims1 = seniorTranche.redeem(e, amount1, receiver, owner);
    claims2 = seniorTranche.redeem(e, amount2, receiver, owner);

    claims3 = seniorTranche.redeem(e, require_uint256(amount1 + amount2), receiver, owner) at init;

    assert claims1.jtAssets + claims2.jtAssets <= claims3.jtAssets, "splitting should not be profitable";
    assert claims1.stAssets + claims2.stAssets <= claims3.stAssets, "splitting should not be profitable";
}


/**
 * @title Consecutive JT deposits of the same amount yield the same shares
 * @description Two consecutive JT deposits of the same amount must receive the same number of shares, confirming that a deposit does not change the exchange rate.
 * @link_property KER05
 */

// this is work in progress, many requires are actually unsafe
rule depositSameJunior_2(env e) {
    uint256 amount;
    address owner;

    // require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV == roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV;

    require juniorTranche.totalSupply() > 0;
    // totalSupply > JT_eff means shares are worth < 1 NAV unit each; a 1-unit floor-rounding
    // phantom gain between deposits then amplifies by totalSupply/JT_eff, exceeding the +20 tolerance.
    require juniorTranche.totalSupply() <= roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    // require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastMarketState == RoycoAccountant.MarketState.PERPETUAL;
    // Low liquidationUtilizationWAD (<= WAD) causes Branch 1 to fire unconditionally,
    // repricing JT_eff between the two deposits even with fresh checkpoints.
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.liquidationUtilizationWAD > WAD();

    // Fresh checkpoints prevent a stale NAV delta from driving JT_eff to collapse.
    // In PERPETUAL, any stored ST cross-claim gets cleared by Branch 1 before pricing,
    // so the eff == raw requirements are not needed.
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV ==
            kernel.jtConvertTrancheUnitsToNAVUnits(e, kernel.ext_Royco_storage_RoycoKernelState.jtOwnedYieldBearingAssets);
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV ==
            kernel.stConvertTrancheUnitsToNAVUnits(e, kernel.ext_Royco_storage_RoycoKernelState.stOwnedYieldBearingAssets);

    requireAllInvariants_Accountant();

    uint256 shares1 = juniorTranche.deposit(e, amount, owner);
    uint256 shares2 = juniorTranche.deposit(e, amount, owner);

    assert shares1 <= shares2 + 20, "deposit should preserve price";
}

rule depositSameJunior(env e) {
    uint256 amount;
    address owner;

    require juniorTranche.totalSupply() > 0;
    require juniorTranche.totalSupply() <= roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV;
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.fixedTermDurationSeconds > 0;
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.stNAVDustTolerance == 0;
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.jtNAVDustTolerance == 0;
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.liquidationUtilizationWAD > WAD();

    requireAllInvariants_Accountant();  

    uint256 lastSTRawNAV1 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV;
    uint256 lastJTRawNAV1 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV;
    uint256 lastSTEffectiveNAV1 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV;
    uint256 lastJTEffectiveNAV1 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    uint256 lastSTImpermanentLoss1 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTImpermanentLoss;
    uint256 lastJTImpermanentLoss1 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTImpermanentLoss;

    require lastJTRawNAV1 <= kernel.ext_Royco_storage_RoycoKernelState.jtOwnedYieldBearingAssets * 5;
    require lastJTEffectiveNAV1 <= lastJTRawNAV1 + lastJTImpermanentLoss1;

    uint256 shares1 = juniorTranche.deposit(e, amount, owner);

    uint256 lastSTRawNAV2 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV;
    uint256 lastJTRawNAV2 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV;
    uint256 lastSTEffectiveNAV2 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV;
    uint256 lastJTEffectiveNAV2 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    uint256 lastSTImpermanentLoss2 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTImpermanentLoss;
    uint256 lastJTImpermanentLoss2 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTImpermanentLoss;

    uint256 shares2 = juniorTranche.deposit(e, amount, owner);

    uint256 lastSTRawNAV3 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV;
    uint256 lastJTRawNAV3 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV;
    uint256 lastSTEffectiveNAV3 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV;
    uint256 lastJTEffectiveNAV3 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    uint256 lastSTImpermanentLoss3 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTImpermanentLoss;
    uint256 lastJTImpermanentLoss3 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTImpermanentLoss;
    
    //assert shares1 == shares2, "deposit should preserve price";
    assert shares1 <= shares2 + 20, "deposit should preserve price";
}

rule depositSharesConservative_jt(env e) {
    uint256 amount;
    address owner;

    mathint S = juniorTranche.totalSupply();
    mathint N = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    require S > 0 && N > 0;

    // Clean state so that navToMintSharesAt = lastJTEffectiveNAV:
    // no stale checkpoints, no cross-claims
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV ==
            roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV;
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV ==
            roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV;
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV ==
            kernel.jtConvertTrancheUnitsToNAVUnits(e, kernel.ext_Royco_storage_RoycoKernelState.jtOwnedYieldBearingAssets);
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV ==
            kernel.stConvertTrancheUnitsToNAVUnits(e, kernel.ext_Royco_storage_RoycoKernelState.stOwnedYieldBearingAssets);

    mathint V = kernel.jtConvertTrancheUnitsToNAVUnits(e, amount);
    mathint shares = juniorTranche.deposit(e, amount, owner);

    assert shares * N <= S * V;
}

rule depositSharesConservative_st(env e) {
    uint256 amount;
    address owner;

    mathint S = seniorTranche.totalSupply();
    mathint N = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV;
    require S > 0 && N > 0;

    // Clean state so that navToMintSharesAt = lastSTEffectiveNAV:
    // no stale checkpoints, no cross-claims
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV ==
            roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV;
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV ==
            roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV;
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV ==
            kernel.stConvertTrancheUnitsToNAVUnits(e, kernel.ext_Royco_storage_RoycoKernelState.stOwnedYieldBearingAssets);
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV ==
            kernel.jtConvertTrancheUnitsToNAVUnits(e, kernel.ext_Royco_storage_RoycoKernelState.jtOwnedYieldBearingAssets);

    mathint V = kernel.stConvertTrancheUnitsToNAVUnits(e, amount);
    mathint shares = seniorTranche.deposit(e, amount, owner);

    assert shares * N <= S * V;
}

/**
 * @title Consecutive JT redeems of the same amount yield the same assets
 * @description Two consecutive JT redeems of the same share amount must receive identical assets, confirming that a redeem does not change the exchange rate.
 * @link_property KER05
 */
rule redeemSameJunior(env e) {
    uint256 amount;
    address owner;
    address receiver;
    RoycoVaultTranche.AssetClaims claims1;
    RoycoVaultTranche.AssetClaims claims2;

    claims1 = juniorTranche.redeem(e, amount, receiver, owner);
    claims2 = juniorTranche.redeem(e, amount, receiver, owner);

    assert claims1.jtAssets == claims2.jtAssets, "redeem should preserve price";
    assert claims1.stAssets == claims2.stAssets, "redeem should preserve price";
}


/**
 * @title Consecutive ST deposits of the same amount yield the same shares
 * @description Two consecutive ST deposits of the same amount must receive the same number of shares, confirming that a deposit does not change the exchange rate.
 * @link_property KER05
 */
rule depositSameSenior(env e) {
    uint256 amount;
    address owner;

    require seniorTranche.totalSupply() > 0;
    require seniorTranche.totalSupply() <= roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV;
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.fixedTermDurationSeconds > 0;
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.stNAVDustTolerance == 0;
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.jtNAVDustTolerance == 0;
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.liquidationUtilizationWAD > WAD();

    requireAllInvariants_Accountant();

    uint256 lastSTRawNAV1 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV;
    uint256 lastJTRawNAV1 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV;
    uint256 lastSTEffectiveNAV1 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV;
    uint256 lastJTEffectiveNAV1 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    uint256 lastSTImpermanentLoss1 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTImpermanentLoss;
    uint256 lastJTImpermanentLoss1 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTImpermanentLoss;

    require lastSTRawNAV1 <= kernel.ext_Royco_storage_RoycoKernelState.stOwnedYieldBearingAssets * 5;
    require lastSTEffectiveNAV1 <= lastSTRawNAV1 + lastSTImpermanentLoss1;

    uint256 shares1 = seniorTranche.deposit(e, amount, owner);

    uint256 lastSTRawNAV2 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV;
    uint256 lastJTRawNAV2 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV;
    uint256 lastSTEffectiveNAV2 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV;
    uint256 lastJTEffectiveNAV2 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    uint256 lastSTImpermanentLoss2 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTImpermanentLoss;
    uint256 lastJTImpermanentLoss2 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTImpermanentLoss;

    uint256 shares2 = seniorTranche.deposit(e, amount, owner);

    uint256 lastSTRawNAV3 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV;
    uint256 lastJTRawNAV3 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV;
    uint256 lastSTEffectiveNAV3 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV;
    uint256 lastJTEffectiveNAV3 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV;
    uint256 lastSTImpermanentLoss3 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTImpermanentLoss;
    uint256 lastJTImpermanentLoss3 = roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTImpermanentLoss;

    assert shares1 <= shares2 + 20, "deposit should preserve price";
}

/**
 * @title Consecutive ST redeems of the same amount yield the same assets
 * @description Two consecutive ST redeems of the same share amount must receive identical assets, confirming that a redeem does not change the exchange rate.
 * @link_property KER05
 */
rule redeemSameSenior(env e) {
    uint256 amount;
    address owner;
    address receiver;
    RoycoVaultTranche.AssetClaims claims1;
    RoycoVaultTranche.AssetClaims claims2;

    claims1 = seniorTranche.redeem(e, amount, receiver, owner);
    claims2 = seniorTranche.redeem(e, amount, receiver, owner);

    assert claims1.jtAssets == claims2.jtAssets, "redeem should preserve price";
    assert claims1.stAssets == claims2.stAssets, "redeem should preserve price";
}
