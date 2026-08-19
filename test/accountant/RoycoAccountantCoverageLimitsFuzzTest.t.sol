// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { AccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { RoycoAccountant } from "../../src/accountant/RoycoAccountant.sol";
import { IRoycoAccountant, Operation } from "../../src/interfaces/IRoycoAccountant.sol";
import { MIN_COVERAGE_WAD, WAD, ZERO_NAV_UNITS } from "../../src/libraries/Constants.sol";
import { SyncedAccountingState } from "../../src/libraries/Types.sol";
import { NAV_UNIT, UnitsMathLib, toNAVUnits, toUint256 } from "../../src/libraries/Units.sol";
import { UtilsLib } from "../../src/libraries/UtilsLib.sol";
import { StaticCurveYDM } from "../../src/ydm/StaticCurveYDM.sol";

/**
 * @title RoycoAccountantCoverageLimitsFuzzTest
 * @notice Checks that the accountant's advertised coverage limits are self-consistent with its own
 *         coverage predicate.
 *
 * @dev The accountant documents the safety property it maintains as
 *
 *          JT_EFFECTIVE_NAV >= (ST_RAW_NAV + (JT_RAW_NAV * beta)) * COV
 *
 *      and exposes two functions that solve it for a bound: `maxSTDepositGivenCoverage` (how much may
 *      be added to the senior tranche) and `maxJTWithdrawalGivenCoverage` (how much may be taken out
 *      of the junior tranche). Those two numbers are what callers size operations against, so if
 *      either overshoots by even a wei the caller is handed a value that breaks senior coverage.
 *
 *      These are pure functions of their inputs, so stateless fuzzing is the right instrument here
 *      rather than a stateful invariant campaign: it explores the (stRawNAV, jtRawNAV, coverage, beta)
 *      space directly instead of reaching it through call sequences.
 *
 *      The property under test is deliberately expressed against the accountant's *own* predicate --
 *      `UtilsLib.computeUtilization(...) <= WAD`, exactly as `_isCoverageRequirementSatisfied` defines
 *      it -- rather than against a formula restated here. A restatement would only test that two
 *      copies of the same algebra agree.
 */
contract RoycoAccountantCoverageLimitsFuzzTest is Test {
    using Math for uint256;
    using UnitsMathLib for NAV_UNIT;

    uint256 internal constant MAX_NAV = 1e30;
    uint256 internal constant MIN_NAV = 1e6;

    uint64 internal constant ST_PROTOCOL_FEE_WAD = 0.1e18;
    uint64 internal constant JT_PROTOCOL_FEE_WAD = 0.1e18;
    uint24 internal constant FIXED_TERM_DURATION_SECONDS = 30 days;
    uint256 internal constant LIQUIDATION_UTILIZATION_WAD = 1.2e18;
    uint64 internal constant YDM_YIELD_AT_ZERO = 0.1e18;
    uint64 internal constant YDM_YIELD_AT_TARGET = 0.3e18;
    uint64 internal constant YDM_YIELD_AT_FULL = 0.9e18;

    RoycoAccountant internal accountantImpl;
    StaticCurveYDM internal ydm;
    AccessManager internal accessManager;
    address internal MOCK_KERNEL;

    function setUp() public {
        MOCK_KERNEL = makeAddr("MOCK_KERNEL");
        accessManager = new AccessManager(address(this));
        ydm = new StaticCurveYDM();
        accountantImpl = new RoycoAccountant(MOCK_KERNEL);
    }

    /// @dev Deploys a fresh accountant so coverage and beta can be fuzzed per case.
    function _deployAccountant(uint64 coverageWAD, uint96 betaWAD, NAV_UNIT dustTolerance) internal returns (IRoycoAccountant) {
        bytes memory ydmInitData = abi.encodeCall(StaticCurveYDM.initializeYDMForMarket, (YDM_YIELD_AT_ZERO, YDM_YIELD_AT_TARGET, YDM_YIELD_AT_FULL));

        IRoycoAccountant.RoycoAccountantInitParams memory params = IRoycoAccountant.RoycoAccountantInitParams({
            stProtocolFeeWAD: ST_PROTOCOL_FEE_WAD,
            jtProtocolFeeWAD: JT_PROTOCOL_FEE_WAD,
            yieldShareProtocolFeeWAD: 0,
            coverageWAD: coverageWAD,
            betaWAD: betaWAD,
            ydm: address(ydm),
            ydmInitializationData: ydmInitData,
            fixedTermDurationSeconds: FIXED_TERM_DURATION_SECONDS,
            liquidationUtilizationWAD: LIQUIDATION_UTILIZATION_WAD,
            stNAVDustTolerance: dustTolerance,
            jtNAVDustTolerance: dustTolerance
        });

        bytes memory initData = abi.encodeCall(RoycoAccountant.initialize, (params, address(accessManager)));
        return IRoycoAccountant(address(new ERC1967Proxy(address(accountantImpl), initData)));
    }

    /// @dev Deploys an accountant AND checkpoints a real baseline through the kernel.
    ///      Without this the accountant's persisted NAVs are zero, so every preview looks like
    ///      "the market just gained everything from nothing" and the yield distribution inflates
    ///      jtEffectiveNAV in step with stRawNAV -- which makes the coverage predicate unable to
    ///      fail at all. See test_Diag_CoveragePredicateIsSensitive.
    function _deployAndSeed(uint64 coverageWAD, uint96 betaWAD, uint256 stSeed, uint256 jtSeed) internal returns (IRoycoAccountant accountant) {
        accountant = _deployAccountant(coverageWAD, betaWAD, ZERO_NAV_UNITS);
        vm.startPrank(MOCK_KERNEL);
        accountant.postOpSyncTrancheAccounting(Operation.JT_DEPOSIT, ZERO_NAV_UNITS, toNAVUnits(jtSeed), ZERO_NAV_UNITS);
        accountant.postOpSyncTrancheAccounting(Operation.ST_DEPOSIT, toNAVUnits(stSeed), toNAVUnits(jtSeed), ZERO_NAV_UNITS);
        vm.stopPrank();
    }

    /// @dev Bounds coverage and beta to the range `_validateCoverageConfig` accepts.
    function _boundConfig(uint64 coverageWAD, uint96 betaWAD) internal pure returns (uint64, uint96) {
        coverageWAD = uint64(bound(coverageWAD, MIN_COVERAGE_WAD, WAD - 1));
        // Coverage config additionally requires ceil(coverage * beta / WAD) < WAD.
        uint96 maxBeta = uint96(uint256(WAD).mulDiv(WAD - 1, coverageWAD, Math.Rounding.Floor));
        betaWAD = uint96(bound(betaWAD, 0, maxBeta > WAD ? WAD : maxBeta));
        return (coverageWAD, betaWAD);
    }

    /// @dev The accountant's own coverage predicate: `_isCoverageRequirementSatisfied(utilization)`.
    function _coverageHolds(
        IRoycoAccountant accountant,
        NAV_UNIT stRawNAV,
        NAV_UNIT jtRawNAV,
        uint64 coverageWAD,
        uint96 betaWAD
    )
        internal
        view
        returns (bool, uint256)
    {
        SyncedAccountingState memory state = accountant.previewSyncTrancheAccounting(stRawNAV, jtRawNAV);
        uint256 utilization = UtilsLib.computeUtilization(stRawNAV, jtRawNAV, betaWAD, coverageWAD, state.jtEffectiveNAV);
        return (utilization <= WAD, utilization);
    }

    // =========================================================================
    // LIVENESS
    // =========================================================================

    /// @notice Proves the harness reaches the functions under test with a non-degenerate result.
    /// @dev Without this, a green fuzz campaign could mean every case returned zero early.
    function test_HarnessProducesNonZeroLimits() public {
        IRoycoAccountant accountant = _deployAccountant(0.5e18, 0.5e18, ZERO_NAV_UNITS);

        NAV_UNIT st = toNAVUnits(uint256(100e18));
        NAV_UNIT jt = toNAVUnits(uint256(1000e18));

        NAV_UNIT maxDeposit = accountant.maxSTDepositGivenCoverage(st, jt);
        assertGt(toUint256(maxDeposit), 0, "maxSTDepositGivenCoverage returned zero for a well-covered market");
        emit log_named_uint("maxSTDeposit for st=100e18 jt=1000e18", toUint256(maxDeposit));

        (NAV_UNIT totalClaimable,,) = accountant.maxJTWithdrawalGivenCoverage(st, jt, toNAVUnits(uint256(200e18)), toNAVUnits(uint256(800e18)));
        assertGt(toUint256(totalClaimable), 0, "maxJTWithdrawalGivenCoverage returned zero for a well-covered market");
        emit log_named_uint("maxJTWithdrawal for the same market", toUint256(totalClaimable));
    }

    // =========================================================================
    // COVERAGE LIMIT CONSISTENCY
    // =========================================================================

    /// @notice Depositing exactly the advertised maximum into the senior tranche must leave the
    ///         coverage requirement satisfied.
    /// @dev If this overshoots, a caller that trusts `maxSTDepositGivenCoverage` -- which is what it
    ///      exists for -- pushes the market into a state where the junior buffer no longer covers
    ///      senior exposure at the configured ratio.
    function testFuzz_maxSTDepositPreservesCoverage(uint256 stRawNAV, uint256 jtRawNAV, uint64 coverageWAD, uint96 betaWAD) public {
        (coverageWAD, betaWAD) = _boundConfig(coverageWAD, betaWAD);
        stRawNAV = bound(stRawNAV, MIN_NAV, MAX_NAV);
        jtRawNAV = bound(jtRawNAV, MIN_NAV, MAX_NAV);

        IRoycoAccountant accountant = _deployAndSeed(coverageWAD, betaWAD, stRawNAV, jtRawNAV);

        NAV_UNIT st = toNAVUnits(stRawNAV);
        NAV_UNIT jt = toNAVUnits(jtRawNAV);

        NAV_UNIT maxDeposit = accountant.maxSTDepositGivenCoverage(st, jt);
        if (maxDeposit == ZERO_NAV_UNITS) return;

        (bool holds, uint256 utilization) = _coverageHolds(accountant, st + maxDeposit, jt, coverageWAD, betaWAD);
        assertTrue(holds, "coverage broken after depositing the advertised maximum into ST");
        assertLe(utilization, WAD, "utilization exceeded WAD at the advertised ST deposit limit");
    }

    /// @notice Withdrawing exactly the advertised maximum from the junior tranche must leave the
    ///         coverage requirement satisfied.
    /// @dev The junior buffer is what protects senior. A withdrawal limit that overshoots hands the
    ///      last junior LP out a value that leaves senior under-covered.
    function testFuzz_maxJTWithdrawalPreservesCoverage(uint256 stRawNAV, uint256 jtRawNAV, uint256 claimSplitWAD, uint64 coverageWAD, uint96 betaWAD) public {
        (coverageWAD, betaWAD) = _boundConfig(coverageWAD, betaWAD);
        stRawNAV = bound(stRawNAV, MIN_NAV, MAX_NAV);
        jtRawNAV = bound(jtRawNAV, MIN_NAV, MAX_NAV);
        claimSplitWAD = bound(claimSplitWAD, 0, WAD);

        IRoycoAccountant accountant = _deployAndSeed(coverageWAD, betaWAD, stRawNAV, jtRawNAV);

        NAV_UNIT st = toNAVUnits(stRawNAV);
        NAV_UNIT jt = toNAVUnits(jtRawNAV);

        // Split the junior tranche's claims across ST and JT assets.
        NAV_UNIT jtClaimOnSt = toNAVUnits(stRawNAV.mulDiv(claimSplitWAD, WAD, Math.Rounding.Floor));
        NAV_UNIT jtClaimOnJt = jt;

        (NAV_UNIT totalClaimable, NAV_UNIT stClaimable, NAV_UNIT jtClaimable) = accountant.maxJTWithdrawalGivenCoverage(st, jt, jtClaimOnSt, jtClaimOnJt);
        if (totalClaimable == ZERO_NAV_UNITS) return;

        (bool holds, uint256 utilization) = _coverageHolds(accountant, st.saturatingSub(stClaimable), jt.saturatingSub(jtClaimable), coverageWAD, betaWAD);
        assertTrue(holds, "coverage broken after withdrawing the advertised maximum from JT");
        assertLe(utilization, WAD, "utilization exceeded WAD at the advertised JT withdrawal limit");
    }
}
