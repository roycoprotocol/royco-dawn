import "../summaries/using-Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel.spec";
import "../summaries/summaries-RoycoAccountant.spec";
import "../external/external-nondet.spec";
import "../lib-summaries/OpenZeppelin/OZ_SafeERC20.spec";
import "../lib-summaries/OpenZeppelin/OZ_Math.spec";


rule sanity {
    env e;
    calldataarg args;
    method certoraF;
    certoraF(e, args);
    satisfy true, "sanity check failed";
}