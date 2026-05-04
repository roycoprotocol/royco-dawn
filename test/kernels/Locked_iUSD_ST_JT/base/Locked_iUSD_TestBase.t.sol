// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Vm } from "../../../../lib/forge-std/src/Vm.sol";
import { IRoycoAccountant } from "../../../../src/interfaces/IRoycoAccountant.sol";
import { IRoycoAuth } from "../../../../src/interfaces/IRoycoAuth.sol";
import { AggregatorV3Interface } from "../../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import { IInfiniFiGateway } from "../../../../src/interfaces/external/infinifi/IInfiniFiGateway.sol";
import { ILockingController } from "../../../../src/interfaces/external/infinifi/ILockingController.sol";
import { Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle } from "../../../../src/kernels/Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle.sol";
import { IdenticalAssetsChainlinkOracleQuoter } from "../../../../src/kernels/base/quoter/base/IdenticalAssetsChainlinkOracleQuoter.sol";
import { WAD } from "../../../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../../src/libraries/Units.sol";
import { AbstractKernelTestSuite } from "../../abstract/AbstractKernelTestSuite.t.sol";

/// @title Locked_iUSD_TestBase
/// @notice Base test contract for Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle
/// @dev Implements the test hooks for locked iUSD tokens using InfiniFi's exchange rate and Chainlink oracle for pricing
///
/// IMPORTANT: This kernel uses two conversion rates:
///   1. InfiniFi LockingController exchange rate: locked iUSD -> iUSD (e.g., 1.05e18 for 5% yield)
///   2. Chainlink oracle or stored rate: iUSD -> NAV (USD)
/// The final conversion: trancheToNAV = liUSDToiUSD * iUSDToNAV / WAD
///
/// MOCKING STRATEGY:
///   - LockingController.exchangeRate() is only mocked when simulateYield/simulateLoss is called
///   - Chainlink oracle is only mocked when simulateYield/simulateLoss is called
///   - Normal operations (deposit, redeem, etc.) use real on-chain values until simulation
abstract contract Locked_iUSD_TestBase is AbstractKernelTestSuite {
    // ═══════════════════════════════════════════════════════════════════════════
    // STATE FOR YIELD/LOSS SIMULATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Baseline liUSD to iUSD exchange rate for yield/loss calculations (WAD scaled)
    /// @dev Stored from initial fork state, used as reference for percentage-based simulations
    uint256 internal mockedLiUSDToIUSDRate;

    /// @notice Baseline chainlink price for yield/loss calculations
    /// @dev Stored from initial fork state, used as reference for percentage-based simulations
    int256 internal mockedChainlinkPrice;

    /// @notice Tracks whether exchange rate mock is active
    bool internal exchangeRateMockActive;

    /// @notice Tracks whether chainlink mock is active
    bool internal chainlinkMockActive;

    /// @notice The staleness threshold for the chainlink oracle
    uint48 internal constant DEFAULT_STALENESS_THRESHOLD = 1 days;

    // ═══════════════════════════════════════════════════════════════════════════
    // INFINIFI ADDRESSES (To be overridden or set by protocol-specific implementations)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the InfiniFi gateway address
    function _getInfiniFiGateway() internal view virtual returns (address);

    /// @notice Returns the chainlink oracle address for iUSD -> NAV conversion
    function _getChainlinkOracle() internal view virtual returns (address);

    /// @notice Returns the unwinding epochs for the locked iUSD token
    function _getUnwindingEpochs() internal view virtual returns (uint32);

    /// @notice Returns the staleness threshold for the chainlink oracle
    function _getStalenessThreshold() internal view virtual returns (uint48) {
        return DEFAULT_STALENESS_THRESHOLD;
    }

    /// @notice Returns the initial iUSD to NAV conversion rate (in WAD precision)
    /// @dev For stablecoins where iUSD ≈ USD, this should be WAD (1e18) for 1:1 conversion
    function _getInitialConversionRate() internal view virtual returns (uint256) {
        return WAD;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // NAV MANIPULATION HOOKS IMPLEMENTATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Simulates yield for ST by increasing the liUSD to iUSD exchange rate
    function simulateSTYield(uint256 _percentageWAD) public virtual override {
        _simulateLiUSDExchangeRateYield(_percentageWAD);
    }

    /// @notice Simulates yield for JT by increasing the liUSD to iUSD exchange rate
    /// @dev For identical assets, ST and JT share the same conversion rate
    function simulateJTYield(uint256 _percentageWAD) public virtual override {
        _simulateLiUSDExchangeRateYield(_percentageWAD);
    }

    /// @notice Simulates loss for ST by randomly decreasing either liUSD rate or chainlink price
    /// @dev Randomly selects between InfiniFi rate and chainlink oracle for better test coverage
    function simulateSTLoss(uint256 _percentageWAD) public virtual override {
        if (vm.randomUint() % 2 == 0) {
            _simulateLiUSDExchangeRateLoss(_percentageWAD);
        } else {
            _simulateChainlinkLoss(_percentageWAD);
        }
    }

    /// @notice Simulates loss for JT by randomly decreasing either liUSD rate or chainlink price
    /// @dev For identical assets, ST and JT share the same conversion rate.
    function simulateJTLoss(uint256 _percentageWAD) public virtual override {
        if (vm.randomUint() % 2 == 0) {
            _simulateLiUSDExchangeRateLoss(_percentageWAD);
        } else {
            _simulateChainlinkLoss(_percentageWAD);
        }
    }

    /// @notice Deals ST asset to an address
    function dealSTAsset(address _to, uint256 _amount) public virtual override {
        deal(config.stAsset, _to, _amount);
    }

    /// @notice Deals JT asset to an address
    function dealJTAsset(address _to, uint256 _amount) public virtual override {
        deal(config.jtAsset, _to, _amount);
    }

    /// @notice Returns max tranche unit delta for comparisons
    function maxTrancheUnitDelta() public view virtual override returns (TRANCHE_UNIT) {
        // Default: 1e12 tolerance (good for 18 decimal tokens)
        return toTrancheUnits(uint256(1e12));
    }

    /// @notice Returns max NAV delta for comparisons
    /// @dev Converts the tranche unit tolerance to NAV using the kernel's conversion
    function maxNAVDelta() public view virtual override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INFINIFI EXCHANGE RATE MANIPULATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Gets the current liUSD to iUSD exchange rate
    /// @dev Returns mocked value if mock is active, otherwise reads from real contract
    /// @return The exchange rate in WAD
    function _getCurrentLiUSDToIUSDRate() internal view returns (uint256) {
        if (exchangeRateMockActive) {
            return mockedLiUSDToIUSDRate;
        }
        // Get the actual rate from the locking controller
        address lockingController = IInfiniFiGateway(_getInfiniFiGateway()).getAddress("lockingController");
        return ILockingController(lockingController).exchangeRate(_getUnwindingEpochs());
    }

    /// @notice Mocks the liUSD to iUSD exchange rate for yield/loss simulation
    /// @dev Only call this when simulating yield/loss, not in setUp
    /// @param _newRateWAD The new exchange rate in WAD
    function _mockLiUSDToIUSDRate(uint256 _newRateWAD) internal {
        mockedLiUSDToIUSDRate = _newRateWAD;
        exchangeRateMockActive = true;

        // Get the locking controller address from gateway
        address lockingController = IInfiniFiGateway(_getInfiniFiGateway()).getAddress("lockingController");

        // Mock exchangeRate() to return the new rate
        vm.mockCall(lockingController, abi.encodeWithSelector(ILockingController.exchangeRate.selector, _getUnwindingEpochs()), abi.encode(_newRateWAD));
    }

    /// @notice Simulates yield by increasing the liUSD to iUSD exchange rate
    /// @param _percentageWAD The yield percentage in WAD (e.g., 0.05e18 = 5%)
    function _simulateLiUSDExchangeRateYield(uint256 _percentageWAD) internal {
        uint256 currentRate = _getCurrentLiUSDToIUSDRate();
        uint256 newRate = currentRate * (WAD + _percentageWAD) / WAD;
        _mockLiUSDToIUSDRate(newRate);
    }

    /// @notice Simulates loss by decreasing the liUSD to iUSD exchange rate
    /// @param _percentageWAD The loss percentage in WAD (e.g., 0.05e18 = 5%)
    function _simulateLiUSDExchangeRateLoss(uint256 _percentageWAD) internal {
        uint256 currentRate = _getCurrentLiUSDToIUSDRate();
        uint256 newRate = currentRate * (WAD - _percentageWAD) / WAD;
        _mockLiUSDToIUSDRate(newRate);
    }

    /// @notice Public function to simulate liUSD exchange rate yield
    function simulateLiUSDExchangeRateYield(uint256 _percentageWAD) public virtual {
        _simulateLiUSDExchangeRateYield(_percentageWAD);
    }

    /// @notice Public function to simulate liUSD exchange rate loss
    function simulateLiUSDExchangeRateLoss(uint256 _percentageWAD) public virtual {
        _simulateLiUSDExchangeRateLoss(_percentageWAD);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CHAINLINK ORACLE PRICE MANIPULATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Gets the current chainlink price
    /// @dev Returns mocked value if mock is active, otherwise reads from real oracle
    /// @return The chainlink price
    function _getCurrentChainlinkPrice() internal view returns (int256) {
        if (chainlinkMockActive) {
            return mockedChainlinkPrice;
        }
        // Get the actual price from the oracle
        (, int256 answer,,,) = AggregatorV3Interface(_getChainlinkOracle()).latestRoundData();
        return answer;
    }

    /// @notice Mocks the latestRoundData function on the chainlink oracle for yield/loss simulation
    /// @dev Only call this when simulating yield/loss, not in setUp
    /// @param _newPrice The new price to return
    function _mockChainlinkPrice(int256 _newPrice) internal {
        mockedChainlinkPrice = _newPrice;
        chainlinkMockActive = true;

        // Mock latestRoundData() to return the new price with valid round data
        vm.mockCall(
            _getChainlinkOracle(),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // roundId
                _newPrice, // answer
                vm.getBlockTimestamp(), // startedAt
                vm.getBlockTimestamp(), // updatedAt (current time to avoid staleness)
                uint80(1) // answeredInRound (>= roundId to avoid incomplete)
            )
        );
    }

    /// @notice Simulates yield by increasing the chainlink oracle price
    /// @param _percentageWAD The yield percentage in WAD (e.g., 0.05e18 = 5%)
    function _simulateChainlinkYield(uint256 _percentageWAD) internal {
        int256 currentPrice = _getCurrentChainlinkPrice();
        int256 newPrice = currentPrice * int256(WAD + _percentageWAD) / int256(WAD);
        _mockChainlinkPrice(newPrice);
    }

    /// @notice Simulates loss by decreasing the chainlink oracle price
    /// @param _percentageWAD The loss percentage in WAD (e.g., 0.05e18 = 5%)
    function _simulateChainlinkLoss(uint256 _percentageWAD) internal {
        int256 currentPrice = _getCurrentChainlinkPrice();
        int256 newPrice = currentPrice * int256(WAD - _percentageWAD) / int256(WAD);
        _mockChainlinkPrice(newPrice);
    }

    /// @notice Public function to simulate chainlink price yield
    function simulateChainlinkPriceYield(uint256 _percentageWAD) public virtual {
        _simulateChainlinkYield(_percentageWAD);
    }

    /// @notice Public function to simulate chainlink price loss
    function simulateChainlinkPriceLoss(uint256 _percentageWAD) public virtual {
        _simulateChainlinkLoss(_percentageWAD);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STORED CONVERSION RATE HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Gets the stored conversion rate (iUSD to NAV) in WAD precision
    function _getStoredConversionRate() internal view returns (uint256) {
        return Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle(address(KERNEL)).getStoredConversionRateWAD();
    }

    /// @notice Sets the stored conversion rate (iUSD to NAV) in WAD precision
    /// @dev Requires ADMIN_ORACLE_QUOTER_ROLE
    function _setStoredConversionRate(uint256 _newRateWAD) internal {
        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle(address(KERNEL)).setConversionRate(_newRateWAD, true);
    }

    /// @notice Simulates yield in the stored conversion rate
    /// @param _percentageWAD The yield percentage in WAD (e.g., 0.05e18 = 5%)
    function simulateStoredRateYield(uint256 _percentageWAD) public virtual {
        uint256 currentRate = _getStoredConversionRate();
        uint256 newRate = currentRate * (WAD + _percentageWAD) / WAD;
        _setStoredConversionRate(newRate);
    }

    /// @notice Simulates loss in the stored conversion rate
    /// @param _percentageWAD The loss percentage in WAD (e.g., 0.05e18 = 5%)
    function simulateStoredRateLoss(uint256 _percentageWAD) public virtual {
        uint256 currentRate = _getStoredConversionRate();
        uint256 newRate = currentRate * (WAD - _percentageWAD) / WAD;
        _setStoredConversionRate(newRate);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INFINIFI EXCHANGE RATE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tests that liUSD exchange rate yield increases NAV
    function testFuzz_liUSDExchangeRate_yield_updatesNAV(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 1, 50); // 1-50% yield

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Simulate liUSD exchange rate yield
        simulateLiUSDExchangeRateYield(_yieldPercentage * 1e16); // Convert to WAD

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after liUSD exchange rate yield");
    }

    /// @notice Tests that liUSD exchange rate loss decreases NAV
    function testFuzz_liUSDExchangeRate_loss_updatesNAV(uint256 _jtAmount, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _lossPercentage = bound(_lossPercentage, 1, 30); // 1-30% loss

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Simulate liUSD exchange rate loss
        simulateLiUSDExchangeRateLoss(_lossPercentage * 1e16); // Convert to WAD

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after liUSD exchange rate loss");
    }

    /// @notice Tests that chainlink price yield increases NAV
    function testFuzz_chainlinkPrice_yield_updatesNAV(uint256 _jtAmount, uint256 _yieldPercentage) external virtual {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 1, 50); // 1-50% yield

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Simulate chainlink price yield
        simulateChainlinkPriceYield(_yieldPercentage * 1e16); // Convert to WAD

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after chainlink price yield");
    }

    /// @notice Tests NAV conservation after rate changes
    function testFuzz_rateChanges_NAVConservation(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 1, 30);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Simulate liUSD exchange rate yield
        simulateLiUSDExchangeRateYield(_yieldPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        _assertNAVConservation();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TIME WARP CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice This kernel does not require time warps for yield/loss simulation
    /// @dev Yield/loss is simulated by mocking exchange rates and oracle prices directly.
    ///      Time passage is irrelevant to NAV calculation for this kernel.
    function _requiresTimeWarpForYield() internal pure override returns (bool) {
        return false;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER CASTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Casts KERNEL to the specific kernel type
    function _kernelCast() internal view returns (Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle) {
        return Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle(address(KERNEL));
    }
}
