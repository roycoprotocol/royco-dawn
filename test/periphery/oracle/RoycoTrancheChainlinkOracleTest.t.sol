// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";

import { ERC20Mock } from "../../../lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { WAD, WAD_DECIMALS } from "../../../src/libraries/Constants.sol";
import { AssetClaims, TrancheType } from "../../../src/libraries/Types.sol";
import { toNAVUnits, toTrancheUnits } from "../../../src/libraries/Units.sol";
import { RoycoTrancheChainlinkOracle } from "../../../src/periphery/oracle/RoycoTrancheChainlinkOracle.sol";

import { MockTranche } from "../entrypoint/mocks/MockTranche.sol";

/// @title RoycoTrancheChainlinkOracleTest
/// @notice Unit tests for RoycoTrancheChainlinkOracle backed by MockTranche
/// @dev MockTranche.convertToAssets(s) = s * sharePriceWAD / 1e18, so for s = WAD the oracle answer
///      is exactly the configured sharePriceWAD. This lets us drive the oracle's output deterministically.
contract RoycoTrancheChainlinkOracleTest is Test {
    /// =====================================================================
    /// STATE
    /// =====================================================================
    ERC20Mock internal asset;
    MockTranche internal seniorTranche;
    MockTranche internal juniorTranche;
    RoycoTrancheChainlinkOracle internal stOracle;
    RoycoTrancheChainlinkOracle internal jtOracle;

    address internal constant FACTORY_PLACEHOLDER = address(0xF);

    /// =====================================================================
    /// SETUP
    /// =====================================================================

    function setUp() public {
        asset = new ERC20Mock();
        seniorTranche = new MockTranche(address(asset), FACTORY_PLACEHOLDER, TrancheType.SENIOR);
        juniorTranche = new MockTranche(address(asset), FACTORY_PLACEHOLDER, TrancheType.JUNIOR);
        stOracle = new RoycoTrancheChainlinkOracle(address(seniorTranche));
        jtOracle = new RoycoTrancheChainlinkOracle(address(juniorTranche));
    }

    /// =====================================================================
    /// CONSTRUCTOR
    /// =====================================================================

    function test_constructor_setsImmutable() public view {
        assertEq(stOracle.ROYCO_TRANCHE(), address(seniorTranche));
        assertEq(jtOracle.ROYCO_TRANCHE(), address(juniorTranche));
    }

    /// =====================================================================
    /// METADATA: decimals / version / description
    /// =====================================================================

    function test_decimals_isWAD() public view {
        assertEq(stOracle.decimals(), uint8(WAD_DECIMALS));
        assertEq(jtOracle.decimals(), uint8(WAD_DECIMALS));
    }

    function test_version_isOne() public view {
        assertEq(stOracle.version(), 1);
        assertEq(jtOracle.version(), 1);
    }

    function test_description_seniorContainsTrancheName() public view {
        assertEq(
            stOracle.description(),
            string(abi.encodePacked("Returns the price of 1 share of ", seniorTranche.name(), " in its NAV units (USD, BTC, ETH, etc.)"))
        );
    }

    function test_description_juniorContainsTrancheName() public view {
        assertEq(
            jtOracle.description(),
            string(abi.encodePacked("Returns the price of 1 share of ", juniorTranche.name(), " in its NAV units (USD, BTC, ETH, etc.)"))
        );
    }

    function test_description_propagatesNameRevert() public {
        // Unlike latestRoundData, description() does NOT wrap in try/catch. A reverting name() must surface.
        vm.mockCallRevert(address(seniorTranche), abi.encodeWithSignature("name()"), "name failed");

        vm.expectRevert(bytes("name failed"));
        stOracle.description();
    }

    /// =====================================================================
    /// latestRoundData
    /// =====================================================================

    function test_latestRoundData_initialPriceIsOne() public view {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = stOracle.latestRoundData();
        assertEq(roundId, 1);
        assertEq(answer, int256(WAD));
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, 1);
    }

    function test_latestRoundData_reflectsYield() public {
        seniorTranche.simulateYield(0.1e18); // +10%

        (, int256 answer,,,) = stOracle.latestRoundData();
        assertEq(answer, int256(uint256(1.1e18)));
    }

    function test_latestRoundData_reflectsLoss() public {
        seniorTranche.simulateLoss(0.25e18); // -25%

        (, int256 answer,,,) = stOracle.latestRoundData();
        assertEq(answer, int256(uint256(0.75e18)));
    }

    function test_latestRoundData_followsExplicitSharePrice() public {
        seniorTranche.setSharePrice(2.5e18);

        (, int256 answer,,,) = stOracle.latestRoundData();
        assertEq(answer, int256(uint256(2.5e18)));
    }

    function test_latestRoundData_timestampsTrackBlockTime() public {
        uint256 future = block.timestamp + 7 days;
        vm.warp(future);

        (,, uint256 startedAt, uint256 updatedAt,) = stOracle.latestRoundData();
        assertEq(startedAt, future);
        assertEq(updatedAt, future);
    }

    function test_latestRoundData_recomputesEveryCall() public {
        (, int256 answerBefore,,,) = stOracle.latestRoundData();
        assertEq(answerBefore, int256(WAD));

        seniorTranche.simulateYield(0.5e18); // +50%

        (, int256 answerAfter,,,) = stOracle.latestRoundData();
        assertEq(answerAfter, int256(uint256(1.5e18)));
        assertGt(answerAfter, answerBefore);
    }

    function test_latestRoundData_juniorTrancheIndependent() public {
        seniorTranche.simulateYield(0.2e18); // ST only
        juniorTranche.simulateLoss(0.1e18); // JT only

        (, int256 stAnswer,,,) = stOracle.latestRoundData();
        (, int256 jtAnswer,,,) = jtOracle.latestRoundData();

        assertEq(stAnswer, int256(uint256(1.2e18)));
        assertEq(jtAnswer, int256(uint256(0.9e18)));
    }

    function test_latestRoundData_revertsAsNoDataWhenTrancheReverts() public {
        // Simulate any downstream failure (paused kernel, stale chainlink, quoter revert, etc.)
        vm.mockCallRevert(address(seniorTranche), abi.encodeWithSelector(IRoycoVaultTranche.convertToAssets.selector, WAD), "downstream");

        vm.expectRevert(bytes("No data present"));
        stOracle.latestRoundData();
    }

    function test_latestRoundData_revertsAsNoDataWhenTrancheRevertsEmpty() public {
        // Empty revert from the underlying must still surface as the canonical "No data present"
        vm.mockCallRevert(address(seniorTranche), abi.encodeWithSelector(IRoycoVaultTranche.convertToAssets.selector, WAD), "");

        vm.expectRevert(bytes("No data present"));
        stOracle.latestRoundData();
    }

    function test_latestRoundData_revertsAsNoDataWhenTrancheRevertsCustomError() public {
        // Custom-error reverts must also be caught by the bare `catch` and rewritten to "No data present"
        bytes memory customError = abi.encodeWithSignature("CustomError(uint256)", uint256(42));
        vm.mockCallRevert(address(seniorTranche), abi.encodeWithSelector(IRoycoVaultTranche.convertToAssets.selector, WAD), customError);

        vm.expectRevert(bytes("No data present"));
        stOracle.latestRoundData();
    }

    function test_latestRoundData_revertsAsNoDataOnPanic() public {
        // Panic(uint256) with arithmetic overflow code (0x11). Bare catch should still rewrap.
        bytes memory panicData = abi.encodeWithSelector(bytes4(0x4e487b71), uint256(0x11));
        vm.mockCallRevert(address(seniorTranche), abi.encodeWithSelector(IRoycoVaultTranche.convertToAssets.selector, WAD), panicData);

        vm.expectRevert(bytes("No data present"));
        stOracle.latestRoundData();
    }

    function test_latestRoundData_returnsZeroWhenSharePriceZero() public {
        // Documents behavior: the oracle does NOT reject a zero answer; downstream consumers must.
        seniorTranche.setSharePrice(0);

        (, int256 answer,,,) = stOracle.latestRoundData();
        assertEq(answer, 0);
    }

    function test_latestRoundData_int256CastWrapsOnOverflow() public {
        // Documents the toInt256 cast: NAV exceeding int256.max wraps unchecked.
        // For nav == type(uint256).max, the cast yields -1.
        AssetClaims memory overflowingClaims = AssetClaims({ stAssets: toTrancheUnits(0), jtAssets: toTrancheUnits(0), nav: toNAVUnits(type(uint256).max) });
        vm.mockCall(address(seniorTranche), abi.encodeWithSelector(IRoycoVaultTranche.convertToAssets.selector, WAD), abi.encode(overflowingClaims));

        (, int256 answer,,,) = stOracle.latestRoundData();
        assertEq(answer, int256(-1));
    }

    function test_latestRoundData_int256CastBoundary() public {
        // At exactly int256.max, the cast is lossless and the oracle returns the max signed value.
        uint256 boundary = uint256(type(int256).max);
        AssetClaims memory boundaryClaims = AssetClaims({ stAssets: toTrancheUnits(0), jtAssets: toTrancheUnits(0), nav: toNAVUnits(boundary) });
        vm.mockCall(address(seniorTranche), abi.encodeWithSelector(IRoycoVaultTranche.convertToAssets.selector, WAD), abi.encode(boundaryClaims));

        (, int256 answer,,,) = stOracle.latestRoundData();
        assertEq(answer, type(int256).max);
    }

    function test_latestRoundData_sameBlockInvarianceUnderConstantState() public view {
        (uint80 r1, int256 a1, uint256 s1, uint256 u1, uint80 ar1) = stOracle.latestRoundData();
        (uint80 r2, int256 a2, uint256 s2, uint256 u2, uint80 ar2) = stOracle.latestRoundData();

        assertEq(r1, r2);
        assertEq(a1, a2);
        assertEq(s1, s2);
        assertEq(u1, u2);
        assertEq(ar1, ar2);
    }

    /// =====================================================================
    /// getRoundData
    /// =====================================================================

    function test_getRoundData_roundOneEqualsLatest() public view {
        (uint80 r1, int256 a1, uint256 s1, uint256 u1, uint80 ar1) = stOracle.latestRoundData();
        (uint80 r2, int256 a2, uint256 s2, uint256 u2, uint80 ar2) = stOracle.getRoundData(1);

        assertEq(r1, r2);
        assertEq(a1, a2);
        assertEq(s1, s2);
        assertEq(u1, u2);
        assertEq(ar1, ar2);
    }

    function test_getRoundData_revertsOnRoundZero() public {
        vm.expectRevert(bytes("No data present"));
        stOracle.getRoundData(0);
    }

    function test_getRoundData_revertsOnRoundTwo() public {
        vm.expectRevert(bytes("No data present"));
        stOracle.getRoundData(2);
    }

    function test_getRoundData_revertsOnMaxRound() public {
        vm.expectRevert(bytes("No data present"));
        stOracle.getRoundData(type(uint80).max);
    }

    function test_getRoundData_propagatesUnderlyingRevertAsNoData() public {
        // getRoundData(1) delegates to latestRoundData. The wrapper's revert must surface unchanged.
        vm.mockCallRevert(address(seniorTranche), abi.encodeWithSelector(IRoycoVaultTranche.convertToAssets.selector, WAD), "downstream");

        vm.expectRevert(bytes("No data present"));
        stOracle.getRoundData(1);
    }

    function test_getRoundData_juniorTrancheRoundOneEqualsLatest() public view {
        (uint80 r1, int256 a1, uint256 s1, uint256 u1, uint80 ar1) = jtOracle.latestRoundData();
        (uint80 r2, int256 a2, uint256 s2, uint256 u2, uint80 ar2) = jtOracle.getRoundData(1);

        assertEq(r1, r2);
        assertEq(a1, a2);
        assertEq(s1, s2);
        assertEq(u1, u2);
        assertEq(ar1, ar2);
    }

    function test_getRoundData_juniorTrancheRevertsOnNonOneRound() public {
        vm.expectRevert(bytes("No data present"));
        jtOracle.getRoundData(2);
    }

    /// =====================================================================
    /// FUZZ
    /// =====================================================================

    /// @dev Bounded to int256 max so the toInt256 cast inside the oracle stays in range.
    ///      Practical share prices are many orders of magnitude below this bound.
    function testFuzz_latestRoundData_matchesSharePrice(uint256 _sharePriceWAD) public {
        _sharePriceWAD = bound(_sharePriceWAD, 1, uint256(type(int256).max));
        seniorTranche.setSharePrice(_sharePriceWAD);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = stOracle.latestRoundData();

        assertEq(roundId, 1);
        assertEq(answeredInRound, 1);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(uint256(answer), _sharePriceWAD);
    }

    function testFuzz_getRoundData_revertsForNonOneRound(uint80 _roundId) public {
        vm.assume(_roundId != 1);
        vm.expectRevert(bytes("No data present"));
        stOracle.getRoundData(_roundId);
    }
}
