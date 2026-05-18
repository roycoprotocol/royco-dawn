
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
    function Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.getTrancheUnitToNAVUnitConversionRateWAD() internal returns (uint256) => CONSTANT;
}

definition WAD() returns mathint = 10^18;

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


rule depositSameJunior(env e) {
    storage init = lastStorage;

    uint256 amount;
    address owner;

    uint256 shares1 = juniorTranche.deposit(e, amount, owner);
    uint256 shares2 = juniorTranche.deposit(e, amount, owner);

    assert shares1 == shares2, "deposit should preserve price";
}

rule redeemSameJunior(env e) {
    storage init = lastStorage;

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


rule depositSameSenior(env e) {
    storage init = lastStorage;

    uint256 amount;
    address owner;

    uint256 shares1 = seniorTranche.deposit(e, amount, owner);
    uint256 shares2 = seniorTranche.deposit(e, amount, owner);

    assert shares1 == shares2, "deposit should preserve price";
}

rule redeemSameSenior(env e) {
    storage init = lastStorage;

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
