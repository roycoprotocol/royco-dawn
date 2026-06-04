// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { DeployScript } from "../../script/Deploy.s.sol";
import { MarketDeploymentConfig } from "../../script/config/MarketDeploymentConfig.sol";
import { IRoycoAccountant } from "../../src/interfaces/IRoycoAccountant.sol";
import { IRoycoFactory } from "../../src/interfaces/IRoycoFactory.sol";
import { IRoycoKernel } from "../../src/interfaces/IRoycoKernel.sol";
import { IdenticalAssetsOracleQuoter } from "../../src/kernels/base/quoter/base/IdenticalAssetsOracleQuoter.sol";
import { WAD } from "../../src/libraries/Constants.sol";
import { AssetClaims, SyncedAccountingState, TrancheType } from "../../src/libraries/Types.sol";
import { toTrancheUnits, toUint256 } from "../../src/libraries/Units.sol";
import { BaseTest } from "../base/BaseTest.t.sol";

/**
 * @title AccountantAttributionFuzzTest
 * @notice Fuzz suite that validates the claim-weighted attribution fix in `RoycoAccountant`
 *         across a broad parameter space. Each test sets up a fresh sNUSD market on a mainnet
 *         fork, parameterizes the deposit amounts / yield magnitudes / YDM split / drain ratio,
 *         and asserts invariants that the OLD (buggy) accountant would violate but the NEW
 *         (claim-weighted) accountant should preserve under all inputs.
 *
 *         If the fix regresses (or a corner case slips through), Foundry's fuzzer will surface
 *         a counterexample.
 */
contract AccountantAttributionFuzzTest is BaseTest {
    address internal constant SNUSD = 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313;
    uint256 internal constant FORK_BLOCK = 25_145_000;

    // Bounded ranges - tight enough that the fuzzer focuses on the interesting regime, broad
    // enough that we explore yield magnitudes / drain depths near the bug.
    uint256 internal constant MIN_DEPOSIT = 1000e18;
    uint256 internal constant MAX_DEPOSIT = 1_000_000e18;
    uint256 internal constant MIN_YIELD_WAD = 0.001e18; // +0.1%
    uint256 internal constant MAX_YIELD_WAD = 0.5e18; // +50%
    /// @dev Drain bps: 9000 = 90% drained, 9999 = 99.99% drained. We deliberately stop short of
    ///      a full drain so a residual ST supply remains; the zero-supply regime is covered by
    ///      `testFuzz_fixHolds_stEffectiveNAVStaysFlatWhenStSupplyIsZero` and the live savUSD
    ///      PoC test.
    uint256 internal constant MIN_DRAIN_BPS = 9000;
    uint256 internal constant MAX_DRAIN_BPS = 9999;

    function setUp() public {
        _setUpRoyco();
    }

    function _setUpRoyco() internal override {
        super._setUpRoyco();
        DeployScript.DeploymentResult memory result = _deployMarket(0.5e18);
        _setDeployedMarket(result);
        _setupProviders();
        _fundProviders();
    }

    function _forkConfiguration() internal view override returns (uint256, string memory) {
        return (FORK_BLOCK, vm.envString("MAINNET_RPC_URL"));
    }

    function _deployMarket(uint256 _jtYieldShareWAD) internal returns (DeployScript.DeploymentResult memory) {
        DeployScript.IdenticalERC4626SharesToAdminOracleQuoterKernelParams memory kernelParams =
            DeployScript.IdenticalERC4626SharesToAdminOracleQuoterKernelParams({ initialConversionRateWAD: WAD });

        DeployScript.AdaptiveCurveYDM_V2_Params memory ydmParams = DeployScript.AdaptiveCurveYDM_V2_Params({
            jtYieldShareAtZeroUtilWAD: uint64(_jtYieldShareWAD),
            jtYieldShareAtTargetUtilWAD: uint64(_jtYieldShareWAD),
            jtYieldShareAtFullUtilWAD: 1e18,
            maxAdaptationSpeedWAD: uint64(30e18 / uint256(365 days))
        });

        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        MarketDeploymentConfig.MarketConfig memory config = MarketDeploymentConfig.MarketConfig({
            marketName: "sNUSD_FUZZ",
            chainId: block.chainid,
            seniorTrancheName: "Royco Fuzz Senior sNUSD",
            seniorTrancheSymbol: "RFS-sNUSD",
            juniorTrancheName: "Royco Fuzz Junior sNUSD",
            juniorTrancheSymbol: "RFJ-sNUSD",
            seniorAsset: SNUSD,
            juniorAsset: SNUSD,
            stDustTolerance: 1,
            jtDustTolerance: 1,
            kernelType: DeployScript.KernelType.Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel,
            kernelSpecificParams: abi.encode(kernelParams),
            stSelfLiquidationBonusWAD: 0,
            enforceVaultSharesTransferWhitelist: false,
            stProtocolFeeWAD: 0,
            jtProtocolFeeWAD: 0,
            jtYieldShareProtocolFeeWAD: 0,
            coverageWAD: COVERAGE_WAD,
            betaWAD: 1e18,
            liquidationUtilizationWAD: LIQUIDATION_UTILIZATION_WAD,
            // Always PERPETUAL so ST redeems aren't blocked by fixed-term gating in fuzz runs.
            fixedTermDurationSeconds: 0,
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            transferAgentAddress: address(0),
            ydmSpecificParams: abi.encode(ydmParams)
        });

        uint32 expiry = DEPLOY_SCRIPT.getChainConfig(block.chainid).scheduledOperationsExpirySeconds;
        return DEPLOY_SCRIPT.deploy(config, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, expiry, roleAssignments, DEPLOYER.privateKey);
    }

    function _fundProviders() internal {
        // Each provider needs to be able to cover MAX_DEPOSIT * (max stAmount ratio = 4) = 4× MAX_DEPOSIT
        // headroom across multiple sub-deposits in some scenarios. 10M each is plenty.
        uint256 amount = 10_000_000e18;
        deal(SNUSD, ST_ALICE_ADDRESS, amount);
        deal(SNUSD, ST_BOB_ADDRESS, amount);
        deal(SNUSD, JT_ALICE_ADDRESS, amount);
        deal(SNUSD, JT_BOB_ADDRESS, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUZZ: post-fix invariants under random scenarios
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Bug-era behavior: `stEffectiveNAV` grew unboundedly with `stShares == 0`.
    ///         Fix-era invariant: when the ST side has zero outstanding shares at the time of
    ///         a yield event, `stEffectiveNAV` does NOT grow on the subsequent sync — the new
    ///         delta is attributed to JT (whose claim against the residual `stRawNAV` is the
    ///         only valid recipient).
    function testFuzz_fixHolds_stEffectiveNAVStaysFlatWhenStSupplyIsZero(
        uint256 _jtAmount,
        uint256 _stAmount,
        uint256 _yield1WAD,
        uint256 _yield2WAD
    )
        external
    {
        _jtAmount = bound(_jtAmount, MIN_DEPOSIT, MAX_DEPOSIT);
        _yield1WAD = bound(_yield1WAD, MIN_YIELD_WAD, MAX_YIELD_WAD);
        _yield2WAD = bound(_yield2WAD, MIN_YIELD_WAD, MAX_YIELD_WAD);

        _depositJT(JT_ALICE_ADDRESS, _jtAmount);

        // Bound ST deposit to the kernel-reported max, which respects the coverage constraint
        // against the just-deposited JT NAV.
        uint256 stMaxNAV = toUint256(ST.maxDeposit(ST_ALICE_ADDRESS));
        assertGt(stMaxNAV, 0, "ST max deposit should be positive after JT deposit");
        _stAmount = bound(_stAmount, MIN_DEPOSIT < stMaxNAV ? MIN_DEPOSIT : 1, stMaxNAV);
        assertGt(_stAmount, 0, "ST deposit amount should be non-zero");

        _depositST(ST_ALICE_ADDRESS, _stAmount);
        _sync();

        _bumpStoredConversionRate(WAD + _yield1WAD);
        _sync();

        _redeemAllST(ST_ALICE_ADDRESS);
        _sync();

        assertEq(ST.totalSupply(), 0, "ST total supply should be 0");

        SyncedAccountingState memory pre;
        (pre,,) = IRoycoKernel(address(KERNEL)).previewSyncTrancheAccounting(TrancheType.SENIOR);
        uint256 stEffPre = toUint256(pre.stEffectiveNAV);

        _bumpStoredConversionRate(WAD + _yield2WAD);
        _sync();

        SyncedAccountingState memory post;
        (post,,) = IRoycoKernel(address(KERNEL)).previewSyncTrancheAccounting(TrancheType.SENIOR);
        uint256 stEffPost = toUint256(post.stEffectiveNAV);

        // INVARIANT — with zero ST supply, `stEffectiveNAV` must not absorb the next yield.
        assertApproxEqAbs(stEffPost, stEffPre, 1, "stEffectiveNAV should not grow on a yield event with ST.totalSupply() == 0");

        // The new yield should instead inflate JT's effective NAV (since JT has all the claim).
        uint256 jtEffPre = toUint256(pre.jtEffectiveNAV);
        uint256 jtEffPost = toUint256(post.jtEffectiveNAV);
        assertGe(jtEffPost, jtEffPre, "JT's effective NAV should not shrink on a positive yield");
    }

    /// @notice Fix-era invariant: a fresh ST depositor entering AFTER a near-drain does NOT
    ///         receive a share price that's many orders of magnitude above the pre-drain basis.
    function testFuzz_fixHolds_freshDepositorEntersAtSaneSharePrice(
        uint256 _jtAmount,
        uint256 _stAmount,
        uint256 _yield1WAD,
        uint256 _drainBps,
        uint256 _yield2WAD,
        uint256 _eveDeposit
    )
        external
    {
        _jtAmount = bound(_jtAmount, MIN_DEPOSIT, MAX_DEPOSIT);
        _yield1WAD = bound(_yield1WAD, MIN_YIELD_WAD, MAX_YIELD_WAD);
        _drainBps = bound(_drainBps, MIN_DRAIN_BPS, MAX_DRAIN_BPS);
        _yield2WAD = bound(_yield2WAD, MIN_YIELD_WAD, MAX_YIELD_WAD);

        // 1. Alice deposits JT.
        _depositJT(JT_ALICE_ADDRESS, _jtAmount);

        uint256 stMaxNAV = toUint256(ST.maxDeposit(ST_ALICE_ADDRESS));
        // Require Alice to deposit at least MIN_DEPOSIT - otherwise even 99% drain leaves dust
        // residual where virtual share offsets dominate the share-price math.
        vm.assume(stMaxNAV >= MIN_DEPOSIT);
        _stAmount = bound(_stAmount, MIN_DEPOSIT, stMaxNAV);
        assertGt(_stAmount, 0, "ST deposit amount should be non-zero");

        // 2. Alice deposits ST.
        uint256 aliceShares = _depositST(ST_ALICE_ADDRESS, _stAmount);
        _sync();
        assertGt(aliceShares, 0, "alice should hold a non-zero ST share count");

        // 3. Bump yield.
        _bumpStoredConversionRate(WAD + _yield1WAD);
        _sync();

        // Bound the drain so we redeem in [1, aliceMaxRedeem - 1] - never fully drain ST
        // (the "freshDepositor" invariant assumes a non-zero residual supply; the
        // zero-supply branch is covered by `testFuzz_fixHolds_stEffectiveNAVStaysFlatWhenStSupplyIsZero`).
        // With totalSupply == 0, the virtual share offset `(T+1)/(E+1)` injects a deterministic
        // drift unrelated to the attribution fix.
        uint256 aliceMaxRedeem = ST.maxRedeem(ST_ALICE_ADDRESS);
        assertGt(aliceMaxRedeem, 1, "alice should have at least 2 redeemable shares");
        uint256 sharesToRedeem = 1 + (aliceMaxRedeem - 2) * (_drainBps - MIN_DRAIN_BPS) / (MAX_DRAIN_BPS - MIN_DRAIN_BPS);
        assertGt(sharesToRedeem, 0, "redeem amount should be non-zero");
        assertLt(sharesToRedeem, aliceMaxRedeem, "redeem must leave residual supply");
        // Skip cases where the redeem's asset claim (in tranche units) rounds to zero
        // through coverage/conversion - those revert with INVALID_POST_OP_STATE(ST_REDEEM)
        // because totalRedemptionNAV becomes zero. Not a fix concern, just unproductive fuzz inputs.
        AssetClaims memory claimPreview = ST.previewRedeem(sharesToRedeem);
        vm.assume(toUint256(claimPreview.stAssets) + toUint256(claimPreview.jtAssets) > 0);
        vm.prank(ST_ALICE_ADDRESS);
        // 4. Alice redeems shares.
        ST.redeem(sharesToRedeem, ST_ALICE_ADDRESS, ST_ALICE_ADDRESS);

        // 5. Bump yield.
        _bumpStoredConversionRate(WAD + _yield2WAD);
        _sync();

        // Grant LP role so `ST.maxDeposit(EVE)` evaluates against EVE's effective deposit
        // ceiling under the post-drain coverage state.
        address EVE = makeAddr("EVE_FUZZ");
        vm.prank(LP_ROLE_ADMIN_ADDRESS);
        FACTORY.grantRole(uint64(uint256(keccak256(abi.encode("ROYCO_ST_LP_ROLE")))), EVE, 0);

        uint256 eveMaxNAV = toUint256(ST.maxDeposit(EVE));
        // Require EVE to be able to deposit at least MIN_DEPOSIT - sub-dust deposits round to
        // zero NAV growth through the quoter and trigger INVALID_POST_OP_STATE.
        vm.assume(eveMaxNAV >= MIN_DEPOSIT);
        _eveDeposit = bound(_eveDeposit, MIN_DEPOSIT, eveMaxNAV);
        assertGt(_eveDeposit, 0, "EVE deposit amount should be non-zero");

        // Reference: share price immediately before EVE deposits.
        uint256 sharePriceBeforeEve = toUint256(ST.convertToAssets(1e18).nav);

        deal(SNUSD, EVE, _eveDeposit);
        vm.startPrank(EVE);
        IERC20(SNUSD).approve(address(ST), _eveDeposit);
        // 6. EVE deposits ST.
        uint256 eveShares = ST.deposit(toTrancheUnits(_eveDeposit), EVE);
        vm.stopPrank();

        assertGt(eveShares, 0, "EVE shares should be > 0");

        uint256 sharePriceAfterEve = toUint256(ST.convertToAssets(1e18).nav);

        // INVARIANT - a deposit is by construction price-neutral: the depositor brings in
        // valueAllocated NAV and receives valueAllocated/sharePrice shares, so both numerator
        // and denominator scale by the same factor and per-share NAV is unchanged. With both
        // (a) the claim-weighted attribution fix and (b) the symmetric virtual-offset fix in
        // `convertToAssets`, this invariant holds exactly (modulo 1 wei rounding from
        // Math.Rounding.Floor in the share-mint conversion).
        assertApproxEqAbs(sharePriceAfterEve, sharePriceBeforeEve, 1, "FIX REGRESSION: per-share NAV moved on EVE's deposit (a deposit must be price-neutral)");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _depositJT(address _u, uint256 _amount) internal {
        vm.startPrank(_u);
        IERC20(SNUSD).approve(address(JT), _amount);
        JT.deposit(toTrancheUnits(_amount), _u);
        vm.stopPrank();
    }

    function _depositST(address _u, uint256 _amount) internal returns (uint256 shares) {
        vm.startPrank(_u);
        IERC20(SNUSD).approve(address(ST), _amount);
        shares = ST.deposit(toTrancheUnits(_amount), _u);
        vm.stopPrank();
    }

    function _redeemAllST(address _u) internal {
        uint256 shares = ST.balanceOf(_u);
        vm.prank(_u);
        ST.redeem(shares, _u, _u);
    }

    function _bumpStoredConversionRate(uint256 _factorWAD) internal {
        uint256 current = IdenticalAssetsOracleQuoter(address(KERNEL)).getStoredConversionRateWAD();
        uint256 next = current * _factorWAD / WAD;
        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        IdenticalAssetsOracleQuoter(address(KERNEL)).setConversionRate(next, false);
    }
}

