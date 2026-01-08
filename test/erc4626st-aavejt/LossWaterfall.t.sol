// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Vm } from "../../lib/forge-std/src/Vm.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoAccountant } from "../../src/interfaces/IRoycoAccountant.sol";
import { IRoycoKernel } from "../../src/interfaces/kernel/IRoycoKernel.sol";
import { ERC_7540_CONTROLLER_DISCRIMINATED_REQUEST_ID, WAD, ZERO_TRANCHE_UNITS } from "../../src/libraries/Constants.sol";
import { AssetClaims, TrancheType } from "../../src/libraries/Types.sol";
import { SyncedAccountingState } from "../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../src/libraries/Units.sol";
import { UnitsMathLib } from "../../src/libraries/Units.sol";
import { MainnetForkWithAaveTestBase } from "./base/MainnetForkWithAaveBaseTest.t.sol";

contract LossWaterfall is MainnetForkWithAaveTestBase {
    using Math for uint256;
    using UnitsMathLib for TRANCHE_UNIT;
    using UnitsMathLib for NAV_UNIT;

    // Test State Trackers
    TrancheState internal stState;
    TrancheState internal jtState;

    function setUp() public {
        _setUpRoyco();
        _setUpTrancheRoles(providers, PAUSER_ADDRESS, UPGRADER_ADDRESS);
    }

    function testFuzz_jtLoss(uint256 _assets) external {
        // Bound assets to reasonable range (avoid zero and very large amounts)
        _assets = bound(_assets, 10e6, 1_000_000e6); // Between 1 USDC and 1M USDC (6 decimals)

        address depositor = ALICE_ADDRESS;

        // Approve the junior tranche to spend assets
        vm.prank(depositor);
        USDC.approve(address(JT), _assets);

        // Deposit into junior tranche
        vm.prank(depositor);
        (uint256 shares,) = JT.deposit(toTrancheUnits(_assets), depositor, depositor);
        AssetClaims memory postDepositUserClaims = JT.convertToAssets(shares);
        (SyncedAccountingState memory postDepositState, AssetClaims memory postDepositTotalClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Simulate a loss by transferring out A Tokens from the kernel
        uint256 lossAssets = bound(_assets, 1e6, _assets - 1);
        vm.prank(address(KERNEL));
        AUSDC.transfer(BOB_ADDRESS, lossAssets);
        AssetClaims memory postLossUserClaims = JT.convertToAssets(shares);
        (SyncedAccountingState memory postLossState, AssetClaims memory postLossTotalClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Assert that the accounting reflects the JT loss
        assertApproxEqRel(
            toUint256(postDepositTotalClaims.jtAssets - postLossTotalClaims.jtAssets),
            lossAssets,
            MAX_CONVERT_TO_ASSETS_RELATIVE_DELTA,
            "JT claims must reflect the loss"
        );
        assertApproxEqRel(
            toUint256(postDepositUserClaims.jtAssets - postLossUserClaims.jtAssets),
            lossAssets,
            MAX_CONVERT_TO_ASSETS_RELATIVE_DELTA,
            "JT LP claims must reflect the loss"
        );
        assertApproxEqRel(
            toUint256(postDepositState.jtRawNAV - postLossState.jtRawNAV), lossAssets, MAX_CONVERT_TO_ASSETS_RELATIVE_DELTA, "JT raw NAV must reflect the loss"
        );
        assertApproxEqRel(
            toUint256(postDepositState.jtEffectiveNAV - postLossState.jtEffectiveNAV),
            lossAssets,
            MAX_CONVERT_TO_ASSETS_RELATIVE_DELTA,
            "JT raw NAV must reflect the loss"
        );
    }

    function testFuzz_jtGain(uint256 _assets, uint256 _timeToTravel) external {
        // Bound assets to reasonable range (avoid zero and very large amounts)
        _assets = bound(_assets, 10e6, 1_000_000e6); // Between 1 USDC and 1M USDC (6 decimals)
        _timeToTravel = bound(_timeToTravel, 1 hours, 365 days);

        address depositor = ALICE_ADDRESS;

        // Approve the junior tranche to spend assets
        vm.prank(depositor);
        USDC.approve(address(JT), _assets);

        // Deposit into junior tranche
        vm.prank(depositor);
        (uint256 shares,) = JT.deposit(toTrancheUnits(_assets), depositor, depositor);
        AssetClaims memory postDepositUserClaims = JT.convertToAssets(shares);
        (SyncedAccountingState memory postDepositState, AssetClaims memory postDepositTotalClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Time travel
        skip(_timeToTravel);

        // Check the state after interest accrued
        AssetClaims memory postGainUserClaims = JT.convertToAssets(shares);
        (SyncedAccountingState memory postGainState, AssetClaims memory postGainTotalClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Assert that the accounting reflects the JT gain
        assertGt(toUint256(postGainState.jtProtocolFeeAccrued), 0, "Must accrue protocol fees on gain");
        assertGt(toUint256(postGainTotalClaims.jtAssets), toUint256(postDepositTotalClaims.jtAssets), "JT claims must reflect the gain");
        assertGt(toUint256(postGainUserClaims.jtAssets), toUint256(postDepositUserClaims.jtAssets), "JT LP claims must reflect the gain");
        assertGt(toUint256(postGainState.jtRawNAV), toUint256(postDepositState.jtRawNAV), "JT raw NAV must reflect the gain");
        assertGt(toUint256(postGainState.jtEffectiveNAV), toUint256(postDepositState.jtEffectiveNAV), "JT effective NAV must reflect the gain");
    }

    function testFuzz_stGain(uint256 _assets, uint256 _stDepositPercentage) external {
        // Bound assets to reasonable range (avoid zero and very large amounts)
        _assets = bound(_assets, 10e6, 1_000_000e6); // Between 1 USDC and 1M USDC (6 decimals)
        _stDepositPercentage = bound(_stDepositPercentage, 1, 90);

        // Deposit into junior tranche
        address depositor = ALICE_ADDRESS;
        vm.startPrank(depositor);
        USDC.approve(address(JT), _assets);
        JT.deposit(toTrancheUnits(_assets), depositor, depositor);
        vm.stopPrank();

        address stDepositor = BOB_ADDRESS;
        TRANCHE_UNIT expectedMaxDeposit = toTrancheUnits(toUint256(JT.totalAssets().nav).mulDiv(WAD, COVERAGE_WAD, Math.Rounding.Floor));
        // Deposit a percentage of the max deposit
        TRANCHE_UNIT depositAmount = expectedMaxDeposit.mulDiv(_stDepositPercentage, 100, Math.Rounding.Floor);
        vm.startPrank(stDepositor);
        USDC.approve(address(ST), toUint256(depositAmount));
        (uint256 shares,) = ST.deposit(depositAmount, stDepositor, stDepositor);
        vm.stopPrank();
        AssetClaims memory postDepositSTUserClaims = ST.convertToAssets(shares);
        (SyncedAccountingState memory postDepositState, AssetClaims memory postDepositSTTotalClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);
        (, AssetClaims memory postDepositJTTotalClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Raise the NAV of ST
        vm.startPrank(stDepositor);
        USDC.transfer(address(MOCK_UNDERLYING_ST_VAULT), 100e6);
        vm.stopPrank();

        skip(1 days);

        AssetClaims memory postGainSTUserClaims = ST.convertToAssets(shares);
        (SyncedAccountingState memory postGainState, AssetClaims memory postGainSTTotalClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);
        (, AssetClaims memory postGainJTTotalClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Assert that the accounting reflects the ST gain
        assertGt(toUint256(postGainState.jtProtocolFeeAccrued), 0, "Must accrue JT protocol fees on gain");
        assertGt(toUint256(postGainState.stProtocolFeeAccrued), 0, "Must accrue ST protocol fees on gain");

        assertGt(toUint256(postGainSTUserClaims.stAssets), toUint256(postDepositSTUserClaims.stAssets), "ST claims must reflect the gain");
        assertGt(toUint256(postGainSTTotalClaims.stAssets), toUint256(postDepositSTTotalClaims.stAssets), "ST LP claims must reflect the gain");
        assertGt(toUint256(postGainJTTotalClaims.stAssets), toUint256(postDepositJTTotalClaims.stAssets), "JT LP claims must reflect the gain");

        assertGt(toUint256(postGainState.jtRawNAV), toUint256(postDepositState.jtRawNAV), "JT raw NAV must reflect the gain");
        assertGt(toUint256(postGainState.jtEffectiveNAV), toUint256(postDepositState.jtEffectiveNAV), "JT effective NAV must reflect the gain");
        assertGt(toUint256(postGainState.stRawNAV), toUint256(postDepositState.stRawNAV), "ST raw NAV must reflect the gain");
        assertGt(toUint256(postGainState.stEffectiveNAV), toUint256(postDepositState.stEffectiveNAV), "ST effective NAV must reflect the gain");
    }

    function testFuzz_stLoss(uint256 _assets, uint256 _stDepositPercentage) external {
        // Bound assets to reasonable range (avoid zero and very large amounts)
        _assets = bound(_assets, 10e6, 1_000_000e6); // Between 1 USDC and 1M USDC (6 decimals)
        _stDepositPercentage = bound(_stDepositPercentage, 20, 90);

        // Deposit into junior tranche
        address depositor = ALICE_ADDRESS;
        vm.startPrank(depositor);
        USDC.approve(address(JT), _assets);
        JT.deposit(toTrancheUnits(_assets), depositor, depositor);
        vm.stopPrank();

        address stDepositor = BOB_ADDRESS;
        TRANCHE_UNIT expectedMaxDeposit = toTrancheUnits(toUint256(JT.totalAssets().nav).mulDiv(WAD, COVERAGE_WAD, Math.Rounding.Floor));
        // Deposit a percentage of the max deposit
        TRANCHE_UNIT depositAmount = expectedMaxDeposit.mulDiv(_stDepositPercentage, 100, Math.Rounding.Floor);
        vm.startPrank(stDepositor);
        USDC.approve(address(ST), toUint256(depositAmount));
        (uint256 shares,) = ST.deposit(depositAmount, stDepositor, stDepositor);
        vm.stopPrank();
        AssetClaims memory postDepositSTUserClaims = ST.convertToAssets(shares);
        (SyncedAccountingState memory postDepositState, AssetClaims memory postDepositSTTotalClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);
        (, AssetClaims memory postDepositJTTotalClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Lower the NAV of ST
        vm.startPrank(address(MOCK_UNDERLYING_ST_VAULT));
        USDC.transfer(BOB_ADDRESS, bound(toUint256(depositAmount), 1e6, toUint256(depositAmount)));
        vm.stopPrank();

        AssetClaims memory postLossSTUserClaims = ST.convertToAssets(shares);
        (SyncedAccountingState memory postLossState, AssetClaims memory postLossSTTotalClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);
        (, AssetClaims memory postLossJTTotalClaims,) = KERNEL.previewSyncTrancheAccounting(TrancheType.JUNIOR);

        // Assert that the accounting reflects the ST gain
        assertEq(toUint256(postLossState.jtProtocolFeeAccrued), 0, "Must accrue JT protocol fees on gain");
        assertEq(toUint256(postLossState.stProtocolFeeAccrued), 0, "Must accrue ST protocol fees on gain");

        assertGt(toUint256(postLossSTUserClaims.jtAssets), toUint256(postDepositSTUserClaims.jtAssets), "ST claims must reflect the gain");
        assertLt(toUint256(postLossSTUserClaims.stAssets), toUint256(postDepositSTUserClaims.stAssets), "ST claims must reflect the gain");
        assertLt(toUint256(postLossSTTotalClaims.stAssets), toUint256(postDepositSTTotalClaims.stAssets), "ST LP claims must reflect the gain");
        assertLt(toUint256(postLossJTTotalClaims.jtAssets), toUint256(postDepositJTTotalClaims.jtAssets), "JT LP claims must reflect the gain");

        assertGt(toUint256(postLossState.jtImpermanentLoss), toUint256(postDepositState.jtImpermanentLoss), "JT raw NAV must reflect the gain");
        assertGe(toUint256(postLossState.stImpermanentLoss), toUint256(postDepositState.stImpermanentLoss), "JT raw NAV must reflect the gain");
        assertLt(toUint256(postLossState.jtEffectiveNAV), toUint256(postDepositState.jtEffectiveNAV), "JT raw NAV must reflect the gain");
        assertLe(toUint256(postLossState.stEffectiveNAV), toUint256(postDepositState.stEffectiveNAV), "JT raw NAV must reflect the gain");
    }
}
