// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Vm } from "../../lib/forge-std/src/Vm.sol";
import { IRoycoAccountant } from "../../src/interfaces/IRoycoAccountant.sol";
import { MainnetForkWithAaveTestBase } from "./base/MainnetForkWithAaveBaseTest.sol";

contract BasicOperationsTest is MainnetForkWithAaveTestBase {
    // Test State Trackers
    TrancheState internal sTState;
    TrancheState internal jTState;

    function setUp() public {
        _setUpRoyco();
        _setUpTrancheRoles(address(JT), providers, PAUSER_ADDRESS, UPGRADER_ADDRESS, SCHEDULER_MANAGER_ADDRESS);
    }

    function testFuzz_depositIntoJT(uint256 _assets) external {
        // Bound assets to reasonable range (avoid zero and very large amounts)
        _assets = bound(_assets, 1e6, 1_000_000e6); // Between 1 USDC and 1M USDC (6 decimals)

        address depositor = ALICE_ADDRESS;

        // Get initial balances
        uint256 initialDepositorBalance = USDC.balanceOf(depositor);
        uint256 initialTrancheShares = JT.balanceOf(depositor);

        // Assert that initially all tranche parameters are 0
        _verifyPreviewNAVs(sTState, jTState, AAVE_MAX_ABS_NAV_DELTA);
        _verifyFeeTaken(sTState, jTState, PROTOCOL_FEE_RECIPIENT_ADDRESS);

        // Approve the junior tranche to spend assets
        vm.prank(depositor);
        USDC.approve(address(JT), _assets);

        // Deposit into junior tranche
        vm.prank(depositor);
        uint256 shares = JT.deposit(_assets, depositor, depositor);
        _updateOnDeposit(jTState, _assets, _assets, shares);

        // Verify shares were minted
        assertGt(shares, 0, "Shares should be greater than 0");
        assertEq(JT.balanceOf(depositor), initialTrancheShares + shares, "Depositor should receive shares");

        // Verify that maxRedeemable shares returns the correct amount
        uint256 maxRedeemableShares = JT.maxRedeem(depositor);
        assertApproxEqRel(maxRedeemableShares, shares, MAX_REDEEM_RELATIVE_DELTA, "Max redeemable shares should return the correct amount");
        assertTrue(maxRedeemableShares <= shares, "Max redeemable shares should be less than or equal to shares");

        // Verify that previewRedeem returns the correct amount
        uint256 convertedAssets = JT.convertToAssets(shares);
        assertApproxEqRel(convertedAssets, _assets, MAX_CONVERT_TO_ASSETS_RELATIVE_DELTA, "Convert to assets should return the correct amount");

        // Verify assets were transferred
        assertEq(USDC.balanceOf(depositor), initialDepositorBalance - _assets, "Depositor balance should decrease by assets amount");

        // Verify that an equivalent amount of AUSDCs were minted
        assertApproxEqAbs(AUSDC.balanceOf(address(KERNEL)), _assets, AAVE_MAX_ABS_NAV_DELTA, "An equivalent amount of AUSDCs should be minted");

        // Verify that the tranche state has been updated
        _verifyPreviewNAVs(sTState, jTState, AAVE_MAX_ABS_NAV_DELTA);
        _verifyFeeTaken(sTState, jTState, PROTOCOL_FEE_RECIPIENT_ADDRESS);
    }

    function testFuzz_multipleDepositsIntoJT(uint256 _numDepositors, uint256 _amountSeed) external {
        // Bound the number of depositors to a reasonable range (avoid zero and very large numbers)
        _numDepositors = bound(_numDepositors, 1, 10);

        // Assert that initially all tranche parameters are 0
        _verifyPreviewNAVs(sTState, jTState, AAVE_MAX_ABS_NAV_DELTA);
        _verifyFeeTaken(sTState, jTState, PROTOCOL_FEE_RECIPIENT_ADDRESS);

        for (uint256 i = 0; i < _numDepositors; i++) {
            // Generate a provider
            Vm.Wallet memory provider = _generateProvider(JT, i);

            // Generate a random amount
            uint256 amount = bound(uint256(keccak256(abi.encodePacked(_amountSeed, i))), 1e6, 1_000_000e6);

            // Get initial balances
            uint256 initialDepositorBalance = USDC.balanceOf(provider.addr);
            uint256 initialTrancheShares = JT.balanceOf(provider.addr);
            uint256 initialATokenBalance = AUSDC.balanceOf(address(KERNEL));

            // Approve the tranche to spend assets
            vm.prank(provider.addr);
            USDC.approve(address(JT), amount);

            // Deposit into the tranche
            vm.prank(provider.addr);
            uint256 shares = JT.deposit(amount, provider.addr, provider.addr);

            // Verify that an equivalent amount of AUSDCs were minted
            assertApproxEqAbs(
                AUSDC.balanceOf(address(KERNEL)), amount + initialATokenBalance, AAVE_MAX_ABS_NAV_DELTA, "An equivalent amount of AUSDCs should be minted"
            );

            uint256 aTokensMinted = AUSDC.balanceOf(address(KERNEL)) - initialATokenBalance;
            _updateOnDeposit(jTState, aTokensMinted, aTokensMinted, shares);

            // Verify that shares were minted
            assertEq(JT.balanceOf(provider.addr), initialTrancheShares + shares, "Provider should receive shares");

            // Verify that maxRedeemable shares returns the correct amount
            uint256 maxRedeemableShares = JT.maxRedeem(provider.addr);
            assertApproxEqRel(maxRedeemableShares, shares, MAX_REDEEM_RELATIVE_DELTA, "Max redeemable shares should return the correct amount");
            assertTrue(maxRedeemableShares <= shares, "Max redeemable shares should be less than or equal to shares");

            // Verify that previewRedeem returns the correct amount
            uint256 convertedAssets = JT.convertToAssets(shares);
            assertApproxEqRel(convertedAssets, amount, MAX_CONVERT_TO_ASSETS_RELATIVE_DELTA, "Convert to assets should return the correct amount");
            assertTrue(convertedAssets <= amount, "Convert to assets should be less than or equal to amount");

            // Verify that assets were transferred
            assertEq(USDC.balanceOf(provider.addr), initialDepositorBalance - amount, "Provider balance should decrease by amount");

            // Verify that the tranche state has been updated
            _verifyPreviewNAVs(sTState, jTState, AAVE_MAX_ABS_NAV_DELTA);
            _verifyFeeTaken(sTState, jTState, PROTOCOL_FEE_RECIPIENT_ADDRESS);
        }
    }

    function testFuzz_depositIntoST(uint256 _jtAssets) external {
        // Bound assets to reasonable range (avoid zero and very large amounts)
        _jtAssets = bound(_jtAssets, 1e6, 1_000_000e6); // Between 1 USDC and 1M USDC (6 decimals)

        // There are no assets in JT initally, therefore depositing into ST should fail
        address stDepositor = BOB_ADDRESS;
        uint256 stDepositAmount = 1;

        vm.startPrank(stDepositor);
        USDC.approve(address(ST), stDepositAmount);
        vm.expectRevert(abi.encodeWithSelector(IRoycoAccountant.COVERAGE_REQUIREMENT_UNSATISFIED.selector));
        ST.deposit(stDepositAmount, stDepositor, stDepositor);
        vm.stopPrank();

        // Deposit assets into the junior tranche to allow deposits into the ST
        address jtDepositor = ALICE_ADDRESS;
        vm.prank(jtDepositor);
        USDC.approve(address(ST), _jtAssets);
    }
}
