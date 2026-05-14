// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { PausableUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { IAccessManaged } from "../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Pausable } from "../../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import { DeployScript } from "../../script/Deploy.s.sol";
import { MarketDeploymentConfig } from "../../script/config/MarketDeploymentConfig.sol";
import { IRoycoAuth } from "../../src/interfaces/IRoycoAuth.sol";
import { IRoycoFactory } from "../../src/interfaces/IRoycoFactory.sol";
import { WAD } from "../../src/libraries/Constants.sol";
import { toTrancheUnits } from "../../src/libraries/Units.sol";
import { BaseTest } from "../base/BaseTest.t.sol";

/// @title PausabilityTestSuite
/// @notice Tests pausability of all Royco protocol contracts
/// @dev Tests that:
///      1. Pausing by ADMIN_PAUSER_ROLE succeeds for all contracts
///      2. Unpausing by ADMIN_PAUSER_ROLE succeeds for all contracts
///      3. Pausing/unpausing by non-pauser fails
///      4. Operations are blocked when paused
///      5. Operations work again after unpausing
contract PausabilityTestSuite is BaseTest {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES (sNUSD for testing)
    // ═══════════════════════════════════════════════════════════════════════════

    address internal constant SNUSD = 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313;
    uint256 internal constant FORK_BLOCK = 24_180_513;

    // ═══════════════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════════════

    function setUp() public {
        _setUpRoyco();
    }

    function _setUpRoyco() internal override {
        super._setUpRoyco();

        DeployScript.DeploymentResult memory result = _deployMarket();
        _setDeployedMarket(result);

        _setupProviders();
        _fundProviders();
    }

    function _forkConfiguration() internal view override returns (uint256 forkBlock, string memory forkRpcUrl) {
        forkBlock = FORK_BLOCK;
        forkRpcUrl = vm.envString("MAINNET_RPC_URL");
    }

    function _deployMarket() internal returns (DeployScript.DeploymentResult memory) {
        DeployScript.IdenticalERC4626SharesToAdminOracleQuoterKernelParams memory kernelParams =
            DeployScript.IdenticalERC4626SharesToAdminOracleQuoterKernelParams({ initialConversionRateWAD: WAD });

        DeployScript.AdaptiveCurveYDM_V2_Params memory ydmParams = DeployScript.AdaptiveCurveYDM_V2_Params({
            jtYieldShareAtZeroUtilWAD: 0.3e18, // Y_0 = Y_T (same as target)
            jtYieldShareAtTargetUtilWAD: 0.3e18,
            jtYieldShareAtFullUtilWAD: 1e18,
            maxAdaptationSpeedWAD: uint64(30e18 / uint256(365 days))
        });

        // Build role assignments using the centralized function
        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        MarketDeploymentConfig.MarketConfig memory config = MarketDeploymentConfig.MarketConfig({
            marketName: "sNUSD",
            chainId: block.chainid,
            seniorTrancheName: "Royco Senior sNUSD",
            seniorTrancheSymbol: "RS-sNUSD",
            juniorTrancheName: "Royco Junior sNUSD",
            juniorTrancheSymbol: "RJ-sNUSD",
            seniorAsset: SNUSD,
            juniorAsset: SNUSD,
            stDustTolerance: 1,
            jtDustTolerance: 1,
            kernelType: DeployScript.KernelType.Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel,
            kernelSpecificParams: abi.encode(kernelParams),
            stSelfLiquidationBonusWAD: 0,
            enforceVaultSharesTransferWhitelist: false,
            stProtocolFeeWAD: ST_PROTOCOL_FEE_WAD,
            jtProtocolFeeWAD: JT_PROTOCOL_FEE_WAD,
            jtYieldShareProtocolFeeWAD: JT_PROTOCOL_FEE_WAD,
            coverageWAD: COVERAGE_WAD,
            betaWAD: 1e18,
            liquidationUtilizationWAD: LIQUIDATION_UTILIZATION_WAD,
            fixedTermDurationSeconds: FIXED_TERM_DURATION_SECONDS,
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            transferAgentAddress: address(0),
            ydmSpecificParams: abi.encode(ydmParams)
        });

        uint32 scheduledOperationsExpirySeconds = DEPLOY_SCRIPT.getChainConfig(block.chainid).scheduledOperationsExpirySeconds;
        return
            DEPLOY_SCRIPT.deploy(config, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, scheduledOperationsExpirySeconds, roleAssignments, DEPLOYER.privateKey);
    }

    function _fundProviders() internal {
        uint256 amount = 1_000_000e18;
        deal(SNUSD, ST_ALICE_ADDRESS, amount);
        deal(SNUSD, JT_ALICE_ADDRESS, amount);
        deal(SNUSD, ST_BOB_ADDRESS, amount);
        deal(SNUSD, JT_BOB_ADDRESS, amount);
        deal(SNUSD, ST_CHARLIE_ADDRESS, amount);
        deal(SNUSD, JT_CHARLIE_ADDRESS, amount);
        deal(SNUSD, ST_DAN_ADDRESS, amount);
        deal(SNUSD, JT_DAN_ADDRESS, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 1: PAUSING BY PAUSER ROLE SUCCEEDS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that ST can be paused by pauser
    function test_stTranche_canBePausedByPauser() external {
        assertFalse(PausableUpgradeable(address(ST)).paused(), "ST should not be paused initially");

        vm.prank(PAUSER_ADDRESS);
        IRoycoAuth(address(ST)).pause();

        assertTrue(PausableUpgradeable(address(ST)).paused(), "ST should be paused after pause()");
    }

    /// @notice Test that JT can be paused by pauser
    function test_jtTranche_canBePausedByPauser() external {
        assertFalse(PausableUpgradeable(address(JT)).paused(), "JT should not be paused initially");

        vm.prank(PAUSER_ADDRESS);
        IRoycoAuth(address(JT)).pause();

        assertTrue(PausableUpgradeable(address(JT)).paused(), "JT should be paused after pause()");
    }

    /// @notice Test that Kernel can be paused by pauser
    function test_kernel_canBePausedByPauser() external {
        assertFalse(PausableUpgradeable(address(KERNEL)).paused(), "Kernel should not be paused initially");

        vm.prank(PAUSER_ADDRESS);
        IRoycoAuth(address(KERNEL)).pause();

        assertTrue(PausableUpgradeable(address(KERNEL)).paused(), "Kernel should be paused after pause()");
    }

    /// @notice Test that Accountant can be paused by pauser
    function test_accountant_canBePausedByPauser() external {
        assertFalse(PausableUpgradeable(address(ACCOUNTANT)).paused(), "Accountant should not be paused initially");

        vm.prank(PAUSER_ADDRESS);
        IRoycoAuth(address(ACCOUNTANT)).pause();

        assertTrue(PausableUpgradeable(address(ACCOUNTANT)).paused(), "Accountant should be paused after pause()");
    }

    /// @notice Schedules + waits + executes `unpause()` on the given target.
    /// @dev `unpause` is gated on `ADMIN_UNPAUSER_ROLE` (Standard, 24h delay), so a direct
    ///      call from `UNPAUSER_ADDRESS` would revert. Tests use this helper to run the
    ///      full schedule → warp → execute flow against the factory.
    function _scheduleAndExecuteUnpause(address _target) internal {
        bytes memory data = abi.encodeCall(IRoycoAuth.unpause, ());
        vm.prank(UNPAUSER_ADDRESS);
        FACTORY.schedule(_target, data, 0);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(UNPAUSER_ADDRESS);
        FACTORY.execute(_target, data);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 2: UNPAUSING BY PAUSER ROLE SUCCEEDS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that ST can be unpaused by unpauser (after the Standard 24h delay)
    function test_stTranche_canBeUnpausedByPauser() external {
        vm.prank(PAUSER_ADDRESS);
        IRoycoAuth(address(ST)).pause();
        assertTrue(PausableUpgradeable(address(ST)).paused(), "ST should be paused");

        _scheduleAndExecuteUnpause(address(ST));
        assertFalse(PausableUpgradeable(address(ST)).paused(), "ST should be unpaused after unpause()");
    }

    /// @notice Test that JT can be unpaused by unpauser (after the Standard 24h delay)
    function test_jtTranche_canBeUnpausedByPauser() external {
        vm.prank(PAUSER_ADDRESS);
        IRoycoAuth(address(JT)).pause();
        assertTrue(PausableUpgradeable(address(JT)).paused(), "JT should be paused");

        _scheduleAndExecuteUnpause(address(JT));
        assertFalse(PausableUpgradeable(address(JT)).paused(), "JT should be unpaused after unpause()");
    }

    /// @notice Test that Kernel can be unpaused by unpauser (after the Standard 24h delay)
    function test_kernel_canBeUnpausedByPauser() external {
        vm.prank(PAUSER_ADDRESS);
        IRoycoAuth(address(KERNEL)).pause();
        assertTrue(PausableUpgradeable(address(KERNEL)).paused(), "Kernel should be paused");

        _scheduleAndExecuteUnpause(address(KERNEL));
        assertFalse(PausableUpgradeable(address(KERNEL)).paused(), "Kernel should be unpaused after unpause()");
    }

    /// @notice Test that Accountant can be unpaused by unpauser (after the Standard 24h delay)
    function test_accountant_canBeUnpausedByPauser() external {
        vm.prank(PAUSER_ADDRESS);
        IRoycoAuth(address(ACCOUNTANT)).pause();
        assertTrue(PausableUpgradeable(address(ACCOUNTANT)).paused(), "Accountant should be paused");

        _scheduleAndExecuteUnpause(address(ACCOUNTANT));
        assertFalse(PausableUpgradeable(address(ACCOUNTANT)).paused(), "Accountant should be unpaused after unpause()");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 3: PAUSING BY NON-PAUSER FAILS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that ST cannot be paused by non-pauser
    function test_stTranche_cannotBePausedByNonPauser() external {
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ALICE_ADDRESS));
        IRoycoAuth(address(ST)).pause();
    }

    /// @notice Test that JT cannot be paused by non-pauser
    function test_jtTranche_cannotBePausedByNonPauser() external {
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ALICE_ADDRESS));
        IRoycoAuth(address(JT)).pause();
    }

    /// @notice Test that Kernel cannot be paused by non-pauser
    function test_kernel_cannotBePausedByNonPauser() external {
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ALICE_ADDRESS));
        IRoycoAuth(address(KERNEL)).pause();
    }

    /// @notice Test that Accountant cannot be paused by non-pauser
    function test_accountant_cannotBePausedByNonPauser() external {
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ALICE_ADDRESS));
        IRoycoAuth(address(ACCOUNTANT)).pause();
    }

    /// @notice Test that ST cannot be paused by owner (who is not pauser)
    function test_stTranche_cannotBePausedByOwner() external {
        vm.prank(OWNER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, OWNER_ADDRESS));
        IRoycoAuth(address(ST)).pause();
    }

    /// @notice Test that Kernel cannot be paused by upgrader
    function test_kernel_cannotBePausedByUpgrader() external {
        vm.prank(UPGRADER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, UPGRADER_ADDRESS));
        IRoycoAuth(address(KERNEL)).pause();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 4: UNPAUSING BY NON-PAUSER FAILS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that ST cannot be unpaused by non-pauser
    function test_stTranche_cannotBeUnpausedByNonPauser() external {
        vm.prank(PAUSER_ADDRESS);
        IRoycoAuth(address(ST)).pause();

        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ALICE_ADDRESS));
        IRoycoAuth(address(ST)).unpause();
    }

    /// @notice Test that JT cannot be unpaused by non-pauser
    function test_jtTranche_cannotBeUnpausedByNonPauser() external {
        vm.prank(PAUSER_ADDRESS);
        IRoycoAuth(address(JT)).pause();

        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ALICE_ADDRESS));
        IRoycoAuth(address(JT)).unpause();
    }

    /// @notice Test that Kernel cannot be unpaused by non-pauser
    function test_kernel_cannotBeUnpausedByNonPauser() external {
        vm.prank(PAUSER_ADDRESS);
        IRoycoAuth(address(KERNEL)).pause();

        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ALICE_ADDRESS));
        IRoycoAuth(address(KERNEL)).unpause();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 5: OPERATIONS BLOCKED WHEN PAUSED
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that JT deposit is blocked when JT is paused
    function test_jtDeposit_blockedWhenJTPaused() external {
        uint256 depositAmount = 100_000e18;

        vm.prank(PAUSER_ADDRESS);
        IRoycoAuth(address(JT)).pause();

        vm.startPrank(ALICE_ADDRESS);
        IERC20(SNUSD).approve(address(JT), depositAmount);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        JT.deposit(toTrancheUnits(depositAmount), ALICE_ADDRESS);
        vm.stopPrank();
    }

    /// @notice Test that ST deposit is blocked when ST is paused
    function test_stDeposit_blockedWhenSTPaused() external {
        uint256 jtAmount = 500_000e18;
        uint256 stAmount = 50_000e18;

        // First deposit JT for coverage
        vm.startPrank(ALICE_ADDRESS);
        IERC20(SNUSD).approve(address(JT), jtAmount);
        JT.deposit(toTrancheUnits(jtAmount), ALICE_ADDRESS);
        vm.stopPrank();

        // Pause ST
        vm.prank(PAUSER_ADDRESS);
        IRoycoAuth(address(ST)).pause();

        // Try to deposit ST - should fail
        vm.startPrank(BOB_ADDRESS);
        IERC20(SNUSD).approve(address(ST), stAmount);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        ST.deposit(toTrancheUnits(stAmount), BOB_ADDRESS);
        vm.stopPrank();
    }

    /// @notice Test that JT redeem request is blocked when JT is paused
    function test_jtRequestRedeem_blockedWhenJTPaused() external {
        uint256 depositAmount = 100_000e18;

        // First deposit JT
        vm.startPrank(ALICE_ADDRESS);
        IERC20(SNUSD).approve(address(JT), depositAmount);
        uint256 shares = JT.deposit(toTrancheUnits(depositAmount), ALICE_ADDRESS);
        vm.stopPrank();

        // Pause JT
        vm.prank(PAUSER_ADDRESS);
        IRoycoAuth(address(JT)).pause();

        // Try to redeem - should fail
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        JT.redeem(shares, ALICE_ADDRESS, ALICE_ADDRESS);
    }

    /// @notice Test that ST redeem is blocked when ST is paused
    function test_stRedeem_blockedWhenSTPaused() external {
        uint256 jtAmount = 500_000e18;
        uint256 stAmount = 50_000e18;

        // Deposit JT for coverage
        vm.startPrank(ALICE_ADDRESS);
        IERC20(SNUSD).approve(address(JT), jtAmount);
        JT.deposit(toTrancheUnits(jtAmount), ALICE_ADDRESS);
        vm.stopPrank();

        // Deposit ST
        vm.startPrank(BOB_ADDRESS);
        IERC20(SNUSD).approve(address(ST), stAmount);
        uint256 shares = ST.deposit(toTrancheUnits(stAmount), BOB_ADDRESS);
        vm.stopPrank();

        // Pause ST
        vm.prank(PAUSER_ADDRESS);
        IRoycoAuth(address(ST)).pause();

        // Try to redeem - should fail
        vm.prank(BOB_ADDRESS);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        ST.redeem(shares, BOB_ADDRESS, BOB_ADDRESS);
    }

    /// @notice Test that kernel sync is blocked when kernel is paused
    function test_kernelSync_blockedWhenKernelPaused() external {
        uint256 depositAmount = 100_000e18;

        // First deposit JT
        vm.startPrank(ALICE_ADDRESS);
        IERC20(SNUSD).approve(address(JT), depositAmount);
        JT.deposit(toTrancheUnits(depositAmount), ALICE_ADDRESS);
        vm.stopPrank();

        // Pause kernel
        vm.prank(PAUSER_ADDRESS);
        IRoycoAuth(address(KERNEL)).pause();

        // Try to sync - should fail
        vm.prank(SYNC_ROLE_ADDRESS);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        KERNEL.syncTrancheAccounting();
    }

    /// @notice Test that ERC20 transfer is blocked when tranche is paused
    function test_jtTransfer_blockedWhenJTPaused() external {
        uint256 depositAmount = 100_000e18;

        // First deposit JT
        vm.startPrank(ALICE_ADDRESS);
        IERC20(SNUSD).approve(address(JT), depositAmount);
        uint256 shares = JT.deposit(toTrancheUnits(depositAmount), ALICE_ADDRESS);
        vm.stopPrank();

        // Pause JT
        vm.prank(PAUSER_ADDRESS);
        IRoycoAuth(address(JT)).pause();

        // Try to transfer - should fail
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        IERC20(address(JT)).transfer(BOB_ADDRESS, shares);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 6: OPERATIONS WORK AFTER UNPAUSING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that JT deposit works after unpausing
    function test_jtDeposit_worksAfterUnpausing() external {
        uint256 depositAmount = 100_000e18;

        // Pause and unpause JT
        vm.prank(PAUSER_ADDRESS);
        IRoycoAuth(address(JT)).pause();

        _scheduleAndExecuteUnpause(address(JT));

        // Deposit should work
        vm.startPrank(ALICE_ADDRESS);
        IERC20(SNUSD).approve(address(JT), depositAmount);
        uint256 shares = JT.deposit(toTrancheUnits(depositAmount), ALICE_ADDRESS);
        vm.stopPrank();

        assertGt(shares, 0, "Shares should be > 0 after deposit");
    }

    /// @notice Test that kernel sync works after unpausing
    function test_kernelSync_worksAfterUnpausing() external {
        uint256 depositAmount = 100_000e18;

        // First deposit JT
        vm.startPrank(ALICE_ADDRESS);
        IERC20(SNUSD).approve(address(JT), depositAmount);
        JT.deposit(toTrancheUnits(depositAmount), ALICE_ADDRESS);
        vm.stopPrank();

        // Pause and unpause kernel
        vm.prank(PAUSER_ADDRESS);
        IRoycoAuth(address(KERNEL)).pause();

        _scheduleAndExecuteUnpause(address(KERNEL));

        // Sync should work
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();
    }

    /// @notice Test that ERC20 transfer works after unpausing
    function test_jtTransfer_worksAfterUnpausing() external {
        uint256 depositAmount = 100_000e18;

        // First deposit JT
        vm.startPrank(ALICE_ADDRESS);
        IERC20(SNUSD).approve(address(JT), depositAmount);
        uint256 shares = JT.deposit(toTrancheUnits(depositAmount), ALICE_ADDRESS);
        vm.stopPrank();

        // Pause and unpause JT
        vm.prank(PAUSER_ADDRESS);
        IRoycoAuth(address(JT)).pause();

        _scheduleAndExecuteUnpause(address(JT));

        // Transfer should work
        vm.prank(ALICE_ADDRESS);
        IERC20(address(JT)).transfer(JT_BOB_ADDRESS, shares / 2);

        assertEq(IERC20(address(JT)).balanceOf(JT_BOB_ADDRESS), shares / 2, "JT_BOB should have received shares");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 7: INDEPENDENT PAUSING (ONE CONTRACT PAUSED DOESN'T AFFECT OTHERS)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that pausing ST doesn't affect JT operations
    function test_pausingST_doesNotAffectJT() external {
        uint256 depositAmount = 100_000e18;

        // Pause ST only
        vm.prank(PAUSER_ADDRESS);
        IRoycoAuth(address(ST)).pause();

        // JT deposit should still work
        vm.startPrank(ALICE_ADDRESS);
        IERC20(SNUSD).approve(address(JT), depositAmount);
        uint256 shares = JT.deposit(toTrancheUnits(depositAmount), ALICE_ADDRESS);
        vm.stopPrank();

        assertGt(shares, 0, "JT deposit should work when only ST is paused");
    }

    /// @notice Test that pausing JT doesn't affect ST operations
    function test_pausingJT_doesNotAffectST() external {
        uint256 jtAmount = 500_000e18;
        uint256 stAmount = 50_000e18;

        // First deposit JT for coverage (before pausing)
        vm.startPrank(ALICE_ADDRESS);
        IERC20(SNUSD).approve(address(JT), jtAmount);
        JT.deposit(toTrancheUnits(jtAmount), ALICE_ADDRESS);
        vm.stopPrank();

        // Pause JT only
        vm.prank(PAUSER_ADDRESS);
        IRoycoAuth(address(JT)).pause();

        // ST deposit should still work
        vm.startPrank(BOB_ADDRESS);
        IERC20(SNUSD).approve(address(ST), stAmount);
        uint256 shares = ST.deposit(toTrancheUnits(stAmount), BOB_ADDRESS);
        vm.stopPrank();

        assertGt(shares, 0, "ST deposit should work when only JT is paused");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 8: PAUSE EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that Paused event is emitted when pausing
    function test_pause_emitsPausedEvent() external {
        vm.prank(PAUSER_ADDRESS);
        vm.expectEmit(true, true, true, true, address(JT));
        emit Pausable.Paused(PAUSER_ADDRESS);
        IRoycoAuth(address(JT)).pause();
    }

    /// @notice Test that Unpaused event is emitted when unpausing
    /// @dev The unpause is routed through the AccessManager's scheduled-execute path, so the
    ///      `Unpaused` event sender is the factory, not the unpauser EOA.
    function test_unpause_emitsUnpausedEvent() external {
        vm.prank(PAUSER_ADDRESS);
        IRoycoAuth(address(JT)).pause();

        bytes memory data = abi.encodeCall(IRoycoAuth.unpause, ());
        vm.prank(UNPAUSER_ADDRESS);
        FACTORY.schedule(address(JT), data, 0);
        vm.warp(vm.getBlockTimestamp() + 1 days);

        vm.expectEmit(true, true, true, true, address(JT));
        emit Pausable.Unpaused(address(FACTORY));
        vm.prank(UNPAUSER_ADDRESS);
        FACTORY.execute(address(JT), data);
    }
}
