#!/bin/sh
# certora/scripts/munge.sh

certoraRun certora/confs/AccountantInvariants.conf --msg AccountantInvariants
certoraRun certora/confs/AccountantMaxDepositRedeem.conf --msg AccountantMaxDepositRedeem
certoraRun certora/confs/KernelProperties.conf --msg KernelProperties

certoraRun certora/confs/LPTokenValue.conf --msg jtTokenValueDoesNotWorsenTooMuch --rule jtTokenValueDoesNotWorsenTooMuch
certoraRun certora/confs/LPTokenValue.conf --msg stTokenValueDoesNotWorsenTooMuch --rule stTokenValueDoesNotWorsenTooMuch
certoraRun certora/confs/LPTokenValue.conf --msg jtTokenValueDoesNotWorsen --rule jtTokenValueDoesNotWorsen
certoraRun certora/confs/LPTokenValue.conf --msg stTokenValueDoesNotWorsenh --rule stTokenValueDoesNotWorsen

certoraRun certora/confs/MaxDepositRedeem.conf --msg MaxDepositRedeem_jtDepositMaxDoesNotRevert --rule jtDepositMaxDoesNotRevert
certoraRun certora/confs/MaxDepositRedeem.conf --msg MaxDepositRedeem_jtRedeemMaxDoesNotRevert --rule jtRedeemMaxDoesNotRevert
certoraRun certora/confs/MaxDepositRedeem.conf --msg MaxDepositRedeem_stDepositMaxDoesNotRevert --rule stDepositMaxDoesNotRevert
certoraRun certora/confs/MaxDepositRedeem.conf --msg MaxDepositRedeem_stRedeemMaxDoesNotRevert --rule stRedeemMaxDoesNotRevert


certoraRun certora/confs/SelfLiquidation.conf --msg SelfLiquidation
certoraRun certora/confs/SyncOp.conf --msg SyncOp
certoraRun certora/confs/TrancheInvariants.conf --msg TrancheInvariants

certoraRun certora/confs/Utilization.conf --msg Utilization_jtDepositPreservesUtilization --rule jtDepositPreservesUtilization --prover_args "-oldSplitParallel true"
certoraRun certora/confs/Utilization.conf --msg Utilization_rest --exclude_rule jtDepositPreservesUtilization

certoraRun certora/confs/DepositRedeem.conf --msg depositRedeemJunior --rule depositRedeemJunior
certoraRun certora/confs/DepositRedeem.conf --msg depositRedeemSenior --rule depositRedeemSenior
certoraRun certora/confs/DepositRedeem.conf --msg depositSameJunior --rule depositSameJunior
certoraRun certora/confs/DepositRedeem.conf --msg depositSameSenior --rule depositSameSenior
certoraRun certora/confs/DepositRedeem.conf --msg depositSplitJunior --rule depositSplitJunior
certoraRun certora/confs/DepositRedeem.conf --msg depositSplitSenior --rule depositSplitSenior
certoraRun certora/confs/DepositRedeem.conf --msg redeemDepositJunior --rule redeemDepositJunior
certoraRun certora/confs/DepositRedeem.conf --msg redeemDepositSenior --rule redeemDepositSenior
certoraRun certora/confs/DepositRedeem.conf --msg redeemSameJunior --rule redeemSameJunior
certoraRun certora/confs/DepositRedeem.conf --msg redeemSameSenior --rule redeemSameSenior
certoraRun certora/confs/DepositRedeem.conf --msg redeemSplitJunior --rule redeemSplitJunior
certoraRun certora/confs/DepositRedeem.conf --msg redeemSplitSenior --rule redeemSplitSenior

# certora/scripts/unmunge.sh