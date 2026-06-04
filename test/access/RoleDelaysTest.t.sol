// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IAccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { RoycoFactory } from "../../src/factory/RoycoFactory.sol";
import { IRoycoFactory } from "../../src/interfaces/IRoycoFactory.sol";

import { BaseTest } from "../base/BaseTest.t.sol";
import { MockRestrictedTarget } from "./MockRestrictedTarget.sol";

/**
 * @title RoleDelaysTest
 * @notice Validates that every role declared in `RolesConfiguration` has its execution
 *         delay enforced end-to-end at the AccessManager level.
 *
 * For each role, three properties are asserted:
 *   1. ATOMIC: if the role has a delay, a direct call (without scheduling) reverts with
 *      `AccessManagerUnauthorizedCall`.
 *   2. EARLY:  after scheduling, executing 1 second before the delay elapses reverts with
 *      `AccessManagerNotReady`.
 *   3. ON-TIME: after scheduling, executing AT the scheduled timepoint succeeds.
 *
 * Roles with `executionDelay == 0` (Immediate) are validated with a single positive test:
 *   the holder can call the gated function directly without scheduling.
 *
 * Additionally, the test asserts the ADR-0003 "admin operations are not immediate" rule:
 *   after applying the migration's final step (`grantRole(ADMIN_ROLE, FNDN, 2 days)`),
 *   role-0 admin operations on the AccessManager itself — `grantRole`,
 *   `setTargetFunctionRole`, `setRoleAdmin`, `setRoleGuardian` — cannot be called
 *   atomically and require schedule + 48h + execute.
 */
contract RoleDelaysTest is BaseTest {
    // ═══════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════

    MockRestrictedTarget internal TARGET;

    /// @dev Per-role test wallets that hold the role. Mirrors `_generateRoleAssignments`.
    mapping(uint64 => address) internal _holder;
    /// @dev Per-role function selector on `TARGET` that the role holder can call.
    mapping(uint64 => bytes4) internal _selector;

    /// @dev List of every role validated by this suite.
    uint64[] internal _roles;

    /// @dev ADR-0003 Critical delay applied to ADMIN_ROLE (role 0) at the end of setUp.
    uint32 internal constant ADMIN_CRITICAL_DELAY = 2 days;

    // ═══════════════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════════════

    function setUp() public {
        _setUpRoyco();
        _deployFactoryStandalone();
        _deployMockTarget();
        _wireSelectors();
        _grantLPRoles();
        _applyADR0003AdminDelay();
    }

    /// @dev Inline factory deploy (no market needed). Uses BaseTest's role wallets so the
    ///      `_generateRoleAssignments` plumbing produces a fully-populated factory. Extra
    ///      roles (`ADMIN_UNPAUSER_ROLE`) are granted post-init pranked as FNDN (=OWNER for
    ///      this standalone deploy), mirroring `BaseTest._wireExtraRoles`.
    function _deployFactoryStandalone() internal {
        RoycoFactory factoryImpl = new RoycoFactory();
        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();
        bytes memory initData = abi.encodeCall(RoycoFactory.initialize, (OWNER_ADDRESS, DEPLOYER_ADDRESS, 1 weeks, roleAssignments));
        FACTORY = RoycoFactory(address(new ERC1967Proxy(address(factoryImpl), initData)));
        vm.label(address(FACTORY), "FACTORY");

        vm.prank(OWNER_ADDRESS);
        IAccessManager(address(FACTORY)).grantRole(ADMIN_UNPAUSER_ROLE, UNPAUSER_ADDRESS, 0);
    }

    function _deployMockTarget() internal {
        MockRestrictedTarget impl = new MockRestrictedTarget();
        bytes memory initData = abi.encodeCall(MockRestrictedTarget.initialize, (address(FACTORY)));
        TARGET = MockRestrictedTarget(address(new ERC1967Proxy(address(impl), initData)));
        vm.label(address(TARGET), "MockRestrictedTarget");
    }

    /// @dev For each role, register its holder + the selector on TARGET that exercises it.
    ///      Then call `setTargetFunctionRole` once per role from OWNER (admin role 0).
    function _wireSelectors() internal {
        _register(ADMIN_PAUSER_ROLE, PAUSER_ADDRESS, TARGET.callAdminPauser.selector);
        _register(ADMIN_UNPAUSER_ROLE, UNPAUSER_ADDRESS, TARGET.callAdminUnpauser.selector);
        _register(ADMIN_UPGRADER_ROLE, UPGRADER_ADDRESS, TARGET.callAdminUpgrader.selector);
        _register(SYNC_ROLE, SYNC_ROLE_ADDRESS, TARGET.callSync.selector);
        _register(ADMIN_KERNEL_ROLE, KERNEL_ADMIN_ADDRESS, TARGET.callAdminKernel.selector);
        _register(ADMIN_ACCOUNTANT_ROLE, ACCOUNTANT_ADMIN_ADDRESS, TARGET.callAdminAccountant.selector);
        _register(ADMIN_PROTOCOL_FEE_SETTER_ROLE, PROTOCOL_FEE_SETTER_ADDRESS, TARGET.callAdminProtocolFeeSetter.selector);
        _register(ADMIN_ORACLE_QUOTER_ROLE, ORACLE_QUOTER_ADMIN_ADDRESS, TARGET.callAdminOracleQuoter.selector);
        _register(LP_ROLE_ADMIN_ROLE, LP_ROLE_ADMIN_ADDRESS, TARGET.callLpRoleAdmin.selector);
        _register(GUARDIAN_ROLE, ROLE_GUARDIAN_ADDRESS, TARGET.callGuardian.selector);
        _register(DEPLOYER_ROLE, DEPLOYER_ADDRESS, TARGET.callDeployer.selector);
        _register(DEPLOYER_ROLE_ADMIN_ROLE, DEPLOYER_ADMIN_ADDRESS, TARGET.callDeployerAdmin.selector);
        _register(TRANSFER_AGENT_ROLE, TRANSFER_AGENT_ADDRESS, TARGET.callTransferAgent.selector);
        _register(ST_LP_ROLE, ST_BOB_ADDRESS, TARGET.callStLp.selector); // ST_BOB is granted ST_LP_ROLE below
        _register(JT_LP_ROLE, JT_ALICE_ADDRESS, TARGET.callJtLp.selector); // JT_ALICE granted JT_LP_ROLE below
    }

    function _register(uint64 _role, address _holderAddr, bytes4 _sel) internal {
        _holder[_role] = _holderAddr;
        _selector[_role] = _sel;
        _roles.push(_role);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = _sel;
        vm.prank(OWNER_ADDRESS);
        IAccessManager(address(FACTORY)).setTargetFunctionRole(address(TARGET), selectors, _role);
    }

    function _grantLPRoles() internal {
        // ST_LP / JT_LP are normally LP-granted by LP_ROLE_ADMIN. Grant the test holders.
        vm.startPrank(LP_ROLE_ADMIN_ADDRESS);
        IAccessManager(address(FACTORY)).grantRole(ST_LP_ROLE, ST_BOB_ADDRESS, 0);
        IAccessManager(address(FACTORY)).grantRole(JT_LP_ROLE, JT_ALICE_ADDRESS, 0);
        vm.stopPrank();
    }

    /// @dev ADR-0003 final migration step: apply Critical delay to the admin holder.
    ///      Re-grants ADMIN_ROLE to OWNER with 2-day execution delay. From this point,
    ///      every role-0-gated factory operation must be schedule + 48h + execute.
    ///
    ///      This grants role 0 to OWNER with delay 2d. Per OZ AccessManager semantics, an
    ///      execution-delay INCREASE (0 → 2d) takes effect immediately; no warp required.
    function _applyADR0003AdminDelay() internal {
        vm.prank(OWNER_ADDRESS);
        IAccessManager(address(FACTORY)).grantRole(_ADMIN_ROLE, OWNER_ADDRESS, ADMIN_CRITICAL_DELAY);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CORE ASSERTIONS — used by every per-role test
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Asserts test 1 + test 2 + on-time success for a role.
    ///      Atomic call must revert; pre-delay execute must revert; on-time execute must succeed.
    function _assertDelayedRoleEnforcement(uint64 _role) internal {
        (, uint32 delay) = IAccessManager(address(FACTORY)).hasRole(_role, _holder[_role]);
        require(delay > 0, "_assertDelayedRoleEnforcement called on immediate role");

        bytes memory data = abi.encodePacked(_selector[_role]);

        // 1. ATOMIC — direct call without scheduling reverts
        vm.prank(_holder[_role]);
        (bool atomicOk,) = address(TARGET).call(data);
        assertFalse(atomicOk, "atomic call must revert for delayed role");

        // Schedule the operation
        vm.prank(_holder[_role]);
        (, uint32 nonce) = IAccessManager(address(FACTORY)).schedule(address(TARGET), data, 0);
        assertTrue(nonce > 0, "schedule must return non-zero nonce");

        // 2. EARLY — execute 1s before the delay elapses reverts (AccessManagerNotReady)
        vm.warp(vm.getBlockTimestamp() + uint256(delay) - 1);
        vm.prank(_holder[_role]);
        (bool earlyOk,) = address(IAccessManager(address(FACTORY))).call(abi.encodeCall(IAccessManager.execute, (address(TARGET), data)));
        assertFalse(earlyOk, "execute one second before delay must revert");

        // 3. ON-TIME — execute exactly when the delay elapses succeeds
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(_holder[_role]);
        IAccessManager(address(FACTORY)).execute(address(TARGET), data);
    }

    /// @dev Asserts an immediate role: holder calls the gated function directly with no scheduling.
    function _assertImmediateRoleEnforcement(uint64 _role) internal {
        (, uint32 delay) = IAccessManager(address(FACTORY)).hasRole(_role, _holder[_role]);
        require(delay == 0, "_assertImmediateRoleEnforcement called on delayed role");

        bytes memory data = abi.encodePacked(_selector[_role]);
        vm.prank(_holder[_role]);
        (bool ok,) = address(TARGET).call(data);
        assertTrue(ok, "immediate role direct call must succeed");
    }

    /// @dev Dispatches to the correct enforcement assertion based on the role's declared delay.
    function _assertRoleEnforcement(uint64 _role) internal {
        (, uint32 delay) = IAccessManager(address(FACTORY)).hasRole(_role, _holder[_role]);
        if (delay > 0) _assertDelayedRoleEnforcement(_role);
        else _assertImmediateRoleEnforcement(_role);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PER-ROLE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_role_ADMIN_PAUSER_ROLE() public {
        _assertRoleEnforcement(ADMIN_PAUSER_ROLE);
    }

    function test_role_ADMIN_UNPAUSER_ROLE() public {
        _assertRoleEnforcement(ADMIN_UNPAUSER_ROLE);
    }

    function test_role_ADMIN_UPGRADER_ROLE() public {
        _assertRoleEnforcement(ADMIN_UPGRADER_ROLE);
    }

    function test_role_SYNC_ROLE() public {
        _assertRoleEnforcement(SYNC_ROLE);
    }

    function test_role_ADMIN_KERNEL_ROLE() public {
        _assertRoleEnforcement(ADMIN_KERNEL_ROLE);
    }

    function test_role_ADMIN_ACCOUNTANT_ROLE() public {
        _assertRoleEnforcement(ADMIN_ACCOUNTANT_ROLE);
    }

    function test_role_ADMIN_PROTOCOL_FEE_SETTER_ROLE() public {
        _assertRoleEnforcement(ADMIN_PROTOCOL_FEE_SETTER_ROLE);
    }

    function test_role_ADMIN_ORACLE_QUOTER_ROLE() public {
        _assertRoleEnforcement(ADMIN_ORACLE_QUOTER_ROLE);
    }

    function test_role_LP_ROLE_ADMIN_ROLE() public {
        _assertRoleEnforcement(LP_ROLE_ADMIN_ROLE);
    }

    function test_role_GUARDIAN_ROLE() public {
        _assertRoleEnforcement(GUARDIAN_ROLE);
    }

    function test_role_DEPLOYER_ROLE() public {
        _assertRoleEnforcement(DEPLOYER_ROLE);
    }

    function test_role_DEPLOYER_ROLE_ADMIN_ROLE() public {
        _assertRoleEnforcement(DEPLOYER_ROLE_ADMIN_ROLE);
    }

    function test_role_TRANSFER_AGENT_ROLE() public {
        _assertRoleEnforcement(TRANSFER_AGENT_ROLE);
    }

    function test_role_ST_LP_ROLE() public {
        _assertRoleEnforcement(ST_LP_ROLE);
    }

    function test_role_JT_LP_ROLE() public {
        _assertRoleEnforcement(JT_LP_ROLE);
    }

    /// @dev Sweep test as a defensive check: every registered role passes its tier.
    ///      Catches any role we forget to add a per-role test for.
    function test_allRoles_sweep() public {
        for (uint256 i = 0; i < _roles.length; i++) {
            _assertRoleEnforcement(_roles[i]);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN-OPERATIONS SANITY (ADR-0003 §3)
    //
    // "Any admin operation not marked as immediate should not be immediate. Changing
    //  any roles / timelock durations should not be immediate — they should be under
    //  a delay."
    // ═══════════════════════════════════════════════════════════════════════════

    function test_adminRole_hasCriticalDelay() public {
        (bool isMember, uint32 delay) = IAccessManager(address(FACTORY)).hasRole(_ADMIN_ROLE, OWNER_ADDRESS);
        assertTrue(isMember, "OWNER must hold ADMIN_ROLE");
        assertEq(uint256(delay), uint256(ADMIN_CRITICAL_DELAY), "ADMIN_ROLE delay must be Critical (48h)");
    }

    function test_adminOp_grantRole_isNotImmediate() public {
        // Granting a role IS an admin operation. After ADR-0003 it must require schedule + 48h.
        bytes memory data = abi.encodeCall(IAccessManager.grantRole, (ADMIN_KERNEL_ROLE, address(0xDEAD), 0));
        _assertAdminOpDelayed(data);
    }

    function test_adminOp_revokeRole_isNotImmediate() public {
        bytes memory data = abi.encodeCall(IAccessManager.revokeRole, (ADMIN_KERNEL_ROLE, KERNEL_ADMIN_ADDRESS));
        _assertAdminOpDelayed(data);
    }

    function test_adminOp_setTargetFunctionRole_isNotImmediate() public {
        bytes4[] memory sel = new bytes4[](1);
        sel[0] = TARGET.callAdminKernel.selector;
        bytes memory data = abi.encodeCall(IAccessManager.setTargetFunctionRole, (address(TARGET), sel, ADMIN_PAUSER_ROLE));
        _assertAdminOpDelayed(data);
    }

    function test_adminOp_setRoleAdmin_isNotImmediate() public {
        bytes memory data = abi.encodeCall(IAccessManager.setRoleAdmin, (ADMIN_KERNEL_ROLE, _ADMIN_ROLE));
        _assertAdminOpDelayed(data);
    }

    function test_adminOp_setRoleGuardian_isNotImmediate() public {
        bytes memory data = abi.encodeCall(IAccessManager.setRoleGuardian, (ADMIN_KERNEL_ROLE, GUARDIAN_ROLE));
        _assertAdminOpDelayed(data);
    }

    function test_adminOp_setTargetClosed_isNotImmediate() public {
        bytes memory data = abi.encodeCall(IAccessManager.setTargetClosed, (address(TARGET), true));
        _assertAdminOpDelayed(data);
    }

    /// @dev Atomic-call must revert + early-execute must revert + on-time execute must succeed,
    ///      using OWNER (the ADMIN_ROLE holder, with Critical delay) as the caller and the
    ///      factory itself as the target.
    function _assertAdminOpDelayed(bytes memory _data) internal {
        // 1. ATOMIC — direct call to the factory must revert
        vm.prank(OWNER_ADDRESS);
        (bool atomicOk,) = address(FACTORY).call(_data);
        assertFalse(atomicOk, "admin op must not be callable atomically");

        // Schedule
        vm.prank(OWNER_ADDRESS);
        (, uint32 nonce) = IAccessManager(address(FACTORY)).schedule(address(FACTORY), _data, 0);
        assertTrue(nonce > 0, "admin op schedule must return non-zero nonce");

        // 2. EARLY — execute 1s before the Critical delay elapses must revert
        vm.warp(vm.getBlockTimestamp() + uint256(ADMIN_CRITICAL_DELAY) - 1);
        vm.prank(OWNER_ADDRESS);
        (bool earlyOk,) = address(FACTORY).call(abi.encodeCall(IAccessManager.execute, (address(FACTORY), _data)));
        assertFalse(earlyOk, "admin op must not execute before Critical delay elapses");

        // 3. ON-TIME — execute when the delay elapses must succeed
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(OWNER_ADDRESS);
        IAccessManager(address(FACTORY)).execute(address(FACTORY), _data);
    }
}
