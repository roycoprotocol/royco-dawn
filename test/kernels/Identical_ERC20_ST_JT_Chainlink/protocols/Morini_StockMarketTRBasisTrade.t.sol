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

/// @notice Minimal interface for Midas mToken pausability
interface IMTokenPausable {
    function paused() external view returns (bool);
}

/// @title Morini_StockMarketTRBasisTrade_Test
/// @notice Integration tests for the StockMarketTRBasisTrade market:
///         Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel with the Morini StockMarketTRBasisTrade
///         Vault token as both the senior and junior tranche asset, on mainnet.
/// @dev StockMarketTRBasisTrade is a Midas mToken (RedDuck stack, same family as mF-ONE) curated by
///      Morini Capital and distributed via Piku:
///        - Tranche Unit:    StockMarketTRBasisTrade (18 decimals; role-minted plain ERC20, pausable,
///                           Midas-blacklistable on both transfer legs)
///        - Chainlink leg:   token -> USD via the RedStone push feed "stockMarketTRBasisTrade/USD"
///                           (8 decimals; NAV-report cadence of 1-4 days, NOT a heartbeat feed)
///        - Stored rate leg: USD -> USD NAV, fixed at 1e18 (initialConversionRateWAD in MarketDeploymentConfig)
contract Morini_StockMarketTRBasisTrade_Test is YieldBearingERC20Chainlink_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Morini StockMarketTRBasisTrade Vault (Midas mToken) on Ethereum mainnet
    address internal constant TR_BASIS_TOKEN = 0x827Ce7E8e35861D9Ac7fE002755767b695A5594a;

    /// @notice RedStone push feed "stockMarketTRBasisTrade/USD" on Ethereum mainnet (8 decimals)
    address internal constant TR_BASIS_USD_FEED = 0x1c7bEc0281080C0A4f85e55151191aF27EC69940;

    /// @notice Fork block for deterministic testing (before the ~25.54M factory role revocation;
    ///         token and feed both live, feed ~1.3 days fresh at this block)
    uint256 internal constant FORK_BLOCK = 25_540_000;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for StockMarketTRBasisTrade
    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({
            forkBlock: FORK_BLOCK, forkRpcUrlEnvVar: "MAINNET_RPC_URL", stAsset: TR_BASIS_TOKEN, jtAsset: TR_BASIS_TOKEN, initialFunding: 1_000_000e18
        });
    }

    /// @notice Returns the deployed RedStone feed used by this market
    function _getChainlinkOracle() internal pure override returns (address) {
        return TR_BASIS_USD_FEED;
    }

    /// @notice Returns the staleness threshold for the chainlink oracle
    /// @dev Max threshold for testing: the suite mocks the oracle after the initial read
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

    /// @notice Deals ST asset to an address using forge's deal cheatcode
    function dealSTAsset(address _to, uint256 _amount) public override {
        deal(TR_BASIS_TOKEN, _to, _amount);
    }

    /// @notice Deals JT asset to an address using forge's deal cheatcode
    function dealJTAsset(address _to, uint256 _amount) public override {
        deal(TR_BASIS_TOKEN, _to, _amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta (18 decimals)
    /// @dev Higher tolerance due to the 8-decimal feed's coarse (1e10 WAD-granularity) pricing
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e12));
    }

    /// @notice Returns max NAV delta
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses MarketDeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the market using MarketDeploymentConfig params against the real RedStone feed
    function _deployKernelAndMarket() internal override returns (DeployScript.DeploymentResult memory) {
        require(TR_BASIS_USD_FEED.code.length > 0, "feed not deployed at FORK_BLOCK");

        MarketDeploymentConfig.MarketConfig memory marketConfig = DEPLOY_SCRIPT.getMarketConfig("StockMarketTRBasisTrade");

        DeployScript.IdenticalAssetsChainlinkToAdminOracleQuoterKernelParams memory kernelParams =
            abi.decode(marketConfig.kernelSpecificParams, (DeployScript.IdenticalAssetsChainlinkToAdminOracleQuoterKernelParams));

        // The config already points at the deployed feed. Relax the staleness threshold for testing and
        // disable the sequencer check at deploy time (the base suite wires its own mock sequencer feed).
        assertEq(kernelParams.trancheAssetToReferenceAssetOracle, TR_BASIS_USD_FEED, "config oracle should be the deployed feed");
        kernelParams.stalenessThresholdSeconds = _getStalenessThreshold();
        kernelParams.sequencerUptimeFeed = address(0);
        kernelParams.gracePeriodSeconds = 0;

        marketConfig.kernelSpecificParams = abi.encode(kernelParams);

        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        uint32 scheduledOperationsExpirySeconds = DEPLOY_SCRIPT.getChainConfig(block.chainid).scheduledOperationsExpirySeconds;
        return DEPLOY_SCRIPT.deploy(
            marketConfig, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, scheduledOperationsExpirySeconds, roleAssignments, DEPLOYER.privateKey
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOKEN / FEED-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies that the mToken is correctly configured
    function test_trBasis_tokenConfiguration() external view {
        assertEq(IERC20Metadata(TR_BASIS_TOKEN).decimals(), 18, "token should have 18 decimals");
        assertEq(IERC20Metadata(TR_BASIS_TOKEN).symbol(), "StockMarketTRBasisTrade", "unexpected symbol");
        assertFalse(IMTokenPausable(TR_BASIS_TOKEN).paused(), "token should not be paused");
    }

    /// @notice Verifies the deployed RedStone feed's shape and live value sanity
    function test_trBasis_feedConfiguration() external view {
        assertEq(AggregatorV3Interface(TR_BASIS_USD_FEED).decimals(), 8, "feed should have 8 decimals");

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = AggregatorV3Interface(TR_BASIS_USD_FEED).latestRoundData();
        // Launched at $1.00 (2026-05-20) accruing basis-trade yield; sanity-band the live value
        assertGe(answer, 1e8, "price should be >= $1.00");
        assertLt(answer, 1.5e8, "price implausibly high");
        assertGt(updatedAt, 0, "feed should have a valid updatedAt");
        assertGe(answeredInRound, roundId, "answeredInRound should be >= roundId");

        // Round history is real (unlike self-reporting adapters): round 1 opened at exactly $1.00
        (, int256 firstAnswer,,,) = AggregatorV3Interface(TR_BASIS_USD_FEED).getRoundData(1);
        assertEq(firstAnswer, 1e8, "round 1 should be $1.00");
    }

    /// @notice Verifies the initial reference-asset-to-NAV conversion rate is 1:1 from the deployment config
    function test_trBasis_initialConversionRate() external view {
        assertEq(_getStoredConversionRate(), 1e18, "Stored rate should be WAD (1:1)");
    }

    /// @notice Verifies the effective tranche rate equals the feed answer scaled 8 -> 18 decimals
    function test_trBasis_effectiveRate_matchesFeed() external view {
        (, int256 answer,,,) = AggregatorV3Interface(TR_BASIS_USD_FEED).latestRoundData();
        uint256 expectedRateWAD = uint256(answer) * 1e10; // 8 -> 18 decimals, USD leg is 1:1

        uint256 effectiveRate = toUint256(KERNEL.stConvertTrancheUnitsToNAVUnits(toTrancheUnits(1e18)));
        assertEq(effectiveRate, expectedRateWAD, "effective rate should equal feed answer scaled to WAD");
    }

    /// @notice Proves the DEPLOYED feed is genuinely invoked by the kernel on the deposit hot path
    function test_trBasis_oracleIsCalledOnDeposit() external {
        uint256 amount = config.initialFunding / 100;

        vm.startPrank(ALICE_ADDRESS);
        IERC20(config.jtAsset).approve(address(JT), amount);
        vm.expectCall(TR_BASIS_USD_FEED, abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector));
        JT.deposit(toTrancheUnits(amount), ALICE_ADDRESS);
        vm.stopPrank();
    }
}
