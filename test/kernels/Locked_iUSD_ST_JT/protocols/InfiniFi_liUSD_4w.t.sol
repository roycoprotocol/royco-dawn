// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { DeployScript } from "../../../../script/Deploy.s.sol";
import { MarketDeploymentConfig } from "../../../../script/config/MarketDeploymentConfig.sol";
import { IRoycoFactory } from "../../../../src/interfaces/IRoycoFactory.sol";
import { AggregatorV3Interface } from "../../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import { IInfiniFiGateway } from "../../../../src/interfaces/external/infinifi/IInfiniFiGateway.sol";
import { ILockingController } from "../../../../src/interfaces/external/infinifi/ILockingController.sol";
import { Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle } from "../../../../src/kernels/Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle.sol";
import { WAD } from "../../../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../../../src/libraries/Units.sol";

import { Locked_iUSD_TestBase } from "../base/Locked_iUSD_TestBase.t.sol";

/// @title InfiniFi_liUSD_4w_Test
/// @notice Tests Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle with InfiniFi 4-week locked iUSD
/// @dev Both ST and JT use liUSD-4w (4-week locked iUSD) as the tranche asset on Ethereum mainnet
///
/// liUSD-4w is InfiniFi's locked position token where:
///   - Tranche Unit: liUSD-4w shares (locked iUSD with 4-week unwinding)
///   - Reference Asset: iUSD (InfiniFi receipt token)
///   - NAV Unit: USD
/// The conversion uses:
///   1. LockingController.exchangeRate(4) for liUSD -> iUSD
///   2. Chainlink oracle for iUSD -> USD
contract InfiniFi_liUSD_4w_Test is Locked_iUSD_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice InfiniFi liUSD-4w (4-week locked position token) on Ethereum mainnet
    address internal constant LIUSD_4W = 0x66bCF6151D5558AfB47c38B20663589843156078;

    /// @notice InfiniFi Gateway on Ethereum mainnet
    address internal constant INFINIFI_GATEWAY = 0x3f04b65Ddbd87f9CE0A2e7Eb24d80e7fb87625b5;

    /// @notice iUSD/USD Chainlink oracle on Ethereum mainnet
    address internal constant IUSD_USD_ORACLE = 0xF81Aa28A4F68124683AfadA81e8EBBf6e2867067;

    /// @notice Unwinding epochs for liUSD-4w (4 weeks)
    uint32 internal constant UNWINDING_EPOCHS = 4;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for liUSD-4w
    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({
            forkBlock: 24_821_265, // Block where liUSD-4w is deployed
            forkRpcUrlEnvVar: "MAINNET_RPC_URL",
            stAsset: LIUSD_4W,
            jtAsset: LIUSD_4W,
            initialFunding: 1_000_000e18 // 1M liUSD-4w
        });
    }

    /// @notice Returns the InfiniFi gateway address
    function _getInfiniFiGateway() internal pure override returns (address) {
        return INFINIFI_GATEWAY;
    }

    /// @notice Returns the chainlink oracle address for iUSD -> NAV conversion
    function _getChainlinkOracle() internal pure override returns (address) {
        return IUSD_USD_ORACLE;
    }

    /// @notice Returns the unwinding epochs for the locked iUSD token
    function _getUnwindingEpochs() internal pure override returns (uint32) {
        return UNWINDING_EPOCHS;
    }

    /// @notice Returns the staleness threshold for the chainlink oracle
    /// @dev Uses production value (1 day) - Chainlink mock is enabled from setUp to handle vm.warp()
    function _getStalenessThreshold() internal pure override returns (uint48) {
        return 86_400; // 1 day - matches production config
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SETUP
    // ════════════════════════════════════════════════════════════���══════════════

    function setUp() public override {
        // Call parent setUp which will fork and deploy
        super.setUp();

        // NOTE: We intentionally do NOT mock any external contracts here.
        // - LockingController.exchangeRate() returns real values until simulation
        // - Chainlink oracle returns real values until simulation
        //
        // Mocks are ONLY applied when simulateYield/simulateLoss is called.
        // This ensures normal operations (deposit, redeem, etc.) test real behavior.
        //
        // Since _requiresTimeWarpForYield() returns false for this kernel,
        // the abstract test suite won't call vm.warp(), so no staleness issues.

        // Store baseline values for yield/loss simulation calculations.
        // These are NOT mocked yet - they're just reference points.
        address lockingController = IInfiniFiGateway(INFINIFI_GATEWAY).getAddress("lockingController");
        mockedLiUSDToIUSDRate = ILockingController(lockingController).exchangeRate(UNWINDING_EPOCHS);

        (, int256 initialPrice,,,) = AggregatorV3Interface(IUSD_USD_ORACLE).latestRoundData();
        mockedChainlinkPrice = initialPrice;

        // Flags remain false - no mocks active until simulation is triggered
        // exchangeRateMockActive = false (default)
        // chainlinkMockActive = false (default)
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses MarketDeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the liUSD-4w kernel and market using parameters from MarketDeploymentConfig
    function _deployKernelAndMarket() internal override returns (DeployScript.DeploymentResult memory) {
        MarketDeploymentConfig.MarketConfig memory marketConfig = DEPLOY_SCRIPT.getMarketConfig("liUSD-4w");

        // Decode kernel params to override staleness threshold for testing
        DeployScript.LockedIUSDKernelParams memory kernelParams = abi.decode(marketConfig.kernelSpecificParams, (DeployScript.LockedIUSDKernelParams));

        // Override staleness threshold for testing
        kernelParams.stalenessThresholdSeconds = _getStalenessThreshold();

        // Re-encode kernel params with overridden staleness threshold
        marketConfig.kernelSpecificParams = abi.encode(kernelParams);

        uint32 scheduledOperationsExpirySeconds = DEPLOY_SCRIPT.getChainConfig(block.chainid).scheduledOperationsExpirySeconds;
        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        return DEPLOY_SCRIPT.deploy(
            marketConfig, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, scheduledOperationsExpirySeconds, roleAssignments, DEPLOYER.privateKey
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for liUSD-4w (18 decimals)
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e12)); // 0.000001 liUSD-4w tolerance
    }

    /// @notice Returns max NAV delta for liUSD-4w
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // liUSD-4w-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies that the liUSD-4w token is correctly configured
    function test_liUSD4w_tokenConfiguration() external view {
        uint8 decimals = IERC20Metadata(LIUSD_4W).decimals();
        assertEq(decimals, 18, "liUSD-4w should have 18 decimals");
    }

    /// @notice Verifies the InfiniFi gateway returns correct addresses
    function test_liUSD4w_infiniFiGatewayConfiguration() external view {
        address lockingController = IInfiniFiGateway(INFINIFI_GATEWAY).getAddress("lockingController");
        assertNotEq(lockingController, address(0), "LockingController should not be zero");

        address yieldSharing = IInfiniFiGateway(INFINIFI_GATEWAY).getAddress("yieldSharing");
        assertNotEq(yieldSharing, address(0), "YieldSharing should not be zero");

        address receiptToken = IInfiniFiGateway(INFINIFI_GATEWAY).getAddress("receiptToken");
        assertNotEq(receiptToken, address(0), "Receipt token (iUSD) should not be zero");
    }

    /// @notice Verifies the share token matches the tranche asset
    function test_liUSD4w_shareTokenMatchesTrancheAsset() external view {
        address lockingController = IInfiniFiGateway(INFINIFI_GATEWAY).getAddress("lockingController");
        address shareToken = ILockingController(lockingController).shareToken(UNWINDING_EPOCHS);
        assertEq(shareToken, LIUSD_4W, "Share token should match liUSD-4w");
    }

    /// @notice Verifies the liUSD to iUSD exchange rate is reasonable
    function test_liUSD4w_exchangeRateIsReasonable() external view {
        uint256 rate = _getCurrentLiUSDToIUSDRate();
        // Exchange rate should be >= 1 WAD (locked tokens accrue yield)
        assertGe(rate, WAD, "Exchange rate should be >= 1 WAD");
        // Exchange rate shouldn't be unreasonably high (e.g., < 2x)
        assertLt(rate, 2 * WAD, "Exchange rate should be < 2 WAD");
    }

    /// @notice Tests that combined yield from both legs works correctly
    function testFuzz_liUSD4w_combinedYield_increasesNAV(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 1, 20); // 1-20% yield

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Simulate yield in both legs
        simulateLiUSDExchangeRateYield(_yieldPercentage * 1e16 / 2); // Half in liUSD rate
        simulateChainlinkPriceYield(_yieldPercentage * 1e16 / 2); // Half in chainlink

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after combined yield");
    }

    /// @notice Tests the full conversion rate calculation
    function test_liUSD4w_conversionRateCalculation() external view {
        uint256 liUSDToIUSD = _getCurrentLiUSDToIUSDRate();
        (, int256 iUSDPrice,,,) = AggregatorV3Interface(IUSD_USD_ORACLE).latestRoundData();
        uint256 oracleDecimals = AggregatorV3Interface(IUSD_USD_ORACLE).decimals();
        uint256 pricePrecision = 10 ** oracleDecimals;

        // Expected: liUSD -> NAV = liUSD -> iUSD * iUSD -> NAV / WAD
        uint256 expectedRate = liUSDToIUSD * uint256(iUSDPrice) * WAD / pricePrecision / WAD;

        uint256 actualRate = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        // Allow small delta due to rounding
        assertApproxEqRel(actualRate, expectedRate, 1e15, "Conversion rate should match expected calculation");
    }
}
