// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Initializable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { IAccessManaged } from "../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { IERC4626 } from "../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { UUPSUpgradeable } from "../../lib/openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { DeployScript } from "../../script/Deploy.s.sol";
import { MarketDeploymentConfig } from "../../script/config/MarketDeploymentConfig.sol";
import { RoycoAccountant } from "../../src/accountant/RoycoAccountant.sol";
import { RoycoFactory } from "../../src/factory/RoycoFactory.sol";
import { IRoycoAccountant } from "../../src/interfaces/IRoycoAccountant.sol";
import { IRoycoDawnKernel } from "../../src/interfaces/IRoycoDawnKernel.sol";
import { IRoycoFactory } from "../../src/interfaces/IRoycoFactory.sol";
import { IRoycoVaultTranche } from "../../src/interfaces/IRoycoVaultTranche.sol";
import { Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel } from "../../src/kernels/dawn/Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel.sol";
import { WAD } from "../../src/libraries/Constants.sol";
import { toTrancheUnits } from "../../src/libraries/Units.sol";
import { RoycoJuniorTranche } from "../../src/tranches/RoycoJuniorTranche.sol";
import { RoycoSeniorTranche } from "../../src/tranches/RoycoSeniorTranche.sol";

import { BaseTest } from "../base/BaseTest.t.sol";

/// @title UpgradabilityTestSuite
/// @notice Tests upgradability of all Royco protocol contracts
/// @dev Tests that:
///      1. All contracts (ST, JT, Kernel, Accountant) are upgradeable by ADMIN_UPGRADER_ROLE
///      2. All implementations are non-initializable (constructor disables initializers)
///      3. Upgrades fail when called by non-upgrader addresses
contract UpgradabilityTestSuite is BaseTest {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES (sNUSD for testing)
    // ═══════════════════════════════════════════════════════════════════════════

    address internal constant SNUSD = 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313;
    uint256 internal constant FORK_BLOCK = 24_180_513;

    // ═══════════════════════════════════════════════════════════════════════════
    // NEW IMPLEMENTATION CONTRACTS FOR UPGRADE TESTING
    // ═══════════════════════════════════════════════════════════════════════════

    RoycoSeniorTranche internal newSTImpl;
    RoycoJuniorTranche internal newJTImpl;
    RoycoAccountant internal newAccountantImpl;
    address internal newKernelImpl;

    // ═══════════════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════════════

    function setUp() public {
        _setUpRoyco();
    }

    function _setUpRoyco() internal override {
        super._setUpRoyco();

        // Deploy market using the deployment script
        DeployScript.DeploymentResult memory result = _deployMarket();
        _setDeployedMarket(result);

        // Setup providers
        _setupProviders();

        // Fund providers with sNUSD
        _fundProviders();

        // Deploy new implementations for upgrade testing
        _deployNewImplementations();
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
            ydmSpecificParams: abi.encode(ydmParams),
            transferAgentAddress: address(0)
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

    function _deployNewImplementations() internal {
        newSTImpl = new RoycoSeniorTranche(SNUSD, address(KERNEL));
        vm.label(address(newSTImpl), "NewSTImpl");

        newJTImpl = new RoycoJuniorTranche(SNUSD, address(KERNEL));
        vm.label(address(newJTImpl), "NewJTImpl");

        newAccountantImpl = new RoycoAccountant(address(KERNEL));
        vm.label(address(newAccountantImpl), "NewAccountantImpl");

        IRoycoDawnKernel.RoycoDawnKernelConstructionParams memory constructionParams = IRoycoDawnKernel.RoycoDawnKernelConstructionParams({
            seniorTranche: address(ST),
            stAsset: SNUSD,
            juniorTranche: address(JT),
            jtAsset: SNUSD,
            accountant: address(ACCOUNTANT),
            enforceVaultSharesTransferWhitelist: false
        });

        newKernelImpl = address(new Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel(constructionParams));
        vm.label(newKernelImpl, "NewKernelImpl");
    }

    /// @notice Helper to schedule and execute an upgrade operation (requires 1 day delay for ADMIN_UPGRADER_ROLE)
    function _executeUpgrade(address _proxy, address _newImpl) internal {
        bytes memory upgradeData = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (_newImpl, ""));

        // Schedule the upgrade
        vm.prank(UPGRADER_ADDRESS);
        FACTORY.schedule(_proxy, upgradeData, 0);

        // Wait for the delay to pass
        vm.warp(block.timestamp + 2 days + 1);

        // Execute the upgrade
        vm.prank(UPGRADER_ADDRESS);
        FACTORY.execute(_proxy, upgradeData);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 1: IMPLEMENTATIONS ARE NON-INITIALIZABLE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that ST implementation cannot be initialized
    function test_stImplementation_cannotBeInitialized() external {
        IRoycoVaultTranche.RoycoTrancheInitParams memory params =
            IRoycoVaultTranche.RoycoTrancheInitParams({ name: "Test ST", symbol: "TST", initialAuthority: address(FACTORY) });

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        ST_IMPL.initialize(params);
    }

    /// @notice Test that JT implementation cannot be initialized
    function test_jtImplementation_cannotBeInitialized() external {
        IRoycoVaultTranche.RoycoTrancheInitParams memory params =
            IRoycoVaultTranche.RoycoTrancheInitParams({ name: "Test JT", symbol: "TJT", initialAuthority: address(FACTORY) });

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        JT_IMPL.initialize(params);
    }

    /// @notice Test that Accountant implementation cannot be initialized
    function test_accountantImplementation_cannotBeInitialized() external {
        IRoycoAccountant.RoycoAccountantInitParams memory params = IRoycoAccountant.RoycoAccountantInitParams({
            stProtocolFeeWAD: ST_PROTOCOL_FEE_WAD,
            jtProtocolFeeWAD: JT_PROTOCOL_FEE_WAD,
            yieldShareProtocolFeeWAD: 0,
            coverageWAD: COVERAGE_WAD,
            betaWAD: BETA_WAD,
            liquidationUtilizationWAD: LIQUIDATION_UTILIZATION_WAD,
            ydm: address(YDM),
            ydmInitializationData: "",
            fixedTermDurationSeconds: FIXED_TERM_DURATION_SECONDS,
            stNAVDustTolerance: DUST_TOLERANCE,
            jtNAVDustTolerance: DUST_TOLERANCE
        });

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        ACCOUNTANT_IMPL.initialize(params, address(FACTORY));
    }

    /// @notice Test that Kernel implementation cannot be initialized
    function test_kernelImplementation_cannotBeInitialized() external {
        IRoycoDawnKernel.RoycoDawnKernelInitParams memory params = IRoycoDawnKernel.RoycoDawnKernelInitParams({
            initialAuthority: address(FACTORY), protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT_ADDRESS, stSelfLiquidationBonusWAD: 0
        });

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel(KERNEL_IMPL).initialize(params, WAD);
    }

    /// @notice Test that new ST implementation cannot be initialized
    function test_newSTImplementation_cannotBeInitialized() external {
        IRoycoVaultTranche.RoycoTrancheInitParams memory params =
            IRoycoVaultTranche.RoycoTrancheInitParams({ name: "Test ST", symbol: "TST", initialAuthority: address(FACTORY) });

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        newSTImpl.initialize(params);
    }

    /// @notice Test that new JT implementation cannot be initialized
    function test_newJTImplementation_cannotBeInitialized() external {
        IRoycoVaultTranche.RoycoTrancheInitParams memory params =
            IRoycoVaultTranche.RoycoTrancheInitParams({ name: "Test JT", symbol: "TJT", initialAuthority: address(FACTORY) });

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        newJTImpl.initialize(params);
    }

    /// @notice Test that new Accountant implementation cannot be initialized
    function test_newAccountantImplementation_cannotBeInitialized() external {
        IRoycoAccountant.RoycoAccountantInitParams memory params = IRoycoAccountant.RoycoAccountantInitParams({
            stProtocolFeeWAD: ST_PROTOCOL_FEE_WAD,
            jtProtocolFeeWAD: JT_PROTOCOL_FEE_WAD,
            yieldShareProtocolFeeWAD: 0,
            coverageWAD: COVERAGE_WAD,
            betaWAD: BETA_WAD,
            liquidationUtilizationWAD: LIQUIDATION_UTILIZATION_WAD,
            ydm: address(YDM),
            ydmInitializationData: "",
            fixedTermDurationSeconds: FIXED_TERM_DURATION_SECONDS,
            stNAVDustTolerance: DUST_TOLERANCE,
            jtNAVDustTolerance: DUST_TOLERANCE
        });

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        newAccountantImpl.initialize(params, address(FACTORY));
    }

    /// @notice Test that new Kernel implementation cannot be initialized
    function test_newKernelImplementation_cannotBeInitialized() external {
        IRoycoDawnKernel.RoycoDawnKernelInitParams memory params = IRoycoDawnKernel.RoycoDawnKernelInitParams({
            initialAuthority: address(FACTORY), protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT_ADDRESS, stSelfLiquidationBonusWAD: 0
        });

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel(newKernelImpl).initialize(params, WAD);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 2: UPGRADES BY UPGRADER ROLE SUCCEED
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that ST can be upgraded by upgrader
    function test_stProxy_canBeUpgradedByUpgrader() external {
        uint256 totalSupplyBefore = ST.totalSupply();
        string memory nameBefore = IERC4626(address(ST)).name();

        _executeUpgrade(address(ST), address(newSTImpl));

        assertEq(ST.totalSupply(), totalSupplyBefore, "Total supply should be preserved after upgrade");
        assertEq(IERC4626(address(ST)).name(), nameBefore, "Name should be preserved after upgrade");
    }

    /// @notice Test that JT can be upgraded by upgrader
    function test_jtProxy_canBeUpgradedByUpgrader() external {
        uint256 totalSupplyBefore = JT.totalSupply();
        string memory nameBefore = IERC4626(address(JT)).name();

        _executeUpgrade(address(JT), address(newJTImpl));

        assertEq(JT.totalSupply(), totalSupplyBefore, "Total supply should be preserved after upgrade");
        assertEq(IERC4626(address(JT)).name(), nameBefore, "Name should be preserved after upgrade");
    }

    /// @notice Test that Accountant can be upgraded by upgrader
    function test_accountantProxy_canBeUpgradedByUpgrader() external {
        uint64 coverageBefore = ACCOUNTANT.getState().coverageWAD;
        address kernelBefore = ACCOUNTANT.KERNEL();

        _executeUpgrade(address(ACCOUNTANT), address(newAccountantImpl));

        assertEq(ACCOUNTANT.getState().coverageWAD, coverageBefore, "Coverage should be preserved after upgrade");
        assertEq(ACCOUNTANT.KERNEL(), kernelBefore, "Kernel should be preserved after upgrade");
    }

    /// @notice Test that Kernel can be upgraded by upgrader
    function test_kernelProxy_canBeUpgradedByUpgrader() external {
        address stBefore = KERNEL.SENIOR_TRANCHE();
        address jtBefore = KERNEL.JUNIOR_TRANCHE();
        address accountantBefore = KERNEL.ACCOUNTANT();

        _executeUpgrade(address(KERNEL), newKernelImpl);

        assertEq(KERNEL.SENIOR_TRANCHE(), stBefore, "ST address should be preserved after upgrade");
        assertEq(KERNEL.JUNIOR_TRANCHE(), jtBefore, "JT address should be preserved after upgrade");
        assertEq(KERNEL.ACCOUNTANT(), accountantBefore, "Accountant should be preserved after upgrade");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 3: UPGRADES BY NON-UPGRADER FAIL
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that ST cannot be upgraded by non-upgrader (random user)
    function test_stProxy_cannotBeUpgradedByNonUpgrader() external {
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ALICE_ADDRESS));
        UUPSUpgradeable(address(ST)).upgradeToAndCall(address(newSTImpl), "");
    }

    /// @notice Test that JT cannot be upgraded by non-upgrader (random user)
    function test_jtProxy_cannotBeUpgradedByNonUpgrader() external {
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ALICE_ADDRESS));
        UUPSUpgradeable(address(JT)).upgradeToAndCall(address(newJTImpl), "");
    }

    /// @notice Test that Accountant cannot be upgraded by non-upgrader (random user)
    function test_accountantProxy_cannotBeUpgradedByNonUpgrader() external {
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ALICE_ADDRESS));
        UUPSUpgradeable(address(ACCOUNTANT)).upgradeToAndCall(address(newAccountantImpl), "");
    }

    /// @notice Test that Kernel cannot be upgraded by non-upgrader (random user)
    function test_kernelProxy_cannotBeUpgradedByNonUpgrader() external {
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ALICE_ADDRESS));
        UUPSUpgradeable(address(KERNEL)).upgradeToAndCall(newKernelImpl, "");
    }

    /// @notice Test that ST cannot be upgraded by owner (who is not upgrader)
    function test_stProxy_cannotBeUpgradedByOwner() external {
        vm.prank(OWNER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, OWNER_ADDRESS));
        UUPSUpgradeable(address(ST)).upgradeToAndCall(address(newSTImpl), "");
    }

    /// @notice Test that Kernel cannot be upgraded by pauser
    function test_kernelProxy_cannotBeUpgradedByPauser() external {
        vm.prank(PAUSER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, PAUSER_ADDRESS));
        UUPSUpgradeable(address(KERNEL)).upgradeToAndCall(newKernelImpl, "");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 4: STATE PRESERVATION AFTER UPGRADE WITH DEPOSITS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that JT state is preserved after upgrade with deposits
    function test_jtProxy_statePreservedAfterUpgrade_withDeposits() external {
        uint256 depositAmount = 100_000e18;

        // Deposit to JT
        vm.startPrank(ALICE_ADDRESS);
        IERC20(SNUSD).approve(address(JT), depositAmount);
        uint256 shares = JT.deposit(toTrancheUnits(depositAmount), ALICE_ADDRESS);
        vm.stopPrank();

        // Record state before upgrade
        uint256 totalSupplyBefore = JT.totalSupply();
        uint256 aliceBalanceBefore = JT.balanceOf(ALICE_ADDRESS);

        // Upgrade JT
        _executeUpgrade(address(JT), address(newJTImpl));

        // Verify state is preserved
        assertEq(JT.totalSupply(), totalSupplyBefore, "Total supply should be preserved");
        assertEq(JT.balanceOf(ALICE_ADDRESS), aliceBalanceBefore, "Alice balance should be preserved");
        assertEq(JT.balanceOf(ALICE_ADDRESS), shares, "Shares should match original deposit");
    }

    /// @notice Test that ST state is preserved after upgrade with deposits
    function test_stProxy_statePreservedAfterUpgrade_withDeposits() external {
        uint256 jtDepositAmount = 500_000e18;
        uint256 stDepositAmount = 50_000e18;

        // Deposit to JT first (for coverage)
        vm.startPrank(ALICE_ADDRESS);
        IERC20(SNUSD).approve(address(JT), jtDepositAmount);
        JT.deposit(toTrancheUnits(jtDepositAmount), ALICE_ADDRESS);
        vm.stopPrank();

        // Deposit to ST
        vm.startPrank(BOB_ADDRESS);
        IERC20(SNUSD).approve(address(ST), stDepositAmount);
        uint256 shares = ST.deposit(toTrancheUnits(stDepositAmount), BOB_ADDRESS);
        vm.stopPrank();

        // Record state before upgrade
        uint256 totalSupplyBefore = ST.totalSupply();
        uint256 bobBalanceBefore = ST.balanceOf(BOB_ADDRESS);

        // Upgrade ST
        _executeUpgrade(address(ST), address(newSTImpl));

        // Verify state is preserved
        assertEq(ST.totalSupply(), totalSupplyBefore, "Total supply should be preserved");
        assertEq(ST.balanceOf(BOB_ADDRESS), bobBalanceBefore, "Bob balance should be preserved");
        assertEq(ST.balanceOf(BOB_ADDRESS), shares, "Shares should match original deposit");
    }

    /// @notice Test operations still work after upgrade
    function test_jtProxy_operationsWorkAfterUpgrade() external {
        uint256 depositAmount = 100_000e18;

        // Deposit before upgrade
        vm.startPrank(ALICE_ADDRESS);
        IERC20(SNUSD).approve(address(JT), depositAmount);
        uint256 sharesBefore = JT.deposit(toTrancheUnits(depositAmount), ALICE_ADDRESS);
        vm.stopPrank();

        // Upgrade JT
        _executeUpgrade(address(JT), address(newJTImpl));

        // Deposit after upgrade should still work
        vm.startPrank(JT_BOB_ADDRESS);
        IERC20(SNUSD).approve(address(JT), depositAmount);
        uint256 sharesAfter = JT.deposit(toTrancheUnits(depositAmount), JT_BOB_ADDRESS);
        vm.stopPrank();

        // Both deposits should have resulted in shares
        assertGt(sharesBefore, 0, "Shares before upgrade should be > 0");
        assertGt(sharesAfter, 0, "Shares after upgrade should be > 0");

        // Total supply should reflect both deposits
        assertGe(JT.totalSupply(), sharesBefore + sharesAfter, "Total supply should include both deposits");
    }

    /// @notice Test kernel sync still works after upgrade
    function test_kernelProxy_syncWorksAfterUpgrade() external {
        uint256 depositAmount = 100_000e18;

        // Setup: deposit JT
        vm.startPrank(ALICE_ADDRESS);
        IERC20(SNUSD).approve(address(JT), depositAmount);
        JT.deposit(toTrancheUnits(depositAmount), ALICE_ADDRESS);
        vm.stopPrank();

        // Upgrade kernel
        _executeUpgrade(address(KERNEL), newKernelImpl);

        // Sync should still work after upgrade
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        // Should not revert - sync completed successfully
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 5: FACTORY UPGRADE RESPECTS 1-DAY DELAY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that factory upgrade succeeds after the 1-day delay
    function test_factoryProxy_canBeUpgradedAfterDelay() external {
        // Deploy a new factory implementation
        RoycoFactory newFactoryImpl = new RoycoFactory();
        vm.label(address(newFactoryImpl), "NewFactoryImpl");

        bytes memory upgradeData = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(newFactoryImpl), ""));

        // Schedule the upgrade
        vm.prank(UPGRADER_ADDRESS);
        FACTORY.schedule(address(FACTORY), upgradeData, 0);

        // Warp past the 2-day delay
        vm.warp(block.timestamp + 2 days + 1);

        // Execute the upgrade — should succeed
        vm.prank(UPGRADER_ADDRESS);
        FACTORY.execute(address(FACTORY), upgradeData);
    }

    /// @notice Test that factory upgrade reverts before the 2-day delay elapses
    function test_factoryProxy_cannotBeUpgradedBeforeDelay() external {
        // Deploy a new factory implementation
        RoycoFactory newFactoryImpl = new RoycoFactory();
        vm.label(address(newFactoryImpl), "NewFactoryImpl");

        bytes memory upgradeData = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(newFactoryImpl), ""));

        // Schedule the upgrade
        vm.prank(UPGRADER_ADDRESS);
        FACTORY.schedule(address(FACTORY), upgradeData, 0);

        // Warp to just before the delay expires
        vm.warp(block.timestamp + 2 days - 1);

        // Execute should revert — delay not yet elapsed
        vm.prank(UPGRADER_ADDRESS);
        vm.expectRevert();
        FACTORY.execute(address(FACTORY), upgradeData);
    }
}
