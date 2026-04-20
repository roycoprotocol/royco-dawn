import "../lib-summaries/OpenZeppelin/OZ_Math.spec";

// turns out some codes do have an 'f'! e.g. Cork
rule sanity {
    env e;
    calldataarg args;
    method certoraF;
    certoraF(e, args);
    satisfy true, "sanity check failed";
}

