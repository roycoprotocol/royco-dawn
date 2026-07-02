// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { DeployScript } from "../../../../script/Deploy.s.sol";
import { MarketDeploymentConfig } from "../../../../script/config/MarketDeploymentConfig.sol";
import { IRoycoFactory } from "../../../../src/interfaces/IRoycoFactory.sol";
import { AggregatorV3Interface } from "../../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../../../src/libraries/Units.sol";
import { YieldBearingERC20Chainlink_TestBase } from "../base/YieldBearingERC20Chainlink_TestBase.t.sol";

/// @title Noon_sUSN_Test
/// @notice Integration tests for the sNUSN market: Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel with
///         Noon staked USN (sUSN) as both the senior and junior tranche asset, on Base.
/// @dev sUSN is priced to USD via a composite Chainlink feed:
///        - Tranche Unit:    sUSN (18 decimals)
///        - Chainlink leg:   sUSN -> USD, produced by the deployed MultiplicativePriceFeed (sUSN/USN * USN/USD)
///        - Stored rate leg: USD -> USD NAV, fixed at 1e18 (initialConversionRateWAD in MarketDeploymentConfig)
///
///      This suite wires the ACTUAL on-chain composite oracle (Compound's audited MultiplicativePriceFeed,
///      deployed on Base with 8-decimal output) into the market, so the deployed oracle is genuinely invoked
///      by the kernel. test_susn_oracleIsCalledOnDeposit asserts the call happens on the hot path.
contract Noon_sUSN_Test is YieldBearingERC20Chainlink_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // BASE ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice sUSN token (Noon staked USN) on Base
    address internal constant SUSN_TOKEN = 0x34a2798D47b238A7CbA9D87D49618DEE6C4D999F;

    /// @notice sUSN / USN feed on Base (18 decimals, Stork-powered Chainlink aggregator port)
    address internal constant SUSN_USN_FEED = 0x907fb22C2DA56642F89702b0970a03ed13EbF136;

    /// @notice USN / USD feed on Base (18 decimals, Stork-powered Chainlink aggregator port)
    address internal constant USN_USD_FEED = 0x0e658Ea83d19e540a5b4cf6BC2A6093a55525561;

    /// @notice The deployed composite sUSN/USD oracle (MultiplicativePriceFeed, 18-decimal output)
    address internal constant SUSN_USD_ORACLE = 0x92B7E06b2C78Ac1dB619980D9a1448428112a376;

    /// @notice Output precision of the deployed composite oracle
    uint8 internal constant ORACLE_DECIMALS = 18;

    /// @notice Fork block for deterministic testing (>= the oracle's deployment block 48_110_006; feeds live and fresh)
    uint256 internal constant FORK_BLOCK = 48_110_500;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for sUSN
    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({ forkBlock: FORK_BLOCK, forkRpcUrlEnvVar: "BASE_RPC_URL", stAsset: SUSN_TOKEN, jtAsset: SUSN_TOKEN, initialFunding: 1_000_000e18 });
    }

    /// @notice Returns the deployed composite sUSN/USD oracle used by this market
    function _getChainlinkOracle() internal pure override returns (address) {
        return SUSN_USD_ORACLE;
    }

    /// @notice Returns the staleness threshold for the chainlink oracle
    /// @dev Use max threshold for testing since the suite mocks the oracle after the initial read
    function _getStalenessThreshold() internal pure override returns (uint48) {
        return type(uint48).max;
    }

    /// @notice Returns the initial reference-asset-to-NAV conversion rate (USD == USD NAV)
    function _getInitialConversionRate() internal pure override returns (uint256) {
        return 1e18;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUNDING OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deals ST asset (sUSN) to an address using forge's deal cheatcode
    function dealSTAsset(address _to, uint256 _amount) public override {
        deal(SUSN_TOKEN, _to, _amount);
    }

    /// @notice Deals JT asset (sUSN) to an address using forge's deal cheatcode
    function dealJTAsset(address _to, uint256 _amount) public override {
        deal(SUSN_TOKEN, _to, _amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for sUSN (18 decimals)
    /// @dev Higher tolerance due to the 8-decimal chainlink oracle's coarser rounding
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e10));
    }

    /// @notice Returns max NAV delta for sUSN
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses MarketDeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the sNUSN kernel/market using MarketDeploymentConfig params against the real oracle
    function _deployKernelAndMarket() internal override returns (DeployScript.DeploymentResult memory) {
        // The deployed composite oracle must exist at the fork block for the market to price sUSN.
        require(SUSN_USD_ORACLE.code.length > 0, "composite oracle not deployed at FORK_BLOCK");

        // Read config from the deploy script (which inherits MarketDeploymentConfig)
        MarketDeploymentConfig.MarketConfig memory susnConfig = DEPLOY_SCRIPT.getMarketConfig("sNUSN");

        // Decode kernel-specific params from the deployment config
        DeployScript.IdenticalAssetsChainlinkToAdminOracleQuoterKernelParams memory kernelParams =
            abi.decode(susnConfig.kernelSpecificParams, (DeployScript.IdenticalAssetsChainlinkToAdminOracleQuoterKernelParams));

        // The config already points at the deployed composite oracle (SUSN_USD_ORACLE). Relax the staleness
        // threshold for testing and disable the sequencer check at deploy time (the base suite wires its own
        // mock sequencer uptime feed afterwards for the sequencer-gated price-path tests).
        assertEq(kernelParams.trancheAssetToReferenceAssetOracle, SUSN_USD_ORACLE, "config oracle should be the deployed composite oracle");
        kernelParams.stalenessThresholdSeconds = _getStalenessThreshold();
        kernelParams.sequencerUptimeFeed = address(0);
        kernelParams.gracePeriodSeconds = 0;

        // Re-encode kernel params with the overrides
        susnConfig.kernelSpecificParams = abi.encode(kernelParams);

        // Build role assignments
        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        uint32 scheduledOperationsExpirySeconds = DEPLOY_SCRIPT.getChainConfig(block.chainid).scheduledOperationsExpirySeconds;
        return DEPLOY_SCRIPT.deploy(
            susnConfig, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, scheduledOperationsExpirySeconds, roleAssignments, DEPLOYER.privateKey
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // sUSN-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies that the sUSN token is correctly configured
    function test_susn_tokenConfiguration() external view {
        assertEq(IERC20Metadata(SUSN_TOKEN).decimals(), 18, "sUSN should have 18 decimals");
    }

    /// @notice Verifies the deployed oracle is wired to the two expected feeds and equals their scaled product
    function test_susn_compositeOracleComposition() external view {
        assertEq(AggregatorV3Interface(SUSN_USD_ORACLE).decimals(), ORACLE_DECIMALS, "oracle should have 18 decimals");

        (, int256 susnUsn,,,) = AggregatorV3Interface(SUSN_USN_FEED).latestRoundData();
        (, int256 usnUsd,,,) = AggregatorV3Interface(USN_USD_FEED).latestRoundData();

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = AggregatorV3Interface(SUSN_USD_ORACLE).latestRoundData();

        // Both feeds are 18 decimals, output is 18 decimals => combinedScale 1e36, priceFeedScale 1e18.
        int256 expected = susnUsn * usnUsd * 1e18 / 1e36;
        assertEq(answer, expected, "composite == sUSN/USN * USN/USD, scaled to 18 decimals");

        // sUSN is a yield-bearing wrapper of USN (~$1), so sUSN/USD (18 decimals) should be comfortably above $1.
        assertGt(answer, 1e18, "sUSN/USD should exceed $1");
        assertLt(answer, 3e18, "sUSN/USD implausibly high");

        assertGt(updatedAt, 0, "oracle should have a valid updatedAt");
        assertGe(answeredInRound, roundId, "answeredInRound should be >= roundId");
    }

    /// @notice Verifies the initial reference-asset-to-NAV conversion rate is 1:1 from the deployment config
    function test_susn_initialConversionRate() external view {
        assertEq(_getStoredConversionRate(), 1e18, "Stored rate should be WAD (1:1)");
    }

    /// @notice Proves the DEPLOYED composite oracle is genuinely invoked by the kernel on the deposit hot path.
    /// @dev No price mock is active here, so the market prices the deposit by calling the real oracle's
    ///      latestRoundData(). vm.expectCall fails the test if that call never happens.
    function test_susn_oracleIsCalledOnDeposit() external {
        uint256 amount = config.initialFunding / 100;

        vm.startPrank(ALICE_ADDRESS);
        IERC20(config.jtAsset).approve(address(JT), amount);
        vm.expectCall(SUSN_USD_ORACLE, abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector));
        JT.deposit(toTrancheUnits(amount), ALICE_ADDRESS);
        vm.stopPrank();
    }
}
