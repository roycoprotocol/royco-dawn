// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";
import { Vm } from "../../../lib/forge-std/src/Vm.sol";

import { ERC20Mock } from "../../../lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

import { WAD } from "../../../src/libraries/Constants.sol";
import { TrancheType } from "../../../src/libraries/Types.sol";
import { RoycoTrancheChainlinkOracle } from "../../../src/periphery/oracle/RoycoTrancheChainlinkOracle.sol";
import { RoycoTrancheChainlinkOracleFactory } from "../../../src/periphery/oracle/RoycoTrancheChainlinkOracleFactory.sol";

import { MockTranche } from "../entrypoint/mocks/MockTranche.sol";

/// @notice Minimal mock implementing only the IRoycoFactory tranche-mapping surface that the oracle factory consumes
contract MockRoycoFactory {
    mapping(address senior => address junior) public seniorTrancheToJuniorTranche;
    mapping(address junior => address senior) public juniorTrancheToSeniorTranche;

    function registerPair(address _senior, address _junior) external {
        seniorTrancheToJuniorTranche[_senior] = _junior;
        juniorTrancheToSeniorTranche[_junior] = _senior;
    }
}

/// @title RoycoTrancheChainlinkOracleFactoryTest
/// @notice Audit-grade unit tests for RoycoTrancheChainlinkOracleFactory backed by MockTranche + MockRoycoFactory
contract RoycoTrancheChainlinkOracleFactoryTest is Test {
    /// =====================================================================
    /// STATE
    /// =====================================================================
    ERC20Mock internal asset;
    MockRoycoFactory internal mockRoycoFactory;
    MockTranche internal seniorTranche;
    MockTranche internal juniorTranche;
    RoycoTrancheChainlinkOracleFactory internal oracleFactory;

    /// @dev Mirrored from RoycoTrancheChainlinkOracleFactory for vm.expectEmit
    event OracleDeployed(address indexed tranche, address indexed oracle);

    /// =====================================================================
    /// SETUP
    /// =====================================================================

    function setUp() public {
        asset = new ERC20Mock();
        mockRoycoFactory = new MockRoycoFactory();

        seniorTranche = new MockTranche(address(asset), address(mockRoycoFactory), TrancheType.SENIOR);
        juniorTranche = new MockTranche(address(asset), address(mockRoycoFactory), TrancheType.JUNIOR);

        mockRoycoFactory.registerPair(address(seniorTranche), address(juniorTranche));

        oracleFactory = new RoycoTrancheChainlinkOracleFactory(address(mockRoycoFactory));
    }

    /// =====================================================================
    /// CONSTRUCTOR
    /// =====================================================================

    function test_constructor_setsImmutable() public view {
        assertEq(oracleFactory.ROYCO_FACTORY(), address(mockRoycoFactory));
    }

    function test_constructor_revertsOnNullAddress() public {
        vm.expectRevert(RoycoTrancheChainlinkOracleFactory.NULL_ADDRESS.selector);
        new RoycoTrancheChainlinkOracleFactory(address(0));
    }

    /// =====================================================================
    /// deployOracle - happy path
    /// =====================================================================

    function test_deployOracle_seniorTranche() public {
        address predicted = oracleFactory.predictOracleAddress(address(seniorTranche));

        vm.expectEmit(true, true, false, false, address(oracleFactory));
        emit OracleDeployed(address(seniorTranche), predicted);

        address deployed = oracleFactory.deployOracle(address(seniorTranche));

        assertEq(deployed, predicted);
        assertGt(deployed.code.length, 0);
        assertEq(oracleFactory.trancheToOracle(address(seniorTranche)), deployed);
    }

    function test_deployOracle_juniorTranche() public {
        address predicted = oracleFactory.predictOracleAddress(address(juniorTranche));

        vm.expectEmit(true, true, false, false, address(oracleFactory));
        emit OracleDeployed(address(juniorTranche), predicted);

        address deployed = oracleFactory.deployOracle(address(juniorTranche));

        assertEq(deployed, predicted);
        assertGt(deployed.code.length, 0);
        assertEq(oracleFactory.trancheToOracle(address(juniorTranche)), deployed);
    }

    function test_deployOracle_oracleWiredToCorrectTranche() public {
        address deployed = oracleFactory.deployOracle(address(seniorTranche));
        assertEq(RoycoTrancheChainlinkOracle(deployed).ROYCO_TRANCHE(), address(seniorTranche));
    }

    function test_deployOracle_deployedOracleIsFunctional() public {
        // Mock tranche default share price = 1e18, so latestRoundData returns WAD.
        address deployed = oracleFactory.deployOracle(address(seniorTranche));
        (, int256 answer,,,) = RoycoTrancheChainlinkOracle(deployed).latestRoundData();
        assertEq(answer, int256(WAD));
    }

    function test_deployOracle_setsMappingsIndependentlyForBothTranches() public {
        address stOracle = oracleFactory.deployOracle(address(seniorTranche));
        address jtOracle = oracleFactory.deployOracle(address(juniorTranche));

        assertEq(oracleFactory.trancheToOracle(address(seniorTranche)), stOracle);
        assertEq(oracleFactory.trancheToOracle(address(juniorTranche)), jtOracle);
        assertTrue(stOracle != jtOracle);
    }

    function test_deployOracle_returnedAddressMatchesPredict() public {
        address predicted = oracleFactory.predictOracleAddress(address(seniorTranche));
        address deployed = oracleFactory.deployOracle(address(seniorTranche));
        assertEq(deployed, predicted);
    }

    /// =====================================================================
    /// deployOracle - revert paths
    /// =====================================================================

    function test_deployOracle_revertsOnNullAddress() public {
        vm.expectRevert(RoycoTrancheChainlinkOracleFactory.NULL_ADDRESS.selector);
        oracleFactory.deployOracle(address(0));
    }

    function test_deployOracle_revertsOnEOA() public {
        // EOA: no code, the high-level TRANCHE_TYPE() call asserts code-existence and reverts.
        address eoa = makeAddr("eoa");
        vm.expectRevert();
        oracleFactory.deployOracle(eoa);
    }

    function test_deployOracle_revertsOnUnregisteredTranche() public {
        // A real tranche but never registered in the canonical factory mapping.
        MockTranche unregistered = new MockTranche(address(asset), address(mockRoycoFactory), TrancheType.SENIOR);
        vm.expectRevert(RoycoTrancheChainlinkOracleFactory.INVALID_TRANCHE.selector);
        oracleFactory.deployOracle(address(unregistered));
    }

    function test_deployOracle_revertsOnTrancheFromDifferentFactory() public {
        // A tranche registered in a different factory should not be deployable through this factory.
        MockRoycoFactory otherFactory = new MockRoycoFactory();
        MockTranche otherSt = new MockTranche(address(asset), address(otherFactory), TrancheType.SENIOR);
        MockTranche otherJt = new MockTranche(address(asset), address(otherFactory), TrancheType.JUNIOR);
        otherFactory.registerPair(address(otherSt), address(otherJt));

        vm.expectRevert(RoycoTrancheChainlinkOracleFactory.INVALID_TRANCHE.selector);
        oracleFactory.deployOracle(address(otherSt));
        vm.expectRevert(RoycoTrancheChainlinkOracleFactory.INVALID_TRANCHE.selector);
        oracleFactory.deployOracle(address(otherJt));
    }

    function test_deployOracle_revertsOnRedeploy() public {
        oracleFactory.deployOracle(address(seniorTranche));

        // Second deploy collides at the deterministic CREATE2 address; the `new` opcode reverts.
        vm.expectRevert();
        oracleFactory.deployOracle(address(seniorTranche));
    }

    function test_deployOracle_failedRedeployDoesNotCorruptMapping() public {
        address firstOracle = oracleFactory.deployOracle(address(seniorTranche));

        vm.expectRevert();
        oracleFactory.deployOracle(address(seniorTranche));

        // Mapping still points at the original oracle.
        assertEq(oracleFactory.trancheToOracle(address(seniorTranche)), firstOracle);
    }

    /// =====================================================================
    /// predictOracleAddress
    /// =====================================================================

    function test_predictOracleAddress_isDeterministic() public view {
        address pred1 = oracleFactory.predictOracleAddress(address(seniorTranche));
        address pred2 = oracleFactory.predictOracleAddress(address(seniorTranche));
        assertEq(pred1, pred2);
    }

    function test_predictOracleAddress_differentTranchesProduceDifferentAddresses() public view {
        address stPred = oracleFactory.predictOracleAddress(address(seniorTranche));
        address jtPred = oracleFactory.predictOracleAddress(address(juniorTranche));
        assertTrue(stPred != jtPred);
    }

    function test_predictOracleAddress_callerIndependent() public {
        // predict has no msg.sender dependency: same input from any caller yields the same address.
        address fromThisCaller = oracleFactory.predictOracleAddress(address(seniorTranche));
        vm.prank(makeAddr("randomCaller"));
        address fromAnotherCaller = oracleFactory.predictOracleAddress(address(seniorTranche));
        assertEq(fromThisCaller, fromAnotherCaller);
    }

    function test_predictOracleAddress_doesNotValidateTranche() public {
        // Predict is a pure deterministic function over the tranche address; it does NOT call the canonical factory.
        // Even an unregistered or non-contract address should yield a non-zero prediction.
        address random = makeAddr("random");
        assertTrue(oracleFactory.predictOracleAddress(random) != address(0));
    }

    /// =====================================================================
    /// PERMISSIONLESS / DETERMINISM
    /// =====================================================================

    function test_deployOracle_permissionlessProducesSameAddressAcrossCallers() public {
        address predicted = oracleFactory.predictOracleAddress(address(seniorTranche));

        vm.prank(makeAddr("randomCaller"));
        address deployed = oracleFactory.deployOracle(address(seniorTranche));

        assertEq(deployed, predicted);
    }

    function test_deployOracle_eventCarriesCorrectTrancheAndOracleTopics() public {
        address predicted = oracleFactory.predictOracleAddress(address(juniorTranche));

        vm.recordLogs();
        oracleFactory.deployOracle(address(juniorTranche));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Find the OracleDeployed log among possibly-emitted events.
        bytes32 expectedTopic0 = keccak256("OracleDeployed(address,address)");
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(oracleFactory)) continue;
            if (logs[i].topics.length != 3 || logs[i].topics[0] != expectedTopic0) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), address(juniorTranche));
            assertEq(address(uint160(uint256(logs[i].topics[2]))), predicted);
            found = true;
            break;
        }
        assertTrue(found);
    }

    /// =====================================================================
    /// FUZZ
    /// =====================================================================

    function testFuzz_predictOracleAddress_doesNotRevert(address _tranche) public view {
        // Predict is total: must not revert for any input.
        oracleFactory.predictOracleAddress(_tranche);
    }

    function testFuzz_predictOracleAddress_isDeterministicAcrossInputs(address _trancheA, address _trancheB) public view {
        // Same input → same address; different inputs → different addresses (CREATE2 is collision-resistant for different init codes).
        if (_trancheA == _trancheB) {
            assertEq(oracleFactory.predictOracleAddress(_trancheA), oracleFactory.predictOracleAddress(_trancheB));
        } else {
            assertTrue(oracleFactory.predictOracleAddress(_trancheA) != oracleFactory.predictOracleAddress(_trancheB));
        }
    }

    function testFuzz_deployOracle_callerIndependence(address _caller) public {
        vm.assume(_caller != address(0));
        address predicted = oracleFactory.predictOracleAddress(address(seniorTranche));

        vm.prank(_caller);
        address deployed = oracleFactory.deployOracle(address(seniorTranche));

        assertEq(deployed, predicted);
        assertEq(oracleFactory.trancheToOracle(address(seniorTranche)), deployed);
    }
}
