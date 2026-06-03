
/*
 * MODULE
 * @module RoycoKernel
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption previewSyncTrancheAccounting is summarized (see summaries-RoycoAccountant.spec)
 * @global_assumption Kernel conversion functions are summarized (see summaries-KernelConversions.spec)
 *
 * PROPERTIES
 * @property UTI02 stRedeem always decreases or preserves utilization (self-liquidation bonus makes it attractive to redeem when over-utilized)
 * @property KER09 previewSyncTrancheAccounting never reverts (liveness property required for maxRedeem to function correctly)
 */

import "../summaries/using-Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.spec";
//import "../summaries/summaries-RoycoAccountant.spec";
//import "../summaries/summaries-KernelConversions.spec";
//import "../external/external-nondet.spec";
import "../lib-summaries/OpenZeppelin/OZ_SafeERC20.spec";
import "../lib-summaries/OpenZeppelin/OZ_Math.spec";

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
    function _.consumeScheduledOp(address,bytes) external => NONDET;
    function _.syncTrancheAccounting() external => DISPATCHER(true);
    function _.previewJTYieldShare(StaticCurveYDM.MarketState,StaticCurveYDM.NAV_UNIT,StaticCurveYDM.NAV_UNIT,uint256,uint256,StaticCurveYDM.NAV_UNIT) external => DISPATCHER(true);
    function _.jtYieldShare(
        RoycoAccountant.MarketState,
        RoycoAccountant.NAV_UNIT _stRawNAV,
        RoycoAccountant.NAV_UNIT _jtRawNAV,
        uint256 _betaWAD,
        uint256 _coverageWAD,
        RoycoAccountant.NAV_UNIT _jtEffectiveNAV
    ) external => jtYieldShareCVL(_stRawNAV, _jtRawNAV, _betaWAD, _coverageWAD, _jtEffectiveNAV) expect (uint256);
    function Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.getTrancheUnitToNAVUnitConversionRateWAD() internal returns (uint256) => conversionRateCVL();
    function IdenticalAssetsOracleQuoter._getCachedTrancheUnitToNAVUnitConversionRateWAD() internal returns (uint256) => conversionRateCVL();
    function Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.TRANCHE_UNIT_SCALE_FACTOR() external returns (uint256) envfree;
}

ghost conversionRateCVL() returns uint256;
ghost jtYieldShareCVL(RoycoAccountant.NAV_UNIT, RoycoAccountant.NAV_UNIT, uint256, uint256, RoycoAccountant.NAV_UNIT) returns uint256 {  
    axiom (forall RoycoAccountant.NAV_UNIT stRawNAV. forall RoycoAccountant.NAV_UNIT jtRawNAV. forall uint256 beta. forall uint256 coverage. forall RoycoAccountant.NAV_UNIT jtEffectiveNAV.
        jtYieldShareCVL(stRawNAV, jtRawNAV, beta, coverage, jtEffectiveNAV) < WAD());
}

definition WAD() returns mathint = 10^18;

/**
 * @title previewSyncTrancheAccounting never reverts
 * @description The preview function must always succeed (not revert) so that maxRedeem() can read the current state without risk of reversion.
 * @link_property KER09
 * @ignore this is tricky because of code complexity. There are possible overflows in previewJTYieldShare.
 * @status WIP
 */
rule previewSyncTrancheAccountingNeverReverts(env e) {
    RoycoKernel.TrancheType trancheType;

    // require fixed price during this rule
    uint256 price = kernel.getTrancheUnitToNAVUnitConversionRateWAD(e);
    uint256 priceDenom = kernel.TRANCHE_UNIT_SCALE_FACTOR();
    require priceDenom != 0, "TRANCHE_UNIT_SCALE_FACTOR initialized to non-zero value";

    require e.msg.value == 0, "Not payable";
    require e.block.timestamp >= roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastAccrualTimestamp, "time is increasing";
    require !kernel.ext_openzeppelin_storage_Pausable._paused, "kernel unpaused";
    require !roycoAccountant.ext_openzeppelin_storage_Pausable._paused, "accountant unpaused";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV < 2^200, "no NAV overflow";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV < 2^200, "no NAV overflow";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV < 2^200, "no NAV overflow";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV < 2^200, "no NAV overflow";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTImpermanentLoss < 2^200, "no NAV overflow";
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTImpermanentLoss < 2^200, "no NAV overflow";

    require price * kernel.ext_Royco_storage_RoycoKernelState.stOwnedYieldBearingAssets / priceDenom < 2^200, "no NAV overflow";
    require price * kernel.ext_Royco_storage_RoycoKernelState.jtOwnedYieldBearingAssets / priceDenom < 2^200, "no NAV overflow";

    // require the raw==effective invariant
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV + roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV 
        == roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV + roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV, "INV01";

    previewSyncTrancheAccounting@withrevert(e, trancheType);

    assert !lastReverted, "previewSyncTrancheAccounting must not revert";
}

/**
 * @title ST redeem (self-liquidation) decreases or preserves utilization
 * @description Any stRedeem call must not increase utilization; the self-liquidation mechanism ensures that redeeming when over-utilized is always beneficial to the pool.
 * @link_property UTI02
 * @status TIMEOUT
 * @report https://prover.certora.com/output/74728/d80c4046daa44edd8e2c38c545a19856/?anonymousKey=a2915aebd31080778bf247799a11154742a79e2d
 */
rule selfLiquidationDecreasesUtilization(env e) {
    uint256 shares;
    address receiver;
    bool bypass;

    // require the raw==effective invariant
    require roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTRawNAV + roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTRawNAV 
        == roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastSTEffectiveNAV + roycoAccountant.ext_Royco_storage_RoycoAccountantState.lastJTEffectiveNAV, "INV01";

    // Capture utilization before stRedeem
    RoycoAccountant.SyncedAccountingState stateBefore;
    RoycoAccountant.AssetClaims claimsBefore;
    uint256 totalSharesBefore;
    (stateBefore, claimsBefore, totalSharesBefore) = previewSyncTrancheAccounting(e, RoycoKernel.TrancheType.SENIOR);
    uint256 utilizationBefore = stateBefore.utilizationWAD;

    kernel.stRedeem(e, shares, receiver, bypass);

    // Capture utilization after stRedeem
    RoycoAccountant.SyncedAccountingState stateAfter;
    RoycoAccountant.AssetClaims claimsAfter;
    uint256 totalSharesAfter;
    (stateAfter, claimsAfter, totalSharesAfter) = previewSyncTrancheAccounting(e, RoycoKernel.TrancheType.SENIOR);
    uint256 utilizationAfter = stateAfter.utilizationWAD;

    assert utilizationAfter <= utilizationBefore;
}
