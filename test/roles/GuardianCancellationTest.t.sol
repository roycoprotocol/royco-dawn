// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { COMPONENT_ID_KERNEL_IDENTICAL_ERC4626_ADMIN_ORACLE } from "../../src/factory/templates/Components.sol";
import { IdenticalERC4626AdminOracleDeploymentTemplate } from "../../src/factory/templates/dawn/IdenticalERC4626AdminOracleDeploymentTemplate.sol";
import { Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel } from "../../src/kernels/dawn/Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel.sol";
import { WAD } from "../../src/libraries/Constants.sol";
import { NAV_UNIT, toNAVUnits } from "../../src/libraries/Units.sol";
import { BaseTest } from "../base/BaseTest.t.sol";

/// @title GuardianCancellationTest
/// @notice Tests that the GUARDIAN_ROLE can cancel any and all delayed operations
/// @dev Tests cover cancellation of operations for ADMIN_KERNEL_ROLE, ADMIN_ACCOUNTANT_ROLE,
///      ADMIN_PROTOCOL_FEE_SETTER_ROLE, and ADMIN_UPGRADER_ROLE. All scheduling /
///      cancellation now flows through the standalone `AccessManager` (the `AM` field on
///      `BaseTest`), not the factory — the factory is just one admin on the AM under the
///      template-driven design.
contract GuardianCancellationTest is BaseTest {
    function setUp() public {
        _setUpRoyco();
    }

    function _setUpRoyco() internal override {
        super._setUpRoyco();

        _setupProviders();
        _setupAssets(10_000_000);

        // Deploy the markets
        MarketDeployment memory deploymentResult = _deployMarketWithKernel();
        _setDeployedMarket(deploymentResult);
    }

    /// @notice Deploys a Dawn market via the canonical template-driven path. The choice of
    ///         market is irrelevant — every assertion below operates on the AM's scheduled-
    ///         operation surface, not on market economics.
    function _deployMarketWithKernel() internal returns (MarketDeployment memory) {
        IdenticalERC4626AdminOracleDeploymentTemplate template = new IdenticalERC4626AdminOracleDeploymentTemplate(FACTORY);

        DawnDeploymentParams memory p;
        p.marketId = keccak256("GUARDIAN_CANCELLATION_TEST");
        p.template = address(template);
        p.kernelComponentId = COMPONENT_ID_KERNEL_IDENTICAL_ERC4626_ADMIN_ORACLE;
        p.kernelCreationCode = type(Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel).creationCode;
        p.stAsset = address(MOCK_USDC_VAULT);
        p.jtAsset = address(MOCK_USDC_VAULT);
        p.kernelSpecificParams = abi.encode(IdenticalERC4626AdminOracleDeploymentTemplate.KernelParams({ initialConversionRateWAD: WAD }));
        p.stProtocolFeeWAD = ST_PROTOCOL_FEE_WAD;
        p.jtProtocolFeeWAD = JT_PROTOCOL_FEE_WAD;
        p.yieldShareProtocolFeeWAD = 0;
        p.coverageWAD = COVERAGE_WAD;
        p.betaWAD = BETA_WAD;
        p.liquidationUtilizationWAD = LIQUIDATION_UTILIZATION_WAD;
        p.fixedTermDurationSeconds = FIXED_TERM_DURATION_SECONDS;
        p.stNAVDustTolerance = DUST_TOLERANCE;
        p.jtNAVDustTolerance = DUST_TOLERANCE;
        p.enforceVaultSharesTransferWhitelist = false;
        p.stSelfLiquidationBonusWAD = 0;
        return _deployDawnMarket(p);
    }

    // ============================================
    // GUARDIAN CANCELLATION TESTS
    // ============================================

    /// @notice Test that guardian can cancel a scheduled kernel admin operation (setProtocolFeeRecipient)
    function test_guardian_canCancelKernelAdminOperation() public {
        address newRecipient = address(0x1234);
        bytes memory data = abi.encodeCall(KERNEL.setProtocolFeeRecipient, (newRecipient));

        // Schedule the operation as kernel admin
        vm.prank(KERNEL_ADMIN_ADDRESS);
        AM.schedule(address(KERNEL), data, 0);

        // Verify operation is scheduled
        bytes32 operationId = AM.hashOperation(KERNEL_ADMIN_ADDRESS, address(KERNEL), data);
        uint48 scheduledTime = AM.getSchedule(operationId);
        assertTrue(scheduledTime > 0, "Operation should be scheduled");

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        AM.cancel(KERNEL_ADMIN_ADDRESS, address(KERNEL), data);

        // Verify operation is cancelled (schedule returns 0)
        scheduledTime = AM.getSchedule(operationId);
        assertEq(scheduledTime, 0, "Operation should be cancelled");

        // Verify the operation cannot be executed even after delay
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(KERNEL_ADMIN_ADDRESS);
        vm.expectRevert(); // Should revert - operation was cancelled
        AM.execute(address(KERNEL), data);
    }

    /// @notice Test that guardian can cancel a scheduled accountant admin operation (setCoverage)
    function test_guardian_canCancelAccountantAdminSetCoverage() public {
        uint64 newCoverage = 0.3e18; // 30%
        bytes memory data = abi.encodeCall(ACCOUNTANT.setCoverage, (newCoverage));

        // Schedule the operation as accountant admin
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        AM.schedule(address(ACCOUNTANT), data, 0);

        // Verify operation is scheduled
        bytes32 operationId = AM.hashOperation(ACCOUNTANT_ADMIN_ADDRESS, address(ACCOUNTANT), data);
        uint48 scheduledTime = AM.getSchedule(operationId);
        assertTrue(scheduledTime > 0, "Operation should be scheduled");

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        AM.cancel(ACCOUNTANT_ADMIN_ADDRESS, address(ACCOUNTANT), data);

        // Verify operation is cancelled
        scheduledTime = AM.getSchedule(operationId);
        assertEq(scheduledTime, 0, "Operation should be cancelled");
    }

    /// @notice Test that guardian can cancel a scheduled accountant admin operation (setBeta)
    function test_guardian_canCancelAccountantAdminSetBeta() public {
        uint96 newBeta = 0.5e18;
        bytes memory data = abi.encodeCall(ACCOUNTANT.setBeta, (newBeta));

        // Schedule the operation as accountant admin
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        AM.schedule(address(ACCOUNTANT), data, 0);

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        AM.cancel(ACCOUNTANT_ADMIN_ADDRESS, address(ACCOUNTANT), data);

        // Verify the operation cannot be executed
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        vm.expectRevert();
        AM.execute(address(ACCOUNTANT), data);
    }

    /// @notice Test that guardian can cancel a scheduled accountant admin operation (setLiquidationUtilization)
    function test_guardian_canCancelAccountantAdminSetLiquidationUtilization() public {
        uint256 newLiquidationUtilization = 5e18;
        bytes memory data = abi.encodeCall(ACCOUNTANT.setLiquidationUtilization, (newLiquidationUtilization));

        // Schedule the operation as accountant admin
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        AM.schedule(address(ACCOUNTANT), data, 0);

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        AM.cancel(ACCOUNTANT_ADMIN_ADDRESS, address(ACCOUNTANT), data);

        // Verify the operation cannot be executed
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        vm.expectRevert();
        AM.execute(address(ACCOUNTANT), data);
    }

    /// @notice Test that guardian can cancel a scheduled accountant admin operation (setFixedTermDuration)
    function test_guardian_canCancelAccountantAdminSetFixedTermDuration() public {
        uint24 newDuration = 4 weeks;
        bytes memory data = abi.encodeCall(ACCOUNTANT.setFixedTermDuration, (newDuration));

        // Schedule the operation as accountant admin
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        AM.schedule(address(ACCOUNTANT), data, 0);

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        AM.cancel(ACCOUNTANT_ADMIN_ADDRESS, address(ACCOUNTANT), data);

        // Verify the operation cannot be executed
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        vm.expectRevert();
        AM.execute(address(ACCOUNTANT), data);
    }

    /// @notice Test that guardian can cancel a scheduled accountant admin operation (setSeniorTrancheDustTolerance)
    function test_guardian_canCancelAccountantAdminSetDustTolerance() public {
        NAV_UNIT newDustTolerance = toNAVUnits(uint256(100));
        bytes memory data = abi.encodeCall(ACCOUNTANT.setSeniorTrancheDustTolerance, (newDustTolerance));

        // Schedule the operation as accountant admin
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        AM.schedule(address(ACCOUNTANT), data, 0);

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        AM.cancel(ACCOUNTANT_ADMIN_ADDRESS, address(ACCOUNTANT), data);

        // Verify the operation cannot be executed
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        vm.expectRevert();
        AM.execute(address(ACCOUNTANT), data);
    }

    /// @notice Test that guardian can cancel a scheduled protocol fee setter operation (setSeniorTrancheProtocolFee)
    function test_guardian_canCancelProtocolFeeSetterSetSTFee() public {
        uint64 newFee = 0.15e18; // 15%
        bytes memory data = abi.encodeCall(ACCOUNTANT.setSeniorTrancheProtocolFee, (newFee));

        // Schedule the operation as protocol fee setter
        vm.prank(PROTOCOL_FEE_SETTER_ADDRESS);
        AM.schedule(address(ACCOUNTANT), data, 0);

        // Verify operation is scheduled
        bytes32 operationId = AM.hashOperation(PROTOCOL_FEE_SETTER_ADDRESS, address(ACCOUNTANT), data);
        uint48 scheduledTime = AM.getSchedule(operationId);
        assertTrue(scheduledTime > 0, "Operation should be scheduled");

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        AM.cancel(PROTOCOL_FEE_SETTER_ADDRESS, address(ACCOUNTANT), data);

        // Verify operation is cancelled
        scheduledTime = AM.getSchedule(operationId);
        assertEq(scheduledTime, 0, "Operation should be cancelled");
    }

    /// @notice Test that guardian can cancel a scheduled protocol fee setter operation (setJuniorTrancheProtocolFee)
    function test_guardian_canCancelProtocolFeeSetterSetJTFee() public {
        uint64 newFee = 0.2e18; // 20%
        bytes memory data = abi.encodeCall(ACCOUNTANT.setJuniorTrancheProtocolFee, (newFee));

        // Schedule the operation as protocol fee setter
        vm.prank(PROTOCOL_FEE_SETTER_ADDRESS);
        AM.schedule(address(ACCOUNTANT), data, 0);

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        AM.cancel(PROTOCOL_FEE_SETTER_ADDRESS, address(ACCOUNTANT), data);

        // Verify the operation cannot be executed
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(PROTOCOL_FEE_SETTER_ADDRESS);
        vm.expectRevert();
        AM.execute(address(ACCOUNTANT), data);
    }

    /// @notice Test that guardian can cancel a scheduled upgrader operation (upgradeToAndCall on kernel)
    function test_guardian_canCancelUpgraderOperation() public {
        // Create mock new implementation address
        address newImpl = address(0xBEEF);
        // Use UUPSUpgradeable.upgradeToAndCall selector
        bytes memory data = abi.encodeWithSelector(bytes4(keccak256("upgradeToAndCall(address,bytes)")), newImpl, "");

        // Schedule the operation as upgrader
        vm.prank(UPGRADER_ADDRESS);
        AM.schedule(address(KERNEL), data, 0);

        // Verify operation is scheduled
        bytes32 operationId = AM.hashOperation(UPGRADER_ADDRESS, address(KERNEL), data);
        uint48 scheduledTime = AM.getSchedule(operationId);
        assertTrue(scheduledTime > 0, "Operation should be scheduled");

        // Guardian cancels the operation
        vm.prank(ROLE_GUARDIAN_ADDRESS);
        AM.cancel(UPGRADER_ADDRESS, address(KERNEL), data);

        // Verify operation is cancelled
        scheduledTime = AM.getSchedule(operationId);
        assertEq(scheduledTime, 0, "Operation should be cancelled");
    }

    /// @notice Test that non-guardian cannot cancel operations
    function test_nonGuardian_cannotCancelOperations() public {
        address newRecipient = address(0x1234);
        bytes memory data = abi.encodeCall(KERNEL.setProtocolFeeRecipient, (newRecipient));

        // Schedule the operation as kernel admin
        vm.prank(KERNEL_ADMIN_ADDRESS);
        AM.schedule(address(KERNEL), data, 0);

        // Random address tries to cancel - should fail
        vm.prank(address(0xBAD));
        vm.expectRevert();
        AM.cancel(KERNEL_ADMIN_ADDRESS, address(KERNEL), data);

        // Even another role holder (not guardian) cannot cancel
        vm.prank(PAUSER_ADDRESS);
        vm.expectRevert();
        AM.cancel(KERNEL_ADMIN_ADDRESS, address(KERNEL), data);
    }

    /// @notice Test that guardian can cancel multiple operations in sequence
    function test_guardian_canCancelMultipleOperations() public {
        // Schedule multiple operations
        bytes memory data1 = abi.encodeCall(KERNEL.setProtocolFeeRecipient, (address(0x1111)));
        bytes memory data2 = abi.encodeCall(ACCOUNTANT.setCoverage, (0.25e18));
        bytes memory data3 = abi.encodeCall(ACCOUNTANT.setSeniorTrancheProtocolFee, (0.12e18));

        vm.prank(KERNEL_ADMIN_ADDRESS);
        AM.schedule(address(KERNEL), data1, 0);

        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        AM.schedule(address(ACCOUNTANT), data2, 0);

        vm.prank(PROTOCOL_FEE_SETTER_ADDRESS);
        AM.schedule(address(ACCOUNTANT), data3, 0);

        // Guardian cancels all operations
        vm.startPrank(ROLE_GUARDIAN_ADDRESS);
        AM.cancel(KERNEL_ADMIN_ADDRESS, address(KERNEL), data1);
        AM.cancel(ACCOUNTANT_ADMIN_ADDRESS, address(ACCOUNTANT), data2);
        AM.cancel(PROTOCOL_FEE_SETTER_ADDRESS, address(ACCOUNTANT), data3);
        vm.stopPrank();

        // Verify all operations are cancelled
        assertEq(AM.getSchedule(AM.hashOperation(KERNEL_ADMIN_ADDRESS, address(KERNEL), data1)), 0);
        assertEq(AM.getSchedule(AM.hashOperation(ACCOUNTANT_ADMIN_ADDRESS, address(ACCOUNTANT), data2)), 0);
        assertEq(AM.getSchedule(AM.hashOperation(PROTOCOL_FEE_SETTER_ADDRESS, address(ACCOUNTANT), data3)), 0);
    }

    // ============================================
    // ROLE ASSIGNMENT TESTS — newly added selectors
    // ============================================

    /// @notice Test that ADMIN_KERNEL_ROLE can call setSeniorTrancheSelfLiquidationBonus
    function test_role_kernelAdmin_canSetSelfLiquidationBonus() public {
        uint64 newBonus = 0.05e18; // 5%
        bytes memory data = abi.encodeCall(KERNEL.setSeniorTrancheSelfLiquidationBonus, (newBonus));

        // Schedule as kernel admin
        vm.prank(KERNEL_ADMIN_ADDRESS);
        AM.schedule(address(KERNEL), data, 0);

        // Advance past execution delay
        vm.warp(block.timestamp + 2 days + 1);

        // Execute
        vm.prank(KERNEL_ADMIN_ADDRESS);
        AM.execute(address(KERNEL), data);
    }

    /// @notice Test that non-kernel-admin cannot call setSeniorTrancheSelfLiquidationBonus
    function test_role_nonKernelAdmin_cannotSetSelfLiquidationBonus() public {
        uint64 newBonus = 0.05e18;
        bytes memory data = abi.encodeCall(KERNEL.setSeniorTrancheSelfLiquidationBonus, (newBonus));

        // Random address tries to schedule — should fail
        vm.prank(address(0xBAD));
        vm.expectRevert();
        AM.schedule(address(KERNEL), data, 0);
    }

    /// @notice Test that ADMIN_PROTOCOL_FEE_SETTER_ROLE can call setYieldShareProtocolFee
    function test_role_protocolFeeSetter_canSetYieldShareProtocolFee() public {
        uint64 newFee = 0.1e18; // 10%
        bytes memory data = abi.encodeCall(ACCOUNTANT.setYieldShareProtocolFee, (newFee));

        // Schedule as protocol fee setter
        vm.prank(PROTOCOL_FEE_SETTER_ADDRESS);
        AM.schedule(address(ACCOUNTANT), data, 0);

        // Advance past execution delay
        vm.warp(block.timestamp + 2 days + 1);

        // Execute
        vm.prank(PROTOCOL_FEE_SETTER_ADDRESS);
        AM.execute(address(ACCOUNTANT), data);
    }

    /// @notice Test that non-fee-setter cannot call setYieldShareProtocolFee
    function test_role_nonFeeSetter_cannotSetYieldShareProtocolFee() public {
        uint64 newFee = 0.1e18;
        bytes memory data = abi.encodeCall(ACCOUNTANT.setYieldShareProtocolFee, (newFee));

        vm.prank(address(0xBAD));
        vm.expectRevert();
        AM.schedule(address(ACCOUNTANT), data, 0);
    }

    /// @notice Test that ADMIN_ACCOUNTANT_ROLE can call setCoverageConfiguration
    function test_role_accountantAdmin_canSetCoverageConfiguration() public {
        uint64 newCoverage = 0.3e18;
        uint96 newBeta = 0.5e18;
        uint256 newLiquidationUtilization = 3e18;
        bytes memory data = abi.encodeCall(ACCOUNTANT.setCoverageConfiguration, (newCoverage, newBeta, newLiquidationUtilization));

        // Schedule as accountant admin
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        AM.schedule(address(ACCOUNTANT), data, 0);

        // Advance past execution delay
        vm.warp(block.timestamp + 2 days + 1);

        // Execute
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        AM.execute(address(ACCOUNTANT), data);
    }

    /// @notice Test that non-accountant-admin cannot call setCoverageConfiguration
    function test_role_nonAccountantAdmin_cannotSetCoverageConfiguration() public {
        uint64 newCoverage = 0.3e18;
        uint96 newBeta = 0.5e18;
        uint256 newLiquidationUtilization = 3e18;
        bytes memory data = abi.encodeCall(ACCOUNTANT.setCoverageConfiguration, (newCoverage, newBeta, newLiquidationUtilization));

        vm.prank(address(0xBAD));
        vm.expectRevert();
        AM.schedule(address(ACCOUNTANT), data, 0);
    }

    /// @notice Test that ADMIN_ACCOUNTANT_ROLE can call setJuniorTrancheDustTolerance
    function test_role_accountantAdmin_canSetJuniorTrancheDustTolerance() public {
        NAV_UNIT newDustTolerance = toNAVUnits(uint256(200));
        bytes memory data = abi.encodeCall(ACCOUNTANT.setJuniorTrancheDustTolerance, (newDustTolerance));

        // Schedule as accountant admin
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        AM.schedule(address(ACCOUNTANT), data, 0);

        // Advance past execution delay
        vm.warp(block.timestamp + 2 days + 1);

        // Execute
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        AM.execute(address(ACCOUNTANT), data);
    }

    /// @notice Test that non-accountant-admin cannot call setJuniorTrancheDustTolerance
    function test_role_nonAccountantAdmin_cannotSetJuniorTrancheDustTolerance() public {
        NAV_UNIT newDustTolerance = toNAVUnits(uint256(200));
        bytes memory data = abi.encodeCall(ACCOUNTANT.setJuniorTrancheDustTolerance, (newDustTolerance));

        vm.prank(address(0xBAD));
        vm.expectRevert();
        AM.schedule(address(ACCOUNTANT), data, 0);
    }

    /// @notice Test that guardian can cancel setSeniorTrancheSelfLiquidationBonus
    function test_guardian_canCancelSetSelfLiquidationBonus() public {
        uint64 newBonus = 0.05e18;
        bytes memory data = abi.encodeCall(KERNEL.setSeniorTrancheSelfLiquidationBonus, (newBonus));

        vm.prank(KERNEL_ADMIN_ADDRESS);
        AM.schedule(address(KERNEL), data, 0);

        vm.prank(ROLE_GUARDIAN_ADDRESS);
        AM.cancel(KERNEL_ADMIN_ADDRESS, address(KERNEL), data);

        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(KERNEL_ADMIN_ADDRESS);
        vm.expectRevert();
        AM.execute(address(KERNEL), data);
    }

    /// @notice Test that guardian can cancel setYieldShareProtocolFee
    function test_guardian_canCancelSetYieldShareProtocolFee() public {
        uint64 newFee = 0.1e18;
        bytes memory data = abi.encodeCall(ACCOUNTANT.setYieldShareProtocolFee, (newFee));

        vm.prank(PROTOCOL_FEE_SETTER_ADDRESS);
        AM.schedule(address(ACCOUNTANT), data, 0);

        vm.prank(ROLE_GUARDIAN_ADDRESS);
        AM.cancel(PROTOCOL_FEE_SETTER_ADDRESS, address(ACCOUNTANT), data);

        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(PROTOCOL_FEE_SETTER_ADDRESS);
        vm.expectRevert();
        AM.execute(address(ACCOUNTANT), data);
    }

    /// @notice Test that guardian can cancel setCoverageConfiguration
    function test_guardian_canCancelSetCoverageConfiguration() public {
        bytes memory data = abi.encodeCall(ACCOUNTANT.setCoverageConfiguration, (0.3e18, 0.5e18, 0.9e18));

        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        AM.schedule(address(ACCOUNTANT), data, 0);

        vm.prank(ROLE_GUARDIAN_ADDRESS);
        AM.cancel(ACCOUNTANT_ADMIN_ADDRESS, address(ACCOUNTANT), data);

        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        vm.expectRevert();
        AM.execute(address(ACCOUNTANT), data);
    }

    /// @notice Test that guardian can cancel setJuniorTrancheDustTolerance
    function test_guardian_canCancelSetJuniorTrancheDustTolerance() public {
        NAV_UNIT newDustTolerance = toNAVUnits(uint256(200));
        bytes memory data = abi.encodeCall(ACCOUNTANT.setJuniorTrancheDustTolerance, (newDustTolerance));

        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        AM.schedule(address(ACCOUNTANT), data, 0);

        vm.prank(ROLE_GUARDIAN_ADDRESS);
        AM.cancel(ACCOUNTANT_ADMIN_ADDRESS, address(ACCOUNTANT), data);

        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        vm.expectRevert();
        AM.execute(address(ACCOUNTANT), data);
    }

    /// @notice Test that the original caller can also cancel their own scheduled operation
    function test_originalCaller_canCancelOwnOperation() public {
        address newRecipient = address(0x1234);
        bytes memory data = abi.encodeCall(KERNEL.setProtocolFeeRecipient, (newRecipient));

        // Schedule the operation as kernel admin
        vm.prank(KERNEL_ADMIN_ADDRESS);
        AM.schedule(address(KERNEL), data, 0);

        // Kernel admin cancels their own operation
        vm.prank(KERNEL_ADMIN_ADDRESS);
        AM.cancel(KERNEL_ADMIN_ADDRESS, address(KERNEL), data);

        // Verify operation is cancelled
        bytes32 operationId = AM.hashOperation(KERNEL_ADMIN_ADDRESS, address(KERNEL), data);
        assertEq(AM.getSchedule(operationId), 0, "Operation should be cancelled");
    }
}
