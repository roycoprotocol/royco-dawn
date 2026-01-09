// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Vm } from "../../lib/forge-std/src/Vm.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IRoycoAccountant } from "../../src/interfaces/IRoycoAccountant.sol";
import { IRoycoKernel } from "../../src/interfaces/kernel/IRoycoKernel.sol";
import { ERC_7540_CONTROLLER_DISCRIMINATED_REQUEST_ID, WAD, ZERO_TRANCHE_UNITS } from "../../src/libraries/Constants.sol";
import { AssetClaims, TrancheType } from "../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../src/libraries/Units.sol";
import { UnitsMathLib } from "../../src/libraries/Units.sol";
import { MainnetForkWithAaveTestBase } from "./base/MainnetForkWithAaveBaseTest.t.sol";

contract BasicOperationsTest is MainnetForkWithAaveTestBase {
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

    function testFuzz_depositIntoJT(uint256 _assets) external {
        // Bound assets to reasonable range (avoid zero and very large amounts)
        _assets = bound(_assets, 1e6, 1_000_000e6); // Between 1 USDC and 1M USDC (6 decimals)
        TRANCHE_UNIT assets = toTrancheUnits(_assets);

        address depositor = ALICE_ADDRESS;

        // Get initial balances
        uint256 initialDepositorBalance = USDC.balanceOf(depositor);
        uint256 initialTrancheShares = JT.balanceOf(depositor);

        // Assert that initially all tranche parameters are 0
        _verifyPreviewNAVs(stState, jtState, AAVE_MAX_ABS_TRANCH_UNIT_DELTA, AAVE_MAX_ABS_NAV_DELTA);
        _verifyFeeTaken(stState, jtState, PROTOCOL_FEE_RECIPIENT_ADDRESS);

        // Fetch the max deposit for the junior tranche
        TRANCHE_UNIT maxDeposit = JT.maxDeposit(depositor);
        assertGt(maxDeposit, toTrancheUnits(0), "Max deposit should be greater than 0");

        // Preview the deposit
        uint256 expectedShares = JT.previewDeposit(assets);

        // Approve the junior tranche to spend assets
        vm.prank(depositor);
        USDC.approve(address(JT), _assets);

        // Deposit into junior tranche
        vm.prank(depositor);
        (uint256 shares,) = JT.deposit(assets, depositor, depositor);
        assertApproxEqRel(shares, expectedShares, AAVE_PREVIEW_DEPOSIT_RELATIVE_DELTA, "Shares minted should be equal to the previewed shares");
        _updateOnDeposit(jtState, assets, _toJTValue(assets), shares, TrancheType.JUNIOR);

        // Verify shares were minted
        assertGt(shares, 0, "Shares should be greater than 0");
        assertEq(JT.balanceOf(depositor), initialTrancheShares + shares, "Depositor should receive shares");

        // Verify that maxRedeemable shares returns the correct amount
        uint256 maxRedeemableShares = JT.maxRedeem(depositor);
        assertApproxEqRel(maxRedeemableShares, shares, MAX_REDEEM_RELATIVE_DELTA, "Max redeemable shares should return the correct amount");
        assertTrue(maxRedeemableShares <= shares, "Max redeemable shares should be less than or equal to shares");

        // Verify that convertToAssets returns the correct amount
        TRANCHE_UNIT convertedAssets = JT.convertToAssets(shares).jtAssets;
        assertApproxEqRel(convertedAssets, assets, MAX_CONVERT_TO_ASSETS_RELATIVE_DELTA, "Convert to assets should return the correct amount");

        // We do not test previewRedeem here because it is expected to revert in async mode

        // Verify assets were transferred
        assertEq(USDC.balanceOf(depositor), initialDepositorBalance - _assets, "Depositor balance should decrease by assets amount");

        // Verify that an equivalent amount of AUSDCs were minted
        assertApproxEqAbs(
            AUSDC.balanceOf(address(KERNEL)), _assets, toUint256(AAVE_MAX_ABS_TRANCH_UNIT_DELTA), "An equivalent amount of AUSDCs should be minted"
        );

        // Verify that the tranche state has been updated
        _verifyPreviewNAVs(stState, jtState, AAVE_MAX_ABS_TRANCH_UNIT_DELTA, AAVE_MAX_ABS_NAV_DELTA);
        _verifyFeeTaken(stState, jtState, PROTOCOL_FEE_RECIPIENT_ADDRESS);
    }

    function testFuzz_multipleDepositsIntoJT(uint256 _numDepositors, uint256 _amountSeed) external {
        // Bound the number of depositors to a reasonable range (avoid zero and very large numbers)
        _numDepositors = bound(_numDepositors, 1, 10);

        // Assert that initially all tranche parameters are 0
        _verifyPreviewNAVs(stState, jtState, AAVE_MAX_ABS_TRANCH_UNIT_DELTA, AAVE_MAX_ABS_NAV_DELTA);
        _verifyFeeTaken(stState, jtState, PROTOCOL_FEE_RECIPIENT_ADDRESS);

        for (uint256 i = 0; i < _numDepositors; i++) {
            // Generate a provider
            Vm.Wallet memory provider = _generateProvider(i);

            // Generate a random amount
            uint256 amount = bound(uint256(keccak256(abi.encodePacked(_amountSeed, i))), 1e6, 1_000_000e6);
            TRANCHE_UNIT assets = toTrancheUnits(amount);

            // Get initial balances
            uint256 initialDepositorBalance = USDC.balanceOf(provider.addr);
            uint256 initialTrancheShares = JT.balanceOf(provider.addr);
            uint256 initialATokenBalance = AUSDC.balanceOf(address(KERNEL));

            // Preview the deposit
            uint256 expectedShares = JT.previewDeposit(assets);

            // Approve the tranche to spend assets
            vm.prank(provider.addr);
            USDC.approve(address(JT), amount);

            // Deposit into the tranche
            vm.prank(provider.addr);
            (uint256 shares,) = JT.deposit(assets, provider.addr, provider.addr);
            assertApproxEqRel(shares, expectedShares, AAVE_PREVIEW_DEPOSIT_RELATIVE_DELTA, "Shares minted should be equal to the previewed shares");

            // Verify that an equivalent amount of AUSDCs were minted
            assertApproxEqAbs(
                AUSDC.balanceOf(address(KERNEL)),
                amount + initialATokenBalance,
                toUint256(AAVE_MAX_ABS_TRANCH_UNIT_DELTA),
                "An equivalent amount of AUSDCs should be minted"
            );

            uint256 aTokensMinted = AUSDC.balanceOf(address(KERNEL)) - initialATokenBalance;
            _updateOnDeposit(jtState, toTrancheUnits(aTokensMinted), _toJTValue(toTrancheUnits(aTokensMinted)), shares, TrancheType.JUNIOR);

            // Verify that shares were minted
            assertEq(JT.balanceOf(provider.addr), initialTrancheShares + shares, "Provider should receive shares");

            // Verify that maxRedeemable shares returns the correct amount
            uint256 maxRedeemableShares = JT.maxRedeem(provider.addr);
            assertApproxEqRel(maxRedeemableShares, shares, MAX_REDEEM_RELATIVE_DELTA, "Max redeemable shares should return the correct amount");
            assertTrue(maxRedeemableShares <= shares, "Max redeemable shares should be less than or equal to shares");

            // Verify that convertToAssets returns the correct amount
            TRANCHE_UNIT convertedAssets = JT.convertToAssets(shares).jtAssets;
            assertApproxEqRel(convertedAssets, assets, MAX_CONVERT_TO_ASSETS_RELATIVE_DELTA, "Convert to assets should return the correct amount");
            assertTrue(convertedAssets <= assets, "Convert to assets should be less than or equal to amount");

            // Verify that assets were transferred
            assertEq(USDC.balanceOf(provider.addr), initialDepositorBalance - amount, "Provider balance should decrease by amount");

            // Verify that the tranche state has been updated
            _verifyPreviewNAVs(stState, jtState, AAVE_MAX_ABS_TRANCH_UNIT_DELTA, AAVE_MAX_ABS_NAV_DELTA);
            _verifyFeeTaken(stState, jtState, PROTOCOL_FEE_RECIPIENT_ADDRESS);
        }
    }

    function testFuzz_depositIntoST_verifyCoverageRequirementEnforcement(uint256 _jtAssets, uint256 _stDepositPercentage) external {
        // Bound assets to reasonable range (avoid zero and very large amounts)
        _jtAssets = bound(_jtAssets, 1e6, 1_000_000e6); // Between 1 USDC and 1M USDC (6 decimals)
        _stDepositPercentage = bound(_stDepositPercentage, 1, 99);
        TRANCHE_UNIT jtAssets = toTrancheUnits(_jtAssets);

        // There are no assets in JT initally, therefore depositing into ST should fail
        address stDepositor = BOB_ADDRESS;
        TRANCHE_UNIT stDepositAmount = toTrancheUnits(1);

        vm.startPrank(stDepositor);
        USDC.approve(address(ST), toUint256(stDepositAmount));
        vm.expectRevert(abi.encodeWithSelector(IRoycoAccountant.COVERAGE_REQUIREMENT_UNSATISFIED.selector));
        ST.deposit(stDepositAmount, stDepositor, stDepositor);
        vm.stopPrank();

        // Deposit assets into the junior tranche to allow deposits into the ST
        address jtDepositor = ALICE_ADDRESS;
        vm.startPrank(jtDepositor);
        USDC.approve(address(JT), _jtAssets);
        (uint256 shares,) = JT.deposit(jtAssets, jtDepositor, jtDepositor);
        vm.stopPrank();

        _updateOnDeposit(jtState, jtAssets, _toJTValue(jtAssets), shares, TrancheType.JUNIOR);
        _verifyPreviewNAVs(stState, jtState, AAVE_MAX_ABS_TRANCH_UNIT_DELTA, AAVE_MAX_ABS_NAV_DELTA);

        // Verify that ST.maxDeposit returns JTEff / coverage
        // BETA is 0
        TRANCHE_UNIT expectedMaxDeposit = toTrancheUnits(toUint256(JT.totalAssets().nav).mulDiv(WAD, COVERAGE_WAD, Math.Rounding.Floor));
        {
            TRANCHE_UNIT maxDeposit = ST.maxDeposit(jtDepositor);
            assertEq(maxDeposit, expectedMaxDeposit, "Max deposit should return JTEff * coverage");
        }

        // Try to deposit more than the max deposit, it should revert
        TRANCHE_UNIT depositAmount = expectedMaxDeposit + toTrancheUnits(1);
        vm.startPrank(stDepositor);
        USDC.approve(address(ST), toUint256(depositAmount));
        vm.expectRevert(abi.encodeWithSelector(IRoycoAccountant.COVERAGE_REQUIREMENT_UNSATISFIED.selector));
        ST.deposit(depositAmount, stDepositor, stDepositor);
        vm.stopPrank();

        //////////////////////////////////////////////////////
        /// Deposit a percentage of the max deposit into ST
        //////////////////////////////////////////////////////

        // Deposit a percentage of the max deposit
        depositAmount = expectedMaxDeposit.mulDiv(_stDepositPercentage, 100, Math.Rounding.Floor);

        // Preview the deposit
        uint256 expectedSharesMinted = ST.previewDeposit(depositAmount);
        assertTrue(expectedSharesMinted > 0, "Expected shares minted should be greater than 0");

        // Perform the deposit
        vm.startPrank(stDepositor);
        USDC.approve(address(ST), toUint256(depositAmount));
        (shares,) = ST.deposit(depositAmount, stDepositor, stDepositor);
        vm.stopPrank();

        // Assert that ST shares were minted to the user
        assertGt(shares, 0, "Shares should be greater than 0");
        assertEq(ST.balanceOf(stDepositor), shares, "User should receive shares");

        // Verify that the shares minted are equal to the previewed shares
        assertEq(shares, expectedSharesMinted, "Shares minted should be equal to the previewed shares");

        // Update the tranche state
        _updateOnDeposit(stState, depositAmount, _toSTValue(depositAmount), shares, TrancheType.SENIOR);

        // Verify that the tranche state has been updated
        _verifyPreviewNAVs(stState, jtState, AAVE_MAX_ABS_TRANCH_UNIT_DELTA, AAVE_MAX_ABS_NAV_DELTA);
        _verifyFeeTaken(stState, jtState, PROTOCOL_FEE_RECIPIENT_ADDRESS);

        // Verify that the amount was transferred to the underlying vault
        assertEq(USDC.balanceOf(address(MOCK_UNDERLYING_ST_VAULT)), toUint256(depositAmount), "Amount should be transferred to the underlying vault");

        // Verify that underlying shares were minted to the kernel
        assertEq(MOCK_UNDERLYING_ST_VAULT.balanceOf(address(KERNEL)), toUint256(depositAmount), "Underlying shares should be minted to the kernel");

        // Verify that ST.maxDeposit went down
        assertEq(ST.maxDeposit(stDepositor), expectedMaxDeposit - depositAmount, "Max deposit should go down expected amount");

        // Verify that JT.maxRedeem went down
        assertApproxEqRel(
            JT.maxRedeem(jtDepositor),
            JT.totalSupply() * (100 - _stDepositPercentage) / 100,
            MAX_REDEEM_RELATIVE_DELTA,
            "Max redeem should go down expected amount"
        );
        {

            // Verify that ST.convertToAssets returns the correct amount
            AssetClaims memory convertToAssetsResult = ST.convertToAssets(shares);
            assertApproxEqAbs(
                convertToAssetsResult.stAssets, depositAmount, AAVE_MAX_ABS_TRANCH_UNIT_DELTA, "Convert to assets should return the correct amount"
            );
            assertEq(convertToAssetsResult.jtAssets, ZERO_TRANCHE_UNITS, "Convert to assets should return 0 JT assets");
            assertApproxEqAbs(convertToAssetsResult.nav, _toSTValue(depositAmount), AAVE_MAX_ABS_NAV_DELTA, "Convert to assets should return the correct NAV");

            // Verify that ST.previewRedeem returns the correct amount
            AssetClaims memory previewRedeemResult = ST.previewRedeem(shares);
            assertApproxEqAbs(previewRedeemResult.stAssets, depositAmount, AAVE_MAX_ABS_TRANCH_UNIT_DELTA, "Preview redeem should return the correct amount");
            assertEq(previewRedeemResult.jtAssets, ZERO_TRANCHE_UNITS, "Preview redeem should return 0 JT assets");
            assertApproxEqAbs(previewRedeemResult.nav, _toSTValue(depositAmount), AAVE_MAX_ABS_NAV_DELTA, "Preview redeem should return the correct NAV");

            // Verify that ST.maxRedeem returns the correct amount
            uint256 maxRedeem = ST.maxRedeem(stDepositor);
            assertEq(maxRedeem, shares, "Max redeem should return the correct amount");
        }

        ////////////////////////////////////////////////////////////////////
        /// Deposit rest of the deposit into ST, driving utilization to 100%
        ////////////////////////////////////////////////////////////////////

        // Preview the deposit
        depositAmount = expectedMaxDeposit - depositAmount;
        expectedSharesMinted = ST.previewDeposit(depositAmount);
        assertTrue(expectedSharesMinted > 0, "Expected shares minted should be greater than 0");

        uint256 stDepositorSharesBeforeDeposit = ST.balanceOf(stDepositor);
        uint256 underlyingVaultSharesBalanceOfKernelBeforeDeposit = MOCK_UNDERLYING_ST_VAULT.balanceOf(address(KERNEL));
        uint256 usdcBalanceOfMockUnderlyingVaultBeforeDeposit = USDC.balanceOf(address(MOCK_UNDERLYING_ST_VAULT));

        // Perform the deposit
        vm.startPrank(stDepositor);
        USDC.approve(address(ST), toUint256(depositAmount));
        (shares,) = ST.deposit(depositAmount, stDepositor, stDepositor);
        vm.stopPrank();

        // Assert that ST shares were minted to the user
        assertGt(shares, 0, "Shares should be greater than 0");
        assertEq(ST.balanceOf(stDepositor), stDepositorSharesBeforeDeposit + shares, "User should receive shares");

        // Verify that the shares minted are equal to the previewed shares
        assertEq(shares, expectedSharesMinted, "Shares minted should be equal to the previewed shares");

        // Update the tranche state
        _updateOnDeposit(stState, depositAmount, _toSTValue(depositAmount), shares, TrancheType.SENIOR);

        // Verify that the tranche state has been updated
        _verifyPreviewNAVs(stState, jtState, AAVE_MAX_ABS_TRANCH_UNIT_DELTA, AAVE_MAX_ABS_NAV_DELTA);
        _verifyFeeTaken(stState, jtState, PROTOCOL_FEE_RECIPIENT_ADDRESS);

        // Verify that the amount was transferred to the underlying vault
        assertEq(
            USDC.balanceOf(address(MOCK_UNDERLYING_ST_VAULT)),
            toUint256(depositAmount) + usdcBalanceOfMockUnderlyingVaultBeforeDeposit,
            "Amount should be transferred to the underlying vault"
        );

        // Verify that underlying shares were minted to the kernel
        assertEq(
            MOCK_UNDERLYING_ST_VAULT.balanceOf(address(KERNEL)),
            toUint256(depositAmount) + underlyingVaultSharesBalanceOfKernelBeforeDeposit,
            "Underlying shares should be minted to the kernel"
        );

        // Verify that ST.maxDeposit went down to 0
        assertEq(ST.maxDeposit(stDepositor), ZERO_TRANCHE_UNITS, "Max deposit should go down to 0");

        // Verify that JT.maxRedeem went down to 0
        assertEq(JT.maxRedeem(jtDepositor), 0, "Max redeem should go down to 0");

        // Verify that ST.convertToAssets returns the correct amount
        AssetClaims memory convertToAssetsResult = ST.convertToAssets(shares + stDepositorSharesBeforeDeposit);
        assertApproxEqAbs(
            convertToAssetsResult.stAssets, expectedMaxDeposit, AAVE_MAX_ABS_TRANCH_UNIT_DELTA, "Convert to assets should return the correct amount"
        );
        assertEq(convertToAssetsResult.jtAssets, ZERO_TRANCHE_UNITS, "Convert to assets should return 0 JT assets");
        assertApproxEqAbs(convertToAssetsResult.nav, _toSTValue(expectedMaxDeposit), AAVE_MAX_ABS_NAV_DELTA, "Convert to assets should return the correct NAV");

        // Verify that ST.previewRedeem returns the correct amount
        AssetClaims memory previewRedeemResult = ST.previewRedeem(shares + stDepositorSharesBeforeDeposit);
        assertApproxEqAbs(previewRedeemResult.stAssets, expectedMaxDeposit, AAVE_MAX_ABS_TRANCH_UNIT_DELTA, "Preview redeem should return the correct amount");
        assertEq(previewRedeemResult.jtAssets, ZERO_TRANCHE_UNITS, "Preview redeem should return 0 JT assets");
        assertApproxEqAbs(previewRedeemResult.nav, _toSTValue(expectedMaxDeposit), AAVE_MAX_ABS_NAV_DELTA, "Preview redeem should return the correct NAV");

        // Verify that ST.maxRedeem returns the correct amount
        uint256 maxRedeem = ST.maxRedeem(stDepositor);
        assertEq(maxRedeem, shares + stDepositorSharesBeforeDeposit, "Max redeem should return the correct amount");
    }

    function testFuzz_jtDeposit_and_consecutive_jtWithdrawals(uint256 _jtAssets, uint256 _totalWithdrawalRequests) external {
        // Bound assets to reasonable range (avoid zero and very large amounts)
        _totalWithdrawalRequests = bound(_totalWithdrawalRequests, 1, 10);
        _jtAssets = bound(_jtAssets, 1e6, 1_000_000e6) / _totalWithdrawalRequests * _totalWithdrawalRequests; // Between 1 USDC and 1M USDC (6 decimals), multiple of _totalWithdrawalRequests

        TRANCHE_UNIT jtAssets = toTrancheUnits(_jtAssets);

        // Deposit assets into the junior tranche
        address jtDepositor = ALICE_ADDRESS;
        vm.startPrank(jtDepositor);
        USDC.approve(address(JT), _jtAssets);
        (uint256 shares,) = JT.deposit(jtAssets, jtDepositor, jtDepositor);
        vm.stopPrank();

        _updateOnDeposit(jtState, jtAssets, _toJTValue(jtAssets), shares, TrancheType.JUNIOR);
        _verifyPreviewNAVs(stState, jtState, AAVE_MAX_ABS_TRANCH_UNIT_DELTA, AAVE_MAX_ABS_NAV_DELTA);

        // Withdraw assets from the junior tranche
        uint256 sharesToWithdraw = shares / _totalWithdrawalRequests;
        for (uint256 i = 0; i < _totalWithdrawalRequests; i++) {
            TRANCHE_UNIT expectedAssetsToWithdraw = JT.convertToAssets(sharesToWithdraw).jtAssets;

            // Request the redeem
            vm.prank(jtDepositor);
            uint256 requestId;
            {
                (requestId,) = JT.requestRedeem(sharesToWithdraw, jtDepositor, jtDepositor);
                assertNotEq(
                    requestId, ERC_7540_CONTROLLER_DISCRIMINATED_REQUEST_ID, "Request ID should not be the ERC-7540 controller discriminated request ID"
                );
            }

            // Verify that the pending redeem request is equal to the shares to withdraw
            assertEq(
                JT.pendingRedeemRequest(requestId, jtDepositor), sharesToWithdraw, "Pending redeem request should be equal to the shares to withdraw initially"
            );

            // Verify that the claimable redeem request is 0
            assertEq(JT.claimableRedeemRequest(requestId, jtDepositor), 0, "Claimable redeem request should be 0 initially");

            // Attempts to redeem right now should revert
            vm.prank(jtDepositor);
            vm.expectRevert(abi.encodeWithSelector(IRoycoKernel.INSUFFICIENT_REDEEMABLE_SHARES.selector, sharesToWithdraw, 0));
            JT.redeem(sharesToWithdraw, jtDepositor, jtDepositor, requestId);

            // Wait for the redemption delay
            vm.warp(vm.getBlockTimestamp() + JT_REDEMPTION_DELAY_SECONDS);

            // Verify that the pending redeem request is equal to 0
            assertEq(JT.pendingRedeemRequest(requestId, jtDepositor), 0, "Pending redeem request should be 0");

            // Verify that the claimable redeem request is equal to the shares to withdraw
            assertEq(JT.claimableRedeemRequest(requestId, jtDepositor), sharesToWithdraw, "Claimable redeem request should be equal to the shares to withdraw");

            uint256 jtDepositorBalanceBeforeRedeem = USDC.balanceOf(jtDepositor);

            // Claim the redeem
            vm.prank(jtDepositor);
            (AssetClaims memory redeemResult,) = JT.redeem(sharesToWithdraw, jtDepositor, jtDepositor, requestId);

            // Verify that the redeem result is the correct amount
            assertApproxEqAbs(
                redeemResult.jtAssets, expectedAssetsToWithdraw, toUint256(AAVE_MAX_ABS_TRANCH_UNIT_DELTA), "Redeem result should be the correct amount"
            );
            assertEq(redeemResult.stAssets, ZERO_TRANCHE_UNITS, "Redeem result should be 0 ST assets");
            assertApproxEqAbs(redeemResult.nav, _toJTValue(expectedAssetsToWithdraw), AAVE_MAX_ABS_NAV_DELTA, "Redeem result should return the correct NAV");

            // Verify that the tokens were transferred to the jtDepositor
            assertApproxEqAbs(
                toTrancheUnits(USDC.balanceOf(jtDepositor) - jtDepositorBalanceBeforeRedeem),
                expectedAssetsToWithdraw,
                toUint256(AAVE_MAX_ABS_TRANCH_UNIT_DELTA),
                "Tokens should be transferred to the jtDepositor"
            );

            // Verify that the pending redeem request is equal to 0
            assertEq(JT.pendingRedeemRequest(requestId, jtDepositor), 0, "Pending redeem request should be 0");

            // Verify that the claimable redeem request is equal to 0
            assertEq(JT.claimableRedeemRequest(requestId, jtDepositor), 0, "Claimable redeem request should be 0");
        }
    }

    function testFuzz_jtDeposit_and_parallel_jtWithdrawals(uint256 _jtAssets, uint256 _totalWithdrawalRequests) external {
        // Bound assets to reasonable range (avoid zero and very large amounts)
        _totalWithdrawalRequests = bound(_totalWithdrawalRequests, 1, 10);
        _jtAssets = bound(_jtAssets, 1e6, 1_000_000e6);

        TRANCHE_UNIT jtAssets = toTrancheUnits(_jtAssets);

        // Deposit assets into the junior tranche
        address jtDepositor = ALICE_ADDRESS;
        vm.startPrank(jtDepositor);
        USDC.approve(address(JT), _jtAssets);
        (uint256 shares,) = JT.deposit(jtAssets, jtDepositor, jtDepositor);
        vm.stopPrank();

        _updateOnDeposit(jtState, jtAssets, _toJTValue(jtAssets), shares, TrancheType.JUNIOR);
        _verifyPreviewNAVs(stState, jtState, AAVE_MAX_ABS_TRANCH_UNIT_DELTA, AAVE_MAX_ABS_NAV_DELTA);

        // Withdraw assets from the junior tranche
        uint256 sharesToWithdraw = shares / _totalWithdrawalRequests;
        uint256 totalSharesWithdrawn = 0;

        uint256[] memory requestIds = new uint256[](_totalWithdrawalRequests);
        uint256[] memory sharesToWithdrawForEachRequest = new uint256[](_totalWithdrawalRequests);
        TRANCHE_UNIT[] memory expectedAssetsToWithdrawForEachRequest = new TRANCHE_UNIT[](_totalWithdrawalRequests);

        uint256 firstRequestRedemptionTimestamp = vm.getBlockTimestamp() + JT_REDEMPTION_DELAY_SECONDS;

        for (uint256 i = 0; i < _totalWithdrawalRequests; i++) {
            // Calculate the total expected assets to withdraw
            sharesToWithdrawForEachRequest[i] = i == _totalWithdrawalRequests - 1 ? shares - totalSharesWithdrawn : sharesToWithdraw;
            expectedAssetsToWithdrawForEachRequest[i] = JT.convertToAssets(sharesToWithdrawForEachRequest[i]).jtAssets;
            totalSharesWithdrawn += sharesToWithdrawForEachRequest[i];

            // Request the redeem
            vm.prank(jtDepositor);
            {
                (requestIds[i],) = JT.requestRedeem(sharesToWithdrawForEachRequest[i], jtDepositor, jtDepositor);
                assertNotEq(
                    requestIds[i], ERC_7540_CONTROLLER_DISCRIMINATED_REQUEST_ID, "Request ID should not be the ERC-7540 controller discriminated request ID"
                );
            }

            // Wait for the redemption delay
            vm.warp(vm.getBlockTimestamp() + 1);
        }

        // Wait for the redemption period of the first request
        vm.warp(firstRequestRedemptionTimestamp + JT_REDEMPTION_DELAY_SECONDS);

        for (uint256 i = 0; i < _totalWithdrawalRequests; ++i) {
            uint256 requestId = requestIds[i];

            // Verify that the pending redeem request is equal to 0
            assertEq(JT.pendingRedeemRequest(requestId, jtDepositor), 0, "Pending redeem request should be 0");

            // Verify that the claimable redeem request is equal to the shares to withdraw
            assertEq(
                JT.claimableRedeemRequest(requestId, jtDepositor),
                sharesToWithdrawForEachRequest[i],
                "Claimable redeem request should be equal to the shares to withdraw"
            );

            uint256 jtDepositorBalanceBeforeRedeem = USDC.balanceOf(jtDepositor);

            // Claim the redeem
            vm.prank(jtDepositor);
            (AssetClaims memory redeemResult,) = JT.redeem(sharesToWithdrawForEachRequest[i], jtDepositor, jtDepositor, requestId);

            // Verify that the redeem result is the correct amount
            assertApproxEqAbs(
                redeemResult.jtAssets,
                expectedAssetsToWithdrawForEachRequest[i],
                toUint256(AAVE_MAX_ABS_TRANCH_UNIT_DELTA),
                "Redeem result should be the correct amount"
            );
            assertEq(redeemResult.stAssets, ZERO_TRANCHE_UNITS, "Redeem result should be 0 ST assets");
            assertApproxEqAbs(
                redeemResult.nav, _toJTValue(expectedAssetsToWithdrawForEachRequest[i]), AAVE_MAX_ABS_NAV_DELTA, "Redeem result should return the correct NAV"
            );

            // Verify that the tokens were transferred to the jtDepositor
            assertApproxEqAbs(
                toTrancheUnits(USDC.balanceOf(jtDepositor) - jtDepositorBalanceBeforeRedeem),
                expectedAssetsToWithdrawForEachRequest[i],
                toUint256(AAVE_MAX_ABS_TRANCH_UNIT_DELTA),
                "Tokens should be transferred to the jtDepositor"
            );

            // Verify that the pending redeem request is equal to 0
            assertEq(JT.pendingRedeemRequest(requestId, jtDepositor), 0, "Pending redeem request should be 0");

            // Verify that the claimable redeem request is equal to 0
            assertEq(JT.claimableRedeemRequest(requestId, jtDepositor), 0, "Claimable redeem request should be 0");

            vm.warp(vm.getBlockTimestamp() + 1);
        }
    }

    function testFuzz_jtDeposit_and_requestWithdraw_thenCancelWithdrawal(uint256 _jtAssets, uint256 _withdrawalPercentage) external {
        // Bound assets to reasonable range (avoid zero and very large amounts)
        _jtAssets = bound(_jtAssets, 1e6, 1_000_000e6); // Between 1 USDC and 1M USDC (6 decimals)
        _withdrawalPercentage = bound(_withdrawalPercentage, 1, 100); // Between 1% and 100%

        TRANCHE_UNIT jtAssets = toTrancheUnits(_jtAssets);

        // Deposit assets into the junior tranche
        address jtDepositor = ALICE_ADDRESS;
        uint256 initialDepositorShares = JT.balanceOf(jtDepositor);
        vm.startPrank(jtDepositor);
        USDC.approve(address(JT), _jtAssets);
        (uint256 shares,) = JT.deposit(jtAssets, jtDepositor, jtDepositor);
        vm.stopPrank();

        _updateOnDeposit(jtState, jtAssets, _toJTValue(jtAssets), shares, TrancheType.JUNIOR);
        _verifyPreviewNAVs(stState, jtState, AAVE_MAX_ABS_TRANCH_UNIT_DELTA, AAVE_MAX_ABS_NAV_DELTA);

        // Calculate shares to withdraw based on percentage
        uint256 sharesToWithdraw = shares * _withdrawalPercentage / 100;
        // Ensure at least 1 share is withdrawn
        if (sharesToWithdraw == 0) {
            sharesToWithdraw = 1;
        }
        // Ensure we don't withdraw more than available
        if (sharesToWithdraw > shares) {
            sharesToWithdraw = shares;
        }

        uint256 initialTotalShares = JT.totalSupply();

        // Verify initial state: depositor has the shares
        assertEq(JT.balanceOf(jtDepositor), initialDepositorShares + shares, "Depositor should have all shares initially");

        // Request the redeem
        vm.prank(jtDepositor);
        uint256 requestId;
        {
            (requestId,) = JT.requestRedeem(sharesToWithdraw, jtDepositor, jtDepositor);
            assertNotEq(requestId, ERC_7540_CONTROLLER_DISCRIMINATED_REQUEST_ID, "Request ID should not be the ERC-7540 controller discriminated request ID");
        }

        // Verify that shares were locked (transferred to the tranche contract) since JT uses BURN_ON_CLAIM_REDEEM
        assertEq(JT.balanceOf(jtDepositor), initialDepositorShares + shares - sharesToWithdraw, "Depositor should have shares reduced by withdrawal amount");
        assertEq(JT.balanceOf(address(JT)), sharesToWithdraw, "Tranche should have locked shares");

        // Verify that the pending redeem request is equal to the shares to withdraw
        assertEq(JT.pendingRedeemRequest(requestId, jtDepositor), sharesToWithdraw, "Pending redeem request should be equal to the shares to withdraw");

        // Verify that the claimable redeem request is 0 (not yet claimable)
        assertEq(JT.claimableRedeemRequest(requestId, jtDepositor), 0, "Claimable redeem request should be 0 initially");

        // Verify that cancel is not yet claimable
        assertEq(JT.claimableCancelRedeemRequest(requestId, jtDepositor), 0, "Claimable cancel should be 0 before cancellation");

        // Cancel the withdrawal request
        vm.prank(jtDepositor);
        JT.cancelRedeemRequest(requestId, jtDepositor);

        // Verify that the pending redeem request is 0 after cancellation (cancellation is instant)
        assertEq(JT.pendingRedeemRequest(requestId, jtDepositor), 0, "Pending redeem request should be 0 after cancellation");

        // Verify that claimable cancel redeem request returns the shares
        assertEq(
            JT.claimableCancelRedeemRequest(requestId, jtDepositor), sharesToWithdraw, "Claimable cancel redeem request should return the shares to withdraw"
        );

        // Verify that pending cancel is false (cancellation is instant)
        assertFalse(JT.pendingCancelRedeemRequest(requestId, jtDepositor), "Pending cancel should be false (cancellation is instant)");

        // Claim the cancelled withdrawal to get shares back
        uint256 depositorSharesBeforeClaim = JT.balanceOf(jtDepositor);
        vm.prank(jtDepositor);
        JT.claimCancelRedeemRequest(requestId, jtDepositor, jtDepositor);

        // Verify that shares were returned to the depositor (transferred back from the tranche)
        assertEq(JT.balanceOf(jtDepositor), depositorSharesBeforeClaim + sharesToWithdraw, "Depositor should receive shares back after claiming cancellation");
        assertEq(JT.balanceOf(address(JT)), 0, "Tranche should have no locked shares after claiming cancellation");

        // Verify that the final balance matches the initial balance (all shares returned)
        assertEq(JT.balanceOf(jtDepositor), initialDepositorShares + shares, "Depositor should have all original shares back");

        // Verify that claimable cancel redeem request is now 0
        assertEq(JT.claimableCancelRedeemRequest(requestId, jtDepositor), 0, "Claimable cancel redeem request should be 0 after claiming");

        // Verify that pending redeem request is 0
        assertEq(JT.pendingRedeemRequest(requestId, jtDepositor), 0, "Pending redeem request should be 0 after cancellation and claim");

        // Verify that claimable redeem request is 0
        assertEq(JT.claimableRedeemRequest(requestId, jtDepositor), 0, "Claimable redeem request should be 0 after cancellation");

        // Verify that total shares is the same as the initial total shares
        assertEq(JT.totalSupply(), initialTotalShares, "Total shares should be the same as the initial total shares");
    }

    function testFuzz_jtDeposit_allowsSTDeposit_thenSTRedeem_allowsJTExit_verifyVaultEmpty(uint256 _jtAssets, uint256 _stDepositPercentage) external {
        // TODO: Improve this test by exactly accouning for the JT appreciation

        // Bound assets to reasonable range (avoid zero and very large amounts)
        _jtAssets = bound(_jtAssets, 1e6, 1_000_000e6); // Between 1 USDC and 1M USDC (6 decimals)
        _stDepositPercentage = bound(_stDepositPercentage, 1, 100); // Between 1% and 100%

        TRANCHE_UNIT jtAssets = toTrancheUnits(_jtAssets);

        address jtDepositor = ALICE_ADDRESS;
        address stDepositor = BOB_ADDRESS;

        // Step 1: JT deposits (provides coverage for ST)
        vm.startPrank(jtDepositor);
        USDC.approve(address(JT), _jtAssets);
        (uint256 jtShares,) = JT.deposit(jtAssets, jtDepositor, jtDepositor);
        vm.stopPrank();

        _updateOnDeposit(jtState, jtAssets, _toJTValue(jtAssets), jtShares, TrancheType.JUNIOR);
        _verifyPreviewNAVs(stState, jtState, AAVE_MAX_ABS_TRANCH_UNIT_DELTA, AAVE_MAX_ABS_NAV_DELTA);

        // Verify JT can exit initially (no ST deposits yet, so no coverage requirement)
        {
            uint256 initialJTMaxRedeem = JT.maxRedeem(jtDepositor);
            assertEq(initialJTMaxRedeem, jtShares, "JT should be able to redeem all shares initially (no ST deposits)");
        }

        // Step 2: ST deposits (uses coverage, JT cannot exit now)
        TRANCHE_UNIT expectedMaxSTDeposit = ST.maxDeposit(stDepositor);
        TRANCHE_UNIT stDepositAmount = expectedMaxSTDeposit.mulDiv(_stDepositPercentage, 100, Math.Rounding.Floor);

        // Ensure at least some deposit
        if (stDepositAmount == ZERO_TRANCHE_UNITS) {
            stDepositAmount = toTrancheUnits(1);
        }

        vm.startPrank(stDepositor);
        USDC.approve(address(ST), toUint256(stDepositAmount));
        (uint256 stShares,) = ST.deposit(stDepositAmount, stDepositor, stDepositor);
        vm.stopPrank();

        _updateOnDeposit(stState, stDepositAmount, _toSTValue(stDepositAmount), stShares, TrancheType.SENIOR);
        _verifyPreviewNAVs(stState, jtState, AAVE_MAX_ABS_TRANCH_UNIT_DELTA, AAVE_MAX_ABS_NAV_DELTA);

        // Verify JT cannot exit now (coverage requirement blocks it)
        {
            uint256 jtMaxRedeemAfterSTDeposit = JT.maxRedeem(jtDepositor);
            assertLt(jtMaxRedeemAfterSTDeposit, jtShares, "JT should not be able to redeem all shares after ST deposit");

            uint256 snapshot = vm.snapshotState();

            vm.startPrank(jtDepositor);
            (uint256 requestId,) = JT.requestRedeem(jtShares, jtDepositor, jtDepositor);
            vm.warp(vm.getBlockTimestamp() + JT_REDEMPTION_DELAY_SECONDS);
            vm.expectRevert(abi.encodeWithSelector(IRoycoAccountant.COVERAGE_REQUIREMENT_UNSATISFIED.selector));
            JT.redeem(jtShares, jtDepositor, jtDepositor, requestId);
            vm.stopPrank();

            vm.revertToState(snapshot);
        }

        // Step 3: ST redeems synchronously (immediately withdraws)
        uint256 stDepositorBalanceBeforeRedeem = USDC.balanceOf(stDepositor);
        vm.startPrank(stDepositor);
        ST.redeem(stShares, stDepositor, stDepositor);
        vm.stopPrank();

        // Verify ST received assets
        assertApproxEqAbs(
            toTrancheUnits(USDC.balanceOf(stDepositor) - stDepositorBalanceBeforeRedeem),
            stDepositAmount,
            toTrancheUnits(1),
            "ST should receive assets after redeem"
        );

        // Verify ST shares were burned
        assertEq(ST.balanceOf(stDepositor), 0, "ST shares should be burned after redeem");
        assertEq(ST.totalSupply(), 0, "ST total supply should be 0 after redeem");

        // Step 4: After ST redeems, JT can now exit (coverage requirement satisfied again)
        uint256 jtMaxRedeemAfterSTRedeem = JT.maxRedeem(jtDepositor);
        assertApproxEqRel(jtMaxRedeemAfterSTRedeem, jtShares, MAX_REDEEM_RELATIVE_DELTA, "JT should be able to redeem all shares after ST redeems");

        // Step 5: JT requests withdrawal (async), waits for delay, then redeems
        vm.prank(jtDepositor);
        uint256 requestId;
        {
            (requestId,) = JT.requestRedeem(jtMaxRedeemAfterSTRedeem, jtDepositor, jtDepositor);
            assertNotEq(requestId, ERC_7540_CONTROLLER_DISCRIMINATED_REQUEST_ID, "Request ID should not be the ERC-7540 controller discriminated request ID");
        }

        // Wait for the redemption delay
        vm.warp(vm.getBlockTimestamp() + JT_REDEMPTION_DELAY_SECONDS);

        // Verify the request is claimable
        assertEq(JT.claimableRedeemRequest(requestId, jtDepositor), jtMaxRedeemAfterSTRedeem, "JT redeem request should be claimable after delay");

        // Claim the redeem
        uint256 jtDepositorBalanceBeforeRedeem = USDC.balanceOf(jtDepositor);
        vm.prank(jtDepositor);
        (AssetClaims memory jtRedeemResult,) = JT.redeem(jtMaxRedeemAfterSTRedeem, jtDepositor, jtDepositor, requestId);

        // Verify JT received assets
        assertApproxEqRel(
            toTrancheUnits(USDC.balanceOf(jtDepositor) - jtDepositorBalanceBeforeRedeem),
            jtAssets,
            MAX_REDEEM_RELATIVE_DELTA,
            "JT should receive assets after redeem"
        );

        // Check that no assets remain in the underlying ST vault
        assertApproxEqAbs(
            USDC.balanceOf(address(MOCK_UNDERLYING_ST_VAULT)),
            0,
            toUint256(AAVE_MAX_ABS_TRANCH_UNIT_DELTA),
            "Underlying ST vault should have no USDC assets remaining"
        );
    }
}
