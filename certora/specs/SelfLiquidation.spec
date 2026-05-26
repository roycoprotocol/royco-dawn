
/*
 * MODULE
 * @module SelfLiquidation
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
import "../summaries/summaries-RoycoAccountant.spec";
import "../summaries/summaries-KernelConversions.spec";
import "../external/external-nondet.spec";
import "../lib-summaries/OpenZeppelin/OZ_SafeERC20.spec";
import "../lib-summaries/OpenZeppelin/OZ_Math.spec";

/**
 * @title previewSyncTrancheAccounting never reverts
 * @description The preview function must always succeed (not revert) so that maxRedeem() can read the current state without risk of reversion.
 * @link_property KER09
 * @status WIP
 */
rule previewSyncTrancheAccountingNeverReverts(env e) {
    RoycoKernel.TrancheType trancheType;

    require e.msg.value == 0, "Not payable";

    previewSyncTrancheAccounting@withrevert(e, trancheType);

    assert !lastReverted, "previewSyncTrancheAccounting must not revert";
}

/**
 * @title ST redeem (self-liquidation) decreases or preserves utilization
 * @description Any stRedeem call must not increase utilization; the self-liquidation mechanism ensures that redeeming when over-utilized is always beneficial to the pool.
 * @link_property UTI02
 * @status WIP
 */
rule selfLiquidationDecreasesUtilization(env e) {
    uint256 shares;
    address receiver;
    bool bypass;

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
