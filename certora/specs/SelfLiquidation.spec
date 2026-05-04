
import "../summaries/using-Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.spec";
import "../summaries/summaries-RoycoAccountant.spec";
import "../summaries/summaries-KernelConversions.spec";
import "../external/external-nondet.spec";
import "../lib-summaries/OpenZeppelin/OZ_SafeERC20.spec";
import "../lib-summaries/OpenZeppelin/OZ_Math.spec";

rule previewSyncTrancheAccountingNeverReverts(env e) {
    RoycoKernel.TrancheType trancheType;

    require e.msg.value == 0, "Not payable";

    previewSyncTrancheAccounting@withrevert(e, trancheType);

    assert !lastReverted, "previewSyncTrancheAccounting must not revert";
}

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
