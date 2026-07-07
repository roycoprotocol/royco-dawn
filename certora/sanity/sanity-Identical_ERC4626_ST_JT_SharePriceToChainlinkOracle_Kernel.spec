// This is here to demonstrate the change to use a different kernel in verification.
// In respective config file we are including a different Kernel and we import a different using to import the alias for kernel.

import "../summaries/using-Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.spec";
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