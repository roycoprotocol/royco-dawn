// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { DeployScript } from "../../../../script/Deploy.s.sol";
import { MarketDeploymentConfig } from "../../../../script/config/MarketDeploymentConfig.sol";
import { IRoycoFactory } from "../../../../src/interfaces/IRoycoFactory.sol";
import { AggregatorV3Interface } from "../../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../../src/libraries/Units.sol";
import { YieldBearingERC20Chainlink_TestBase } from "../base/YieldBearingERC20Chainlink_TestBase.t.sol";

/// @title Piku_USP_Test
/// @notice Integration tests for the USP market: Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel with
///         Piku's USP (yield-optimized stablecoin) as both the senior and junior tranche asset, on mainnet.
/// @dev USP is a plain ERC20 (Inverter Network issuance token) whose NAV lives entirely in an external
///      permissioned oracle module:
///        - Tranche Unit:    USP (18 decimals)
///        - Chainlink leg:   USP -> USD via USPChainlinkAdapter (6 decimals, AggregatorV3-compatible view
///                           over Piku's LM_Oracle_Permissioned price, hard-bounded to [$0.90, $5.00])
///        - Stored rate leg: USDC -> USD NAV, fixed at 1e18 (initialConversionRateWAD in MarketDeploymentConfig)
///
///      Caveats encoded in this suite: the adapter self-reports updatedAt = block.timestamp (staleness checks
///      are structurally ineffective) and getRoundData() reverts; the price is admin-pushed and CAN decrease.
contract Piku_USP_Test is YieldBearingERC20Chainlink_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice USP token (Piku / Inverter ERC20IssuanceUpgradeable_Blacklist_v1) on Ethereum mainnet
    address internal constant USP_TOKEN = 0x098697bA3Fee4eA76294C5d6A466a4e3b3E95FE6;

    /// @notice USPChainlinkAdapter (USP/USD, 6 decimals) on Ethereum mainnet
    address internal constant USP_USD_ADAPTER = 0xb52eb13139905Eb11c472100a1E86cB1961b8EF3;

    /// @notice Adapter hard price bounds (6 decimals)
    int256 internal constant ADAPTER_MIN_ANSWER = 900_000; // $0.90
    int256 internal constant ADAPTER_MAX_ANSWER = 5_000_000; // $5.00

    /// @notice Fork block for deterministic testing (before the ~25.54M factory role revocation; USP live)
    uint256 internal constant FORK_BLOCK = 25_540_000;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for USP
    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({ forkBlock: FORK_BLOCK, forkRpcUrlEnvVar: "MAINNET_RPC_URL", stAsset: USP_TOKEN, jtAsset: USP_TOKEN, initialFunding: 1_000_000e18 });
    }

    /// @notice Returns the deployed USP/USD adapter used by this market
    function _getChainlinkOracle() internal pure override returns (address) {
        return USP_USD_ADAPTER;
    }

    /// @notice Returns the staleness threshold for the chainlink oracle
    /// @dev Max threshold for testing: the suite mocks the oracle after the initial read (and the live
    ///      adapter's updatedAt is always block.timestamp anyway)
    function _getStalenessThreshold() internal pure override returns (uint48) {
        return type(uint48).max;
    }

    /// @notice Returns the initial reference-asset-to-NAV conversion rate (USDC == USD NAV)
    function _getInitialConversionRate() internal pure override returns (uint256) {
        return 1e18;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUNDING OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deals ST asset (USP) to an address using forge's deal cheatcode
    function dealSTAsset(address _to, uint256 _amount) public override {
        deal(USP_TOKEN, _to, _amount);
    }

    /// @notice Deals JT asset (USP) to an address using forge's deal cheatcode
    function dealJTAsset(address _to, uint256 _amount) public override {
        deal(USP_TOKEN, _to, _amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for USP (18 decimals)
    /// @dev Higher tolerance due to the 6-decimal adapter's coarse (1e12 WAD-granularity) pricing
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e12));
    }

    /// @notice Returns max NAV delta for USP
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses MarketDeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the USP kernel/market using MarketDeploymentConfig params against the real adapter
    function _deployKernelAndMarket() internal override returns (DeployScript.DeploymentResult memory) {
        require(USP_USD_ADAPTER.code.length > 0, "USP adapter not deployed at FORK_BLOCK");

        MarketDeploymentConfig.MarketConfig memory uspConfig = DEPLOY_SCRIPT.getMarketConfig("USP");

        DeployScript.IdenticalAssetsChainlinkToAdminOracleQuoterKernelParams memory kernelParams =
            abi.decode(uspConfig.kernelSpecificParams, (DeployScript.IdenticalAssetsChainlinkToAdminOracleQuoterKernelParams));

        // The config already points at the deployed adapter. Relax the staleness threshold for testing and
        // disable the sequencer check at deploy time (the base suite wires its own mock sequencer feed).
        assertEq(kernelParams.trancheAssetToReferenceAssetOracle, USP_USD_ADAPTER, "config oracle should be the deployed USP adapter");
        kernelParams.stalenessThresholdSeconds = _getStalenessThreshold();
        kernelParams.sequencerUptimeFeed = address(0);
        kernelParams.gracePeriodSeconds = 0;

        uspConfig.kernelSpecificParams = abi.encode(kernelParams);

        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        uint32 scheduledOperationsExpirySeconds = DEPLOY_SCRIPT.getChainConfig(block.chainid).scheduledOperationsExpirySeconds;
        return DEPLOY_SCRIPT.deploy(
            uspConfig, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, scheduledOperationsExpirySeconds, roleAssignments, DEPLOYER.privateKey
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // USP-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies that the USP token is correctly configured
    function test_usp_tokenConfiguration() external view {
        assertEq(IERC20Metadata(USP_TOKEN).decimals(), 18, "USP should have 18 decimals");
    }

    /// @notice Verifies the deployed adapter's shape and that the live price is inside its hard bounds
    function test_usp_adapterConfiguration() external view {
        assertEq(AggregatorV3Interface(USP_USD_ADAPTER).decimals(), 6, "adapter should have 6 decimals");

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = AggregatorV3Interface(USP_USD_ADAPTER).latestRoundData();
        assertGe(answer, ADAPTER_MIN_ANSWER, "answer below adapter MIN_ANSWER");
        assertLe(answer, ADAPTER_MAX_ANSWER, "answer above adapter MAX_ANSWER");
        // USP started at $1.00 and accrues ~10%/yr; sanity-band the live value
        assertGt(answer, 1_000_000, "USP/USD should exceed $1");
        assertLt(answer, 2_000_000, "USP/USD implausibly high");

        // The adapter self-reports freshness — document the structural caveat in-suite
        assertEq(updatedAt, block.timestamp, "adapter always reports updatedAt == block.timestamp");
        assertGe(answeredInRound, roundId, "answeredInRound should be >= roundId");
    }

    /// @notice Verifies the initial reference-asset-to-NAV conversion rate is 1:1 from the deployment config
    function test_usp_initialConversionRate() external view {
        assertEq(_getStoredConversionRate(), 1e18, "Stored rate should be WAD (1:1)");
    }

    /// @notice Verifies the effective tranche rate equals the adapter answer scaled 6 -> 18 decimals
    function test_usp_effectiveRate_matchesAdapter() external view {
        (, int256 answer,,,) = AggregatorV3Interface(USP_USD_ADAPTER).latestRoundData();
        uint256 expectedRateWAD = uint256(answer) * 1e12; // 6 -> 18 decimals, USDC leg is 1:1

        uint256 effectiveRate = toUint256(KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18)));
        assertEq(effectiveRate, expectedRateWAD, "effective rate should equal adapter answer scaled to WAD");
    }

    /// @notice Proves the DEPLOYED adapter is genuinely invoked by the kernel on the deposit hot path
    function test_usp_oracleIsCalledOnDeposit() external {
        uint256 amount = config.initialFunding / 100;

        vm.startPrank(ALICE_ADDRESS);
        IERC20(config.jtAsset).approve(address(JT), amount);
        vm.expectCall(USP_USD_ADAPTER, abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector));
        JT.deposit(toTrancheUnits(amount), ALICE_ADDRESS);
        vm.stopPrank();
    }
}
