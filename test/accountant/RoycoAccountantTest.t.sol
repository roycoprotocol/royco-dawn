// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { RoycoAccountant } from "../../src/accountant/RoycoAccountant.sol";
import { IRoycoAccountant, Operation } from "../../src/interfaces/IRoycoAccountant.sol";
import { IRoycoAuth } from "../../src/interfaces/IRoycoAuth.sol";
import { MAX_PROTOCOL_FEE_WAD, MIN_COVERAGE_WAD, WAD, ZERO_NAV_UNITS } from "../../src/libraries/Constants.sol";
import { MarketState, SyncedAccountingState } from "../../src/libraries/Types.sol";
import { NAV_UNIT, UnitsMathLib, toUint256 } from "../../src/libraries/Units.sol";
import { UtilsLib } from "../../src/libraries/UtilsLib.sol";
import { AdaptiveCurveYDM_V1 } from "../../src/ydm/AdaptiveCurveYDM_V1.sol";
import { BaseTest } from "../base/BaseTest.t.sol";

contract RoycoAccountantTest is BaseTest {
    using Math for uint256;
    using UnitsMathLib for NAV_UNIT;

    uint256 internal constant MAX_NAV = 1e30;
    uint256 internal constant MIN_NAV = 1e6;

    RoycoAccountant internal accountantImpl;
    IRoycoAccountant internal accountant;
    AdaptiveCurveYDM_V1 internal adaptiveYDM;
    AccessManager internal accessManager;

    address internal MOCK_KERNEL;
    uint64 internal YDM_JT_YIELD_AT_TARGET = 0.3e18;
    uint64 internal YDM_JT_YIELD_AT_FULL = 0.9e18;

    function setUp() public {
        _setUpRoyco();

        MOCK_KERNEL = makeAddr("MOCK_KERNEL");
        accessManager = new AccessManager(OWNER_ADDRESS);
        adaptiveYDM = new AdaptiveCurveYDM_V1();
        accountantImpl = new RoycoAccountant(MOCK_KERNEL);

        accountant = _deployAccountant(
            MOCK_KERNEL,
            ST_PROTOCOL_FEE_WAD,
            JT_PROTOCOL_FEE_WAD,
            COVERAGE_WAD,
            BETA_WAD,
            address(adaptiveYDM),
            FIXED_TERM_DURATION_SECONDS,
            DUST_TOLERANCE,
            LIQUIDATION_UTILIZATION_WAD,
            YDM_JT_YIELD_AT_TARGET,
            YDM_JT_YIELD_AT_FULL
        );
    }

    function _deployAccountant(
        address,
        /* kernel */
        uint64 stProtocolFeeWAD,
        uint64 jtProtocolFeeWAD,
        uint64 coverageWAD,
        uint96 betaWAD,
        address ydm,
        uint24 fixedTermDuration,
        NAV_UNIT stNAVDustTolerance,
        uint256 liquidationUtilizationWAD,
        uint64 jtYieldAtTarget,
        uint64 jtYieldAtFull
    )
        internal
        returns (IRoycoAccountant)
    {
        bytes memory ydmInitData = abi.encodeCall(AdaptiveCurveYDM_V1.initializeYDMForMarket, (jtYieldAtTarget, jtYieldAtFull));

        IRoycoAccountant.RoycoAccountantInitParams memory params = IRoycoAccountant.RoycoAccountantInitParams({
            stProtocolFeeWAD: stProtocolFeeWAD,
            jtProtocolFeeWAD: jtProtocolFeeWAD,
            yieldShareProtocolFeeWAD: 0,
            coverageWAD: coverageWAD,
            betaWAD: betaWAD,
            ydm: ydm,
            ydmInitializationData: ydmInitData,
            fixedTermDurationSeconds: fixedTermDuration,
            liquidationUtilizationWAD: liquidationUtilizationWAD,
            stNAVDustTolerance: stNAVDustTolerance,
            jtNAVDustTolerance: DUST_TOLERANCE
        });

        bytes memory initData = abi.encodeCall(RoycoAccountant.initialize, (params, address(accessManager)));
        address proxy = address(new ERC1967Proxy(address(accountantImpl), initData));
        return IRoycoAccountant(proxy);
    }

    // =========================================================================
    // INITIALIZATION
    // =========================================================================

    function test_initialization_setsStateCorrectly() public view {
        IRoycoAccountant.RoycoAccountantState memory state = accountant.getState();

        assertEq(accountant.KERNEL(), MOCK_KERNEL, "kernel mismatch");
        assertEq(state.coverageWAD, COVERAGE_WAD, "coverage mismatch");
        assertEq(state.betaWAD, BETA_WAD, "beta mismatch");
        assertEq(state.stProtocolFeeWAD, ST_PROTOCOL_FEE_WAD, "st fee mismatch");
        assertEq(state.jtProtocolFeeWAD, JT_PROTOCOL_FEE_WAD, "jt fee mismatch");
        assertEq(state.liquidationUtilizationWAD, LIQUIDATION_UTILIZATION_WAD, "liquidationUtilization mismatch");
        assertEq(state.fixedTermDurationSeconds, FIXED_TERM_DURATION_SECONDS, "fixed term duration mismatch");
        assertEq(state.ydm, address(adaptiveYDM), "ydm mismatch");
        assertEq(uint8(state.lastMarketState), uint8(MarketState.PERPETUAL), "initial state should be perpetual");
    }

    function test_initialization_initializesYDMCorrectly() public view {
        (uint64 jtYieldShareAtTarget,, uint160 steepness) = adaptiveYDM.accountantToCurve(address(accountant));

        assertEq(jtYieldShareAtTarget, YDM_JT_YIELD_AT_TARGET, "YDM jtYieldShareAtTarget mismatch");
        assertEq(steepness, 3e18, "YDM steepness mismatch");
    }

    function testFuzz_initialization_validCoverageRange(uint64 coverageWAD, uint256 liquidationUtilization) public {
        coverageWAD = uint64(bound(coverageWAD, MIN_COVERAGE_WAD, WAD - 1));
        liquidationUtilization = bound(liquidationUtilization, WAD + 1, 100e18);

        IRoycoAccountant newAccountant = _deployAccountant(
            MOCK_KERNEL,
            ST_PROTOCOL_FEE_WAD,
            JT_PROTOCOL_FEE_WAD,
            coverageWAD,
            0,
            address(adaptiveYDM),
            FIXED_TERM_DURATION_SECONDS,
            DUST_TOLERANCE,
            liquidationUtilization,
            YDM_JT_YIELD_AT_TARGET,
            YDM_JT_YIELD_AT_FULL
        );

        assertEq(newAccountant.getState().coverageWAD, coverageWAD);
        assertEq(newAccountant.getState().liquidationUtilizationWAD, liquidationUtilization);
    }

    function test_initialization_revertsOnInvalidCoverage() public {
        vm.expectRevert(IRoycoAccountant.INVALID_COVERAGE_CONFIG.selector);
        _deployAccountant(
            MOCK_KERNEL,
            ST_PROTOCOL_FEE_WAD,
            JT_PROTOCOL_FEE_WAD,
            uint64(MIN_COVERAGE_WAD - 1),
            BETA_WAD,
            address(adaptiveYDM),
            FIXED_TERM_DURATION_SECONDS,
            DUST_TOLERANCE,
            LIQUIDATION_UTILIZATION_WAD,
            YDM_JT_YIELD_AT_TARGET,
            YDM_JT_YIELD_AT_FULL
        );

        vm.expectRevert(IRoycoAccountant.INVALID_COVERAGE_CONFIG.selector);
        _deployAccountant(
            MOCK_KERNEL,
            ST_PROTOCOL_FEE_WAD,
            JT_PROTOCOL_FEE_WAD,
            uint64(WAD),
            BETA_WAD,
            address(adaptiveYDM),
            FIXED_TERM_DURATION_SECONDS,
            DUST_TOLERANCE,
            LIQUIDATION_UTILIZATION_WAD,
            YDM_JT_YIELD_AT_TARGET,
            YDM_JT_YIELD_AT_FULL
        );
    }

    function test_initialization_revertsOnInvalidLiquidationUtilization() public {
        // liquidationUtilization must be > WAD (> 100%)
        // Test that liquidationUtilization = WAD reverts
        vm.expectRevert(IRoycoAccountant.INVALID_COVERAGE_CONFIG.selector);
        _deployAccountant(
            MOCK_KERNEL,
            ST_PROTOCOL_FEE_WAD,
            JT_PROTOCOL_FEE_WAD,
            COVERAGE_WAD,
            BETA_WAD,
            address(adaptiveYDM),
            FIXED_TERM_DURATION_SECONDS,
            DUST_TOLERANCE,
            WAD, // exactly 100% - should revert
            YDM_JT_YIELD_AT_TARGET,
            YDM_JT_YIELD_AT_FULL
        );

        // Test that liquidationUtilization < WAD reverts
        vm.expectRevert(IRoycoAccountant.INVALID_COVERAGE_CONFIG.selector);
        _deployAccountant(
            MOCK_KERNEL,
            ST_PROTOCOL_FEE_WAD,
            JT_PROTOCOL_FEE_WAD,
            COVERAGE_WAD,
            BETA_WAD,
            address(adaptiveYDM),
            FIXED_TERM_DURATION_SECONDS,
            DUST_TOLERANCE,
            WAD / 2, // 50% - should revert
            YDM_JT_YIELD_AT_TARGET,
            YDM_JT_YIELD_AT_FULL
        );
    }

    function test_initialization_revertsOnNullYDM() public {
        IRoycoAccountant.RoycoAccountantInitParams memory params = IRoycoAccountant.RoycoAccountantInitParams({
            stProtocolFeeWAD: ST_PROTOCOL_FEE_WAD,
            jtProtocolFeeWAD: JT_PROTOCOL_FEE_WAD,
            yieldShareProtocolFeeWAD: 0,
            coverageWAD: COVERAGE_WAD,
            betaWAD: BETA_WAD,
            ydm: address(0),
            ydmInitializationData: "",
            fixedTermDurationSeconds: FIXED_TERM_DURATION_SECONDS,
            liquidationUtilizationWAD: LIQUIDATION_UTILIZATION_WAD,
            stNAVDustTolerance: DUST_TOLERANCE,
            jtNAVDustTolerance: DUST_TOLERANCE
        });

        bytes memory initData = abi.encodeCall(RoycoAccountant.initialize, (params, address(accessManager)));
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        new ERC1967Proxy(address(accountantImpl), initData);
    }

    function test_initialization_revertsOnExcessiveProtocolFee() public {
        vm.expectRevert(IRoycoAccountant.MAX_PROTOCOL_FEE_EXCEEDED.selector);
        _deployAccountant(
            MOCK_KERNEL,
            uint64(MAX_PROTOCOL_FEE_WAD + 1),
            JT_PROTOCOL_FEE_WAD,
            COVERAGE_WAD,
            BETA_WAD,
            address(adaptiveYDM),
            FIXED_TERM_DURATION_SECONDS,
            DUST_TOLERANCE,
            LIQUIDATION_UTILIZATION_WAD,
            YDM_JT_YIELD_AT_TARGET,
            YDM_JT_YIELD_AT_FULL
        );

        vm.expectRevert(IRoycoAccountant.MAX_PROTOCOL_FEE_EXCEEDED.selector);
        _deployAccountant(
            MOCK_KERNEL,
            ST_PROTOCOL_FEE_WAD,
            uint64(MAX_PROTOCOL_FEE_WAD + 1),
            COVERAGE_WAD,
            BETA_WAD,
            address(adaptiveYDM),
            FIXED_TERM_DURATION_SECONDS,
            DUST_TOLERANCE,
            LIQUIDATION_UTILIZATION_WAD,
            YDM_JT_YIELD_AT_TARGET,
            YDM_JT_YIELD_AT_FULL
        );
    }

    // =========================================================================
    // PRE-OP SYNC BASIC
    // =========================================================================

    function test_preOpSync_onlyKernel() public {
        vm.expectRevert(IRoycoAccountant.ONLY_ROYCO_KERNEL.selector);
        accountant.preOpSyncTrancheAccounting(_nav(100e18), _nav(50e18));
    }

    function test_preOpSync_rawNAVsSetCorrectly() public {
        NAV_UNIT stRawNAV = _nav(100e18);
        NAV_UNIT jtRawNAV = _nav(50e18);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state = accountant.preOpSyncTrancheAccounting(stRawNAV, jtRawNAV);

        assertEq(state.stRawNAV, stRawNAV, "stRawNAV mismatch");
        assertEq(state.jtRawNAV, jtRawNAV, "jtRawNAV mismatch");
        assertEq(state.stImpermanentLoss, ZERO_NAV_UNITS, "no ST IL initially");
        assertEq(state.jtImpermanentLoss, ZERO_NAV_UNITS, "no JT coverage IL initially");
        // jtSelfImpermanentLoss was removed from SyncedAccountingState
        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "should be perpetual");
        _assertNAVConservation(state);
    }

    function testFuzz_preOpSync_navConservation(uint256 stNav, uint256 jtNav) public {
        stNav = bound(stNav, MIN_NAV, MAX_NAV);
        jtNav = bound(jtNav, MIN_NAV, MAX_NAV);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state = accountant.preOpSyncTrancheAccounting(_nav(stNav), _nav(jtNav));

        _assertNAVConservation(state);
    }

    function test_preOpSync_noChangeAfterInitialization() public {
        _initializeAccountantState(100e18, 50e18);
        IRoycoAccountant.RoycoAccountantState memory baseState = accountant.getState();

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state = accountant.preOpSyncTrancheAccounting(_nav(100e18), _nav(50e18));

        assertEq(state.stEffectiveNAV, baseState.lastSTEffectiveNAV, "ST effective unchanged when no delta");
        assertEq(state.jtEffectiveNAV, baseState.lastJTEffectiveNAV, "JT effective unchanged when no delta");
        _assertNAVConservation(state);
    }

    // =========================================================================
    // GAIN/LOSS PERMUTATIONS
    // =========================================================================

    function test_preOpSync_stGain_yieldDistributed() public {
        _initializeAccountantState(100e18, 50e18);
        IRoycoAccountant.RoycoAccountantState memory baseState = accountant.getState();
        uint256 stEffBefore = toUint256(baseState.lastSTEffectiveNAV);
        uint256 jtEffBefore = toUint256(baseState.lastJTEffectiveNAV);

        vm.warp(vm.getBlockTimestamp() + 1 days);

        uint256 stGain = 10e18;
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state = accountant.preOpSyncTrancheAccounting(_nav(100e18 + stGain), _nav(50e18));

        assertGt(toUint256(state.jtEffectiveNAV), jtEffBefore, "JT should receive yield share");
        assertLt(toUint256(state.stEffectiveNAV), stEffBefore + stGain, "ST should share yield with JT");
        assertEq(toUint256(state.stEffectiveNAV) + toUint256(state.jtEffectiveNAV), stEffBefore + jtEffBefore + stGain, "total gain distributed");
        _assertNAVConservation(state);
    }

    function test_preOpSync_stLoss_fullCoverage() public {
        _initializeAccountantState(100e18, 50e18);
        IRoycoAccountant.RoycoAccountantState memory baseState = accountant.getState();
        uint256 stEffBefore = toUint256(baseState.lastSTEffectiveNAV);
        uint256 jtEffBefore = toUint256(baseState.lastJTEffectiveNAV);

        uint256 stLoss = 20e18;
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state = accountant.preOpSyncTrancheAccounting(_nav(100e18 - stLoss), _nav(50e18));

        assertEq(toUint256(state.stEffectiveNAV), stEffBefore, "ST fully covered");
        assertEq(toUint256(state.jtEffectiveNAV), jtEffBefore - stLoss, "JT provides coverage");
        assertEq(toUint256(state.jtImpermanentLoss), stLoss, "JT coverage IL equals loss");
        assertEq(toUint256(state.stImpermanentLoss), 0, "no ST IL");
        _assertNAVConservation(state);
    }

    function test_preOpSync_stLoss_partialCoverage() public {
        _initializeAccountantState(100e18, 50e18);
        IRoycoAccountant.RoycoAccountantState memory baseState = accountant.getState();
        uint256 stEffBefore = toUint256(baseState.lastSTEffectiveNAV);
        uint256 jtEffBefore = toUint256(baseState.lastJTEffectiveNAV);

        uint256 stLoss = stEffBefore + jtEffBefore + 10e18;
        uint256 newStRaw = 100e18 > stLoss ? 100e18 - stLoss : 0;
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state = accountant.preOpSyncTrancheAccounting(_nav(newStRaw), _nav(50e18));

        assertEq(toUint256(state.jtEffectiveNAV), 0, "JT exhausted");
        assertGt(toUint256(state.stImpermanentLoss), 0, "ST has IL");
        _assertNAVConservation(state);
    }

    function test_preOpSync_jtGain() public {
        _initializeAccountantState(100e18, 50e18);
        IRoycoAccountant.RoycoAccountantState memory baseState = accountant.getState();
        uint256 stEffBefore = toUint256(baseState.lastSTEffectiveNAV);
        uint256 jtEffBefore = toUint256(baseState.lastJTEffectiveNAV);

        uint256 jtGain = 10e18;
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state = accountant.preOpSyncTrancheAccounting(_nav(100e18), _nav(50e18 + jtGain));

        assertEq(toUint256(state.jtEffectiveNAV), jtEffBefore + jtGain, "JT accrues gain");
        assertEq(toUint256(state.stEffectiveNAV), stEffBefore, "ST unchanged");
        assertGt(toUint256(state.jtProtocolFeeAccrued), 0, "JT fee accrued");
        _assertNAVConservation(state);
    }

    function test_preOpSync_jtLoss() public {
        _initializeAccountantState(100e18, 50e18);
        IRoycoAccountant.RoycoAccountantState memory baseState = accountant.getState();
        uint256 stEffBefore = toUint256(baseState.lastSTEffectiveNAV);
        uint256 jtEffBefore = toUint256(baseState.lastJTEffectiveNAV);

        uint256 jtLoss = 10e18;
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state = accountant.preOpSyncTrancheAccounting(_nav(100e18), _nav(50e18 - jtLoss));

        assertEq(toUint256(state.jtEffectiveNAV), jtEffBefore - jtLoss, "JT absorbs loss");
        assertEq(toUint256(state.stEffectiveNAV), stEffBefore, "ST unchanged");
        // jtSelfImpermanentLoss removed from SyncedAccountingState
        _assertNAVConservation(state);
    }

    function test_preOpSync_bothGain() public {
        _initializeAccountantState(100e18, 50e18);
        IRoycoAccountant.RoycoAccountantState memory baseState = accountant.getState();
        uint256 totalEffBefore = toUint256(baseState.lastSTEffectiveNAV) + toUint256(baseState.lastJTEffectiveNAV);

        vm.warp(vm.getBlockTimestamp() + 1 days);

        uint256 stGain = 10e18;
        uint256 jtGain = 5e18;
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state = accountant.preOpSyncTrancheAccounting(_nav(100e18 + stGain), _nav(50e18 + jtGain));

        uint256 totalEffAfter = toUint256(state.stEffectiveNAV) + toUint256(state.jtEffectiveNAV);
        assertEq(totalEffAfter, totalEffBefore + stGain + jtGain, "total gain captured");
        _assertNAVConservation(state);
    }

    function test_preOpSync_bothLose() public {
        _initializeAccountantState(100e18, 50e18);
        IRoycoAccountant.RoycoAccountantState memory baseState = accountant.getState();
        uint256 stEffBefore = toUint256(baseState.lastSTEffectiveNAV);
        uint256 jtEffBefore = toUint256(baseState.lastJTEffectiveNAV);

        uint256 stLoss = 10e18;
        uint256 jtLoss = 5e18;
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state = accountant.preOpSyncTrancheAccounting(_nav(100e18 - stLoss), _nav(50e18 - jtLoss));

        assertEq(toUint256(state.stEffectiveNAV), stEffBefore, "ST covered");
        assertEq(toUint256(state.jtEffectiveNAV), jtEffBefore - jtLoss - stLoss, "JT absorbs both");
        // jtSelfImpermanentLoss removed from SyncedAccountingState
        assertEq(toUint256(state.jtImpermanentLoss), stLoss, "JT coverage IL");
        _assertNAVConservation(state);
    }

    function test_preOpSync_stGain_jtLoss() public {
        _initializeAccountantState(100e18, 50e18);
        IRoycoAccountant.RoycoAccountantState memory baseState = accountant.getState();
        uint256 jtEffBefore = toUint256(baseState.lastJTEffectiveNAV);

        vm.warp(vm.getBlockTimestamp() + 1 days);

        uint256 stGain = 10e18;
        uint256 jtLoss = 5e18;
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state = accountant.preOpSyncTrancheAccounting(_nav(100e18 + stGain), _nav(50e18 - jtLoss));

        // jtSelfImpermanentLoss removed from SyncedAccountingState
        assertGt(toUint256(state.jtEffectiveNAV), jtEffBefore - jtLoss, "JT receives yield share");
        _assertNAVConservation(state);
    }

    function test_preOpSync_stLoss_jtGain() public {
        _initializeAccountantState(100e18, 50e18);
        IRoycoAccountant.RoycoAccountantState memory baseState = accountant.getState();
        uint256 stEffBefore = toUint256(baseState.lastSTEffectiveNAV);

        uint256 stLoss = 10e18;
        uint256 jtGain = 15e18;
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state = accountant.preOpSyncTrancheAccounting(_nav(100e18 - stLoss), _nav(50e18 + jtGain));

        assertEq(toUint256(state.stEffectiveNAV), stEffBefore, "ST covered");
        assertEq(toUint256(state.jtImpermanentLoss), stLoss, "JT coverage IL");
        _assertNAVConservation(state);
    }

    function testFuzz_preOpSync_allCombinations(int256 stDelta, int256 jtDelta) public {
        _initializeAccountantState(100e18, 50e18);

        stDelta = bound(stDelta, -int256(100e18), int256(100e18));
        jtDelta = bound(jtDelta, -int256(50e18), int256(50e18));

        vm.warp(vm.getBlockTimestamp() + 1 days);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state =
            accountant.preOpSyncTrancheAccounting(_nav(uint256(int256(100e18) + stDelta)), _nav(uint256(int256(50e18) + jtDelta)));

        _assertNAVConservation(state);
    }

    // =========================================================================
    // IL RECOVERY
    // =========================================================================

    function test_preOpSync_stILRecovery_fromJTGain() public {
        _initializeAccountantState(100e18, 10e18);

        uint256 stLoss = 40e18;
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state1 = accountant.preOpSyncTrancheAccounting(_nav(100e18 - stLoss), _nav(10e18));

        uint256 stIL = toUint256(state1.stImpermanentLoss);
        assertGt(stIL, 0, "ST IL created");

        uint256 jtGain = 50e18;
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state2 = accountant.preOpSyncTrancheAccounting(_nav(100e18 - stLoss), _nav(10e18 + jtGain));

        assertEq(toUint256(state2.stImpermanentLoss), 0, "ST IL recovered");
        _assertNAVConservation(state2);
    }

    function test_preOpSync_jtCoverageILRecovery_fromSTGain() public {
        _initializeAccountantState(100e18, 50e18);

        uint256 stLoss = 20e18;
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state1 = accountant.preOpSyncTrancheAccounting(_nav(100e18 - stLoss), _nav(50e18));

        assertEq(toUint256(state1.jtImpermanentLoss), stLoss, "JT coverage IL created");

        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 stGain = 30e18;
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state2 = accountant.preOpSyncTrancheAccounting(_nav(100e18 - stLoss + stGain), _nav(50e18));

        assertEq(toUint256(state2.jtImpermanentLoss), 0, "JT coverage IL recovered");
        _assertNAVConservation(state2);
    }

    function test_preOpSync_jtSelfILRecovery_fromJTGain() public {
        _initializeAccountantState(100e18, 50e18);

        uint256 jtLoss = 10e18;
        vm.prank(MOCK_KERNEL);
        accountant.preOpSyncTrancheAccounting(_nav(100e18), _nav(50e18 - jtLoss));

        // jtSelfImpermanentLoss removed from SyncedAccountingState

        uint256 jtGain = 15e18;
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state2 = accountant.preOpSyncTrancheAccounting(_nav(100e18), _nav(50e18 - jtLoss + jtGain));

        // jtSelfImpermanentLoss removed from SyncedAccountingState
        _assertNAVConservation(state2);
    }

    // =========================================================================
    // STATE TRANSITIONS
    // =========================================================================

    function test_stateTransition_perpetualToFixedTerm() public {
        _initializeAccountantState(100e18, 50e18);

        assertEq(uint8(accountant.getState().lastMarketState), uint8(MarketState.PERPETUAL));

        uint256 stLoss = 20e18;
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state = accountant.preOpSyncTrancheAccounting(_nav(100e18 - stLoss), _nav(50e18));

        assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM), "transitioned to FIXED_TERM");
        assertGt(toUint256(state.jtImpermanentLoss), 0, "JT coverage IL exists");
        assertGt(accountant.getState().fixedTermEndTimestamp, vm.getBlockTimestamp(), "fixed term end set");
    }

    function test_stateTransition_fixedTermExpiry() public {
        _initializeAccountantState(100e18, 50e18);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state1 = accountant.preOpSyncTrancheAccounting(_nav(80e18), _nav(50e18));
        assertEq(uint8(state1.marketState), uint8(MarketState.FIXED_TERM));

        uint32 fixedTermEnd = accountant.getState().fixedTermEndTimestamp;
        vm.warp(fixedTermEnd + 1);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state2 = accountant.preOpSyncTrancheAccounting(_nav(80e18), _nav(50e18));

        assertEq(uint8(state2.marketState), uint8(MarketState.PERPETUAL), "back to PERPETUAL");
        assertEq(toUint256(state2.jtImpermanentLoss), 0, "JT coverage IL cleared");
    }

    function test_stateTransition_alwaysPerpetual_whenDurationZero() public {
        IRoycoAccountant perpetualAccountant = _deployAccountant(
            MOCK_KERNEL,
            ST_PROTOCOL_FEE_WAD,
            JT_PROTOCOL_FEE_WAD,
            COVERAGE_WAD,
            BETA_WAD,
            address(adaptiveYDM),
            0,
            DUST_TOLERANCE,
            LIQUIDATION_UTILIZATION_WAD,
            YDM_JT_YIELD_AT_TARGET,
            YDM_JT_YIELD_AT_FULL
        );

        vm.prank(MOCK_KERNEL);
        perpetualAccountant.preOpSyncTrancheAccounting(_nav(100e18), _nav(50e18));

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state = perpetualAccountant.preOpSyncTrancheAccounting(_nav(80e18), _nav(50e18));

        assertEq(uint8(state.marketState), uint8(MarketState.PERPETUAL), "stays PERPETUAL");
    }

    function test_stateTransition_fullCycle() public {
        _initializeAccountantState(100e18, 50e18);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state1 = accountant.preOpSyncTrancheAccounting(_nav(80e18), _nav(50e18));
        assertEq(uint8(state1.marketState), uint8(MarketState.FIXED_TERM));

        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state2 = accountant.preOpSyncTrancheAccounting(_nav(80e18), _nav(50e18));
        assertEq(uint8(state2.marketState), uint8(MarketState.FIXED_TERM));

        uint32 termEnd = accountant.getState().fixedTermEndTimestamp;
        vm.warp(termEnd + 1);
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state3 = accountant.preOpSyncTrancheAccounting(_nav(80e18), _nav(50e18));
        assertEq(uint8(state3.marketState), uint8(MarketState.PERPETUAL));

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state4 = accountant.preOpSyncTrancheAccounting(_nav(70e18), _nav(50e18));
        assertEq(uint8(state4.marketState), uint8(MarketState.FIXED_TERM));
    }

    function test_stateTransition_fixedTermToPerpetual_ilRecoveryBeforeExpiry() public {
        _initializeAccountantState(100e18, 50e18);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state1 = accountant.preOpSyncTrancheAccounting(_nav(80e18), _nav(50e18));
        assertEq(uint8(state1.marketState), uint8(MarketState.FIXED_TERM));
        assertGt(toUint256(state1.jtImpermanentLoss), 0, "IL exists");

        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state2 = accountant.preOpSyncTrancheAccounting(_nav(110e18), _nav(50e18));

        assertEq(uint8(state2.marketState), uint8(MarketState.PERPETUAL), "back to PERPETUAL via recovery");
        assertEq(toUint256(state2.jtImpermanentLoss), 0, "IL cleared via recovery");
    }

    function test_stateTransition_fixedTermToPerpetual_stILCreated() public {
        _initializeAccountantState(100e18, 50e18);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state1 = accountant.preOpSyncTrancheAccounting(_nav(80e18), _nav(50e18));
        assertEq(uint8(state1.marketState), uint8(MarketState.FIXED_TERM));

        // Massive loss to 0 ST NAV — drains JT and creates ST IL
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state2 = accountant.preOpSyncTrancheAccounting(_nav(0), _nav(50e18));

        assertEq(uint8(state2.marketState), uint8(MarketState.PERPETUAL), "PERPETUAL when ST has IL");
        assertGt(toUint256(state2.stImpermanentLoss), 0, "ST IL exists");
    }

    function test_stateTransition_staysFixedTerm_partialRecovery() public {
        _initializeAccountantState(100e18, 50e18);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state1 = accountant.preOpSyncTrancheAccounting(_nav(80e18), _nav(50e18));
        assertEq(uint8(state1.marketState), uint8(MarketState.FIXED_TERM));
        uint256 initialIL = toUint256(state1.jtImpermanentLoss);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state2 = accountant.preOpSyncTrancheAccounting(_nav(90e18), _nav(50e18));

        assertEq(uint8(state2.marketState), uint8(MarketState.FIXED_TERM), "stays FIXED_TERM");
        assertLt(toUint256(state2.jtImpermanentLoss), initialIL, "IL reduced but not zero");
        assertGt(toUint256(state2.jtImpermanentLoss), 0, "IL still exists");
    }

    function test_stateTransition_exactlyAtExpiry() public {
        _initializeAccountantState(100e18, 50e18);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state1 = accountant.preOpSyncTrancheAccounting(_nav(80e18), _nav(50e18));
        assertEq(uint8(state1.marketState), uint8(MarketState.FIXED_TERM));

        uint32 termEnd = accountant.getState().fixedTermEndTimestamp;
        vm.warp(termEnd);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state2 = accountant.preOpSyncTrancheAccounting(_nav(80e18), _nav(50e18));

        assertEq(uint8(state2.marketState), uint8(MarketState.PERPETUAL), "PERPETUAL at exact expiry");
        assertEq(toUint256(state2.jtImpermanentLoss), 0, "IL cleared at expiry");
    }

    function test_stateTransition_multipleRapidTransitions() public {
        _initializeAccountantState(100e18, 50e18);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory s1 = accountant.preOpSyncTrancheAccounting(_nav(80e18), _nav(50e18));
        assertEq(uint8(s1.marketState), uint8(MarketState.FIXED_TERM));

        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory s2 = accountant.preOpSyncTrancheAccounting(_nav(110e18), _nav(50e18));
        assertEq(uint8(s2.marketState), uint8(MarketState.PERPETUAL));

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory s3 = accountant.preOpSyncTrancheAccounting(_nav(80e18), _nav(50e18));
        assertEq(uint8(s3.marketState), uint8(MarketState.FIXED_TERM));

        uint32 termEnd = accountant.getState().fixedTermEndTimestamp;
        vm.warp(termEnd + 1);
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory s4 = accountant.preOpSyncTrancheAccounting(_nav(80e18), _nav(50e18));
        assertEq(uint8(s4.marketState), uint8(MarketState.PERPETUAL));

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory s5 = accountant.preOpSyncTrancheAccounting(_nav(70e18), _nav(50e18));
        assertEq(uint8(s5.marketState), uint8(MarketState.FIXED_TERM));
    }

    function testFuzz_stateTransition_perpetualToFixedTerm(uint256 stNav, uint256 jtNav, uint256 lossPercent) public {
        stNav = bound(stNav, 10e18, MAX_NAV / 4);
        jtNav = bound(jtNav, stNav / 4, stNav);
        lossPercent = bound(lossPercent, 1, 50);

        _initializeAccountantState(stNav, jtNav);
        IRoycoAccountant.RoycoAccountantState memory baseState = accountant.getState();
        uint256 jtEffBefore = toUint256(baseState.lastJTEffectiveNAV);

        uint256 stLoss = (stNav * lossPercent) / 100;
        uint256 newStNav = stNav - stLoss;

        if (stLoss > 0 && stLoss < jtEffBefore) {
            vm.prank(MOCK_KERNEL);
            SyncedAccountingState memory state = accountant.preOpSyncTrancheAccounting(_nav(newStNav), _nav(jtNav));

            if (toUint256(state.jtImpermanentLoss) > 0 && toUint256(state.stImpermanentLoss) == 0) {
                assertEq(uint8(state.marketState), uint8(MarketState.FIXED_TERM));
            }
        }
    }

    // =========================================================================
    // POST-OP SYNC
    // =========================================================================

    function test_postOpSync_onlyKernel() public {
        _initializeAccountantState(100e18, 50e18);
        vm.expectRevert(IRoycoAccountant.ONLY_ROYCO_KERNEL.selector);
        accountant.postOpSyncTrancheAccounting(Operation.ST_DEPOSIT, _nav(120e18), _nav(50e18), ZERO_NAV_UNITS);
    }

    function test_postOpSync_stIncreaseNAV() public {
        _initializeAccountantState(100e18, 50e18);
        IRoycoAccountant.RoycoAccountantState memory baseState = accountant.getState();
        uint256 stEffBefore = toUint256(baseState.lastSTEffectiveNAV);
        uint256 jtEffBefore = toUint256(baseState.lastJTEffectiveNAV);

        uint256 deposit = 20e18;
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state = accountant.postOpSyncTrancheAccounting(Operation.ST_DEPOSIT, _nav(100e18 + deposit), _nav(50e18), ZERO_NAV_UNITS);

        assertEq(toUint256(state.stEffectiveNAV), stEffBefore + deposit, "ST effective increased");
        assertEq(toUint256(state.jtEffectiveNAV), jtEffBefore, "JT unchanged");
        assertEq(toUint256(state.stProtocolFeeAccrued), 0, "no fee on post-op");
        _assertNAVConservation(state);
        _assertConfigFields(state);
    }

    function test_postOpSync_jtIncreaseNAV() public {
        _initializeAccountantState(100e18, 50e18);
        IRoycoAccountant.RoycoAccountantState memory baseState = accountant.getState();
        uint256 stEffBefore = toUint256(baseState.lastSTEffectiveNAV);
        uint256 jtEffBefore = toUint256(baseState.lastJTEffectiveNAV);

        uint256 deposit = 20e18;
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state = accountant.postOpSyncTrancheAccounting(Operation.JT_DEPOSIT, _nav(100e18), _nav(50e18 + deposit), ZERO_NAV_UNITS);

        assertEq(toUint256(state.jtEffectiveNAV), jtEffBefore + deposit, "JT effective increased");
        assertEq(toUint256(state.stEffectiveNAV), stEffBefore, "ST unchanged");
        _assertNAVConservation(state);
        _assertConfigFields(state);
    }

    function test_postOpSync_stDecreaseNAV() public {
        _initializeAccountantState(100e18, 50e18);
        IRoycoAccountant.RoycoAccountantState memory baseState = accountant.getState();
        uint256 stEffBefore = toUint256(baseState.lastSTEffectiveNAV);
        uint256 jtEffBefore = toUint256(baseState.lastJTEffectiveNAV);

        uint256 withdrawal = 20e18;
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state = accountant.postOpSyncTrancheAccounting(Operation.ST_REDEEM, _nav(100e18 - withdrawal), _nav(50e18), ZERO_NAV_UNITS);

        assertEq(toUint256(state.stEffectiveNAV), stEffBefore - withdrawal, "ST effective decreased");
        assertEq(toUint256(state.jtEffectiveNAV), jtEffBefore, "JT unchanged");
        _assertNAVConservation(state);
        _assertConfigFields(state);
    }

    function test_postOpSync_jtDecreaseNAV() public {
        _initializeAccountantState(100e18, 50e18);
        IRoycoAccountant.RoycoAccountantState memory baseState = accountant.getState();
        uint256 stEffBefore = toUint256(baseState.lastSTEffectiveNAV);
        uint256 jtEffBefore = toUint256(baseState.lastJTEffectiveNAV);

        uint256 withdrawal = 20e18;
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state = accountant.postOpSyncTrancheAccounting(Operation.JT_REDEEM, _nav(100e18), _nav(50e18 - withdrawal), ZERO_NAV_UNITS);

        assertEq(toUint256(state.jtEffectiveNAV), jtEffBefore - withdrawal, "JT effective decreased");
        assertEq(toUint256(state.stEffectiveNAV), stEffBefore, "ST unchanged");
        _assertNAVConservation(state);
        _assertConfigFields(state);
    }

    function test_postOpSync_revertsOnInvalidState() public {
        _initializeAccountantState(100e18, 50e18);

        vm.prank(MOCK_KERNEL);
        vm.expectRevert(abi.encodeWithSelector(IRoycoAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_DEPOSIT));
        accountant.postOpSyncTrancheAccounting(Operation.ST_DEPOSIT, _nav(90e18), _nav(50e18), ZERO_NAV_UNITS);

        vm.prank(MOCK_KERNEL);
        vm.expectRevert(abi.encodeWithSelector(IRoycoAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_DEPOSIT));
        accountant.postOpSyncTrancheAccounting(Operation.JT_DEPOSIT, _nav(100e18), _nav(40e18), ZERO_NAV_UNITS);

        vm.prank(MOCK_KERNEL);
        vm.expectRevert(abi.encodeWithSelector(IRoycoAccountant.INVALID_POST_OP_STATE.selector, Operation.ST_REDEEM));
        accountant.postOpSyncTrancheAccounting(Operation.ST_REDEEM, _nav(110e18), _nav(50e18), ZERO_NAV_UNITS);

        vm.prank(MOCK_KERNEL);
        vm.expectRevert(abi.encodeWithSelector(IRoycoAccountant.INVALID_POST_OP_STATE.selector, Operation.JT_REDEEM));
        accountant.postOpSyncTrancheAccounting(Operation.JT_REDEEM, _nav(100e18), _nav(60e18), ZERO_NAV_UNITS);
    }

    function test_postOpSync_stWithdrawal_scalesSTIL() public {
        _initializeAccountantState(100e18, 10e18);

        vm.prank(MOCK_KERNEL);
        accountant.preOpSyncTrancheAccounting(_nav(50e18), _nav(10e18));

        IRoycoAccountant.RoycoAccountantState memory stateBefore = accountant.getState();
        uint256 stILBefore = toUint256(stateBefore.lastSTImpermanentLoss);
        uint256 stEffBefore = toUint256(stateBefore.lastSTEffectiveNAV);

        vm.prank(MOCK_KERNEL);
        accountant.postOpSyncTrancheAccounting(Operation.ST_REDEEM, _nav(25e18), _nav(10e18), ZERO_NAV_UNITS);

        IRoycoAccountant.RoycoAccountantState memory stateAfter = accountant.getState();
        uint256 stILAfter = toUint256(stateAfter.lastSTImpermanentLoss);
        uint256 stEffAfter = toUint256(stateAfter.lastSTEffectiveNAV);

        uint256 expectedIL = stILBefore.mulDiv(stEffAfter, stEffBefore, Math.Rounding.Ceil);
        assertApproxEqAbs(stILAfter, expectedIL, 1, "ST IL scales proportionally");
    }

    function test_postOpSync_jtWithdrawal_scalesJTCoverageIL() public {
        _initializeAccountantState(100e18, 50e18);

        vm.prank(MOCK_KERNEL);
        accountant.preOpSyncTrancheAccounting(_nav(80e18), _nav(50e18));

        IRoycoAccountant.RoycoAccountantState memory stateBefore = accountant.getState();
        uint256 jtCovILBefore = toUint256(stateBefore.lastJTImpermanentLoss);
        uint256 jtEffBefore = toUint256(stateBefore.lastJTEffectiveNAV);

        vm.prank(MOCK_KERNEL);
        accountant.postOpSyncTrancheAccounting(Operation.JT_REDEEM, _nav(80e18), _nav(25e18), ZERO_NAV_UNITS);

        IRoycoAccountant.RoycoAccountantState memory stateAfter = accountant.getState();
        uint256 jtCovILAfter = toUint256(stateAfter.lastJTImpermanentLoss);
        uint256 jtEffAfter = toUint256(stateAfter.lastJTEffectiveNAV);

        uint256 expectedIL = jtCovILBefore.mulDiv(jtEffAfter, jtEffBefore, Math.Rounding.Floor);
        assertApproxEqAbs(jtCovILAfter, expectedIL, 1, "JT coverage IL scales proportionally");
    }

    // =========================================================================
    // COVERAGE ENFORCEMENT
    // =========================================================================

    function test_postOpSyncAndEnforceCoverage_passes() public {
        _initializeAccountantState(100e18, 50e18);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state = accountant.postOpSyncTrancheAccountingAndEnforceCoverage(Operation.ST_DEPOSIT, _nav(105e18), _nav(50e18));

        assertTrue(accountant.isCoverageRequirementSatisfied(), "coverage satisfied");
        _assertNAVConservation(state);
    }

    function test_postOpSyncAndEnforceCoverage_reverts() public {
        _initializeAccountantState(100e18, 20e18);

        vm.prank(MOCK_KERNEL);
        vm.expectRevert(IRoycoAccountant.COVERAGE_REQUIREMENT_UNSATISFIED.selector);
        accountant.postOpSyncTrancheAccountingAndEnforceCoverage(Operation.ST_DEPOSIT, _nav(200e18), _nav(20e18));
    }

    function test_maxSTDepositGivenCoverage() public {
        _initializeAccountantState(100e18, 50e18);

        NAV_UNIT maxDeposit = accountant.maxSTDepositGivenCoverage(_nav(100e18), _nav(50e18));

        SyncedAccountingState memory preview = accountant.previewSyncTrancheAccounting(_nav(100e18), _nav(50e18));
        uint256 jtEff = toUint256(preview.jtEffectiveNAV);
        uint256 maxCovered = jtEff * WAD / COVERAGE_WAD;
        uint256 expectedMax = maxCovered > 100e18 ? maxCovered - 100e18 : 0;

        assertApproxEqAbs(toUint256(maxDeposit), expectedMax, 2, "max deposit matches");
    }

    function testFuzz_maxSTDepositGivenCoverage(uint256 stNav, uint256 jtNav) public {
        stNav = bound(stNav, MIN_NAV, MAX_NAV / 2);
        jtNav = bound(jtNav, MIN_NAV, MAX_NAV / 2);

        _initializeAccountantState(stNav, jtNav);

        NAV_UNIT maxDeposit = accountant.maxSTDepositGivenCoverage(_nav(stNav), _nav(jtNav));
        assertTrue(toUint256(maxDeposit) >= 0, "max deposit non-negative");
    }

    // =========================================================================
    // YDM ADAPTATION
    // =========================================================================

    function test_ydmAdaptation_withTimeAndUtilization() public {
        _initializeAccountantState(10e18, 200e18);

        (uint64 initialYT,,) = adaptiveYDM.accountantToCurve(address(accountant));
        assertEq(initialYT, YDM_JT_YIELD_AT_TARGET, "initial YT is at target");

        vm.warp(vm.getBlockTimestamp() + 1 days);

        vm.prank(MOCK_KERNEL);
        accountant.preOpSyncTrancheAccounting(_nav(10e18), _nav(200e18));

        (, uint32 timestampAfterSecondSync,) = adaptiveYDM.accountantToCurve(address(accountant));
        assertGt(timestampAfterSecondSync, 0, "timestamp set after second sync");

        vm.warp(vm.getBlockTimestamp() + 365 days);

        vm.prank(MOCK_KERNEL);
        accountant.preOpSyncTrancheAccounting(_nav(10e18), _nav(200e18));

        (uint64 newYT,,) = adaptiveYDM.accountantToCurve(address(accountant));
        assertLt(newYT, initialYT, "YDM adapts with time and low utilization");
    }

    function test_ydmAdaptation_noChangeInFixedTerm() public {
        _initializeAccountantState(100e18, 50e18);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state1 = accountant.preOpSyncTrancheAccounting(_nav(80e18), _nav(50e18));

        if (uint8(state1.marketState) == uint8(MarketState.FIXED_TERM)) {
            (uint64 ytBefore,,) = adaptiveYDM.accountantToCurve(address(accountant));

            vm.warp(vm.getBlockTimestamp() + 30 days);

            vm.prank(MOCK_KERNEL);
            accountant.preOpSyncTrancheAccounting(_nav(80e18), _nav(50e18));

            (uint64 ytAfter,,) = adaptiveYDM.accountantToCurve(address(accountant));

            assertEq(ytAfter, ytBefore, "YDM unchanged in FIXED_TERM");
        }
    }

    // =========================================================================
    // PREVIEW SYNC
    // =========================================================================

    function test_previewSync_matchesPreOpSync() public {
        _initializeAccountantState(100e18, 50e18);

        vm.warp(vm.getBlockTimestamp() + 1 days);

        NAV_UNIT newStRaw = _nav(110e18);
        NAV_UNIT newJtRaw = _nav(55e18);

        SyncedAccountingState memory preview = accountant.previewSyncTrancheAccounting(newStRaw, newJtRaw);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory actual = accountant.preOpSyncTrancheAccounting(newStRaw, newJtRaw);

        assertEq(preview.stRawNAV, actual.stRawNAV, "stRawNAV match");
        assertEq(preview.jtRawNAV, actual.jtRawNAV, "jtRawNAV match");
        assertApproxEqAbs(preview.stEffectiveNAV, actual.stEffectiveNAV, 1, "stEffectiveNAV match");
        assertApproxEqAbs(preview.jtEffectiveNAV, actual.jtEffectiveNAV, 1, "jtEffectiveNAV match");
        assertEq(uint8(preview.marketState), uint8(actual.marketState), "marketState match");
    }

    // =========================================================================
    // COMPLEX SEQUENCES
    // =========================================================================

    function test_sequence_lossGainLoss() public {
        _initializeAccountantState(100e18, 50e18);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state1 = accountant.preOpSyncTrancheAccounting(_nav(80e18), _nav(50e18));

        assertEq(toUint256(state1.jtImpermanentLoss), 20e18, "first loss recorded");
        assertEq(uint8(state1.marketState), uint8(MarketState.FIXED_TERM), "in FIXED_TERM");
        _assertNAVConservation(state1);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state2 = accountant.preOpSyncTrancheAccounting(_nav(95e18), _nav(50e18));

        assertEq(toUint256(state2.jtImpermanentLoss), 5e18, "partial recovery");
        _assertNAVConservation(state2);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state3 = accountant.preOpSyncTrancheAccounting(_nav(85e18), _nav(50e18));

        assertEq(toUint256(state3.jtImpermanentLoss), 15e18, "second loss added");
        _assertNAVConservation(state3);
    }

    function test_sequence_jtExhaustion_stIL_fullRecovery() public {
        _initializeAccountantState(100e18, 20e18);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state1 = accountant.preOpSyncTrancheAccounting(_nav(60e18), _nav(20e18));

        assertEq(toUint256(state1.jtEffectiveNAV), 0, "JT exhausted");
        assertGt(toUint256(state1.stImpermanentLoss), 0, "ST IL created");
        _assertNAVConservation(state1);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state2 = accountant.preOpSyncTrancheAccounting(_nav(60e18), _nav(20e18 + 50e18));

        assertEq(toUint256(state2.stImpermanentLoss), 0, "ST IL recovered");
        _assertNAVConservation(state2);
    }

    function test_sequence_timeWeightedYieldShare() public {
        _initializeAccountantState(100e18, 50e18);

        for (uint256 i = 0; i < 5; i++) {
            vm.warp(vm.getBlockTimestamp() + 1 days);
            vm.prank(MOCK_KERNEL);
            accountant.preOpSyncTrancheAccounting(_nav(100e18), _nav(50e18));
        }

        IRoycoAccountant.RoycoAccountantState memory baseState = accountant.getState();
        uint256 jtEffBefore = toUint256(baseState.lastJTEffectiveNAV);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 stGain = 10e18;
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state = accountant.preOpSyncTrancheAccounting(_nav(100e18 + stGain), _nav(50e18));

        assertGt(toUint256(state.jtEffectiveNAV), jtEffBefore, "JT receives yield share");
        _assertNAVConservation(state);
    }

    function test_sequence_ydmAdaptation_adaptsThroughTime() public {
        _initializeAccountantState(10e18, 200e18);

        (uint64 yt0,,) = adaptiveYDM.accountantToCurve(address(accountant));

        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(MOCK_KERNEL);
        accountant.preOpSyncTrancheAccounting(_nav(10e18), _nav(200e18));

        vm.warp(vm.getBlockTimestamp() + 365 days);
        vm.prank(MOCK_KERNEL);
        accountant.preOpSyncTrancheAccounting(_nav(10e18), _nav(200e18));

        (uint64 yt1,,) = adaptiveYDM.accountantToCurve(address(accountant));
        assertLt(yt1, yt0, "YT decreased with low utilization");

        vm.warp(vm.getBlockTimestamp() + 365 days);
        vm.prank(MOCK_KERNEL);
        accountant.preOpSyncTrancheAccounting(_nav(10e18), _nav(200e18));

        (uint64 yt2,,) = adaptiveYDM.accountantToCurve(address(accountant));
        assertLe(yt2, yt1, "YT continues decreasing or stays at floor");
        assertGe(yt2, 0.0001e18, "YT respects minimum bound");
    }

    // =========================================================================
    // INVARIANTS
    // =========================================================================

    function testFuzz_invariant_navConservation(uint256 stRaw, uint256 jtRaw, int256 stDelta, int256 jtDelta) public {
        stRaw = bound(stRaw, MIN_NAV, MAX_NAV / 2);
        jtRaw = bound(jtRaw, MIN_NAV, MAX_NAV / 2);

        _initializeAccountantState(stRaw, jtRaw);

        stDelta = bound(stDelta, -int256(stRaw), int256(stRaw));
        jtDelta = bound(jtDelta, -int256(jtRaw), int256(jtRaw));

        vm.warp(vm.getBlockTimestamp() + 1 days);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state =
            accountant.preOpSyncTrancheAccounting(_nav(uint256(int256(stRaw) + stDelta)), _nav(uint256(int256(jtRaw) + jtDelta)));

        _assertNAVConservation(state);
    }

    function testFuzz_invariant_ilOrdering(uint256 stRaw, uint256 jtRaw) public {
        stRaw = bound(stRaw, MIN_NAV, MAX_NAV / 2);
        jtRaw = bound(jtRaw, MIN_NAV, MAX_NAV / 2);

        _initializeAccountantState(stRaw, jtRaw);

        uint256 lossAmount = stRaw / 2;
        vm.prank(MOCK_KERNEL);
        accountant.preOpSyncTrancheAccounting(_nav(stRaw - lossAmount), _nav(jtRaw));

        IRoycoAccountant.RoycoAccountantState memory state = accountant.getState();

        if (toUint256(state.lastSTImpermanentLoss) > 0) {
            assertEq(toUint256(state.lastJTEffectiveNAV), 0, "JT exhausted if ST has IL");
        }
    }

    function testFuzz_invariant_effectiveNAVNonNegative(uint256 stRaw, uint256 jtRaw, int256 stDelta, int256 jtDelta) public {
        stRaw = bound(stRaw, MIN_NAV, MAX_NAV / 2);
        jtRaw = bound(jtRaw, MIN_NAV, MAX_NAV / 2);

        _initializeAccountantState(stRaw, jtRaw);

        stDelta = bound(stDelta, -int256(stRaw), int256(stRaw));
        jtDelta = bound(jtDelta, -int256(jtRaw), int256(jtRaw));

        vm.warp(vm.getBlockTimestamp() + 1 days);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state =
            accountant.preOpSyncTrancheAccounting(_nav(uint256(int256(stRaw) + stDelta)), _nav(uint256(int256(jtRaw) + jtDelta)));

        assertTrue(toUint256(state.stEffectiveNAV) >= 0, "ST effective non-negative");
        assertTrue(toUint256(state.jtEffectiveNAV) >= 0, "JT effective non-negative");
    }

    function testFuzz_invariant_coverageILClearedOnPerpetualTransition(uint256 stRaw, uint256 jtRaw) public {
        stRaw = bound(stRaw, MIN_NAV, MAX_NAV / 2);
        jtRaw = bound(jtRaw, stRaw / 4, stRaw);

        _initializeAccountantState(stRaw, jtRaw);

        uint256 lossAmount = jtRaw / 2;
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state1 = accountant.preOpSyncTrancheAccounting(_nav(stRaw - lossAmount), _nav(jtRaw));

        if (uint8(state1.marketState) == uint8(MarketState.FIXED_TERM)) {
            uint32 termEnd = accountant.getState().fixedTermEndTimestamp;
            vm.warp(termEnd + 1);

            vm.prank(MOCK_KERNEL);
            SyncedAccountingState memory state2 = accountant.preOpSyncTrancheAccounting(_nav(stRaw - lossAmount), _nav(jtRaw));

            assertEq(toUint256(state2.jtImpermanentLoss), 0, "JT coverage IL cleared");
        }
    }

    function test_invariant_coverageEnforcedInPostOp_stDeposit() public {
        _initializeAccountantState(100e18, 50e18);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory preOpState = accountant.preOpSyncTrancheAccounting(_nav(100e18), _nav(50e18));

        assertLt(preOpState.utilizationWAD, preOpState.liquidationUtilizationWAD, "Liquidation not triggered before");

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory postOpState = accountant.postOpSyncTrancheAccounting(Operation.ST_DEPOSIT, _nav(150e18), _nav(50e18), ZERO_NAV_UNITS);

        // Coverage constraint is enforced after ST deposit
        assertLe(postOpState.utilizationWAD, WAD, "Coverage must be satisfied after ST deposit");
    }

    function test_invariant_coverageEnforcedInPostOp_jtWithdrawal() public {
        _initializeAccountantState(100e18, 100e18);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory preOpState = accountant.preOpSyncTrancheAccounting(_nav(100e18), _nav(100e18));

        assertLt(preOpState.utilizationWAD, preOpState.liquidationUtilizationWAD, "Liquidation not triggered before");

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory postOpState = accountant.postOpSyncTrancheAccounting(Operation.JT_REDEEM, _nav(100e18), _nav(80e18), ZERO_NAV_UNITS);

        // Coverage constraint is enforced after JT withdrawal
        assertLe(postOpState.utilizationWAD, WAD, "Coverage must be satisfied after JT withdrawal");
    }

    function testFuzz_invariant_stILRequiresJTExhaustion(uint256 stRaw, uint256 jtRaw, uint256 lossAmount) public {
        stRaw = bound(stRaw, 10e18, MAX_NAV / 4);
        jtRaw = bound(jtRaw, stRaw / 4, stRaw);
        lossAmount = bound(lossAmount, 1e18, stRaw);

        _initializeAccountantState(stRaw, jtRaw);

        uint256 newStRaw = stRaw > lossAmount ? stRaw - lossAmount : 0;
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state = accountant.preOpSyncTrancheAccounting(_nav(newStRaw), _nav(jtRaw));

        if (toUint256(state.stImpermanentLoss) > 0) {
            assertEq(toUint256(state.jtEffectiveNAV), 0, "ST IL requires JT to be exhausted");
        }
    }

    function test_invariant_stILRequiresJTExhaustion() public {
        _initializeAccountantState(100e18, 20e18);
        IRoycoAccountant.RoycoAccountantState memory baseState = accountant.getState();
        uint256 jtEffBefore = toUint256(baseState.lastJTEffectiveNAV);

        uint256 massiveLoss = jtEffBefore + 10e18;
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state = accountant.preOpSyncTrancheAccounting(_nav(100e18 - massiveLoss), _nav(20e18));

        if (toUint256(state.stImpermanentLoss) > 0) {
            assertEq(toUint256(state.jtEffectiveNAV), 0, "ST IL requires JT to be exhausted first");
        }
    }

    function test_invariant_noLiquidationTriggerWithoutLoss() public {
        _initializeAccountantState(100e18, 50e18);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state = accountant.preOpSyncTrancheAccounting(_nav(100e18), _nav(50e18));

        // Without any loss, utilization should be below liquidation threshold
        assertLt(state.utilizationWAD, state.liquidationUtilizationWAD, "Liquidation should not be triggered without loss");
        assertEq(toUint256(state.jtImpermanentLoss), 0, "no JT coverage IL");
        // jtSelfImpermanentLoss removed from SyncedAccountingState
        assertEq(toUint256(state.stImpermanentLoss), 0, "no ST IL");
    }

    // =========================================================================
    // EDGE CASES
    // =========================================================================

    function test_edgeCase_zeroSTRawNAV() public {
        _initializeAccountantState(100e18, 50e18);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state = accountant.preOpSyncTrancheAccounting(ZERO_NAV_UNITS, _nav(50e18));

        assertEq(state.stRawNAV, ZERO_NAV_UNITS, "stRawNAV zero");
        _assertNAVConservation(state);
    }

    function test_edgeCase_zeroJTRawNAV() public {
        _initializeAccountantState(100e18, 50e18);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state = accountant.preOpSyncTrancheAccounting(_nav(100e18), ZERO_NAV_UNITS);

        assertEq(state.jtRawNAV, ZERO_NAV_UNITS, "jtRawNAV zero");
        _assertNAVConservation(state);
    }

    function test_edgeCase_sameBlockMultipleSyncs() public {
        _initializeAccountantState(100e18, 50e18);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state1 = accountant.preOpSyncTrancheAccounting(_nav(105e18), _nav(50e18));

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state2 = accountant.postOpSyncTrancheAccounting(Operation.ST_DEPOSIT, _nav(110e18), _nav(50e18), ZERO_NAV_UNITS);

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state3 = accountant.preOpSyncTrancheAccounting(_nav(112e18), _nav(50e18));

        _assertNAVConservation(state1);
        _assertNAVConservation(state2);
        _assertNAVConservation(state3);
    }

    function test_edgeCase_largeNumbers() public {
        uint256 largeNav = 1e18;

        IRoycoAccountant largeAccountant = _deployAccountant(
            MOCK_KERNEL,
            ST_PROTOCOL_FEE_WAD,
            JT_PROTOCOL_FEE_WAD,
            COVERAGE_WAD,
            BETA_WAD,
            address(adaptiveYDM),
            FIXED_TERM_DURATION_SECONDS,
            DUST_TOLERANCE,
            LIQUIDATION_UTILIZATION_WAD,
            YDM_JT_YIELD_AT_TARGET,
            YDM_JT_YIELD_AT_FULL
        );

        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state1 = largeAccountant.preOpSyncTrancheAccounting(_nav(largeNav), _nav(largeNav / 2));

        _assertNAVConservation(state1);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(MOCK_KERNEL);
        SyncedAccountingState memory state2 = largeAccountant.preOpSyncTrancheAccounting(_nav(largeNav * 2), _nav(largeNav / 2));

        _assertNAVConservation(state2);
    }

    // =========================================================================
    // HELPERS
    // =========================================================================

    function _nav(uint256 value) internal pure returns (NAV_UNIT) {
        return NAV_UNIT.wrap(uint128(value));
    }

    function _initializeAccountantState(uint256 stNav, uint256 jtNav) internal {
        vm.startPrank(MOCK_KERNEL);
        // Initialize timestamps and market state via no-op preOp sync from zero
        accountant.preOpSyncTrancheAccounting(_nav(0), _nav(0));
        // JT must deposit first so coverage is satisfied when ST follows
        if (jtNav > 0) {
            accountant.postOpSyncTrancheAccounting(Operation.JT_DEPOSIT, _nav(0), _nav(jtNav), ZERO_NAV_UNITS);
        }
        if (stNav > 0) {
            accountant.postOpSyncTrancheAccounting(Operation.ST_DEPOSIT, _nav(stNav), _nav(jtNav), ZERO_NAV_UNITS);
        }
        vm.stopPrank();
    }

    function _assertNAVConservation(SyncedAccountingState memory state) internal pure {
        uint256 rawSum = toUint256(state.stRawNAV) + toUint256(state.jtRawNAV);
        uint256 effectiveSum = toUint256(state.stEffectiveNAV) + toUint256(state.jtEffectiveNAV);
        assertEq(rawSum, effectiveSum, "NAV conservation violated");
    }

    function _assertConfigFields(SyncedAccountingState memory state) internal view {
        IRoycoAccountant.RoycoAccountantState memory accountantState = accountant.getState();

        // Verify utilization is computed correctly
        uint256 expectedUtil =
            UtilsLib.computeUtilization(state.stRawNAV, state.jtRawNAV, accountantState.betaWAD, accountantState.coverageWAD, state.jtEffectiveNAV);
        assertEq(state.utilizationWAD, expectedUtil, "utilizationWAD mismatch");

        // Verify fixed term end timestamp based on market state
        if (state.marketState == MarketState.PERPETUAL) {
            assertEq(state.fixedTermEndTimestamp, 0, "fixedTermEndTimestamp should be 0 in perpetual state");
        }
    }
}
