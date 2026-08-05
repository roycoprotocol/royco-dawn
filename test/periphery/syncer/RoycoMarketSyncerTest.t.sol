// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Vm } from "../../../lib/forge-std/src/Vm.sol";
import { PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ExtraRoles } from "../../../script/config/ExtraRoles.sol";
import { DeploySyncerScript } from "../../../script/independent/DeploySyncer.s.sol";
import { RoycoBase } from "../../../src/base/RoycoBase.sol";
import { RolesConfiguration } from "../../../src/factory/RolesConfiguration.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";
import { IRoycoAuth } from "../../../src/interfaces/IRoycoAuth.sol";
import { IRoycoFactory } from "../../../src/interfaces/IRoycoFactory.sol";
import { RoycoMarketSyncer } from "../../../src/periphery/RoycoMarketSyncer.sol";

/// @dev Mock kernel contract for testing with configurable revert behavior
contract MockKernel {
    address public immutable SENIOR_TRANCHE;
    uint256 public syncCallCount;

    enum RevertType {
        None,
        StringRevert,
        CustomError,
        EmptyRevert,
        Panic,
        LargeError
    }

    RevertType public revertType;
    uint256 public largeErrorSize;

    error CustomSyncError(uint256 code, string reason);
    error LargeError(bytes data);

    constructor(address _seniorTranche) {
        SENIOR_TRANCHE = _seniorTranche;
    }

    function setRevertType(RevertType _revertType) external {
        revertType = _revertType;
    }

    function setLargeErrorSize(uint256 _size) external {
        largeErrorSize = _size;
    }

    // Legacy setters for backwards compatibility with existing tests
    function setShouldRevert(bool _shouldRevert) external {
        revertType = _shouldRevert ? RevertType.StringRevert : RevertType.None;
    }

    function setShouldRevertWithCustomError(bool _shouldRevert) external {
        revertType = _shouldRevert ? RevertType.CustomError : RevertType.None;
    }

    function syncTrancheAccounting() external {
        if (revertType == RevertType.CustomError) {
            revert CustomSyncError(42, "custom error");
        }
        if (revertType == RevertType.StringRevert) {
            revert("MockKernel: sync failed");
        }
        if (revertType == RevertType.EmptyRevert) {
            revert();
        }
        if (revertType == RevertType.Panic) {
            assert(false);
        }
        if (revertType == RevertType.LargeError) {
            uint256 size = largeErrorSize > 0 ? largeErrorSize : 1024;
            bytes memory largeData = new bytes(size);
            for (uint256 i = 0; i < size; i++) {
                largeData[i] = bytes1(uint8(i % 256));
            }
            revert LargeError(largeData);
        }
        syncCallCount++;
    }
}

/// @dev Mock tranche contract for testing
contract MockTranche {
    address public immutable KERNEL;

    constructor(address _kernel) {
        KERNEL = _kernel;
    }
}

/**
 * @title RoycoMarketSyncerTest
 * @notice Comprehensive test suite for the RoycoMarketSyncer contract
 * @dev Uses the DeploySyncer script to deploy the syncer and configures roles using
 *      production configuration from buildSyncerConfigTransactions.
 *      Tests are 1:1 with production role assignments:
 *      - SYNC_ROLE: executeBatchAccountingSync, executeBatchAccountingSyncFor, addMarketKernels, removeMarketKernels
 *      - ADMIN_PAUSER_ROLE: pause, unpause
 *      - ADMIN_UPGRADER_ROLE: upgradeToAndCall
 */
contract RoycoMarketSyncerTest is Test, RolesConfiguration, ExtraRoles {
    // ═══════════════════════════════════════════════════════════════════════════
    // TEST STATE
    // ═══════════════════════════════════════════════════════════════════════════

    DeploySyncerScript internal deployScript;
    RoycoMarketSyncer internal syncer;
    RoycoFactory internal factory;

    // Mock kernels and tranches
    MockKernel internal mockKernel1;
    MockKernel internal mockKernel2;
    MockKernel internal mockKernel3;
    MockTranche internal mockTranche1;
    MockTranche internal mockTranche2;
    MockTranche internal mockTranche3;

    // Test wallets
    Vm.Wallet internal FACTORY_ADMIN;
    address internal FACTORY_ADMIN_ADDRESS;

    Vm.Wallet internal DEPLOYER;
    address internal DEPLOYER_ADDRESS;

    Vm.Wallet internal SYNC_OPERATOR;
    address internal SYNC_OPERATOR_ADDRESS;

    Vm.Wallet internal PAUSER;
    address internal PAUSER_ADDRESS;

    Vm.Wallet internal UNAUTHORIZED_USER;
    address internal UNAUTHORIZED_USER_ADDRESS;

    // ═══════════════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════════════

    function setUp() public {
        // Setup wallets
        _setupWallets();

        // Deploy CREATE2 factory (deterministic deployer)
        _deployCreate2Factory();

        // Deploy real RoycoFactory
        _deployFactory();

        // Deploy mock kernels and tranches
        _deployMockKernelsAndTranches();

        // Deploy syncer using the deployment script
        deployScript = new DeploySyncerScript();
        address[] memory emptyKernels = new address[](0);
        address syncerAddr = deployScript.deploySyncer(address(factory), emptyKernels, DEPLOYER.privateKey);
        syncer = RoycoMarketSyncer(syncerAddr);

        // Label contracts for debugging
        vm.label(address(syncer), "Syncer");
        vm.label(address(factory), "Factory");
        vm.label(address(mockKernel1), "MockKernel1");
        vm.label(address(mockKernel2), "MockKernel2");
        vm.label(address(mockKernel3), "MockKernel3");

        // Configure roles using production configuration
        _configureProductionRoles();

        // Setup mock kernel validation on factory
        _setupKernelValidation();
    }

    function _setupWallets() internal {
        FACTORY_ADMIN = vm.createWallet("FACTORY_ADMIN");
        FACTORY_ADMIN_ADDRESS = FACTORY_ADMIN.addr;
        vm.label(FACTORY_ADMIN_ADDRESS, "FACTORY_ADMIN");
        vm.deal(FACTORY_ADMIN_ADDRESS, 100 ether);

        DEPLOYER = vm.createWallet("DEPLOYER");
        DEPLOYER_ADDRESS = DEPLOYER.addr;
        vm.label(DEPLOYER_ADDRESS, "DEPLOYER");
        vm.deal(DEPLOYER_ADDRESS, 100 ether);

        SYNC_OPERATOR = vm.createWallet("SYNC_OPERATOR");
        SYNC_OPERATOR_ADDRESS = SYNC_OPERATOR.addr;
        vm.label(SYNC_OPERATOR_ADDRESS, "SYNC_OPERATOR");
        vm.deal(SYNC_OPERATOR_ADDRESS, 100 ether);

        PAUSER = vm.createWallet("PAUSER");
        PAUSER_ADDRESS = PAUSER.addr;
        vm.label(PAUSER_ADDRESS, "PAUSER");
        vm.deal(PAUSER_ADDRESS, 100 ether);

        UNAUTHORIZED_USER = vm.createWallet("UNAUTHORIZED_USER");
        UNAUTHORIZED_USER_ADDRESS = UNAUTHORIZED_USER.addr;
        vm.label(UNAUTHORIZED_USER_ADDRESS, "UNAUTHORIZED_USER");
        vm.deal(UNAUTHORIZED_USER_ADDRESS, 100 ether);
    }

    function _deployCreate2Factory() internal {
        // Deploy the deterministic CREATE2 factory
        // This is the standard CREATE2 deployer bytecode
        bytes memory create2FactoryBytecode =
            hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
        vm.etch(CREATE2_FACTORY, create2FactoryBytecode);
    }

    function _deployFactory() internal {
        // Deploy factory implementation
        RoycoFactory factoryImpl = new RoycoFactory();

        // Create empty role assignments array (we'll configure roles after syncer deployment)
        IRoycoFactory.RoleAssignmentConfiguration[] memory emptyRoles = new IRoycoFactory.RoleAssignmentConfiguration[](0);

        // Deploy factory proxy with initialization
        // _admin, _deployer, _scheduledOperationsExpirySeconds, _roles
        bytes memory initData = abi.encodeCall(RoycoFactory.initialize, (FACTORY_ADMIN_ADDRESS, DEPLOYER_ADDRESS, 7 days, emptyRoles));
        ERC1967Proxy factoryProxy = new ERC1967Proxy(address(factoryImpl), initData);
        factory = RoycoFactory(address(factoryProxy));
    }

    function _deployMockKernelsAndTranches() internal {
        // Create mock tranche addresses
        address tranche1Addr = makeAddr("Tranche1");
        address tranche2Addr = makeAddr("Tranche2");
        address tranche3Addr = makeAddr("Tranche3");

        // Deploy kernels pointing to tranche addresses
        mockKernel1 = new MockKernel(tranche1Addr);
        mockKernel2 = new MockKernel(tranche2Addr);
        mockKernel3 = new MockKernel(tranche3Addr);

        // Deploy tranches pointing back to kernels
        mockTranche1 = new MockTranche(address(mockKernel1));
        mockTranche2 = new MockTranche(address(mockKernel2));
        mockTranche3 = new MockTranche(address(mockKernel3));

        // Mock the tranche addresses to have the MockTranche code
        vm.etch(tranche1Addr, address(mockTranche1).code);
        vm.etch(tranche2Addr, address(mockTranche2).code);
        vm.etch(tranche3Addr, address(mockTranche3).code);

        // Store the KERNEL slot in the tranche contracts (slot 0 for immutable KERNEL)
        vm.store(tranche1Addr, bytes32(0), bytes32(uint256(uint160(address(mockKernel1)))));
        vm.store(tranche2Addr, bytes32(0), bytes32(uint256(uint160(address(mockKernel2)))));
        vm.store(tranche3Addr, bytes32(0), bytes32(uint256(uint160(address(mockKernel3)))));
    }

    function _configureProductionRoles() internal {
        // Build sync operators array (production: this would be the sync bot/keeper addresses)
        address[] memory syncOperators = new address[](1);
        syncOperators[0] = SYNC_OPERATOR_ADDRESS;

        // Get production role configuration transactions from the deployment script
        // This includes both setTargetFunctionRole AND grantRole for sync operators
        DeploySyncerScript.SafeTransaction[] memory transactions = deployScript.buildSyncerConfigTransactions(address(factory), address(syncer), syncOperators);

        // Execute each transaction as the factory admin to configure roles
        vm.startPrank(FACTORY_ADMIN_ADDRESS);
        for (uint256 i = 0; i < transactions.length; i++) {
            (bool success,) = transactions[i].to.call(transactions[i].data);
            require(success, "Failed to configure syncer roles");
        }
        vm.stopPrank();

        // Grant ADMIN_PAUSER_ROLE to PAUSER (not included in buildSyncerConfigTransactions)
        vm.prank(FACTORY_ADMIN_ADDRESS);
        factory.grantRole(ADMIN_PAUSER_ROLE, PAUSER_ADDRESS, 0);

        // Grant ADMIN_UNPAUSER_ROLE to PAUSER as well, with delay 0 (test convenience).
        // In production this role is held by FNDN with a 1-day Standard delay; the
        // delay-enforcement tests live in `test/access/RoleDelaysTest.t.sol`.
        vm.prank(FACTORY_ADMIN_ADDRESS);
        factory.grantRole(ADMIN_UNPAUSER_ROLE, PAUSER_ADDRESS, 0);

        // Grant ADMIN_UPGRADER_ROLE to DEPLOYER (not included in buildSyncerConfigTransactions)
        vm.prank(FACTORY_ADMIN_ADDRESS);
        factory.grantRole(ADMIN_UPGRADER_ROLE, DEPLOYER_ADDRESS, 0);
    }

    function _setupKernelValidation() internal {
        // Mock factory's seniorTrancheToJuniorTranche to return valid junior tranche for valid kernels
        // This is necessary because we're using mock kernels that weren't deployed via the factory
        vm.mockCall(
            address(factory),
            abi.encodeWithSelector(IRoycoFactory.seniorTrancheToJuniorTranche.selector, mockKernel1.SENIOR_TRANCHE()),
            abi.encode(makeAddr("JuniorTranche1"))
        );

        vm.mockCall(
            address(factory),
            abi.encodeWithSelector(IRoycoFactory.seniorTrancheToJuniorTranche.selector, mockKernel2.SENIOR_TRANCHE()),
            abi.encode(makeAddr("JuniorTranche2"))
        );

        vm.mockCall(
            address(factory),
            abi.encodeWithSelector(IRoycoFactory.seniorTrancheToJuniorTranche.selector, mockKernel3.SENIOR_TRANCHE()),
            abi.encode(makeAddr("JuniorTranche3"))
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Helper to add kernels with proper permissions (SYNC_ROLE in production)
    function _addKernels(address[] memory kernels) internal {
        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.addMarketKernels(kernels);
    }

    /// @notice Helper to remove kernels with proper permissions (SYNC_ROLE in production)
    function _removeKernels(address[] memory kernels) internal {
        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.removeMarketKernels(kernels);
    }

    /// @notice Helper to get all mock kernels as array
    function _getAllKernels() internal view returns (address[] memory) {
        address[] memory kernels = new address[](3);
        kernels[0] = address(mockKernel1);
        kernels[1] = address(mockKernel2);
        kernels[2] = address(mockKernel3);
        return kernels;
    }

    /// @notice Helper to get single kernel as array
    function _singleKernelArray(address kernel) internal pure returns (address[] memory) {
        address[] memory kernels = new address[](1);
        kernels[0] = kernel;
        return kernels;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 1: INITIALIZATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that syncer initializes correctly with empty kernels
    function test_initialize_withEmptyKernels() external view {
        address[] memory kernels = syncer.getMarketKernels();
        assertEq(kernels.length, 0, "Should initialize with no kernels");
    }

    /// @notice Test that syncer initializes with correct authority
    function test_initialize_setsCorrectAuthority() external view {
        assertEq(syncer.authority(), address(factory), "Authority should be factory");
    }

    /// @notice Test that syncer cannot be reinitialized
    function test_initialize_cannotReinitialize() external {
        address[] memory kernels = new address[](0);
        vm.expectRevert();
        syncer.initialize(address(factory), kernels);
    }

    /// @notice Test initialization with kernels using deployment script
    function test_initialize_withKernels() external {
        // Deploy a new syncer with kernels using the deployment script
        address[] memory initialKernels = _getAllKernels();
        address newSyncerAddr = deployScript.deploySyncer(address(factory), initialKernels, DEPLOYER.privateKey);
        RoycoMarketSyncer newSyncer = RoycoMarketSyncer(newSyncerAddr);

        address[] memory kernels = newSyncer.getMarketKernels();
        assertEq(kernels.length, 3, "Should initialize with 3 kernels");
    }

    /// @notice Test deployment script returns deterministic address
    function test_deploy_deterministicAddress() external {
        // Deploy syncer twice - should get same address due to CREATE2
        address[] memory emptyKernels = new address[](0);

        // First deployment already happened in setUp, get the address
        address firstDeployAddr = address(syncer);

        // Deploy again - should return same address (already deployed)
        address secondDeployAddr = deployScript.deploySyncer(address(factory), emptyKernels, DEPLOYER.privateKey);

        assertEq(firstDeployAddr, secondDeployAddr, "CREATE2 should give deterministic address");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 2: KERNEL VALIDATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that valid mock kernels pass validation
    function test_validation_validKernelsPasses() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        address[] memory registeredKernels = syncer.getMarketKernels();
        assertEq(registeredKernels.length, 1, "Should have 1 kernel");
        assertEq(registeredKernels[0], address(mockKernel1), "Should be mockKernel1");
    }

    /// @notice Test that null address fails validation
    function test_validation_nullAddressReverts() external {
        address[] memory kernels = new address[](1);
        kernels[0] = address(0);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        vm.expectRevert();
        syncer.addMarketKernels(kernels);
    }

    /// @notice Test that random address fails validation (no factory mapping)
    function test_validation_invalidKernelReverts_noJuniorTranche() external {
        // Create a mock that has SENIOR_TRANCHE but factory returns address(0) for it
        MockKernel fakeKernel = new MockKernel(makeAddr("FakeTranche"));

        // Mock factory to return address(0) for this tranche (indicating not from factory)
        vm.mockCall(
            address(factory), abi.encodeWithSelector(IRoycoFactory.seniorTrancheToJuniorTranche.selector, fakeKernel.SENIOR_TRANCHE()), abi.encode(address(0))
        );

        address[] memory kernels = _singleKernelArray(address(fakeKernel));

        vm.prank(SYNC_OPERATOR_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(RoycoMarketSyncer.INVALID_KERNEL.selector, address(fakeKernel)));
        syncer.addMarketKernels(kernels);
    }

    /// @notice Test that kernel fails validation when tranche.KERNEL() doesn't match
    function test_validation_invalidKernelReverts_kernelMismatch() external {
        // Create a fake kernel with a tranche that points to a DIFFERENT kernel
        address fakeTranche = makeAddr("FakeTranche2");
        MockKernel fakeKernel = new MockKernel(fakeTranche);

        // Deploy a tranche that points to a DIFFERENT kernel (not fakeKernel)
        address differentKernel = makeAddr("DifferentKernel");
        MockTranche mismatchedTranche = new MockTranche(differentKernel);
        vm.etch(fakeTranche, address(mismatchedTranche).code);
        vm.store(fakeTranche, bytes32(0), bytes32(uint256(uint160(differentKernel))));

        // Mock factory to return a valid junior tranche (non-zero)
        vm.mockCall(
            address(factory),
            abi.encodeWithSelector(IRoycoFactory.seniorTrancheToJuniorTranche.selector, fakeTranche),
            abi.encode(makeAddr("SomeJuniorTranche"))
        );

        address[] memory kernels = _singleKernelArray(address(fakeKernel));

        vm.prank(SYNC_OPERATOR_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(RoycoMarketSyncer.INVALID_KERNEL.selector, address(fakeKernel)));
        syncer.addMarketKernels(kernels);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 3: ADD KERNELS TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test adding a single kernel
    function test_addKernels_single() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        address[] memory registeredKernels = syncer.getMarketKernels();
        assertEq(registeredKernels.length, 1, "Should have 1 kernel");
    }

    /// @notice Test adding multiple kernels at once
    function test_addKernels_multiple() external {
        address[] memory kernels = _getAllKernels();
        _addKernels(kernels);

        address[] memory registeredKernels = syncer.getMarketKernels();
        assertEq(registeredKernels.length, 3, "Should have 3 kernels");
    }

    /// @notice Test adding kernels emits events
    function test_addKernels_emitsEvents() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        vm.expectEmit(true, false, false, true, address(syncer));
        emit RoycoMarketSyncer.MarketKernelAdded(address(mockKernel1));

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.addMarketKernels(kernels);
    }

    /// @notice Test adding duplicate kernel reverts
    function test_addKernels_duplicateReverts() external {
        // Add first time
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        // Try to add again - should revert
        vm.prank(SYNC_OPERATOR_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(RoycoMarketSyncer.KERNEL_ALREADY_REGISTERED.selector, address(mockKernel1)));
        syncer.addMarketKernels(kernels);
    }

    /// @notice Test adding empty array succeeds (no-op)
    function test_addKernels_emptyArray() external {
        address[] memory kernels = new address[](0);
        _addKernels(kernels);
        assertEq(syncer.getMarketKernels().length, 0, "Should still have 0 kernels");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 4: REMOVE KERNELS TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test removing a single kernel
    function test_removeKernels_single() external {
        // First add kernels
        address[] memory kernels = _getAllKernels();
        _addKernels(kernels);
        assertEq(syncer.getMarketKernels().length, 3, "Should have 3 kernels");

        // Remove one
        address[] memory toRemove = _singleKernelArray(address(mockKernel1));
        _removeKernels(toRemove);

        address[] memory remaining = syncer.getMarketKernels();
        assertEq(remaining.length, 2, "Should have 2 kernels");
    }

    /// @notice Test removing multiple kernels
    function test_removeKernels_multiple() external {
        // First add kernels
        address[] memory kernels = _getAllKernels();
        _addKernels(kernels);

        // Remove all
        _removeKernels(kernels);

        assertEq(syncer.getMarketKernels().length, 0, "Should have 0 kernels");
    }

    /// @notice Test removing emits events
    function test_removeKernels_emitsEvents() external {
        // First add kernel
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        vm.expectEmit(true, false, false, true, address(syncer));
        emit RoycoMarketSyncer.MarketKernelRemoved(address(mockKernel1));

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.removeMarketKernels(kernels);
    }

    /// @notice Test removing non-existent kernel reverts
    function test_removeKernels_nonExistentReverts() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        vm.prank(SYNC_OPERATOR_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(RoycoMarketSyncer.KERNEL_IS_NOT_REGISTERED.selector, address(mockKernel1)));
        syncer.removeMarketKernels(kernels);
    }

    /// @notice Test removing empty array succeeds (no-op)
    function test_removeKernels_emptyArray() external {
        address[] memory kernels = new address[](0);
        _removeKernels(kernels);
        // Should succeed without reverting
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 5: EXECUTE BATCH ACCOUNTING SYNC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test batch sync with single kernel succeeds
    function test_executeBatchSync_singleKernel() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        // Execute sync
        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        // Verify sync was called
        assertEq(mockKernel1.syncCallCount(), 1, "Sync should have been called once");
    }

    /// @notice Test batch sync with multiple kernels succeeds
    function test_executeBatchSync_multipleKernels() external {
        address[] memory kernels = _getAllKernels();
        _addKernels(kernels);

        // Execute sync
        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        // Verify all syncs were called
        assertEq(mockKernel1.syncCallCount(), 1, "Kernel1 sync should have been called");
        assertEq(mockKernel2.syncCallCount(), 1, "Kernel2 sync should have been called");
        assertEq(mockKernel3.syncCallCount(), 1, "Kernel3 sync should have been called");
    }

    /// @notice Test batch sync with zero kernels succeeds (no-op)
    function test_executeBatchSync_zeroKernels() external {
        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);
        // Should succeed without reverting
    }

    /// @notice Test batch sync tolerates individual kernel failures when flag is true
    function test_executeBatchSync_toleratesFailures() external {
        address[] memory kernels = _getAllKernels();
        _addKernels(kernels);

        // Set first kernel to fail
        mockKernel1.setShouldRevert(true);

        // Should still succeed with tolerance
        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        // Verify other kernels were still synced
        assertEq(mockKernel2.syncCallCount(), 1, "Kernel2 sync should have been called");
        assertEq(mockKernel3.syncCallCount(), 1, "Kernel3 sync should have been called");
    }

    /// @notice Test batch sync emits failure event when kernel fails
    function test_executeBatchSync_emitsFailureEvent() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        // Set kernel to fail
        mockKernel1.setShouldRevert(true);

        // Get expected error bytes by calling kernel directly
        bytes memory expectedErrorBytes;
        try mockKernel1.syncTrancheAccounting() {
            revert("Should have reverted");
        } catch (bytes memory errorBytes) {
            expectedErrorBytes = errorBytes;
        }

        // Check all event parameters: indexed address AND error data
        vm.expectEmit(true, false, false, true, address(syncer));
        emit RoycoMarketSyncer.AccountingSyncFailed(address(mockKernel1), expectedErrorBytes);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);
    }

    /// @notice Test that emitted event contains exact error bytes
    function test_executeBatchSync_emittedEventErrorBytesMatchExactly() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        mockKernel1.setShouldRevert(true);

        // Get expected error bytes by calling kernel directly
        bytes memory expectedErrorBytes;
        try mockKernel1.syncTrancheAccounting() {
            revert("Should have reverted");
        } catch (bytes memory errorBytes) {
            expectedErrorBytes = errorBytes;
        }

        // Record logs
        vm.recordLogs();

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        // Find and verify the AccountingSyncFailed event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSig = keccak256("AccountingSyncFailed(address,bytes)");

        bool foundEvent = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                foundEvent = true;
                // Verify indexed kernel address
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(mockKernel1), "Kernel address mismatch");
                // Decode and verify error bytes from event data
                bytes memory emittedErrorBytes = abi.decode(logs[i].data, (bytes));
                assertEq(emittedErrorBytes, expectedErrorBytes, "Emitted error bytes should match exactly");
                break;
            }
        }
        assertTrue(foundEvent, "AccountingSyncFailed event not found");
    }

    /// @notice Test batch sync reverts on failure when tolerance is false
    function test_executeBatchSync_revertsOnFailureWhenNotTolerant() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        // Set kernel to fail
        mockKernel1.setShouldRevert(true);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        // Verify the exact error is propagated from the kernel
        vm.expectRevert("MockKernel: sync failed");
        syncer.executeBatchAccountingSync(false);
    }

    /// @notice Test batch sync propagates the exact error from failing kernel
    function test_executeBatchSync_propagatesExactError() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        // Set kernel to fail
        mockKernel1.setShouldRevert(true);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        // The error "MockKernel: sync failed" should be propagated exactly
        vm.expectRevert("MockKernel: sync failed");
        syncer.executeBatchAccountingSync(false);
    }

    /// @notice Test batch sync propagates custom errors correctly
    function test_executeBatchSync_propagatesCustomError() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        // Set kernel to fail with custom error
        mockKernel1.setShouldRevertWithCustomError(true);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        // The custom error should be propagated exactly
        vm.expectRevert(abi.encodeWithSelector(MockKernel.CustomSyncError.selector, 42, "custom error"));
        syncer.executeBatchAccountingSync(false);
    }

    /// @notice Test that error bytes are propagated exactly (byte-by-byte verification)
    function test_executeBatchSync_errorBytesMatchExactly() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        // Set kernel to fail
        mockKernel1.setShouldRevert(true);

        // Get expected error bytes by calling kernel directly
        bytes memory expectedErrorBytes;
        try mockKernel1.syncTrancheAccounting() {
            revert("Should have reverted");
        } catch (bytes memory errorBytes) {
            expectedErrorBytes = errorBytes;
        }

        // Now call through syncer and capture the propagated error
        bytes memory actualErrorBytes;
        vm.prank(SYNC_OPERATOR_ADDRESS);
        try syncer.executeBatchAccountingSync(false) {
            revert("Should have reverted");
        } catch (bytes memory errorBytes) {
            actualErrorBytes = errorBytes;
        }

        // Verify the error bytes match exactly
        assertEq(actualErrorBytes, expectedErrorBytes, "Error bytes should be propagated exactly");
    }

    /// @notice Test batch sync success path does not emit failure event
    function test_executeBatchSync_successDoesNotEmitFailureEvent() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        // Record logs to verify no AccountingSyncFailed event is emitted
        vm.recordLogs();

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        // Get all emitted logs
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Verify no AccountingSyncFailed event was emitted
        bytes32 failureEventSig = keccak256("AccountingSyncFailed(address,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != failureEventSig, "Should not emit AccountingSyncFailed on success");
        }

        // Verify sync was actually called
        assertEq(mockKernel1.syncCallCount(), 1, "Sync should have been called");
    }

    /// @notice Test batch sync continues after failure when tolerant
    function test_executeBatchSync_continuesAfterFailure() external {
        address[] memory kernels = _getAllKernels();
        _addKernels(kernels);

        // Set first kernel to fail
        mockKernel1.setShouldRevert(true);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        // Verify that kernel2 and kernel3 were still called
        assertEq(mockKernel2.syncCallCount(), 1, "Kernel2 should have been synced");
        assertEq(mockKernel3.syncCallCount(), 1, "Kernel3 should have been synced");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 5B: EXECUTE BATCH ACCOUNTING SYNC FOR (SPECIFIC KERNELS) TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test batch sync for specific kernels with single kernel succeeds
    function test_executeBatchSyncFor_singleKernel() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);

        assertEq(mockKernel1.syncCallCount(), 1, "Sync should have been called once");
    }

    /// @notice Test batch sync for specific kernels with multiple kernels succeeds
    function test_executeBatchSyncFor_multipleKernels() external {
        address[] memory kernels = _getAllKernels();

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);

        assertEq(mockKernel1.syncCallCount(), 1, "Kernel1 sync should have been called");
        assertEq(mockKernel2.syncCallCount(), 1, "Kernel2 sync should have been called");
        assertEq(mockKernel3.syncCallCount(), 1, "Kernel3 sync should have been called");
    }

    /// @notice Test batch sync for specific kernels with zero kernels succeeds (no-op)
    function test_executeBatchSyncFor_zeroKernels() external {
        address[] memory kernels = new address[](0);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);
        // Should succeed without reverting
    }

    /// @notice Test batch sync for specific kernels tolerates individual kernel failures when flag is true
    function test_executeBatchSyncFor_toleratesFailures() external {
        address[] memory kernels = _getAllKernels();

        // Set first kernel to fail
        mockKernel1.setShouldRevert(true);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);

        // Verify other kernels were still synced
        assertEq(mockKernel2.syncCallCount(), 1, "Kernel2 sync should have been called");
        assertEq(mockKernel3.syncCallCount(), 1, "Kernel3 sync should have been called");
    }

    /// @notice Test batch sync for specific kernels emits failure event when kernel fails
    function test_executeBatchSyncFor_emitsFailureEvent() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        mockKernel1.setShouldRevert(true);

        // Get expected error bytes by calling kernel directly
        bytes memory expectedErrorBytes;
        try mockKernel1.syncTrancheAccounting() {
            revert("Should have reverted");
        } catch (bytes memory errorBytes) {
            expectedErrorBytes = errorBytes;
        }

        // Check all event parameters: indexed address AND error data
        vm.expectEmit(true, false, false, true, address(syncer));
        emit RoycoMarketSyncer.AccountingSyncFailed(address(mockKernel1), expectedErrorBytes);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);
    }

    /// @notice Test that emitted event contains exact error bytes for specific kernels
    function test_executeBatchSyncFor_emittedEventErrorBytesMatchExactly() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        mockKernel1.setShouldRevert(true);

        // Get expected error bytes by calling kernel directly
        bytes memory expectedErrorBytes;
        try mockKernel1.syncTrancheAccounting() {
            revert("Should have reverted");
        } catch (bytes memory errorBytes) {
            expectedErrorBytes = errorBytes;
        }

        // Record logs
        vm.recordLogs();

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);

        // Find and verify the AccountingSyncFailed event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSig = keccak256("AccountingSyncFailed(address,bytes)");

        bool foundEvent = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                foundEvent = true;
                // Verify indexed kernel address
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(mockKernel1), "Kernel address mismatch");
                // Decode and verify error bytes from event data
                bytes memory emittedErrorBytes = abi.decode(logs[i].data, (bytes));
                assertEq(emittedErrorBytes, expectedErrorBytes, "Emitted error bytes should match exactly");
                break;
            }
        }
        assertTrue(foundEvent, "AccountingSyncFailed event not found");
    }

    /// @notice Test batch sync for specific kernels reverts on failure when tolerance is false
    function test_executeBatchSyncFor_revertsOnFailureWhenNotTolerant() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        mockKernel1.setShouldRevert(true);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        vm.expectRevert("MockKernel: sync failed");
        syncer.executeBatchAccountingSyncFor(kernels, false);
    }

    /// @notice Test batch sync for specific kernels propagates the exact error from failing kernel
    function test_executeBatchSyncFor_propagatesExactError() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        mockKernel1.setShouldRevert(true);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        vm.expectRevert("MockKernel: sync failed");
        syncer.executeBatchAccountingSyncFor(kernels, false);
    }

    /// @notice Test batch sync for specific kernels propagates custom errors correctly
    function test_executeBatchSyncFor_propagatesCustomError() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        mockKernel1.setShouldRevertWithCustomError(true);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(MockKernel.CustomSyncError.selector, 42, "custom error"));
        syncer.executeBatchAccountingSyncFor(kernels, false);
    }

    /// @notice Test that error bytes are propagated exactly for specific kernels (byte-by-byte verification)
    function test_executeBatchSyncFor_errorBytesMatchExactly() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        mockKernel1.setShouldRevert(true);

        // Get expected error bytes by calling kernel directly
        bytes memory expectedErrorBytes;
        try mockKernel1.syncTrancheAccounting() {
            revert("Should have reverted");
        } catch (bytes memory errorBytes) {
            expectedErrorBytes = errorBytes;
        }

        // Now call through syncer and capture the propagated error
        bytes memory actualErrorBytes;
        vm.prank(SYNC_OPERATOR_ADDRESS);
        try syncer.executeBatchAccountingSyncFor(kernels, false) {
            revert("Should have reverted");
        } catch (bytes memory errorBytes) {
            actualErrorBytes = errorBytes;
        }

        assertEq(actualErrorBytes, expectedErrorBytes, "Error bytes should be propagated exactly");
    }

    /// @notice Test batch sync for specific kernels success path does not emit failure event
    function test_executeBatchSyncFor_successDoesNotEmitFailureEvent() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        vm.recordLogs();

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 failureEventSig = keccak256("AccountingSyncFailed(address,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != failureEventSig, "Should not emit AccountingSyncFailed on success");
        }

        assertEq(mockKernel1.syncCallCount(), 1, "Sync should have been called");
    }

    /// @notice Test batch sync for specific kernels continues after failure when tolerant
    function test_executeBatchSyncFor_continuesAfterFailure() external {
        address[] memory kernels = _getAllKernels();

        mockKernel1.setShouldRevert(true);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);

        assertEq(mockKernel2.syncCallCount(), 1, "Kernel2 should have been synced");
        assertEq(mockKernel3.syncCallCount(), 1, "Kernel3 should have been synced");
    }

    /// @notice Test batch sync for specific kernels works with unregistered kernels
    function test_executeBatchSyncFor_worksWithUnregisteredKernels() external {
        // Don't register kernels, just sync them directly
        address[] memory kernels = _getAllKernels();

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);

        // Verify all kernels were synced even though they weren't registered
        assertEq(mockKernel1.syncCallCount(), 1, "Kernel1 sync should have been called");
        assertEq(mockKernel2.syncCallCount(), 1, "Kernel2 sync should have been called");
        assertEq(mockKernel3.syncCallCount(), 1, "Kernel3 sync should have been called");

        // Verify they are not in the registered list
        address[] memory registeredKernels = syncer.getMarketKernels();
        assertEq(registeredKernels.length, 0, "No kernels should be registered");
    }

    /// @notice Test batch sync for specific kernels can sync same kernel multiple times
    function test_executeBatchSyncFor_canSyncSameKernelMultipleTimes() external {
        address[] memory kernels = new address[](3);
        kernels[0] = address(mockKernel1);
        kernels[1] = address(mockKernel1);
        kernels[2] = address(mockKernel1);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);

        assertEq(mockKernel1.syncCallCount(), 3, "Kernel1 should have been synced 3 times");
    }

    /// @notice Test batch sync for specific kernels with middle kernel failing
    function test_executeBatchSyncFor_middleKernelFails() external {
        address[] memory kernels = _getAllKernels();

        // Set middle kernel to fail
        mockKernel2.setShouldRevert(true);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);

        // Verify kernel1 and kernel3 were synced, kernel2 was attempted
        assertEq(mockKernel1.syncCallCount(), 1, "Kernel1 should have been synced");
        assertEq(mockKernel3.syncCallCount(), 1, "Kernel3 should have been synced");
    }

    /// @notice Test batch sync for specific kernels stops at first failure when not tolerant
    function test_executeBatchSyncFor_stopsAtFirstFailureWhenNotTolerant() external {
        address[] memory kernels = _getAllKernels();

        // Set first kernel to fail
        mockKernel1.setShouldRevert(true);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        vm.expectRevert("MockKernel: sync failed");
        syncer.executeBatchAccountingSyncFor(kernels, false);

        // Verify subsequent kernels were NOT called
        assertEq(mockKernel2.syncCallCount(), 0, "Kernel2 should NOT have been synced");
        assertEq(mockKernel3.syncCallCount(), 0, "Kernel3 should NOT have been synced");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 6: ACCESS CONTROL TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test unauthorized user cannot execute batch sync
    function test_accessControl_unauthorizedCannotSync() external {
        vm.prank(UNAUTHORIZED_USER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, UNAUTHORIZED_USER_ADDRESS));
        syncer.executeBatchAccountingSync(true);
    }

    /// @notice Test unauthorized user cannot execute batch sync for specific kernels
    function test_accessControl_unauthorizedCannotSyncFor() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        vm.prank(UNAUTHORIZED_USER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, UNAUTHORIZED_USER_ADDRESS));
        syncer.executeBatchAccountingSyncFor(kernels, true);
    }

    /// @notice Test unauthorized user cannot add kernels
    function test_accessControl_unauthorizedCannotAddKernels() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        vm.prank(UNAUTHORIZED_USER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, UNAUTHORIZED_USER_ADDRESS));
        syncer.addMarketKernels(kernels);
    }

    /// @notice Test unauthorized user cannot remove kernels
    function test_accessControl_unauthorizedCannotRemoveKernels() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        vm.prank(UNAUTHORIZED_USER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, UNAUTHORIZED_USER_ADDRESS));
        syncer.removeMarketKernels(kernels);
    }

    /// @notice Test unauthorized user cannot pause
    function test_accessControl_unauthorizedCannotPause() external {
        vm.prank(UNAUTHORIZED_USER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, UNAUTHORIZED_USER_ADDRESS));
        syncer.pause();
    }

    /// @notice Test SYNC_ROLE holder can add kernels (production config)
    function test_accessControl_syncRoleCanAddKernels() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.addMarketKernels(kernels);
        assertEq(syncer.getMarketKernels().length, 1, "SYNC_ROLE should be able to add kernels");
    }

    /// @notice Test SYNC_ROLE holder can remove kernels (production config)
    function test_accessControl_syncRoleCanRemoveKernels() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.removeMarketKernels(kernels);
        assertEq(syncer.getMarketKernels().length, 0, "SYNC_ROLE should be able to remove kernels");
    }

    /// @notice Test SYNC_ROLE holder can execute batch sync (production config)
    function test_accessControl_syncRoleCanSync() external {
        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);
        // Should not revert
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 7: PAUSABILITY TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test syncer can be paused
    function test_pause_succeeds() external {
        assertFalse(PausableUpgradeable(address(syncer)).paused(), "Should not be paused initially");

        vm.prank(PAUSER_ADDRESS);
        syncer.pause();

        assertTrue(PausableUpgradeable(address(syncer)).paused(), "Should be paused");
    }

    /// @notice Test syncer can be unpaused
    function test_unpause_succeeds() external {
        vm.prank(PAUSER_ADDRESS);
        syncer.pause();
        assertTrue(PausableUpgradeable(address(syncer)).paused(), "Should be paused");

        vm.prank(PAUSER_ADDRESS);
        syncer.unpause();
        assertFalse(PausableUpgradeable(address(syncer)).paused(), "Should be unpaused");
    }

    /// @notice Test batch sync fails when paused
    function test_pause_blocksBatchSync() external {
        vm.prank(PAUSER_ADDRESS);
        syncer.pause();

        vm.prank(SYNC_OPERATOR_ADDRESS);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        syncer.executeBatchAccountingSync(true);
    }

    /// @notice Test pause blocks executeBatchAccountingSyncFor
    function test_pause_blocksBatchSyncFor() external {
        vm.prank(PAUSER_ADDRESS);
        syncer.pause();

        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        vm.prank(SYNC_OPERATOR_ADDRESS);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        syncer.executeBatchAccountingSyncFor(kernels, true);
    }

    /// @notice Test add kernels fails when paused
    function test_pause_blocksAddKernels() external {
        vm.prank(PAUSER_ADDRESS);
        syncer.pause();

        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        vm.prank(SYNC_OPERATOR_ADDRESS);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        syncer.addMarketKernels(kernels);
    }

    /// @notice Test remove kernels fails when paused
    function test_pause_blocksRemoveKernels() external {
        // First add kernels while unpaused
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        // Now pause
        vm.prank(PAUSER_ADDRESS);
        syncer.pause();

        vm.prank(SYNC_OPERATOR_ADDRESS);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        syncer.removeMarketKernels(kernels);
    }

    /// @notice Test operations work after unpause
    function test_pause_operationsWorkAfterUnpause() external {
        // Pause
        vm.prank(PAUSER_ADDRESS);
        syncer.pause();

        // Unpause
        vm.prank(PAUSER_ADDRESS);
        syncer.unpause();

        // Add kernels should work
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        assertEq(syncer.getMarketKernels().length, 1, "Should have 1 kernel");

        // Sync should work
        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 8: VIEW FUNCTIONS TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test getMarketKernels returns correct kernels
    function test_getMarketKernels_returnsCorrectKernels() external {
        address[] memory kernels = _getAllKernels();
        _addKernels(kernels);

        address[] memory result = syncer.getMarketKernels();
        assertEq(result.length, 3, "Should have 3 kernels");

        // Note: Order may not be preserved due to EnumerableSet implementation
        bool foundKernel1 = false;
        bool foundKernel2 = false;
        bool foundKernel3 = false;
        for (uint256 i = 0; i < result.length; i++) {
            if (result[i] == address(mockKernel1)) foundKernel1 = true;
            if (result[i] == address(mockKernel2)) foundKernel2 = true;
            if (result[i] == address(mockKernel3)) foundKernel3 = true;
        }
        assertTrue(foundKernel1, "Should contain kernel1");
        assertTrue(foundKernel2, "Should contain kernel2");
        assertTrue(foundKernel3, "Should contain kernel3");
    }

    /// @notice Test getMarketKernels returns empty array when no kernels
    function test_getMarketKernels_returnsEmptyWhenNone() external view {
        address[] memory result = syncer.getMarketKernels();
        assertEq(result.length, 0, "Should have 0 kernels");
    }

    /// @notice Test isMarketKernelRegistered returns true for registered kernel
    function test_isMarketKernelRegistered_returnsTrueForRegistered() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        assertTrue(syncer.isMarketKernelRegistered(address(mockKernel1)), "Kernel1 should be registered");
    }

    /// @notice Test isMarketKernelRegistered returns false for unregistered kernel
    function test_isMarketKernelRegistered_returnsFalseForUnregistered() external view {
        assertFalse(syncer.isMarketKernelRegistered(address(mockKernel1)), "Kernel1 should not be registered");
    }

    /// @notice Test isMarketKernelRegistered returns false after kernel is removed
    function test_isMarketKernelRegistered_returnsFalseAfterRemoval() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        assertTrue(syncer.isMarketKernelRegistered(address(mockKernel1)), "Kernel1 should be registered");

        _removeKernels(kernels);

        assertFalse(syncer.isMarketKernelRegistered(address(mockKernel1)), "Kernel1 should not be registered after removal");
    }

    /// @notice Test isMarketKernelRegistered returns false for zero address
    function test_isMarketKernelRegistered_returnsFalseForZeroAddress() external view {
        assertFalse(syncer.isMarketKernelRegistered(address(0)), "Zero address should not be registered");
    }

    /// @notice Test isMarketKernelRegistered with multiple kernels registered
    function test_isMarketKernelRegistered_multipleKernels() external {
        address[] memory kernels = _getAllKernels();
        _addKernels(kernels);

        assertTrue(syncer.isMarketKernelRegistered(address(mockKernel1)), "Kernel1 should be registered");
        assertTrue(syncer.isMarketKernelRegistered(address(mockKernel2)), "Kernel2 should be registered");
        assertTrue(syncer.isMarketKernelRegistered(address(mockKernel3)), "Kernel3 should be registered");

        // Random address should not be registered
        assertFalse(syncer.isMarketKernelRegistered(address(0x1234)), "Random address should not be registered");
    }

    /// @notice Test isMarketKernelRegistered correctly tracks partial removals
    function test_isMarketKernelRegistered_partialRemoval() external {
        address[] memory kernels = _getAllKernels();
        _addKernels(kernels);

        // Remove only kernel2
        address[] memory toRemove = _singleKernelArray(address(mockKernel2));
        _removeKernels(toRemove);

        assertTrue(syncer.isMarketKernelRegistered(address(mockKernel1)), "Kernel1 should still be registered");
        assertFalse(syncer.isMarketKernelRegistered(address(mockKernel2)), "Kernel2 should not be registered");
        assertTrue(syncer.isMarketKernelRegistered(address(mockKernel3)), "Kernel3 should still be registered");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 9: UPGRADE TESTS (inherited from RoycoBase)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that authorized user can upgrade to valid implementation
    function test_upgrade_authorizedCanUpgrade() external {
        // Deploy new implementation
        RoycoMarketSyncer newImpl = new RoycoMarketSyncer();

        // Mock permission for upgrade
        vm.mockCall(
            address(factory),
            abi.encodeWithSelector(IAccessManager.canCall.selector, DEPLOYER_ADDRESS, address(syncer), syncer.upgradeToAndCall.selector),
            abi.encode(true, uint32(0))
        );

        vm.prank(DEPLOYER_ADDRESS);
        syncer.upgradeToAndCall(address(newImpl), "");

        // Verify upgrade succeeded - implementation changed
        // The syncer should still work after upgrade
        assertEq(syncer.authority(), address(factory), "Authority should remain after upgrade");
    }

    /// @notice Test that upgrade to EOA (no code) reverts
    function test_upgrade_invalidImplementationReverts() external {
        address eoaAddress = makeAddr("EOA");

        // Mock permission for upgrade
        vm.mockCall(
            address(factory),
            abi.encodeWithSelector(IAccessManager.canCall.selector, DEPLOYER_ADDRESS, address(syncer), syncer.upgradeToAndCall.selector),
            abi.encode(true, uint32(0))
        );

        vm.prank(DEPLOYER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(RoycoBase.INVALID_IMPLEMENTATION.selector));
        syncer.upgradeToAndCall(eoaAddress, "");
    }

    /// @notice Test that unauthorized user cannot upgrade
    function test_upgrade_unauthorizedCannotUpgrade() external {
        RoycoMarketSyncer newImpl = new RoycoMarketSyncer();

        vm.prank(UNAUTHORIZED_USER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, UNAUTHORIZED_USER_ADDRESS));
        syncer.upgradeToAndCall(address(newImpl), "");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 10: INTEGRATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test full workflow: add, sync, remove
    function test_integration_fullWorkflow() external {
        // Start with no kernels
        assertEq(syncer.getMarketKernels().length, 0, "Should start with 0 kernels");

        // Add all kernels
        address[] memory allKernels = _getAllKernels();
        _addKernels(allKernels);
        assertEq(syncer.getMarketKernels().length, 3, "Should have 3 kernels");

        // Execute sync
        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        // Verify all syncs were called
        assertEq(mockKernel1.syncCallCount(), 1, "Kernel1 should have synced");
        assertEq(mockKernel2.syncCallCount(), 1, "Kernel2 should have synced");
        assertEq(mockKernel3.syncCallCount(), 1, "Kernel3 should have synced");

        // Remove one kernel
        address[] memory toRemove = _singleKernelArray(address(mockKernel2));
        _removeKernels(toRemove);
        assertEq(syncer.getMarketKernels().length, 2, "Should have 2 kernels");

        // Sync again
        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        // Verify only remaining kernels were synced again
        assertEq(mockKernel1.syncCallCount(), 2, "Kernel1 should have synced twice");
        assertEq(mockKernel2.syncCallCount(), 1, "Kernel2 should still have 1 sync");
        assertEq(mockKernel3.syncCallCount(), 2, "Kernel3 should have synced twice");

        // Remove remaining
        address[] memory remaining = syncer.getMarketKernels();
        _removeKernels(remaining);
        assertEq(syncer.getMarketKernels().length, 0, "Should have 0 kernels");
    }

    /// @notice Test adding and removing same kernel multiple times
    function test_integration_addRemoveMultipleTimes() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        // Add
        _addKernels(kernels);
        assertEq(syncer.getMarketKernels().length, 1);

        // Remove
        _removeKernels(kernels);
        assertEq(syncer.getMarketKernels().length, 0);

        // Add again
        _addKernels(kernels);
        assertEq(syncer.getMarketKernels().length, 1);

        // Remove again
        _removeKernels(kernels);
        assertEq(syncer.getMarketKernels().length, 0);
    }

    /// @notice Test sync counts accumulate correctly
    function test_integration_syncCountsAccumulate() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        // Sync multiple times
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(SYNC_OPERATOR_ADDRESS);
            syncer.executeBatchAccountingSync(true);
        }

        assertEq(mockKernel1.syncCallCount(), 5, "Should have synced 5 times");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 11: PRODUCTION ROLE CONFIGURATION VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════════
    // These tests explicitly verify that the production role configuration from
    // buildSyncerConfigTransactions matches expected values and is correctly applied.

    /// @notice Verify buildSyncerConfigTransactions returns exactly 5 transactions when no sync operators
    function test_productionConfig_transactionCount_noOperators() external view {
        DeploySyncerScript.SafeTransaction[] memory txs = deployScript.buildSyncerConfigTransactions(address(factory), address(syncer), new address[](0));
        assertEq(
            txs.length, 5, "Should have exactly 5 role configuration transactions with no operators (sync/pause/unpause/upgrader + grant SYNC_ROLE to syncer)"
        );
    }

    /// @notice Verify buildSyncerConfigTransactions returns 5 + N transactions with N sync operators
    function test_productionConfig_transactionCount_withOperators() external view {
        address[] memory syncOperators = new address[](2);
        syncOperators[0] = address(0x1111);
        syncOperators[1] = address(0x2222);

        DeploySyncerScript.SafeTransaction[] memory txs = deployScript.buildSyncerConfigTransactions(address(factory), address(syncer), syncOperators);
        assertEq(txs.length, 7, "Should have 5 role config + 2 grantRole transactions");
    }

    /// @notice Verify all transactions target the factory
    function test_productionConfig_allTransactionsTargetFactory() external view {
        address[] memory syncOperators = new address[](1);
        syncOperators[0] = SYNC_OPERATOR_ADDRESS;

        DeploySyncerScript.SafeTransaction[] memory txs = deployScript.buildSyncerConfigTransactions(address(factory), address(syncer), syncOperators);
        for (uint256 i = 0; i < txs.length; i++) {
            assertEq(txs[i].to, address(factory), string.concat("Transaction ", vm.toString(i), " should target factory"));
            assertEq(txs[i].value, 0, string.concat("Transaction ", vm.toString(i), " should have zero value"));
        }
    }

    /// @notice Verify SYNC_ROLE is assigned to the correct 4 functions
    function test_productionConfig_syncRoleFunctions() external view {
        // Verify factory's canCall returns true for SYNC_ROLE holder on all 4 functions
        bytes4[4] memory syncSelectors = [
            RoycoMarketSyncer.executeBatchAccountingSync.selector,
            RoycoMarketSyncer.executeBatchAccountingSyncFor.selector,
            RoycoMarketSyncer.addMarketKernels.selector,
            RoycoMarketSyncer.removeMarketKernels.selector
        ];

        for (uint256 i = 0; i < syncSelectors.length; i++) {
            (bool canCall, uint32 delay) = factory.canCall(SYNC_OPERATOR_ADDRESS, address(syncer), syncSelectors[i]);
            assertTrue(canCall, string.concat("SYNC_ROLE should be able to call selector index ", vm.toString(i)));
            assertEq(delay, 0, string.concat("SYNC_ROLE should have no delay for selector index ", vm.toString(i)));
        }
    }

    /// @notice Verify ADMIN_PAUSER_ROLE is assigned to pause
    function test_productionConfig_pauserRoleFunctions() external view {
        (bool canCall, uint32 delay) = factory.canCall(PAUSER_ADDRESS, address(syncer), IRoycoAuth.pause.selector);
        assertTrue(canCall, "ADMIN_PAUSER_ROLE should be able to call pause");
        assertEq(delay, 0, "ADMIN_PAUSER_ROLE should have no delay for pause");
    }

    /// @notice Verify ADMIN_UNPAUSER_ROLE is assigned to unpause
    /// @dev In `_configureProductionRoles` PAUSER_ADDRESS is also granted ADMIN_UNPAUSER_ROLE with delay 0
    ///      for test convenience; production grants this role with the Standard 24h delay.
    function test_productionConfig_unpauserRoleFunctions() external view {
        (bool canCall, uint32 delay) = factory.canCall(PAUSER_ADDRESS, address(syncer), IRoycoAuth.unpause.selector);
        assertTrue(canCall, "ADMIN_UNPAUSER_ROLE should be able to call unpause");
        assertEq(delay, 0, "ADMIN_UNPAUSER_ROLE should have no delay for unpause (test config)");
    }

    /// @notice Verify ADMIN_UPGRADER_ROLE is assigned to upgradeToAndCall
    function test_productionConfig_upgraderRoleFunction() external view {
        (bool canCall,) = factory.canCall(DEPLOYER_ADDRESS, address(syncer), syncer.upgradeToAndCall.selector);
        assertTrue(canCall, "ADMIN_UPGRADER_ROLE should be able to call upgradeToAndCall");
    }

    /// @notice Verify unauthorized users cannot call any restricted function
    function test_productionConfig_unauthorizedCannotCallAnyFunction() external view {
        bytes4[7] memory allRestrictedSelectors = [
            RoycoMarketSyncer.executeBatchAccountingSync.selector,
            RoycoMarketSyncer.executeBatchAccountingSyncFor.selector,
            RoycoMarketSyncer.addMarketKernels.selector,
            RoycoMarketSyncer.removeMarketKernels.selector,
            IRoycoAuth.pause.selector,
            IRoycoAuth.unpause.selector,
            syncer.upgradeToAndCall.selector
        ];

        for (uint256 i = 0; i < allRestrictedSelectors.length; i++) {
            (bool canCall,) = factory.canCall(UNAUTHORIZED_USER_ADDRESS, address(syncer), allRestrictedSelectors[i]);
            assertFalse(canCall, string.concat("Unauthorized user should NOT be able to call selector index ", vm.toString(i)));
        }
    }

    /// @notice Verify role separation - SYNC_ROLE cannot pause
    function test_productionConfig_roleSeparation_syncCannotPause() external view {
        (bool canCall,) = factory.canCall(SYNC_OPERATOR_ADDRESS, address(syncer), IRoycoAuth.pause.selector);
        assertFalse(canCall, "SYNC_ROLE should NOT be able to pause");

        (canCall,) = factory.canCall(SYNC_OPERATOR_ADDRESS, address(syncer), IRoycoAuth.unpause.selector);
        assertFalse(canCall, "SYNC_ROLE should NOT be able to unpause");
    }

    /// @notice Verify role separation - PAUSER cannot sync
    function test_productionConfig_roleSeparation_pauserCannotSync() external view {
        (bool canCall,) = factory.canCall(PAUSER_ADDRESS, address(syncer), RoycoMarketSyncer.executeBatchAccountingSync.selector);
        assertFalse(canCall, "ADMIN_PAUSER_ROLE should NOT be able to sync");

        (canCall,) = factory.canCall(PAUSER_ADDRESS, address(syncer), RoycoMarketSyncer.addMarketKernels.selector);
        assertFalse(canCall, "ADMIN_PAUSER_ROLE should NOT be able to add kernels");
    }

    /// @notice Verify role separation - SYNC_ROLE cannot upgrade
    function test_productionConfig_roleSeparation_syncCannotUpgrade() external view {
        (bool canCall,) = factory.canCall(SYNC_OPERATOR_ADDRESS, address(syncer), syncer.upgradeToAndCall.selector);
        assertFalse(canCall, "SYNC_ROLE should NOT be able to upgrade");
    }

    /// @notice Verify the exact role IDs from RolesConfiguration are used
    function test_productionConfig_usesCorrectRoleIds() external view {
        // Get the role assigned to each function via getTargetFunctionRole
        uint64 syncRole = factory.getTargetFunctionRole(address(syncer), RoycoMarketSyncer.executeBatchAccountingSync.selector);
        uint64 addKernelsRole = factory.getTargetFunctionRole(address(syncer), RoycoMarketSyncer.addMarketKernels.selector);
        uint64 removeKernelsRole = factory.getTargetFunctionRole(address(syncer), RoycoMarketSyncer.removeMarketKernels.selector);
        uint64 syncForRole = factory.getTargetFunctionRole(address(syncer), RoycoMarketSyncer.executeBatchAccountingSyncFor.selector);
        uint64 pauseRole = factory.getTargetFunctionRole(address(syncer), IRoycoAuth.pause.selector);
        uint64 unpauseRole = factory.getTargetFunctionRole(address(syncer), IRoycoAuth.unpause.selector);
        uint64 upgradeRole = factory.getTargetFunctionRole(address(syncer), syncer.upgradeToAndCall.selector);

        // Verify SYNC_ROLE for all 4 sync-related functions
        assertEq(syncRole, SYNC_ROLE, "executeBatchAccountingSync should use SYNC_ROLE");
        assertEq(syncForRole, SYNC_ROLE, "executeBatchAccountingSyncFor should use SYNC_ROLE");
        assertEq(addKernelsRole, SYNC_ROLE, "addMarketKernels should use SYNC_ROLE");
        assertEq(removeKernelsRole, SYNC_ROLE, "removeMarketKernels should use SYNC_ROLE");

        // Verify ADMIN_PAUSER_ROLE for pause and ADMIN_UNPAUSER_ROLE for unpause (split per the security model)
        assertEq(pauseRole, ADMIN_PAUSER_ROLE, "pause should use ADMIN_PAUSER_ROLE");
        assertEq(unpauseRole, ADMIN_UNPAUSER_ROLE, "unpause should use ADMIN_UNPAUSER_ROLE");

        // Verify ADMIN_UPGRADER_ROLE for upgrade
        assertEq(upgradeRole, ADMIN_UPGRADER_ROLE, "upgradeToAndCall should use ADMIN_UPGRADER_ROLE");
    }

    /// @notice Verify the selectors in buildSyncerConfigTransactions match actual function selectors
    function test_productionConfig_selectorsMatchActualFunctions() external pure {
        // These are the expected selectors - verify they match the actual contract
        assertEq(RoycoMarketSyncer.executeBatchAccountingSync.selector, bytes4(keccak256("executeBatchAccountingSync(bool)")));
        assertEq(RoycoMarketSyncer.executeBatchAccountingSyncFor.selector, bytes4(keccak256("executeBatchAccountingSyncFor(address[],bool)")));
        assertEq(RoycoMarketSyncer.addMarketKernels.selector, bytes4(keccak256("addMarketKernels(address[])")));
        assertEq(RoycoMarketSyncer.removeMarketKernels.selector, bytes4(keccak256("removeMarketKernels(address[])")));
        assertEq(IRoycoAuth.pause.selector, bytes4(keccak256("pause()")));
        assertEq(IRoycoAuth.unpause.selector, bytes4(keccak256("unpause()")));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 12: _executeAccountingSync COMPREHENSIVE EDGE CASE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test empty revert is handled correctly when tolerant
    function test_executeAccountingSync_emptyRevert_tolerant() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        mockKernel1.setRevertType(MockKernel.RevertType.EmptyRevert);

        vm.recordLogs();

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        // Verify event was emitted with empty error data
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSig = keccak256("AccountingSyncFailed(address,bytes)");

        bool foundEvent = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                foundEvent = true;
                bytes memory emittedErrorBytes = abi.decode(logs[i].data, (bytes));
                assertEq(emittedErrorBytes.length, 0, "Empty revert should have zero-length error bytes");
                break;
            }
        }
        assertTrue(foundEvent, "AccountingSyncFailed event should be emitted for empty revert");
    }

    /// @notice Test empty revert is propagated correctly when not tolerant
    function test_executeAccountingSync_emptyRevert_notTolerant() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        mockKernel1.setRevertType(MockKernel.RevertType.EmptyRevert);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        vm.expectRevert(bytes(""));
        syncer.executeBatchAccountingSync(false);
    }

    /// @notice Test panic (assert failure) is handled correctly when tolerant
    function test_executeAccountingSync_panic_tolerant() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        mockKernel1.setRevertType(MockKernel.RevertType.Panic);

        vm.recordLogs();

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        // Verify event was emitted with panic error data
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSig = keccak256("AccountingSyncFailed(address,bytes)");

        bool foundEvent = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                foundEvent = true;
                bytes memory emittedErrorBytes = abi.decode(logs[i].data, (bytes));
                // Panic errors have selector 0x4e487b71 followed by panic code
                assertEq(bytes4(emittedErrorBytes), bytes4(0x4e487b71), "Should be a panic error");
                break;
            }
        }
        assertTrue(foundEvent, "AccountingSyncFailed event should be emitted for panic");
    }

    /// @notice Test panic is propagated correctly when not tolerant
    function test_executeAccountingSync_panic_notTolerant() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        mockKernel1.setRevertType(MockKernel.RevertType.Panic);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        // Panic code 0x01 is for assert failures
        vm.expectRevert(abi.encodeWithSelector(0x4e487b71, uint256(0x01)));
        syncer.executeBatchAccountingSync(false);
    }

    /// @notice Test panic error bytes match exactly between kernel and syncer
    function test_executeAccountingSync_panicErrorBytesMatchExactly() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        mockKernel1.setRevertType(MockKernel.RevertType.Panic);

        // Get expected panic error bytes from kernel
        bytes memory expectedErrorBytes;
        try mockKernel1.syncTrancheAccounting() {
            revert("Should have reverted");
        } catch (bytes memory errorBytes) {
            expectedErrorBytes = errorBytes;
        }

        // Get actual error bytes from syncer
        bytes memory actualErrorBytes;
        vm.prank(SYNC_OPERATOR_ADDRESS);
        try syncer.executeBatchAccountingSync(false) {
            revert("Should have reverted");
        } catch (bytes memory errorBytes) {
            actualErrorBytes = errorBytes;
        }

        assertEq(actualErrorBytes, expectedErrorBytes, "Panic error bytes should match exactly");
    }

    /// @notice Test large error data (1KB) is handled correctly when tolerant
    function test_executeAccountingSync_largeError_tolerant() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        mockKernel1.setRevertType(MockKernel.RevertType.LargeError);
        mockKernel1.setLargeErrorSize(1024);

        vm.recordLogs();

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        // Verify event was emitted with large error data
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSig = keccak256("AccountingSyncFailed(address,bytes)");

        bool foundEvent = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                foundEvent = true;
                bytes memory emittedErrorBytes = abi.decode(logs[i].data, (bytes));
                // LargeError selector (4 bytes) + ABI encoded bytes (offset + length + data)
                assertTrue(emittedErrorBytes.length > 1024, "Should contain large error data");
                break;
            }
        }
        assertTrue(foundEvent, "AccountingSyncFailed event should be emitted for large error");
    }

    /// @notice Test large error data bytes match exactly
    function test_executeAccountingSync_largeErrorBytesMatchExactly() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        mockKernel1.setRevertType(MockKernel.RevertType.LargeError);
        mockKernel1.setLargeErrorSize(1024);

        // Get expected error bytes from kernel
        bytes memory expectedErrorBytes;
        try mockKernel1.syncTrancheAccounting() {
            revert("Should have reverted");
        } catch (bytes memory errorBytes) {
            expectedErrorBytes = errorBytes;
        }

        // Verify via event emission
        vm.recordLogs();

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSig = keccak256("AccountingSyncFailed(address,bytes)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                bytes memory emittedErrorBytes = abi.decode(logs[i].data, (bytes));
                assertEq(emittedErrorBytes, expectedErrorBytes, "Large error bytes should match exactly");
                break;
            }
        }
    }

    /// @notice Test very large error data (10KB) is handled correctly
    function test_executeAccountingSync_veryLargeError_tolerant() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        mockKernel1.setRevertType(MockKernel.RevertType.LargeError);
        mockKernel1.setLargeErrorSize(10_240);

        vm.recordLogs();

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSig = keccak256("AccountingSyncFailed(address,bytes)");

        bool foundEvent = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                foundEvent = true;
                bytes memory emittedErrorBytes = abi.decode(logs[i].data, (bytes));
                assertTrue(emittedErrorBytes.length > 10_240, "Should contain very large error data");
                break;
            }
        }
        assertTrue(foundEvent, "AccountingSyncFailed event should be emitted");
    }

    /// @notice Test large error is propagated correctly when not tolerant
    function test_executeAccountingSync_largeError_notTolerant() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        mockKernel1.setRevertType(MockKernel.RevertType.LargeError);
        mockKernel1.setLargeErrorSize(1024);

        // Get expected error bytes by calling kernel directly
        bytes memory expectedErrorBytes;
        try mockKernel1.syncTrancheAccounting() {
            revert("Should have reverted");
        } catch (bytes memory errorBytes) {
            expectedErrorBytes = errorBytes;
        }

        // Verify the error is propagated exactly
        bytes memory actualErrorBytes;
        vm.prank(SYNC_OPERATOR_ADDRESS);
        try syncer.executeBatchAccountingSync(false) {
            revert("Should have reverted");
        } catch (bytes memory errorBytes) {
            actualErrorBytes = errorBytes;
        }

        assertEq(actualErrorBytes, expectedErrorBytes, "Large error bytes should be propagated exactly");
    }

    /// @notice Test executeBatchSyncFor with large error tolerant
    function test_executeBatchSyncFor_largeError_tolerant() external {
        mockKernel1.setRevertType(MockKernel.RevertType.LargeError);
        mockKernel1.setLargeErrorSize(1024);

        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        // Get expected error bytes
        bytes memory expectedErrorBytes;
        try mockKernel1.syncTrancheAccounting() {
            revert("Should have reverted");
        } catch (bytes memory errorBytes) {
            expectedErrorBytes = errorBytes;
        }

        vm.recordLogs();

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSig = keccak256("AccountingSyncFailed(address,bytes)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                bytes memory emittedErrorBytes = abi.decode(logs[i].data, (bytes));
                assertEq(emittedErrorBytes, expectedErrorBytes, "Large error bytes should match");
                break;
            }
        }
    }

    /// @notice Test executeBatchSyncFor with large error not tolerant
    function test_executeBatchSyncFor_largeError_notTolerant() external {
        mockKernel1.setRevertType(MockKernel.RevertType.LargeError);
        mockKernel1.setLargeErrorSize(1024);

        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        // Get expected error bytes
        bytes memory expectedErrorBytes;
        try mockKernel1.syncTrancheAccounting() {
            revert("Should have reverted");
        } catch (bytes memory errorBytes) {
            expectedErrorBytes = errorBytes;
        }

        // Verify the error is propagated exactly
        bytes memory actualErrorBytes;
        vm.prank(SYNC_OPERATOR_ADDRESS);
        try syncer.executeBatchAccountingSyncFor(kernels, false) {
            revert("Should have reverted");
        } catch (bytes memory errorBytes) {
            actualErrorBytes = errorBytes;
        }

        assertEq(actualErrorBytes, expectedErrorBytes, "Large error bytes should be propagated exactly");
    }

    /// @notice Test all kernels failing in batch with tolerance
    function test_executeAccountingSync_allKernelsFail_tolerant() external {
        address[] memory kernels = _getAllKernels();
        _addKernels(kernels);

        // Set all kernels to fail with different error types
        mockKernel1.setRevertType(MockKernel.RevertType.StringRevert);
        mockKernel2.setRevertType(MockKernel.RevertType.CustomError);
        mockKernel3.setRevertType(MockKernel.RevertType.EmptyRevert);

        vm.recordLogs();

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        // Verify 3 failure events were emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSig = keccak256("AccountingSyncFailed(address,bytes)");

        uint256 failureEventCount = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                failureEventCount++;
            }
        }
        assertEq(failureEventCount, 3, "Should emit 3 failure events");
    }

    /// @notice Test last kernel failing in batch
    function test_executeAccountingSync_lastKernelFails_tolerant() external {
        address[] memory kernels = _getAllKernels();
        _addKernels(kernels);

        // Only last kernel fails
        mockKernel3.setRevertType(MockKernel.RevertType.StringRevert);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        // Verify first two kernels were synced
        assertEq(mockKernel1.syncCallCount(), 1, "Kernel1 should have synced");
        assertEq(mockKernel2.syncCallCount(), 1, "Kernel2 should have synced");
    }

    /// @notice Test last kernel failing stops execution when not tolerant
    function test_executeAccountingSync_lastKernelFails_notTolerant() external {
        address[] memory kernels = _getAllKernels();
        _addKernels(kernels);

        mockKernel3.setRevertType(MockKernel.RevertType.StringRevert);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        vm.expectRevert("MockKernel: sync failed");
        syncer.executeBatchAccountingSync(false);

        // Note: When the transaction reverts, all state changes are rolled back,
        // so sync counts remain 0 even though kernels 1 & 2 were called before the revert
        assertEq(mockKernel1.syncCallCount(), 0, "Kernel1 sync count rolled back");
        assertEq(mockKernel2.syncCallCount(), 0, "Kernel2 sync count rolled back");
    }

    /// @notice Test calling EOA (no code) is handled gracefully
    function test_executeBatchSyncFor_callingEOA_tolerant() external {
        address eoa = makeAddr("EOA");
        address[] memory kernels = new address[](1);
        kernels[0] = eoa;

        vm.recordLogs();

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);

        // Call to EOA succeeds (no code to execute), so no failure event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSig = keccak256("AccountingSyncFailed(address,bytes)");

        uint256 failureEventCount = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                failureEventCount++;
            }
        }
        // Note: Calling an EOA with no code doesn't revert - it just succeeds
        assertEq(failureEventCount, 0, "EOA call should not fail");
    }

    /// @notice Test multiple sync calls accumulate correctly
    function test_executeAccountingSync_multipleSyncsAccumulate() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        // Execute multiple syncs
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(SYNC_OPERATOR_ADDRESS);
            syncer.executeBatchAccountingSync(true);
        }

        assertEq(mockKernel1.syncCallCount(), 10, "Should have synced 10 times");
    }

    /// @notice Test alternating success and failure in batch
    function test_executeAccountingSync_alternatingSuccessFailure() external {
        address[] memory kernels = _getAllKernels();
        _addKernels(kernels);

        // Alternate: kernel1 succeeds, kernel2 fails, kernel3 succeeds
        mockKernel2.setRevertType(MockKernel.RevertType.CustomError);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        assertEq(mockKernel1.syncCallCount(), 1, "Kernel1 should have synced");
        assertEq(mockKernel3.syncCallCount(), 1, "Kernel3 should have synced");
    }

    /// @notice Test executeBatchSyncFor with empty revert
    function test_executeBatchSyncFor_emptyRevert_errorBytesMatch() external {
        mockKernel1.setRevertType(MockKernel.RevertType.EmptyRevert);

        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        // Get expected empty error bytes
        bytes memory expectedErrorBytes;
        try mockKernel1.syncTrancheAccounting() {
            revert("Should have reverted");
        } catch (bytes memory errorBytes) {
            expectedErrorBytes = errorBytes;
        }

        vm.recordLogs();

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSig = keccak256("AccountingSyncFailed(address,bytes)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                bytes memory emittedErrorBytes = abi.decode(logs[i].data, (bytes));
                assertEq(emittedErrorBytes, expectedErrorBytes, "Empty error bytes should match");
                assertEq(emittedErrorBytes.length, 0, "Should be zero length");
                break;
            }
        }
    }

    /// @notice Test executeBatchSyncFor with panic
    function test_executeBatchSyncFor_panic_errorBytesMatch() external {
        mockKernel1.setRevertType(MockKernel.RevertType.Panic);

        address[] memory kernels = _singleKernelArray(address(mockKernel1));

        // Get expected panic error bytes
        bytes memory expectedErrorBytes;
        try mockKernel1.syncTrancheAccounting() {
            revert("Should have reverted");
        } catch (bytes memory errorBytes) {
            expectedErrorBytes = errorBytes;
        }

        vm.recordLogs();

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSig = keccak256("AccountingSyncFailed(address,bytes)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                bytes memory emittedErrorBytes = abi.decode(logs[i].data, (bytes));
                assertEq(emittedErrorBytes, expectedErrorBytes, "Panic error bytes should match");
                break;
            }
        }
    }

    /// @notice Test custom error with various parameter sizes
    function test_executeAccountingSync_customErrorBytesMatchExactly() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        mockKernel1.setRevertType(MockKernel.RevertType.CustomError);

        // Get expected custom error bytes
        bytes memory expectedErrorBytes;
        try mockKernel1.syncTrancheAccounting() {
            revert("Should have reverted");
        } catch (bytes memory errorBytes) {
            expectedErrorBytes = errorBytes;
        }

        vm.recordLogs();

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSig = keccak256("AccountingSyncFailed(address,bytes)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                bytes memory emittedErrorBytes = abi.decode(logs[i].data, (bytes));
                assertEq(emittedErrorBytes, expectedErrorBytes, "Custom error bytes should match exactly");
                // Verify it starts with CustomSyncError selector
                assertEq(bytes4(emittedErrorBytes), MockKernel.CustomSyncError.selector, "Should be CustomSyncError");
                break;
            }
        }
    }

    /// @notice Test kernel that resets between calls
    function test_executeAccountingSync_kernelStateReset() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        // First call fails
        mockKernel1.setRevertType(MockKernel.RevertType.StringRevert);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);
        assertEq(mockKernel1.syncCallCount(), 0, "Should not have synced");

        // Reset kernel to succeed
        mockKernel1.setRevertType(MockKernel.RevertType.None);

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);
        assertEq(mockKernel1.syncCallCount(), 1, "Should have synced after reset");
    }

    /// @notice Test indexed kernel address in event matches actual kernel
    function test_executeAccountingSync_eventIndexedAddressCorrect() external {
        address[] memory kernels = _getAllKernels();
        _addKernels(kernels);

        mockKernel1.setRevertType(MockKernel.RevertType.StringRevert);
        mockKernel2.setRevertType(MockKernel.RevertType.CustomError);
        mockKernel3.setRevertType(MockKernel.RevertType.EmptyRevert);

        vm.recordLogs();

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSig = keccak256("AccountingSyncFailed(address,bytes)");

        address[] memory failedKernels = new address[](3);
        uint256 count = 0;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                address kernelAddr = address(uint160(uint256(logs[i].topics[1])));
                failedKernels[count] = kernelAddr;
                count++;
            }
        }

        assertEq(count, 3, "Should have 3 failure events");
        // Verify each kernel address was emitted (order may vary due to EnumerableSet)
        bool found1 = false;
        bool found2 = false;
        bool found3 = false;
        for (uint256 i = 0; i < 3; i++) {
            if (failedKernels[i] == address(mockKernel1)) found1 = true;
            if (failedKernels[i] == address(mockKernel2)) found2 = true;
            if (failedKernels[i] == address(mockKernel3)) found3 = true;
        }
        assertTrue(found1, "Kernel1 should be in events");
        assertTrue(found2, "Kernel2 should be in events");
        assertTrue(found3, "Kernel3 should be in events");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION 13: EDGE CASE STRESS TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test syncing a large number of kernels (100+) to verify gas efficiency and correctness
    function test_executeBatchSyncFor_largeKernelSet() external {
        uint256 numKernels = 100;
        address[] memory kernels = new address[](numKernels);

        // Create 100 mock kernels
        for (uint256 i = 0; i < numKernels; i++) {
            address trancheAddr = makeAddr(string.concat("Tranche", vm.toString(i)));
            MockKernel kernel = new MockKernel(trancheAddr);
            kernels[i] = address(kernel);

            // Deploy matching tranche
            MockTranche tranche = new MockTranche(address(kernel));
            vm.etch(trancheAddr, address(tranche).code);
            vm.store(trancheAddr, bytes32(0), bytes32(uint256(uint160(address(kernel)))));
        }

        // Sync all 100 kernels
        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);

        // Verify all kernels were synced
        for (uint256 i = 0; i < numKernels; i++) {
            assertEq(MockKernel(kernels[i]).syncCallCount(), 1, "Each kernel should be synced once");
        }
    }

    /// @notice Test syncing large kernel set with mixed success/failure
    function test_executeBatchSyncFor_largeKernelSet_mixedResults() external {
        uint256 numKernels = 50;
        address[] memory kernels = new address[](numKernels);

        // Create 50 mock kernels, half will fail
        for (uint256 i = 0; i < numKernels; i++) {
            address trancheAddr = makeAddr(string.concat("TrancheM", vm.toString(i)));
            MockKernel kernel = new MockKernel(trancheAddr);
            kernels[i] = address(kernel);

            // Every other kernel fails
            if (i % 2 == 0) {
                kernel.setRevertType(MockKernel.RevertType.StringRevert);
            }
        }

        vm.recordLogs();

        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSyncFor(kernels, true);

        // Count failure events
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSig = keccak256("AccountingSyncFailed(address,bytes)");
        uint256 failureCount = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                failureCount++;
            }
        }

        assertEq(failureCount, 25, "Should have 25 failure events");

        // Verify successful kernels were synced
        for (uint256 i = 0; i < numKernels; i++) {
            if (i % 2 == 1) {
                assertEq(MockKernel(kernels[i]).syncCallCount(), 1, "Odd kernels should be synced");
            }
        }
    }

    /// @notice Test that selector storage works correctly even with dirty memory
    /// @dev Verifies _allocateSyncSelector works regardless of prior memory state
    function test_executeAccountingSync_selectorWithDirtyMemory() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        // Allocate and dirty some memory before the sync call
        // This simulates a scenario where free memory pointer points to used/dirty memory
        assembly {
            let ptr := mload(0x40)
            // Write garbage to the next 128 bytes
            mstore(ptr, 0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef)
            mstore(add(ptr, 0x20), 0xcafebabecafebabecafebabecafebabecafebabecafebabecafebabecafebabe)
            mstore(add(ptr, 0x40), 0x1234567812345678123456781234567812345678123456781234567812345678)
            mstore(add(ptr, 0x60), 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff)
            // Don't update free memory pointer - leave it pointing to dirty memory
        }

        // Execute sync - should work correctly despite dirty memory
        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        // Verify sync was called correctly
        assertEq(mockKernel1.syncCallCount(), 1, "Sync should succeed with dirty memory");
    }

    /// @notice Test selector storage after multiple memory allocations
    function test_executeAccountingSync_selectorAfterManyAllocations() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        // Perform many memory allocations to move free memory pointer far
        for (uint256 i = 0; i < 100; i++) {
            bytes memory temp = new bytes(256);
            temp[0] = bytes1(uint8(i));
        }

        // Execute sync - selector should still be stored and called correctly
        vm.prank(SYNC_OPERATOR_ADDRESS);
        syncer.executeBatchAccountingSync(true);

        assertEq(mockKernel1.syncCallCount(), 1, "Sync should succeed after many allocations");
    }

    /// @notice Test that repeated syncs work correctly (memory cleanup between calls)
    function test_executeAccountingSync_repeatedSyncsWithFailures() external {
        address[] memory kernels = _singleKernelArray(address(mockKernel1));
        _addKernels(kernels);

        // Alternate between success and failure over 10 syncs
        for (uint256 i = 0; i < 10; i++) {
            if (i % 2 == 0) {
                mockKernel1.setRevertType(MockKernel.RevertType.StringRevert);
            } else {
                mockKernel1.setRevertType(MockKernel.RevertType.None);
            }

            vm.prank(SYNC_OPERATOR_ADDRESS);
            syncer.executeBatchAccountingSync(true);
        }

        // 5 successful syncs (i = 1, 3, 5, 7, 9)
        assertEq(mockKernel1.syncCallCount(), 5, "Should have 5 successful syncs");
    }
}
