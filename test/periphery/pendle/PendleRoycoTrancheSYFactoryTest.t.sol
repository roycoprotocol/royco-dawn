// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Vm } from "../../../lib/forge-std/src/Vm.sol";

import { ERC20Mock } from "../../../lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

import { TrancheType } from "../../../src/libraries/Types.sol";
import { PendleRoycoTrancheSY } from "../../../src/periphery/pendle/PendleRoycoTrancheSY.sol";
import { PendleRoycoTrancheSYFactory } from "../../../src/periphery/pendle/PendleRoycoTrancheSYFactory.sol";

import { MockTranche } from "../entrypoint/mocks/MockTranche.sol";

/// @notice Minimal mock implementing only the IRoycoFactory tranche-mapping surface that the SY factory consumes
contract MockRoycoFactory {
    mapping(address senior => address junior) public seniorTrancheToJuniorTranche;
    mapping(address junior => address senior) public juniorTrancheToSeniorTranche;

    function registerPair(address _senior, address _junior) external {
        seniorTrancheToJuniorTranche[_senior] = _junior;
        juniorTrancheToSeniorTranche[_junior] = _senior;
    }
}

/// @title PendleRoycoTrancheSYFactoryTest
/// @notice Audit-grade unit tests for PendleRoycoTrancheSYFactory backed by MockTranche + MockRoycoFactory
contract PendleRoycoTrancheSYFactoryTest is Test {
    /// =====================================================================
    /// CONSTANTS (mirrored from spec)
    /// =====================================================================
    address internal constant PENDLE_PROXY_ADMIN = 0xA28c08f165116587D4F3E708743B4dEe155c5E64;
    address internal constant PENDLE_PAUSE_CONTROLLER = 0x2aD631F72fB16d91c4953A7f4260A97C2fE2f31e;
    /// @dev EIP-1967 admin storage slot: bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1)
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    /// =====================================================================
    /// STATE
    /// =====================================================================
    ERC20Mock internal asset;
    MockRoycoFactory internal mockRoycoFactory;
    MockTranche internal seniorTranche;
    MockTranche internal juniorTranche;
    PendleRoycoTrancheSYFactory internal syFactory;

    address internal rewardManager = makeAddr("rewardManager");

    /// @dev Mirrored from PendleRoycoTrancheSYFactory for vm.expectEmit
    event SYDeployed(address indexed tranche, address indexed sy, address indexed implementation);

    /// =====================================================================
    /// SETUP
    /// =====================================================================

    function setUp() public {
        asset = new ERC20Mock();
        mockRoycoFactory = new MockRoycoFactory();

        seniorTranche = new MockTranche(address(asset), address(mockRoycoFactory), TrancheType.SENIOR);
        juniorTranche = new MockTranche(address(asset), address(mockRoycoFactory), TrancheType.JUNIOR);

        mockRoycoFactory.registerPair(address(seniorTranche), address(juniorTranche));

        syFactory = new PendleRoycoTrancheSYFactory(address(mockRoycoFactory));
    }

    /// =====================================================================
    /// CONSTRUCTOR + CONSTANTS
    /// =====================================================================

    function test_constructor_setsImmutable() public view {
        assertEq(syFactory.ROYCO_FACTORY(), address(mockRoycoFactory));
    }

    function test_constructor_revertsOnNullAddress() public {
        vm.expectRevert(PendleRoycoTrancheSYFactory.NULL_ADDRESS.selector);
        new PendleRoycoTrancheSYFactory(address(0));
    }

    function test_constants_matchPendleSpec() public view {
        assertEq(syFactory.PENDLE_PROXY_ADMIN(), PENDLE_PROXY_ADMIN);
        assertEq(syFactory.PENDLE_PAUSE_CONTROLLER(), PENDLE_PAUSE_CONTROLLER);
    }

    /// =====================================================================
    /// deploySY - happy path
    /// =====================================================================

    function test_deploySY_seniorTranche() public {
        address sy = syFactory.deploySY(address(seniorTranche), rewardManager);

        assertGt(sy.code.length, 0);
        assertEq(syFactory.trancheToOffchainRewardManagerToSY(address(seniorTranche), rewardManager), sy);
    }

    function test_deploySY_juniorTranche() public {
        address sy = syFactory.deploySY(address(juniorTranche), rewardManager);

        assertGt(sy.code.length, 0);
        assertEq(syFactory.trancheToOffchainRewardManagerToSY(address(juniorTranche), rewardManager), sy);
    }

    function test_deploySY_eventEmittedWithCorrectTopics() public {
        vm.recordLogs();
        address sy = syFactory.deploySY(address(seniorTranche), rewardManager);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 expectedTopic0 = keccak256("SYDeployed(address,address,address)");
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(syFactory)) continue;
            if (logs[i].topics.length != 4 || logs[i].topics[0] != expectedTopic0) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), address(seniorTranche));
            assertEq(address(uint160(uint256(logs[i].topics[2]))), sy);
            assertGt(uint256(logs[i].topics[3]), 0); // implementation address non-zero
            found = true;
            break;
        }
        assertTrue(found, "SYDeployed log not found");
    }

    function test_deploySY_zeroRewardManagerAllowed() public {
        // Spec allows null reward manager when no offchain rewards exist for this SY.
        address sy = syFactory.deploySY(address(seniorTranche), address(0));
        assertEq(PendleRoycoTrancheSY(payable(sy)).offchainRewardManager(), address(0));
    }

    function test_deploySY_setsMappingsIndependentlyForBothTranches() public {
        address stSY = syFactory.deploySY(address(seniorTranche), rewardManager);
        address jtSY = syFactory.deploySY(address(juniorTranche), rewardManager);

        assertEq(syFactory.trancheToOffchainRewardManagerToSY(address(seniorTranche), rewardManager), stSY);
        assertEq(syFactory.trancheToOffchainRewardManagerToSY(address(juniorTranche), rewardManager), jtSY);
        assertTrue(stSY != jtSY);
    }

    /// =====================================================================
    /// deploySY - SY initialization correctness
    /// =====================================================================

    function test_deploySY_namingConventionFollowsPendleSpec() public {
        // Spec: SY name = "SY " + name(); SY symbol = "SY-" + symbol().
        address stSY = syFactory.deploySY(address(seniorTranche), rewardManager);
        assertEq(PendleRoycoTrancheSY(payable(stSY)).name(), string.concat("SY ", seniorTranche.name()));
        assertEq(PendleRoycoTrancheSY(payable(stSY)).symbol(), string.concat("SY-", seniorTranche.symbol()));

        address jtSY = syFactory.deploySY(address(juniorTranche), rewardManager);
        assertEq(PendleRoycoTrancheSY(payable(jtSY)).name(), string.concat("SY ", juniorTranche.name()));
        assertEq(PendleRoycoTrancheSY(payable(jtSY)).symbol(), string.concat("SY-", juniorTranche.symbol()));
    }

    function test_deploySY_ownerIsPendlePauseController() public {
        // Spec: ownership must be set to Pendle's pause controller (BoringOwnable single-owner).
        address sy = syFactory.deploySY(address(seniorTranche), rewardManager);
        assertEq(PendleRoycoTrancheSY(payable(sy)).owner(), PENDLE_PAUSE_CONTROLLER);
    }

    function test_deploySY_factoryDoesNotRetainOwnership() public {
        address sy = syFactory.deploySY(address(seniorTranche), rewardManager);
        assertTrue(PendleRoycoTrancheSY(payable(sy)).owner() != address(syFactory));
    }

    function test_deploySY_proxyAdminIsPendleProxyAdmin() public {
        // Spec: proxy admin must be Pendle's ProxyAdmin set DIRECTLY as admin (no new ProxyAdmin deployed).
        address sy = syFactory.deploySY(address(seniorTranche), rewardManager);
        bytes32 storedAdmin = vm.load(sy, ADMIN_SLOT);
        assertEq(address(uint160(uint256(storedAdmin))), PENDLE_PROXY_ADMIN);
    }

    function test_deploySY_yieldTokenIsTranche() public {
        address sy = syFactory.deploySY(address(seniorTranche), rewardManager);
        assertEq(PendleRoycoTrancheSY(payable(sy)).yieldToken(), address(seniorTranche));
    }

    function test_deploySY_offchainRewardManagerIsBakedIntoImpl() public {
        address sy = syFactory.deploySY(address(seniorTranche), rewardManager);
        assertEq(PendleRoycoTrancheSY(payable(sy)).offchainRewardManager(), rewardManager);
    }

    function test_deploySY_decimalsMatchTranche() public {
        address sy = syFactory.deploySY(address(seniorTranche), rewardManager);
        assertEq(PendleRoycoTrancheSY(payable(sy)).decimals(), seniorTranche.decimals());
    }

    function test_deploySY_implementationDiffersFromProxy() public {
        vm.recordLogs();
        address sy = syFactory.deploySY(address(seniorTranche), rewardManager);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Pull implementation from the SYDeployed event's third indexed topic.
        bytes32 expectedTopic0 = keccak256("SYDeployed(address,address,address)");
        address implementation;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(syFactory)) continue;
            if (logs[i].topics.length != 4 || logs[i].topics[0] != expectedTopic0) continue;
            implementation = address(uint160(uint256(logs[i].topics[3])));
            break;
        }
        assertTrue(implementation != address(0));
        assertTrue(implementation != sy);
        assertGt(implementation.code.length, 0);
    }

    /// =====================================================================
    /// deploySY - revert paths
    /// =====================================================================

    function test_deploySY_revertsOnNullTranche() public {
        vm.expectRevert(PendleRoycoTrancheSYFactory.NULL_ADDRESS.selector);
        syFactory.deploySY(address(0), rewardManager);
    }

    function test_deploySY_revertsOnEOATranche() public {
        // EOA: no code, the high-level TRANCHE_TYPE() call fails with code-existence check.
        address eoa = makeAddr("eoa");
        vm.expectRevert();
        syFactory.deploySY(eoa, rewardManager);
    }

    function test_deploySY_revertsOnUnregisteredTranche() public {
        // A real tranche that was never registered in the canonical factory mapping.
        MockTranche unregistered = new MockTranche(address(asset), address(mockRoycoFactory), TrancheType.SENIOR);
        vm.expectRevert(PendleRoycoTrancheSYFactory.INVALID_TRANCHE.selector);
        syFactory.deploySY(address(unregistered), rewardManager);
    }

    function test_deploySY_revertsOnTrancheFromDifferentFactory() public {
        MockRoycoFactory otherFactory = new MockRoycoFactory();
        MockTranche otherSt = new MockTranche(address(asset), address(otherFactory), TrancheType.SENIOR);
        MockTranche otherJt = new MockTranche(address(asset), address(otherFactory), TrancheType.JUNIOR);
        otherFactory.registerPair(address(otherSt), address(otherJt));

        vm.expectRevert(PendleRoycoTrancheSYFactory.INVALID_TRANCHE.selector);
        syFactory.deploySY(address(otherSt), rewardManager);
        vm.expectRevert(PendleRoycoTrancheSYFactory.INVALID_TRANCHE.selector);
        syFactory.deploySY(address(otherJt), rewardManager);
    }

    function test_deploySY_revertsOnDuplicateDeployment() public {
        // Same (tranche, rewardManager) pair must collide.
        syFactory.deploySY(address(seniorTranche), rewardManager);
        vm.expectRevert(PendleRoycoTrancheSYFactory.SY_ALREADY_DEPLOYED.selector);
        syFactory.deploySY(address(seniorTranche), rewardManager);
    }

    function test_deploySY_failedRedeployDoesNotCorruptMapping() public {
        // Re-deploying with the same (tranche, rewardManager) pair reverts and leaves the slot intact.
        address firstSY = syFactory.deploySY(address(seniorTranche), rewardManager);

        vm.expectRevert(PendleRoycoTrancheSYFactory.SY_ALREADY_DEPLOYED.selector);
        syFactory.deploySY(address(seniorTranche), rewardManager);

        assertEq(syFactory.trancheToOffchainRewardManagerToSY(address(seniorTranche), rewardManager), firstSY);
        assertEq(PendleRoycoTrancheSY(payable(firstSY)).offchainRewardManager(), rewardManager);
    }

    /// =====================================================================
    /// PERMISSIONLESS / FRONT-RUN NEUTRALIZATION (C-1 fix)
    /// =====================================================================

    function test_deploySY_permissionless_anyCallerCanDeploy() public {
        // deploySY is intentionally permissionless: any address can deploy.
        vm.prank(makeAddr("randomCaller"));
        address sy = syFactory.deploySY(address(seniorTranche), rewardManager);
        assertEq(syFactory.trancheToOffchainRewardManagerToSY(address(seniorTranche), rewardManager), sy);
    }

    function test_deploySY_frontRunDoesNotLockOutLegitimateDeployer() public {
        // C-1 fix: keying trancheToSY by (tranche, rewardManager) means a malicious front-run
        // only occupies the attacker's own slot. The legitimate (tranche, rewardManager) pair
        // remains free, and the legitimate SY is the one Pendle will list.
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        address attackerSY = syFactory.deploySY(address(seniorTranche), attacker);

        // Legitimate deployer can still deploy with their own reward manager.
        address legitSY = syFactory.deploySY(address(seniorTranche), rewardManager);

        assertTrue(legitSY != attackerSY);
        assertEq(syFactory.trancheToOffchainRewardManagerToSY(address(seniorTranche), attacker), attackerSY);
        assertEq(syFactory.trancheToOffchainRewardManagerToSY(address(seniorTranche), rewardManager), legitSY);
        assertEq(PendleRoycoTrancheSY(payable(legitSY)).offchainRewardManager(), rewardManager);
        assertEq(PendleRoycoTrancheSY(payable(attackerSY)).offchainRewardManager(), attacker);
    }

    /// =====================================================================
    /// FUZZ
    /// =====================================================================

    function testFuzz_deploySY_callerIndependence(address _caller) public {
        vm.assume(_caller != address(0));
        vm.prank(_caller);
        address sy = syFactory.deploySY(address(seniorTranche), rewardManager);

        assertEq(syFactory.trancheToOffchainRewardManagerToSY(address(seniorTranche), rewardManager), sy);
        assertEq(PendleRoycoTrancheSY(payable(sy)).owner(), PENDLE_PAUSE_CONTROLLER);
        assertEq(PendleRoycoTrancheSY(payable(sy)).yieldToken(), address(seniorTranche));
    }

    function testFuzz_deploySY_rewardManagerPassThrough(address _rewardManager) public {
        address sy = syFactory.deploySY(address(seniorTranche), _rewardManager);
        assertEq(PendleRoycoTrancheSY(payable(sy)).offchainRewardManager(), _rewardManager);
    }
}
