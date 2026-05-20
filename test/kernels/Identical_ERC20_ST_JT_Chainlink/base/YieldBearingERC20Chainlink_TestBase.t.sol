// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Vm } from "../../../../lib/forge-std/src/Vm.sol";
import { IRoycoAccountant } from "../../../../src/interfaces/IRoycoAccountant.sol";
import { IRoycoAuth } from "../../../../src/interfaces/IRoycoAuth.sol";
import { AggregatorV3Interface } from "../../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import { IdenticalAssetsChainlinkOracleQuoter } from "../../../../src/kernels/base/quoter/dawn/identical-assets/base/IdenticalAssetsChainlinkOracleQuoter.sol";
import { Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel } from "../../../../src/kernels/dawn/Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel.sol";
import { WAD } from "../../../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../../src/libraries/Units.sol";
import { AbstractKernelTestSuite } from "../../abstract/AbstractKernelTestSuite.t.sol";

/// @title YieldBearingERC20Chainlink_TestBase
/// @notice Base test contract for Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel
/// @dev Implements the test hooks for yield-bearing ERC20 assets using Chainlink oracle for pricing
///
/// IMPORTANT: This kernel uses two conversion rates:
///   1. Chainlink oracle price: tranche asset -> reference asset (e.g., PT-cUSD -> SY-cUSD)
///   2. Stored conversion rate: reference asset -> NAV (e.g., SY-cUSD -> USD)
/// The final conversion: trancheToNAV = chainlinkPrice * storedRate / precision
abstract contract YieldBearingERC20Chainlink_TestBase is AbstractKernelTestSuite {
    // ═══════════════════════════════════════════════════════════════════════════
    // STATE FOR MOCKED CHAINLINK ORACLE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tracks the mocked chainlink price
    /// @dev When non-zero, this value is used to mock latestRoundData() calls
    int256 internal mockedChainlinkPrice;

    /// @notice The staleness threshold for the chainlink oracle
    uint48 internal constant DEFAULT_STALENESS_THRESHOLD = 1 days;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIGURATION (To be overridden by protocol-specific implementations)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the chainlink oracle address for the protocol
    function _getChainlinkOracle() internal view virtual returns (address);

    /// @notice Returns the staleness threshold for the chainlink oracle
    function _getStalenessThreshold() internal view virtual returns (uint48) {
        return DEFAULT_STALENESS_THRESHOLD;
    }

    /// @notice Returns the initial reference-asset-to-NAV conversion rate (in WAD precision)
    /// @dev For stablecoins where reference asset ≈ USD, this should be WAD (1e18) for 1:1 conversion
    /// Override this for non-stablecoin assets where the reference asset has a different NAV
    function _getInitialConversionRate() internal view virtual returns (uint256) {
        // Default: 1:1 conversion in WAD precision (for stablecoins)
        return WAD;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // NAV MANIPULATION HOOKS IMPLEMENTATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Simulates yield for ST by increasing the chainlink oracle price
    function simulateSTYield(uint256 _percentageWAD) public virtual override {
        _simulateChainlinkYield(_percentageWAD);
    }

    /// @notice Simulates yield for JT by increasing the chainlink oracle price
    /// @dev For identical assets, ST and JT share the same conversion rate
    function simulateJTYield(uint256 _percentageWAD) public virtual override {
        _simulateChainlinkYield(_percentageWAD);
    }

    /// @notice Simulates loss for ST by randomly decreasing either chainlink price or stored rate
    /// @dev Randomly selects between chainlink and admin oracle legs for better test coverage
    function simulateSTLoss(uint256 _percentageWAD) public virtual override {
        if (vm.randomUint() % 2 == 0) {
            _simulateChainlinkLoss(_percentageWAD);
        } else {
            simulateStoredRateLoss(_percentageWAD);
        }
    }

    /// @notice Simulates loss for JT by randomly decreasing either chainlink price or stored rate
    /// @dev For identical assets, ST and JT share the same conversion rate.
    ///      Randomly selects between chainlink and admin oracle legs for better test coverage.
    function simulateJTLoss(uint256 _percentageWAD) public virtual override {
        if (vm.randomUint() % 2 == 0) {
            _simulateChainlinkLoss(_percentageWAD);
        } else {
            simulateStoredRateLoss(_percentageWAD);
        }
    }

    /// @notice Sets the conversion rate for ST (via chainlink mock)
    function setSTConversionRate(uint256 _priceScaled) public virtual {
        _mockChainlinkPrice(int256(_priceScaled));
    }

    /// @notice Sets the conversion rate for JT (via chainlink mock)
    /// @dev For identical assets, this is the same as ST
    function setJTConversionRate(uint256 _priceScaled) public virtual {
        _mockChainlinkPrice(int256(_priceScaled));
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
    // CHAINLINK ORACLE PRICE MANIPULATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Simulates yield by increasing the chainlink oracle price
    /// @param _percentageWAD The percentage increase in WAD (e.g., 0.05e18 = 5%)
    function simulateChainlinkPriceYield(uint256 _percentageWAD) public virtual {
        int256 currentPrice = _getCurrentChainlinkPrice();

        int256 newPrice = currentPrice * int256(WAD + _percentageWAD) / int256(WAD);
        _mockChainlinkPrice(newPrice);
    }

    /// @notice Simulates loss by decreasing the chainlink oracle price
    /// @param _percentageWAD The percentage decrease in WAD (e.g., 0.05e18 = 5%)
    function simulateChainlinkPriceLoss(uint256 _percentageWAD) public virtual {
        int256 currentPrice = _getCurrentChainlinkPrice();

        int256 newPrice = currentPrice * int256(WAD - _percentageWAD) / int256(WAD);
        _mockChainlinkPrice(newPrice);
    }

    /// @notice Gets the current chainlink price (either mocked or from the actual oracle)
    /// @return The chainlink price
    function _getCurrentChainlinkPrice() internal view returns (int256) {
        if (mockedChainlinkPrice != 0) {
            return mockedChainlinkPrice;
        }
        // Get the actual price from the oracle
        (, int256 answer,,,) = AggregatorV3Interface(_getChainlinkOracle()).latestRoundData();
        return answer;
    }

    /// @notice Mocks the latestRoundData function on the chainlink oracle
    /// @param _newPrice The new price to return
    function _mockChainlinkPrice(int256 _newPrice) internal {
        mockedChainlinkPrice = _newPrice;

        // Mock latestRoundData() to return the new price with valid round data
        // Returns: (roundId, answer, startedAt, updatedAt, answeredInRound)
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

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS (CHAINLINK PRICE MANIPULATION)
    // ═══════════════════════════════════════════════════════════════════════════

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

    // ═══════════════════════════════════════════════════════════════════════════
    // STORED CONVERSION RATE HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Gets the stored conversion rate (reference asset to NAV) in WAD precision
    function _getStoredConversionRate() internal view returns (uint256) {
        return Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel(address(KERNEL)).getStoredConversionRateWAD();
    }

    /// @notice Sets the stored conversion rate (reference asset to NAV) in WAD precision
    /// @dev Requires ADMIN_ORACLE_QUOTER_ROLE, which is granted to ORACLE_QUOTER_ADMIN_ADDRESS
    function _setStoredConversionRate(uint256 _newRateWAD) internal {
        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel(address(KERNEL)).setConversionRate(_newRateWAD, true);
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
    // CHAINLINK PRICE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tests that chainlink price yield increases NAV
    function testFuzz_chainlinkPrice_yield_updatesNAV(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 1, 50); // 1-50% yield

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Simulate chainlink price yield (mocks latestRoundData)
        simulateChainlinkPriceYield(_yieldPercentage * 1e16); // Convert to WAD

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after chainlink price yield");
    }

    /// @notice Tests that chainlink price loss decreases NAV
    function testFuzz_chainlinkPrice_loss_updatesNAV(uint256 _jtAmount, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _lossPercentage = bound(_lossPercentage, 1, 30); // 1-30% loss

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Simulate chainlink price loss (mocks latestRoundData)
        simulateChainlinkPriceLoss(_lossPercentage * 1e16); // Convert to WAD

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after chainlink price loss");
    }

    /// @notice Tests that chainlink price yield with ST deposits distributes correctly
    function testFuzz_chainlinkPrice_yield_distributesToJT(uint256 _jtAmount, uint256 _stPercentage, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 10, 50);
        _yieldPercentage = bound(_yieldPercentage, 1, 20);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;

        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        NAV_UNIT jtNavBefore = JT.totalAssets().nav;

        // Simulate chainlink price yield
        simulateChainlinkPriceYield(_yieldPercentage * 1e16);

        // Warp time for yield distribution
        vm.warp(vm.getBlockTimestamp() + 1 days);

        // Trigger sync
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT jtNavAfter = JT.totalAssets().nav;

        // JT should receive portion of yield based on YDM
        assertGe(jtNavAfter, jtNavBefore, "JT NAV should increase or stay same from chainlink price yield");
    }

    /// @notice Tests NAV conservation after chainlink price changes
    function testFuzz_chainlinkPrice_NAVConservation(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 1, 30);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Simulate chainlink price yield
        simulateChainlinkPriceYield(_yieldPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        _assertNAVConservation();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SET TRANCHE ASSET TO REFERENCE ASSET ORACLE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tests that setting a new oracle works with valid params
    function test_setChainlinkOracle_success() external {
        // Create mock oracle addresses
        address newOracle = makeAddr("newOracle");
        address anotherOracle = makeAddr("anotherOracle");
        uint48 newStaleness = 2 days;

        // Mock the decimals and latestRoundData calls on the new oracle
        vm.mockCall(newOracle, abi.encodeWithSelector(AggregatorV3Interface.decimals.selector), abi.encode(uint8(18)));
        vm.mockCall(
            newOracle,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1e18), uint256(0), block.timestamp, uint80(1))
        );

        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel(address(KERNEL)).setChainlinkOracle(newOracle, newStaleness, true);

        // Verify by checking that it doesn't revert when called again with different values
        vm.mockCall(anotherOracle, abi.encodeWithSelector(AggregatorV3Interface.decimals.selector), abi.encode(uint8(8)));
        vm.mockCall(
            anotherOracle,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1e8), uint256(0), block.timestamp, uint80(1))
        );

        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel(address(KERNEL)).setChainlinkOracle(anotherOracle, 3 days, true);
    }

    /// @notice Tests that setting oracle with zero address reverts
    function test_setChainlinkOracle_revertsOnZeroAddress() external {
        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel(address(KERNEL)).setChainlinkOracle(address(0), 1 days, true);
    }

    /// @notice Tests that setting oracle with zero staleness reverts
    function test_setChainlinkOracle_revertsOnZeroStaleness() external {
        address newOracle = makeAddr("newOracleForZeroStaleness");

        vm.mockCall(newOracle, abi.encodeWithSelector(AggregatorV3Interface.decimals.selector), abi.encode(uint8(18)));

        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        vm.expectRevert(IdenticalAssetsChainlinkOracleQuoter.INVALID_STALENESS_THRESHOLD_SECONDS.selector);
        Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel(address(KERNEL)).setChainlinkOracle(newOracle, 0, true);
    }

    /// @notice Tests that non-admin cannot set oracle
    function test_setChainlinkOracle_revertsOnUnauthorized() external {
        address newOracle = makeAddr("newOracleForUnauthorized");

        vm.mockCall(newOracle, abi.encodeWithSelector(AggregatorV3Interface.decimals.selector), abi.encode(uint8(18)));

        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(); // AccessManagerUnauthorizedAccount
        Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel(address(KERNEL)).setChainlinkOracle(newOracle, 1 days, true);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // _syncBeforeUpdate FLAG TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Counts TrancheAccountingSynced events in recorded logs
    function _countSyncEvents(Vm.Log[] memory logs) internal pure returns (uint256 count) {
        bytes32 syncSelector = IRoycoAccountant.TrancheAccountingSynced.selector;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == syncSelector) {
                count++;
            }
        }
    }

    /// @notice Tests that setConversionRate with false skips the pre-update sync (1 sync total)
    function test_setConversionRate_skipPreSync() external {
        vm.recordLogs();

        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel(address(KERNEL)).setConversionRate(WAD * 2, false);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countSyncEvents(logs), 1, "Should have exactly 1 sync (post-update only)");
    }

    /// @notice Tests that setConversionRate with true fires both pre and post sync (2 syncs total)
    function test_setConversionRate_withPreSync() external {
        vm.recordLogs();

        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel(address(KERNEL)).setConversionRate(WAD * 2, true);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countSyncEvents(logs), 2, "Should have exactly 2 syncs (pre + post update)");
    }

    /// @notice Tests that setChainlinkOracle with false skips the pre-update sync (1 sync total)
    function test_setChainlinkOracle_skipPreSync() external {
        address newOracle = makeAddr("newOracleSkipSync");

        vm.mockCall(newOracle, abi.encodeWithSelector(AggregatorV3Interface.decimals.selector), abi.encode(uint8(8)));
        vm.mockCall(
            newOracle,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1e8), uint256(0), block.timestamp, uint80(1))
        );

        vm.recordLogs();

        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel(address(KERNEL)).setChainlinkOracle(newOracle, 1 days, false);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countSyncEvents(logs), 1, "Should have exactly 1 sync (post-update only)");
    }

    /// @notice Tests that setChainlinkOracle with true fires both pre and post sync (2 syncs total)
    function test_setChainlinkOracle_withPreSync() external {
        address newOracle = makeAddr("newOracleWithSync");

        vm.mockCall(newOracle, abi.encodeWithSelector(AggregatorV3Interface.decimals.selector), abi.encode(uint8(8)));
        vm.mockCall(
            newOracle,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1e8), uint256(0), block.timestamp, uint80(1))
        );

        vm.recordLogs();

        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel(address(KERNEL)).setChainlinkOracle(newOracle, 1 days, true);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countSyncEvents(logs), 2, "Should have exactly 2 syncs (pre + post update)");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ORACLE VALIDATION TESTS (STALE_PRICE, INVALID_PRICE, INCOMPLETE_PRICE)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tests that stale price causes STALE_PRICE revert
    function testFuzz_oracleValidation_revertsOnStalePrice(uint256 _stalenessThreshold) external virtual {
        // Clear the mock to allow real call behavior
        vm.clearMockedCalls();

        // Mock a stale price (updatedAt is old)
        vm.warp(vm.getBlockTimestamp() + _getStalenessThreshold() + 1);
        vm.mockCall(
            _getChainlinkOracle(),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // roundId
                int256(1e18), // answer (positive)
                0, // startedAt
                0, // updatedAt (stale!)
                uint80(1) // answeredInRound
            )
        );

        // Try to get conversion rate - should revert with STALE_PRICE
        vm.expectRevert(IdenticalAssetsChainlinkOracleQuoter.STALE_PRICE.selector);
        Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel(address(KERNEL)).getTrancheUnitToNAVUnitConversionRateWAD();
    }

    /// @notice Tests that zero/negative price causes INVALID_PRICE revert
    function test_oracleValidation_revertsOnZeroPrice() external {
        // Clear the mock
        vm.clearMockedCalls();

        // Mock a zero price
        vm.mockCall(
            _getChainlinkOracle(),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // roundId
                int256(0), // answer (ZERO - invalid!)
                vm.getBlockTimestamp(), // startedAt
                vm.getBlockTimestamp(), // updatedAt
                uint80(1) // answeredInRound
            )
        );

        vm.expectRevert(IdenticalAssetsChainlinkOracleQuoter.INVALID_PRICE.selector);
        Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel(address(KERNEL)).getTrancheUnitToNAVUnitConversionRateWAD();
    }

    /// @notice Tests that negative price causes INVALID_PRICE revert
    function test_oracleValidation_revertsOnNegativePrice() external {
        // Clear the mock
        vm.clearMockedCalls();

        // Mock a negative price
        vm.mockCall(
            _getChainlinkOracle(),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // roundId
                int256(-1e18), // answer (NEGATIVE - invalid!)
                vm.getBlockTimestamp(), // startedAt
                vm.getBlockTimestamp(), // updatedAt
                uint80(1) // answeredInRound
            )
        );

        vm.expectRevert(IdenticalAssetsChainlinkOracleQuoter.INVALID_PRICE.selector);
        Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel(address(KERNEL)).getTrancheUnitToNAVUnitConversionRateWAD();
    }

    /// @notice Tests that incomplete round causes INCOMPLETE_PRICE revert
    function test_oracleValidation_revertsOnIncompleteRound() external {
        // Clear the mock
        vm.clearMockedCalls();

        // Mock an incomplete round (answeredInRound < roundId)
        vm.mockCall(
            _getChainlinkOracle(),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(10), // roundId
                int256(1e18), // answer (positive)
                vm.getBlockTimestamp(), // startedAt
                vm.getBlockTimestamp(), // updatedAt
                uint80(5) // answeredInRound (LESS than roundId - incomplete!)
            )
        );

        vm.expectRevert(IdenticalAssetsChainlinkOracleQuoter.INCOMPLETE_PRICE.selector);
        Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel(address(KERNEL)).getTrancheUnitToNAVUnitConversionRateWAD();
    }

    /// @notice Tests that valid oracle data passes all checks
    function test_oracleValidation_passesWithValidData() external {
        // Clear and set valid mock
        vm.clearMockedCalls();

        vm.mockCall(
            _getChainlinkOracle(),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(10), // roundId
                int256(1e18), // answer (positive)
                vm.getBlockTimestamp(), // startedAt
                vm.getBlockTimestamp(), // updatedAt (fresh)
                uint80(10) // answeredInRound (== roundId - complete)
            )
        );

        // Should not revert
        uint256 rate = Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel(address(KERNEL)).getTrancheUnitToNAVUnitConversionRateWAD();
        assertGt(rate, 0, "Conversion rate should be positive");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ORACLE REFRESH HOOK
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Refresh chainlink oracle after vm.warp to avoid STALE_PRICE errors
    /// @dev Re-mocks the chainlink price with current timestamp
    function _refreshOraclesAfterWarp() internal virtual override {
        // Re-mock with the same price but updated timestamp
        int256 currentPrice = _getCurrentChainlinkPrice();
        _mockChainlinkPrice(currentPrice);
    }
}
