
/*
 * MODULE
 * @module RoycoVaultTranche
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption upgradeToAndCall is excluded from all invariants — it can reinitialize the contract
 * @global_assumption safeTransfer and safeTransferFrom are modeled as direct balance updates via ghost
 * @global_assumption The oracle price is modeled as a constant per rule execution
 * @global_assumption canCall is modeled as an abstract function (the checkRestricted rule verifies that successful calls must have had canCall return true)
 *
 * PROPERTIES
 * @property TrancheSupplyIntegrity JT and ST totalSupply always equals the sum of all holder balances
 * @property KernelBalanceIntegrity kernel.stOwnedYieldBearingAssets + kernel.jtOwnedYieldBearingAssets equals the kernel's actual token balance (for identical-asset and separate-asset variants)
 * @property AUTH04 All non-view operations on RoycoVaultTranche (and the kernel) require canCall authorization to succeed
 */

import "../summaries/using-Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.spec";
//import "../summaries/summaries-RoycoAccountant.spec";
//import "../external/external-nondet.spec";
//import "../lib-summaries/OpenZeppelin/OZ_SafeERC20.spec";
import "../lib-summaries/OpenZeppelin/OZ_Math.spec";
//import "../summaries/summaries-KernelConversions.spec";
using RoycoAccountant as roycoAccountant;

// using DummyERC20A as erc20a;
// using DummyERC20B as erc20b;

using RoycoJuniorTranche as juniorTranche;
using RoycoSeniorTranche as seniorTranche;

links {
    // Important: Note that the kernel is imported via import "using-Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel.spec".
    //kernel.JT_ASSET => erc20b;
    //kernel.ST_ASSET => erc20a;

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
    function kernel.ST_ASSET() external returns address envfree;
    function kernel.JT_ASSET() external returns address envfree;
    function seniorTranche.ASSET() external returns address envfree;
    function juniorTranche.ASSET() external returns address envfree;
    function _.canCall(address caller,address target,bytes4 selector) external => canCallCVL(caller, target) expect (bool,uint256);
    function _.consumeScheduledOp(address,bytes) external => NONDET;
    function _.syncTrancheAccounting() external => DISPATCHER(true);
    function _.previewJTYieldShare(StaticCurveYDM.MarketState,StaticCurveYDM.NAV_UNIT,StaticCurveYDM.NAV_UNIT,uint256,uint256,StaticCurveYDM.NAV_UNIT) external => NONDET;
    function _.jtYieldShare(
        RoycoAccountant.MarketState,
        RoycoAccountant.NAV_UNIT _stRawNAV,
        RoycoAccountant.NAV_UNIT _jtRawNAV,
        uint256 _betaWAD,
        uint256 _coverageWAD,
        RoycoAccountant.NAV_UNIT _jtEffectiveNAV
    ) external => NONDET;
    function _.safeTransfer(address token, address to, uint256 value) internal => transferFromCVL(token, executingContract, to, value) expect void;
    function _.safeTransferFrom(address token, address from, address to, uint256 value) internal => transferFromCVL(token, from, to, value) expect void;
    function Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.getTrancheUnitToNAVUnitConversionRateWAD() internal returns (uint256) => conversionRateCVL();
    function IdenticalAssetsOracleQuoter._getCachedTrancheUnitToNAVUnitConversionRateWAD() internal returns (uint256) => conversionRateCVL();
    function Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.TRANCHE_UNIT_SCALE_FACTOR() external returns (uint256) envfree;
}

ghost conversionRateCVL() returns uint256;



ghost bool canCallWasCalled;

ghost permitted(address, address) returns bool;

ghost mapping(address => mapping(address => uint256)) tokenBalances
{
    init_state axiom (forall address token. forall address user. tokenBalances[token][user] == 0);
}

function canCallCVL(address caller, address callee) returns (bool, uint256) {
    bool immediate;
    uint256 delay;
    if (!permitted(caller, callee)) {
        revert();
    }
    return (immediate, delay);
}

function transferFromCVL(address token, address from, address to, uint256 amount) {
    tokenBalances[token][from] = require_uint256(tokenBalances[token][from] - amount);
    tokenBalances[token][to] = require_uint256(tokenBalances[token][to] + amount);
}


definition excludeUpgradeAndCall(method f) returns bool =
    f.selector != sig:upgradeToAndCall(address,bytes).selector;

definition isERC20Public(method f) returns bool =
    f.selector == sig:RoycoJuniorTranche.transfer(address,uint256).selector
    || f.selector == sig:RoycoJuniorTranche.transferFrom(address,address,uint256).selector
    || f.selector == sig:RoycoJuniorTranche.approve(address,uint256).selector
    || f.selector == sig:RoycoJuniorTranche.permit(address,address,uint256,uint256,uint8,bytes32,bytes32).selector;

ghost mapping(address => uint256) stBalances
{
    init_state axiom (usum address user. stBalances[user]) == 0;
}
ghost mapping(address => uint256) jtBalances
{
    init_state axiom (usum address user. jtBalances[user]) == 0;
}

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

/**
 * @title JT totalSupply equals sum of all holder balances
 * @description The JT ERC20 totalSupply must always equal the sum of all individual balances tracked by the ghost, confirming no shares are minted or burned outside of proper accounting.
 * Constructor fails, because we do not check deployment.
 * @link_property TrancheSupplyIntegrity
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/267667e11bdc4653b12b31bcddc39924/?anonymousKey=119d7e769cc74796c52a669165a9a38974e6c01d
 */
invariant jtTotalSupplyIsSumOfBalances()
    (usum address user. jtBalances[user]) == juniorTranche.totalSupply()
    filtered { f -> excludeUpgradeAndCall(f)}

/**
 * @title ST totalSupply equals sum of all holder balances
 * @description The ST ERC20 totalSupply must always equal the sum of all individual balances tracked by the ghost, confirming no shares are minted or burned outside of proper accounting.
 * Constructor fails, because we do not check deployment.
 * @link_property TrancheSupplyIntegrity
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/267667e11bdc4653b12b31bcddc39924/?anonymousKey=119d7e769cc74796c52a669165a9a38974e6c01d
 */
invariant stTotalSupplyIsSumOfBalances()
    (usum address user. stBalances[user]) == seniorTranche.totalSupply()
    filtered { f -> excludeUpgradeAndCall(f)}

/**
 * @title Kernel token balance equals stOwned + jtOwned (identical-asset variant)
 * @description When ST and JT share the same asset, the kernel's actual token balance must equal stOwnedYieldBearingAssets + jtOwnedYieldBearingAssets.
 * @link_property KernelBalanceIntegrity
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/267667e11bdc4653b12b31bcddc39924/?anonymousKey=119d7e769cc74796c52a669165a9a38974e6c01d
 */
invariant kernelTokenBalances()
    kernel.ext_Royco_storage_RoycoKernelState.stOwnedYieldBearingAssets +
    kernel.ext_Royco_storage_RoycoKernelState.jtOwnedYieldBearingAssets == tokenBalances[seniorTranche.ASSET()][kernel]
    filtered { f -> excludeUpgradeAndCall(f)}
{
    preserved with (env e) {
        require seniorTranche.ASSET() == juniorTranche.ASSET(), "Assume identical assets";
        require seniorTranche.ASSET() == kernel.ST_ASSET(), "Assets setup correctly";
        require juniorTranche.ASSET() == kernel.JT_ASSET(), "Assets setup correctly";
    }

    preserved seniorTranche.deposit(uint256 amount, address receiver) with (env e) {
        require e.msg.sender != kernel, "roycoKernel doesn't deposit/withdraw";
        require seniorTranche.ASSET() == juniorTranche.ASSET(), "Assume identical assets";
        require seniorTranche.ASSET() == kernel.ST_ASSET(), "Assets setup correctly";
        require juniorTranche.ASSET() == kernel.JT_ASSET(), "Assets setup correctly";
    }

    preserved seniorTranche.redeem(uint256 amount, address receiver, address owner) with (env e) {
        require receiver != kernel, "roycoKernel doesn't deposit/withdraw";
        require seniorTranche.ASSET() == juniorTranche.ASSET(), "Assume identical assets";
        require seniorTranche.ASSET() == kernel.ST_ASSET(), "Assets setup correctly";
        require juniorTranche.ASSET() == kernel.JT_ASSET(), "Assets setup correctly";
    }

    preserved seniorTranche.seizeAndRedeemShares(address from, address receiver, uint256 amount) with (env e) {
        require receiver != kernel, "roycoKernel doesn't deposit/withdraw";
        require seniorTranche.ASSET() == juniorTranche.ASSET(), "Assume identical assets";
        require seniorTranche.ASSET() == kernel.ST_ASSET(), "Assets setup correctly";
        require juniorTranche.ASSET() == kernel.JT_ASSET(), "Assets setup correctly";
    }

    preserved juniorTranche.deposit(uint256 amount, address receiver) with (env e) {
        require e.msg.sender != kernel, "roycoKernel doesn't deposit/withdraw";
        require seniorTranche.ASSET() == juniorTranche.ASSET(), "Assume identical assets";
        require seniorTranche.ASSET() == kernel.ST_ASSET(), "Assets setup correctly";
        require juniorTranche.ASSET() == kernel.JT_ASSET(), "Assets setup correctly";
    }

    preserved juniorTranche.redeem(uint256 amount, address receiver, address owner) with (env e) {
        require receiver != kernel, "roycoKernel doesn't deposit/withdraw";
        require seniorTranche.ASSET() == juniorTranche.ASSET(), "Assume identical assets";
        require seniorTranche.ASSET() == kernel.ST_ASSET(), "Assets setup correctly";
        require juniorTranche.ASSET() == kernel.JT_ASSET(), "Assets setup correctly";
    }

    preserved juniorTranche.seizeAndRedeemShares(address from, address receiver, uint256 amount) with (env e) {
        require receiver != kernel, "roycoKernel doesn't deposit/withdraw";
        require seniorTranche.ASSET() == juniorTranche.ASSET(), "Assume identical assets";
        require seniorTranche.ASSET() == kernel.ST_ASSET(), "Assets setup correctly";
        require juniorTranche.ASSET() == kernel.JT_ASSET(), "Assets setup correctly";
    }
}

/**
 * @title Kernel ST token balance equals stOwnedYieldBearingAssets (separate-asset variant)
 * @description When ST and JT use different assets, the kernel's ST token balance must equal stOwnedYieldBearingAssets independently.
 * @link_property KernelBalanceIntegrity
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/267667e11bdc4653b12b31bcddc39924/?anonymousKey=119d7e769cc74796c52a669165a9a38974e6c01d
 */
invariant kernelTokenStBalances()
    kernel.ext_Royco_storage_RoycoKernelState.stOwnedYieldBearingAssets == tokenBalances[seniorTranche.ASSET()][kernel]
    filtered { f -> excludeUpgradeAndCall(f)}
{
    preserved with (env e) {
        require seniorTranche.ASSET() != juniorTranche.ASSET(), "Assume assets distinct";
        require seniorTranche.ASSET() == kernel.ST_ASSET(), "Assets setup correctly";
        require juniorTranche.ASSET() == kernel.JT_ASSET(), "Assets setup correctly";
    }

    preserved seniorTranche.deposit(uint256 amount, address receiver) with (env e) {
        require e.msg.sender != kernel, "roycoKernel doesn't deposit/withdraw";
        require seniorTranche.ASSET() != juniorTranche.ASSET(), "Assume assets distinct";
        require seniorTranche.ASSET() == kernel.ST_ASSET(), "Assets setup correctly";
        require juniorTranche.ASSET() == kernel.JT_ASSET(), "Assets setup correctly";
    }

    preserved seniorTranche.redeem(uint256 amount, address receiver, address owner) with (env e) {
        require receiver != kernel, "roycoKernel doesn't deposit/withdraw";
        require seniorTranche.ASSET() != juniorTranche.ASSET(), "Assume assets distinct";
        require seniorTranche.ASSET() == kernel.ST_ASSET(), "Assets setup correctly";
        require juniorTranche.ASSET() == kernel.JT_ASSET(), "Assets setup correctly";
    }

    preserved seniorTranche.seizeAndRedeemShares(address from, address receiver, uint256 amount) with (env e) {
        require receiver != kernel, "roycoKernel doesn't deposit/withdraw";
        require seniorTranche.ASSET() != juniorTranche.ASSET(), "Assume assets distinct";
        require seniorTranche.ASSET() == kernel.ST_ASSET(), "Assets setup correctly";
        require juniorTranche.ASSET() == kernel.JT_ASSET(), "Assets setup correctly";
    }

    preserved juniorTranche.deposit(uint256 amount, address receiver) with (env e) {
        require e.msg.sender != kernel, "roycoKernel doesn't deposit/withdraw";
        require seniorTranche.ASSET() != juniorTranche.ASSET(), "Assume assets distinct";
        require seniorTranche.ASSET() == kernel.ST_ASSET(), "Assets setup correctly";
        require juniorTranche.ASSET() == kernel.JT_ASSET(), "Assets setup correctly";
    }

    preserved juniorTranche.redeem(uint256 amount, address receiver, address owner) with (env e) {
        require receiver != kernel, "roycoKernel doesn't deposit/withdraw";
        require seniorTranche.ASSET() != juniorTranche.ASSET(), "Assume assets distinct";
        require seniorTranche.ASSET() == kernel.ST_ASSET(), "Assets setup correctly";
        require juniorTranche.ASSET() == kernel.JT_ASSET(), "Assets setup correctly";
    }

    preserved juniorTranche.seizeAndRedeemShares(address from, address receiver, uint256 amount) with (env e) {
        require receiver != kernel, "roycoKernel doesn't deposit/withdraw";
        require seniorTranche.ASSET() != juniorTranche.ASSET(), "Assume assets distinct";
        require seniorTranche.ASSET() == kernel.ST_ASSET(), "Assets setup correctly";
        require juniorTranche.ASSET() == kernel.JT_ASSET(), "Assets setup correctly";
    }
}

/**
 * @title Kernel JT token balance equals jtOwnedYieldBearingAssets (separate-asset variant)
 * @description When ST and JT use different assets, the kernel's JT token balance must equal jtOwnedYieldBearingAssets independently.
 * @link_property KernelBalanceIntegrity
 * @status VERIFIED
 * @report https://prover.certora.com/output/74728/267667e11bdc4653b12b31bcddc39924/?anonymousKey=119d7e769cc74796c52a669165a9a38974e6c01d
 */
invariant kernelTokenJtBalances()
    kernel.ext_Royco_storage_RoycoKernelState.jtOwnedYieldBearingAssets == tokenBalances[juniorTranche.ASSET()][kernel]
    filtered { f -> excludeUpgradeAndCall(f) }
{
    preserved with (env e) {
        require seniorTranche.ASSET() != juniorTranche.ASSET(), "Assume assets distinct";
        require seniorTranche.ASSET() == kernel.ST_ASSET(), "Assets setup correctly";
        require juniorTranche.ASSET() == kernel.JT_ASSET(), "Assets setup correctly";
    }

    preserved seniorTranche.deposit(uint256 amount, address receiver) with (env e) {
        require e.msg.sender != kernel, "roycoKernel doesn't deposit/withdraw";
        require seniorTranche.ASSET() != juniorTranche.ASSET(), "Assume assets distinct";
        require seniorTranche.ASSET() == kernel.ST_ASSET(), "Assets setup correctly";
        require juniorTranche.ASSET() == kernel.JT_ASSET(), "Assets setup correctly";
    }

    preserved seniorTranche.redeem(uint256 amount, address receiver, address owner) with (env e) {
        require receiver != kernel, "roycoKernel doesn't deposit/withdraw";
        require seniorTranche.ASSET() != juniorTranche.ASSET(), "Assume assets distinct";
        require seniorTranche.ASSET() == kernel.ST_ASSET(), "Assets setup correctly";
        require juniorTranche.ASSET() == kernel.JT_ASSET(), "Assets setup correctly";
    }

    preserved seniorTranche.seizeAndRedeemShares(address from, address receiver, uint256 amount) with (env e) {
        require receiver != kernel, "roycoKernel doesn't deposit/withdraw";
        require seniorTranche.ASSET() != juniorTranche.ASSET(), "Assume assets distinct";
        require seniorTranche.ASSET() == kernel.ST_ASSET(), "Assets setup correctly";
        require juniorTranche.ASSET() == kernel.JT_ASSET(), "Assets setup correctly";
    }

    preserved juniorTranche.deposit(uint256 amount, address receiver) with (env e) {
        require e.msg.sender != kernel, "roycoKernel doesn't deposit/withdraw";
        require seniorTranche.ASSET() != juniorTranche.ASSET(), "Assume assets distinct";
        require seniorTranche.ASSET() == kernel.ST_ASSET(), "Assets setup correctly";
        require juniorTranche.ASSET() == kernel.JT_ASSET(), "Assets setup correctly";
    }

    preserved juniorTranche.redeem(uint256 amount, address receiver, address owner) with (env e) {
        require receiver != kernel, "roycoKernel doesn't deposit/withdraw";
        require seniorTranche.ASSET() != juniorTranche.ASSET(), "Assume assets distinct";
        require seniorTranche.ASSET() == kernel.ST_ASSET(), "Assets setup correctly";
        require juniorTranche.ASSET() == kernel.JT_ASSET(), "Assets setup correctly";
    }

    preserved juniorTranche.seizeAndRedeemShares(address from, address receiver, uint256 amount) with (env e) {
        require receiver != kernel, "roycoKernel doesn't deposit/withdraw";
        require seniorTranche.ASSET() != juniorTranche.ASSET(), "Assume assets distinct";
        require seniorTranche.ASSET() == kernel.ST_ASSET(), "Assets setup correctly";
        require juniorTranche.ASSET() == kernel.JT_ASSET(), "Assets setup correctly";
    }
}

/**
 * @title All successful operations require canCall authorization
 * @description Every non-reverting call to any tranche or kernel function must have been authorized via canCall(msg.sender, target, selector); unauthorized calls must revert.
 * Violation due to linking problems in upgradeAndCall.
 * @link_property AUTH04
 */
rule checkRestricted(method f, env e, calldataarg args) 
filtered { f -> !f.isView && !isERC20Public(f) 
    && excludeUpgradeAndCall(f)   // this function breaks the static analysis but it does call canCall.
}
{
    address authorityBefore = f.contract == seniorTranche ? seniorTranche.ext_openzeppelin_storage_AccessManaged._authority
        : juniorTranche.ext_openzeppelin_storage_AccessManaged._authority;
    uint64 initializedBefore = f.contract == seniorTranche ? seniorTranche.ext_openzeppelin_storage_Initializable._initialized
        : juniorTranche.ext_openzeppelin_storage_Initializable._initialized;

    f(e, args);

    assert permitted(e.msg.sender, f.contract) || e.msg.sender == kernel
        || e.msg.sender == authorityBefore
        || initializedBefore == 0, // for initialize()
         "Permission must have been granted";
}
