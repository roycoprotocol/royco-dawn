// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { Initializable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { AccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ADMIN_FACTORY_ROLE, ADMIN_ROLE, DEPLOYER_ROLE } from "../../src/factory/RolesConfiguration.sol";
import { RoycoFactory } from "../../src/factory/RoycoFactory.sol";
import { IBaseTemplate } from "../../src/interfaces/factory/IBaseTemplate.sol";
import { IRoycoFactory } from "../../src/interfaces/factory/IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "../../src/interfaces/factory/IRoycoProtocolTemplate.sol";

// ──────────────────────────────────────────────────────────────────────────────
// MockTemplate
//
// Minimal IBaseTemplate implementation we can use to exercise the factory's
// lifecycle without dragging in the full Dawn/Dusk machinery. Tracks how it was
// called so tests can assert what the factory invoked.
//
// Because the real `BaseDeploymentTemplate.initialize` is `external`, we
// duplicate just the surface we need (immutable factory binding + one-shot
// initialize + SSTORE2-free pointer storage) rather than inheriting the heavy
// base.
// ──────────────────────────────────────────────────────────────────────────────
contract MockTemplate is IBaseTemplate, Initializable {
    IRoycoFactory public immutable override(IBaseTemplate) ROYCO_FACTORY;

    /// @dev Loose storage — we don't need SSTORE2 in tests. Just records the IDs registered.
    mapping(bytes32 => bytes) public storedCode;

    /// @dev Public counters / last-call inspectors used in assertions. `verify` is `view` on
    /// the interface, so we count its calls in a separate side-channel contract.
    uint256 public deployMarketCalls;
    bytes public lastDeployMarketParams;

    /// @dev Programmable hook — when non-zero, deployMarket calls back into this slot's
    /// configured factory primitive to assert active-template gating in tests.
    enum CallbackMode {
        NONE,
        DEPLOY_CONTRACT,
        DEPLOY_PROXY,
        SET_ROLE,
        GRANT_ROLE
    }

    CallbackMode public callbackMode;
    bytes public callbackCode;
    bytes32 public callbackSalt;
    address public callbackTarget;
    bytes4 public callbackSelector;
    uint64 public callbackRoleId;
    address public callbackAccount;
    uint32 public callbackDelay;
    address public callbackImpl;

    address public lastDeployedAddress;
    bool public lastAlreadyDeployed;

    bool public verifyShouldRevert;

    constructor(IRoycoFactory _factory) {
        ROYCO_FACTORY = _factory;
    }

    function bytecodePointer(bytes32 _componentId) external view override(IBaseTemplate) returns (address) {
        // We just return a non-zero sentinel if we have any stored code for the ID,
        // good enough for the "did init populate something" check in tests.
        return storedCode[_componentId].length > 0 ? address(this) : address(0);
    }

    function initialize(bytes32[] calldata _componentIds, bytes[] calldata _creationCodes) external override(IRoycoProtocolTemplate) initializer {
        require(msg.sender == address(ROYCO_FACTORY), ONLY_ROYCO_FACTORY());
        require(_componentIds.length == _creationCodes.length, LENGTH_MISMATCH());
        for (uint256 i; i < _componentIds.length; ++i) {
            require(_creationCodes[i].length > 0, CREATION_CODE_CANNOT_BE_EMPTY(_componentIds[i]));
            storedCode[_componentIds[i]] = _creationCodes[i];
        }
    }

    function validateParams(bytes calldata) external pure override(IRoycoProtocolTemplate) {
        // No-op: any params are valid in tests.
    }

    function deployMarket(bytes calldata _params) external override(IRoycoProtocolTemplate) returns (DeploymentResult memory result) {
        ++deployMarketCalls;
        lastDeployMarketParams = _params;

        if (callbackMode == CallbackMode.DEPLOY_CONTRACT) {
            (lastDeployedAddress, lastAlreadyDeployed) = ROYCO_FACTORY.deployDeterministicContract(callbackCode, callbackSalt);
        } else if (callbackMode == CallbackMode.DEPLOY_PROXY) {
            // Non-empty initData required by OZ ERC1967Proxy. The test wires up `callbackImpl`
            // to a `TrivialInitializable` whose `initialize()` is a no-op.
            (lastDeployedAddress, lastAlreadyDeployed) =
                ROYCO_FACTORY.deployDeterministicProxy(callbackImpl, abi.encodeCall(TrivialInitializable.initialize, ()), callbackSalt);
        } else if (callbackMode == CallbackMode.SET_ROLE) {
            ROYCO_FACTORY.setMarketTargetFunctionRole(callbackTarget, callbackSelector, callbackRoleId);
        } else if (callbackMode == CallbackMode.GRANT_ROLE) {
            ROYCO_FACTORY.grantMarketRole(callbackRoleId, callbackAccount, callbackDelay);
        }

        // Return some non-zero sentinels so verify() has something to inspect.
        result.seniorTranche = address(0x1111);
        result.juniorTranche = address(0x2222);
        result.kernel = address(0x3333);
        result.accountant = address(0x4444);
        result.ydm = address(0x5555);
        result.extras = "";
    }

    function verify(DeploymentResult calldata) external view override(IRoycoProtocolTemplate) {
        require(!verifyShouldRevert, "MOCK_VERIFY_REVERT");
    }

    // ─── test-side configurators ──────────────────────────────────────────────
    function setVerifyShouldRevert(bool _v) external {
        verifyShouldRevert = _v;
    }

    function configureDeployContractCallback(bytes calldata _code, bytes32 _salt) external {
        callbackMode = CallbackMode.DEPLOY_CONTRACT;
        callbackCode = _code;
        callbackSalt = _salt;
    }

    function configureDeployProxyCallback(address _impl, bytes32 _salt) external {
        callbackMode = CallbackMode.DEPLOY_PROXY;
        callbackImpl = _impl;
        callbackSalt = _salt;
    }

    function configureSetRoleCallback(address _t, bytes4 _s, uint64 _r) external {
        callbackMode = CallbackMode.SET_ROLE;
        callbackTarget = _t;
        callbackSelector = _s;
        callbackRoleId = _r;
    }

    function configureGrantRoleCallback(uint64 _r, address _a, uint32 _d) external {
        callbackMode = CallbackMode.GRANT_ROLE;
        callbackRoleId = _r;
        callbackAccount = _a;
        callbackDelay = _d;
    }
}

    /// @dev Trivial deployable contract — used by idempotency tests.
    contract TinyContract {
        uint256 public immutable n;

        constructor(uint256 _n) {
            n = _n;
        }
    }

    /// @dev Tiny initializable impl for proxy idempotency tests. OZ ERC1967Proxy now requires
    ///      non-empty initData; this gives us a target whose `initialize()` is a no-op and
    ///      doesn't need any external state setup (no AM, no roles).
    contract TrivialInitializable {
        function initialize() external { }
    }

    contract RoycoFactoryTest is Test {
        AccessManager internal am;
        RoycoFactory internal factoryImpl;
        RoycoFactory internal factory;

        address internal constant ADMIN = address(0xA11CE);
        address internal constant DEPLOYER = address(0xDEEDEE);
        address internal constant FACTORY_ADMIN = address(0xFACADE);
        address internal constant RANDO = address(0xBEEF);

        function setUp() public {
            // ADMIN owns the AM. The factory must hold `ADMIN_ROLE` on the AM BEFORE
            // its proxy constructor fires `initialize` (OZ ERC1967Proxy now mandates atomic
            // init), so we predict the proxy address up front, grant the role, then deploy.
            am = new AccessManager(ADMIN);
            factoryImpl = new RoycoFactory();

            address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
            vm.prank(ADMIN);
            am.grantRole(ADMIN_ROLE, predicted, 0);

            factory = RoycoFactory(address(new ERC1967Proxy(address(factoryImpl), abi.encodeCall(RoycoFactory.initialize, (address(am))))));
            require(address(factory) == predicted, "predicted-vs-actual proxy mismatch");

            vm.startPrank(ADMIN);
            am.grantRole(ADMIN_FACTORY_ROLE, FACTORY_ADMIN, 0);
            am.grantRole(DEPLOYER_ROLE, DEPLOYER, 0);
            vm.stopPrank();
        }

        // ═══════════════════════════════════════════════════════════════════════════
        // INITIALIZATION
        // ═══════════════════════════════════════════════════════════════════════════
        //
        // OZ ERC1967Proxy now requires non-empty initData, so the failure modes that used to
        // happen during a separate `initialize()` call now bubble up through the proxy's
        // constructor's delegatecall. Each `revertsFor*` test deploys the proxy with bad
        // init data and expects the constructor itself to revert.

        function test_initialize_revertsForZeroAccessManager() public {
            vm.expectRevert(IRoycoFactory.ACCESS_MANAGER_CANNOT_BE_ZERO_ADDRESS.selector);
            new ERC1967Proxy(address(factoryImpl), abi.encodeCall(RoycoFactory.initialize, (address(0))));
        }

        function test_initialize_revertsForAccessManagerWithoutCode() public {
            vm.expectRevert(IRoycoFactory.ACCESS_MANAGER_HAS_NO_CODE.selector);
            new ERC1967Proxy(address(factoryImpl), abi.encodeCall(RoycoFactory.initialize, (address(0xC0DE))));
        }

        function test_initialize_revertsWhenFactoryNotAdminOnAM() public {
            AccessManager fresh = new AccessManager(ADMIN);
            vm.expectRevert(IRoycoFactory.FACTORY_NOT_ADMIN_ON_ACCESS_MANAGER.selector);
            new ERC1967Proxy(address(factoryImpl), abi.encodeCall(RoycoFactory.initialize, (address(fresh))));
        }

        function test_initialize_setsAuthorityAndAccessManager() public view {
            assertEq(factory.ROYCO_AUTHORITY(), address(am));
            assertEq(factory.authority(), address(am));
        }

        function test_initialize_cannotBeCalledTwice() public {
            vm.expectRevert(Initializable.InvalidInitialization.selector);
            factory.initialize(address(am));
        }

        // ═══════════════════════════════════════════════════════════════════════════
        // TEMPLATE REGISTRATION
        // ═══════════════════════════════════════════════════════════════════════════

        function test_registerTemplate_revertsForNonAdmin() public {
            MockTemplate tmpl = new MockTemplate(IRoycoFactory(address(factory)));
            bytes32[] memory ids = new bytes32[](0);
            bytes[] memory codes = new bytes[](0);
            vm.prank(RANDO);
            vm.expectRevert(); // AccessManagedUnauthorized
            factory.registerTemplate(address(tmpl), ids, codes);
        }

        function test_registerTemplate_revertsForZeroAddress() public {
            bytes32[] memory ids = new bytes32[](0);
            bytes[] memory codes = new bytes[](0);
            vm.prank(FACTORY_ADMIN);
            vm.expectRevert(IRoycoFactory.TEMPLATE_CANNOT_BE_ZERO_ADDRESS.selector);
            factory.registerTemplate(address(0), ids, codes);
        }

        function test_registerTemplate_revertsForWrongFactoryBinding() public {
            // Construct a template pointing at a *different* factory address — this one is
            // pointed at the AccessManager just to use any non-factory address.
            MockTemplate tmpl = new MockTemplate(IRoycoFactory(address(am)));
            bytes32[] memory ids = new bytes32[](0);
            bytes[] memory codes = new bytes[](0);
            vm.prank(FACTORY_ADMIN);
            vm.expectRevert(IRoycoFactory.TEMPLATE_BOUND_TO_DIFFERENT_FACTORY.selector);
            factory.registerTemplate(address(tmpl), ids, codes);
        }

        function test_registerTemplate_initializesAndEnables() public {
            MockTemplate tmpl = new MockTemplate(IRoycoFactory(address(factory)));
            bytes32[] memory ids = new bytes32[](2);
            ids[0] = keccak256("TEST_COMPONENT_A");
            ids[1] = keccak256("TEST_COMPONENT_B");
            bytes[] memory codes = new bytes[](2);
            codes[0] = hex"deadbeef";
            codes[1] = hex"cafebabe";

            vm.expectEmit(true, false, false, false);
            emit IRoycoFactory.TemplateRegistered(address(tmpl));
            vm.prank(FACTORY_ADMIN);
            factory.registerTemplate(address(tmpl), ids, codes);

            assertTrue(factory.isTemplateEnabled(address(tmpl)));
            assertEq(tmpl.storedCode(ids[0]), hex"deadbeef");
            assertEq(tmpl.storedCode(ids[1]), hex"cafebabe");
        }

        function test_registerTemplate_revertsOnDuplicateRegistration() public {
            MockTemplate tmpl = new MockTemplate(IRoycoFactory(address(factory)));
            bytes32[] memory ids = new bytes32[](0);
            bytes[] memory codes = new bytes[](0);

            vm.prank(FACTORY_ADMIN);
            factory.registerTemplate(address(tmpl), ids, codes);

            vm.prank(FACTORY_ADMIN);
            vm.expectRevert(IRoycoFactory.TEMPLATE_ALREADY_REGISTERED.selector);
            factory.registerTemplate(address(tmpl), ids, codes);
        }

        function test_initialize_revertsWhenCalledDirectlyAfterRegistration() public {
            MockTemplate tmpl = new MockTemplate(IRoycoFactory(address(factory)));
            bytes32[] memory ids = new bytes32[](0);
            bytes[] memory codes = new bytes[](0);
            vm.prank(FACTORY_ADMIN);
            factory.registerTemplate(address(tmpl), ids, codes);

            // Direct call to template.initialize is blocked by both OZ Initializable AND the
            // factory-only check; OZ's check happens first.
            vm.prank(address(factory));
            vm.expectRevert(Initializable.InvalidInitialization.selector);
            tmpl.initialize(ids, codes);
        }

        function test_initialize_revertsWhenNotCalledByFactory() public {
            MockTemplate tmpl = new MockTemplate(IRoycoFactory(address(factory)));
            bytes32[] memory ids = new bytes32[](0);
            bytes[] memory codes = new bytes[](0);
            // Direct EOA call without going through factory — fails the msg.sender check.
            vm.expectRevert(IRoycoProtocolTemplate.ONLY_ROYCO_FACTORY.selector);
            tmpl.initialize(ids, codes);
        }

        // ═══════════════════════════════════════════════════════════════════════════
        // TEMPLATE DISABLE
        // ═══════════════════════════════════════════════════════════════════════════

        function test_disableTemplate_flipsEnabledBit() public {
            MockTemplate tmpl = _registerMockTemplate();

            vm.expectEmit(true, false, false, false);
            emit IRoycoFactory.TemplateDisabled(address(tmpl));
            vm.prank(FACTORY_ADMIN);
            factory.disableTemplate(address(tmpl));

            assertFalse(factory.isTemplateEnabled(address(tmpl)));
        }

        function test_disableTemplate_blocksFurtherDeployments() public {
            MockTemplate tmpl = _registerMockTemplate();

            vm.prank(FACTORY_ADMIN);
            factory.disableTemplate(address(tmpl));

            vm.prank(DEPLOYER);
            vm.expectRevert(IRoycoFactory.TEMPLATE_NOT_ENABLED.selector);
            factory.executeMarketDeployment(address(tmpl), "");
        }

        // ═══════════════════════════════════════════════════════════════════════════
        // executeMarketDeployment
        // ═══════════════════════════════════════════════════════════════════════════

        function test_executeMarketDeployment_revertsForNonDeployer() public {
            MockTemplate tmpl = _registerMockTemplate();
            vm.prank(RANDO);
            vm.expectRevert();
            factory.executeMarketDeployment(address(tmpl), "");
        }

        function test_executeMarketDeployment_callsDeployAndVerify() public {
            MockTemplate tmpl = _registerMockTemplate();
            bytes memory params = hex"abcd";

            // Assert verify is called (it's view so we can't count it from inside the mock).
            vm.expectCall(address(tmpl), abi.encodeWithSelector(IRoycoProtocolTemplate.verify.selector));
            vm.prank(DEPLOYER);
            IRoycoProtocolTemplate.DeploymentResult memory r = factory.executeMarketDeployment(address(tmpl), params);

            assertEq(tmpl.deployMarketCalls(), 1);
            assertEq(tmpl.lastDeployMarketParams(), params);
            assertEq(r.seniorTranche, address(0x1111));
        }

        function test_executeMarketDeployment_abortsWhenVerifyReverts() public {
            MockTemplate tmpl = _registerMockTemplate();
            tmpl.setVerifyShouldRevert(true);

            vm.prank(DEPLOYER);
            vm.expectRevert("MOCK_VERIFY_REVERT");
            factory.executeMarketDeployment(address(tmpl), "");
        }

        // ═══════════════════════════════════════════════════════════════════════════
        // TEMPLATE-CALLABLE PRIMITIVES (gated by onlyActiveTemplate)
        // ═══════════════════════════════════════════════════════════════════════════

        function test_primitives_revertWhenCalledOutsideDeployment() public {
            // EOA direct calls fail because there is no active template.
            vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
            factory.deployDeterministicContract(hex"00", bytes32(0));
            vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
            factory.deployDeterministicProxy(address(0xBEEF), "", bytes32(0));
            vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
            factory.setMarketTargetFunctionRole(address(0xBEEF), bytes4(0), 0);
            vm.expectRevert(IRoycoFactory.ONLY_ACTIVE_TEMPLATE.selector);
            factory.grantMarketRole(0, address(0xBEEF), 0);
        }

        function test_deployDeterministicContract_idempotent() public {
            MockTemplate tmpl = _registerMockTemplate();

            bytes memory code = abi.encodePacked(type(TinyContract).creationCode, abi.encode(uint256(42)));
            bytes32 salt = keccak256("test-tiny");

            // First call deploys.
            tmpl.configureDeployContractCallback(code, salt);
            vm.prank(DEPLOYER);
            factory.executeMarketDeployment(address(tmpl), "");
            address firstAddr = tmpl.lastDeployedAddress();
            assertTrue(firstAddr.code.length > 0, "first deploy should produce code");
            assertFalse(tmpl.lastAlreadyDeployed(), "first call should not report alreadyDeployed");

            // Second call returns the same address with alreadyDeployed = true.
            tmpl.configureDeployContractCallback(code, salt);
            vm.prank(DEPLOYER);
            factory.executeMarketDeployment(address(tmpl), "");
            assertEq(tmpl.lastDeployedAddress(), firstAddr);
            assertTrue(tmpl.lastAlreadyDeployed(), "second call should report alreadyDeployed");
        }

        function test_deployDeterministicProxy_idempotent() public {
            MockTemplate tmpl = _registerMockTemplate();

            // Use TrivialInitializable as a dummy implementation — its `initialize()` is a no-op
            // so the proxy constructor's mandatory delegatecall succeeds without setup.
            TrivialInitializable impl = new TrivialInitializable();
            bytes32 salt = keccak256("test-proxy");
            tmpl.configureDeployProxyCallback(address(impl), salt);
            vm.prank(DEPLOYER);
            factory.executeMarketDeployment(address(tmpl), "");
            address firstAddr = tmpl.lastDeployedAddress();
            assertTrue(firstAddr.code.length > 0);
            assertFalse(tmpl.lastAlreadyDeployed());

            tmpl.configureDeployProxyCallback(address(impl), salt);
            vm.prank(DEPLOYER);
            factory.executeMarketDeployment(address(tmpl), "");
            assertEq(tmpl.lastDeployedAddress(), firstAddr);
            assertTrue(tmpl.lastAlreadyDeployed());
        }

        function test_predictDeterministicAddress_matchesActualDeploy() public {
            MockTemplate tmpl = _registerMockTemplate();
            bytes memory code = abi.encodePacked(type(TinyContract).creationCode, abi.encode(uint256(7)));
            bytes32 salt = keccak256("predict-vs-deploy");

            address predicted = factory.predictDeterministicAddress(salt);

            tmpl.configureDeployContractCallback(code, salt);
            vm.prank(DEPLOYER);
            factory.executeMarketDeployment(address(tmpl), "");
            assertEq(tmpl.lastDeployedAddress(), predicted);
        }

        function test_setMarketTargetFunctionRole_callableByActiveTemplate() public {
            MockTemplate tmpl = _registerMockTemplate();

            // Use the factory itself as the target — we know it has code and is managed by the AM.
            bytes4 someSelector = bytes4(0xdeadbeef);
            uint64 someRole = DEPLOYER_ROLE;

            tmpl.configureSetRoleCallback(address(factory), someSelector, someRole);
            vm.prank(DEPLOYER);
            factory.executeMarketDeployment(address(tmpl), "");

            // AccessManager exposes getTargetFunctionRole to read back what was set.
            assertEq(am.getTargetFunctionRole(address(factory), someSelector), someRole);
        }

        function test_grantMarketRole_callableByActiveTemplate() public {
            MockTemplate tmpl = _registerMockTemplate();

            uint64 newRole = uint64(uint256(keccak256("TEST_NEW_ROLE")));
            tmpl.configureGrantRoleCallback(newRole, RANDO, 0);
            vm.prank(DEPLOYER);
            factory.executeMarketDeployment(address(tmpl), "");

            (bool isMember,) = am.hasRole(newRole, RANDO);
            assertTrue(isMember);
        }

        // ═══════════════════════════════════════════════════════════════════════════
        // HELPERS
        // ═══════════════════════════════════════════════════════════════════════════

        function _registerMockTemplate() internal returns (MockTemplate tmpl) {
            tmpl = new MockTemplate(IRoycoFactory(address(factory)));
            bytes32[] memory ids = new bytes32[](0);
            bytes[] memory codes = new bytes[](0);
            vm.prank(FACTORY_ADMIN);
            factory.registerTemplate(address(tmpl), ids, codes);
        }
    }
