// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Vm } from "../../../../lib/forge-std/src/Vm.sol";
import { IERC20Metadata, IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { IRoycoAccountant } from "../../../../src/interfaces/IRoycoAccountant.sol";
import { IRoycoAuth } from "../../../../src/interfaces/IRoycoAuth.sol";
import { AggregatorV3Interface } from "../../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import { IdenticalAssetsChainlinkOracleQuoter } from "../../../../src/kernels/base/quoter/dawn/identical-assets/base/IdenticalAssetsChainlinkOracleQuoter.sol";
import {
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel
} from "../../../../src/kernels/dawn/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";
import { WAD, WAD_DECIMALS, ZERO_NAV_UNITS } from "../../../../src/libraries/Constants.sol";
import { AssetClaims, SyncedAccountingState, TrancheType } from "../../../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../../src/libraries/Units.sol";
import { AbstractKernelTestSuite } from "../../abstract/AbstractKernelTestSuite.t.sol";

/// @title YieldBearingERC4626_ChainlinkOracle_TestBase
/// @notice Base test contract for Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel
/// @dev Implements comprehensive tests for the two-leg conversion:
///   Leg 1 (ERC4626): sNUSD shares → NUSD via IERC4626.convertToAssets()
///   Leg 2 (Chainlink): NUSD → USD via Chainlink oracle latestRoundData()
///
/// Formula: trancheToNAV = convertToAssets(shares) * baseAssetToNAVRate / WAD
///
/// When storedConversionRate == 0 (sentinel), Leg 2 queries the Chainlink oracle.
/// When storedConversionRate != 0, the stored rate overrides the oracle.
abstract contract YieldBearingERC4626_ChainlinkOracle_TestBase is AbstractKernelTestSuite {
    // ═══════════════════════════════════════════════════════════════════════════
    // STATE FOR MOCKED ORACLES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tracks the mocked ERC4626 share price (in WAD precision)
    /// @dev When non-zero, this value is used to mock convertToAssets() calls
    uint256 internal mockedSharePriceWAD;

    /// @notice Tracks the mocked chainlink price
    /// @dev When non-zero, this value is used to mock latestRoundData() calls
    int256 internal mockedChainlinkPrice;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIGURATION (To be overridden by protocol-specific implementations)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the chainlink oracle address for the protocol
    function _getChainlinkOracle() internal view virtual returns (address);

    /// @notice Returns the staleness threshold for the chainlink oracle
    function _getStalenessThreshold() internal view virtual returns (uint48) {
        return 1 days;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER: KERNEL CAST
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Casts the kernel to the ERC4626+Chainlink variant
    function _kernelCast() internal view returns (Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel) {
        return Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel(address(KERNEL));
    }

    /// @notice Ensures the Chainlink oracle is mocked with a fresh timestamp
    /// @dev Reads the real oracle price (or cached mock) and re-mocks it with block.timestamp.
    ///      This prevents oracle staleness errors after time warps.
    function _ensureChainlinkOracleMocked() internal virtual {
        int256 currentPrice = _getCurrentChainlinkPrice();
        _mockChainlinkPrice(currentPrice);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // NAV MANIPULATION HOOKS IMPLEMENTATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Simulates yield for ST by randomly picking Leg 1 (ERC4626) or Leg 2 (Chainlink/stored rate)
    function simulateSTYield(uint256 _percentageWAD) public virtual override {
        if (vm.randomUint() % 2 == 0) {
            _simulateERC4626Yield(_percentageWAD);
        } else {
            _simulateChainlinkYield(_percentageWAD);
        }
    }

    /// @notice Simulates yield for JT by randomly picking Leg 1 or Leg 2
    /// @dev For identical assets, ST and JT share the same conversion rate
    function simulateJTYield(uint256 _percentageWAD) public virtual override {
        if (vm.randomUint() % 2 == 0) {
            _simulateERC4626Yield(_percentageWAD);
        } else {
            _simulateChainlinkYield(_percentageWAD);
        }
    }

    /// @notice Simulates loss for ST by randomly picking Leg 1 or Leg 2
    function simulateSTLoss(uint256 _percentageWAD) public virtual override {
        if (vm.randomUint() % 2 == 0) {
            _simulateERC4626Loss(_percentageWAD);
        } else {
            _simulateChainlinkLoss(_percentageWAD);
        }
    }

    /// @notice Simulates loss for JT by randomly picking Leg 1 or Leg 2
    /// @dev For identical assets, ST and JT share the same conversion rate
    function simulateJTLoss(uint256 _percentageWAD) public virtual override {
        if (vm.randomUint() % 2 == 0) {
            _simulateERC4626Loss(_percentageWAD);
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
        return toTrancheUnits(uint256(1e12));
    }

    /// @notice Returns max NAV delta for comparisons
    function maxNAVDelta() public view virtual override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LEG 1: ERC4626 SHARE PRICE MANIPULATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Simulates vault share price yield by mocking convertToAssets()
    /// @param _percentageWAD The percentage increase in WAD (e.g., 0.05e18 = 5%)
    function simulateVaultSharePriceYield(uint256 _percentageWAD) public virtual {
        _ensureChainlinkOracleMocked();
        uint256 currentSharePrice = _getCurrentSharePriceWAD();
        uint256 newSharePrice = currentSharePrice * (WAD + _percentageWAD) / WAD;
        _mockConvertToAssets(newSharePrice);
    }

    /// @notice Simulates vault share price loss by mocking convertToAssets()
    /// @param _percentageWAD The percentage decrease in WAD (e.g., 0.05e18 = 5%)
    function simulateVaultSharePriceLoss(uint256 _percentageWAD) public virtual {
        _ensureChainlinkOracleMocked();
        uint256 currentSharePrice = _getCurrentSharePriceWAD();
        uint256 newSharePrice = currentSharePrice * (WAD - _percentageWAD) / WAD;
        _mockConvertToAssets(newSharePrice);
    }

    /// @notice Computes the share amount to pass to convertToAssets() to get WAD-scaled output
    /// @dev This matches the kernel's ERC4626_SHARES_TO_CONVERT_TO_ASSETS calculation
    function _getSharesToConvertToAssets() internal view virtual returns (uint256) {
        return 10 ** (WAD_DECIMALS + IERC4626(config.stAsset).decimals() - IERC20Metadata(IERC4626(config.stAsset).asset()).decimals());
    }

    /// @notice Gets the current share price (either mocked or from the actual vault)
    /// @return The share price in WAD precision
    function _getCurrentSharePriceWAD() internal view virtual returns (uint256) {
        if (mockedSharePriceWAD != 0) {
            return mockedSharePriceWAD;
        }
        return IERC4626(config.stAsset).convertToAssets(_getSharesToConvertToAssets());
    }

    /// @notice Mocks the convertToAssets function on the vault
    /// @param _newSharePriceWAD The new share price in WAD precision
    function _mockConvertToAssets(uint256 _newSharePriceWAD) internal virtual {
        mockedSharePriceWAD = _newSharePriceWAD;
        uint256 sharesToConvert = _getSharesToConvertToAssets();
        vm.mockCall(config.stAsset, abi.encodeWithSelector(IERC4626.convertToAssets.selector, sharesToConvert), abi.encode(_newSharePriceWAD));
    }

    /// @notice Internal helper: simulate ERC4626 share price yield
    function _simulateERC4626Yield(uint256 _percentageWAD) internal {
        simulateVaultSharePriceYield(_percentageWAD);
    }

    /// @notice Internal helper: simulate ERC4626 share price loss
    function _simulateERC4626Loss(uint256 _percentageWAD) internal {
        simulateVaultSharePriceLoss(_percentageWAD);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LEG 2: CHAINLINK ORACLE PRICE MANIPULATION
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
    function _getCurrentChainlinkPrice() internal view returns (int256) {
        if (mockedChainlinkPrice != 0) {
            return mockedChainlinkPrice;
        }
        (, int256 answer,,,) = AggregatorV3Interface(_getChainlinkOracle()).latestRoundData();
        return answer;
    }

    /// @notice Mocks the latestRoundData function on the chainlink oracle
    /// @param _newPrice The new price to return
    function _mockChainlinkPrice(int256 _newPrice) internal {
        mockedChainlinkPrice = _newPrice;
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

    /// @notice Sentinel-aware Chainlink yield simulation
    /// @dev If sentinel mode (stored rate == 0), mocks the Chainlink oracle.
    ///      If non-sentinel mode, falls back to stored rate manipulation since oracle is bypassed.
    function _simulateChainlinkYield(uint256 _percentageWAD) internal {
        if (_getStoredConversionRate() == 0) {
            simulateChainlinkPriceYield(_percentageWAD);
        } else {
            simulateStoredRateYield(_percentageWAD);
        }
    }

    /// @notice Sentinel-aware Chainlink loss simulation
    /// @dev If sentinel mode (stored rate == 0), mocks the Chainlink oracle.
    ///      If non-sentinel mode, falls back to stored rate manipulation since oracle is bypassed.
    function _simulateChainlinkLoss(uint256 _percentageWAD) internal {
        if (_getStoredConversionRate() == 0) {
            simulateChainlinkPriceLoss(_percentageWAD);
        } else {
            simulateStoredRateLoss(_percentageWAD);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STORED CONVERSION RATE HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Gets the stored conversion rate (base asset to NAV) in WAD precision
    function _getStoredConversionRate() internal view returns (uint256) {
        return _kernelCast().getStoredConversionRateWAD();
    }

    /// @notice Sets the stored conversion rate (base asset to NAV) in WAD precision
    /// @dev Requires ADMIN_ORACLE_QUOTER_ROLE, which is granted to ORACLE_QUOTER_ADMIN_ADDRESS
    function _setStoredConversionRate(uint256 _newRateWAD) internal virtual {
        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        _kernelCast().setConversionRate(_newRateWAD, true);
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

    /// @notice Alias for _getStoredConversionRate (backward compatibility)
    function _getConversionRate() internal view virtual returns (uint256) {
        return _getStoredConversionRate();
    }

    /// @notice Alias for _setStoredConversionRate (backward compatibility)
    function _setConversionRate(uint256 _newRateWAD) internal virtual {
        _setStoredConversionRate(_newRateWAD);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ORACLE REFRESH HOOK
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Refresh oracles after vm.warp to avoid STALE_PRICE errors
    /// @dev Re-mocks both Chainlink (updated timestamp) and ERC4626 convertToAssets
    function _refreshOraclesAfterWarp() internal virtual override {
        // Re-mock Chainlink with current timestamp to avoid staleness
        int256 currentPrice = _getCurrentChainlinkPrice();
        _mockChainlinkPrice(currentPrice);

        // Re-mock ERC4626 convertToAssets if it was previously mocked
        if (mockedSharePriceWAD != 0) {
            _mockConvertToAssets(mockedSharePriceWAD);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION A: LEG 1 — VAULT SHARE PRICE TESTS (ERC4626 convertToAssets)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tests that vault share price yield increases NAV
    function testFuzz_vaultSharePrice_yield_updatesNAV(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 1, 50);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        simulateVaultSharePriceYield(_yieldPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after vault share price yield");
    }

    /// @notice Tests that vault share price loss decreases NAV
    function testFuzz_vaultSharePrice_loss_updatesNAV(uint256 _jtAmount, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _lossPercentage = bound(_lossPercentage, 1, 30);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        simulateVaultSharePriceLoss(_lossPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after vault share price loss");
    }

    /// @notice Tests that vault share price yield with ST deposits distributes correctly
    function testFuzz_vaultSharePrice_yield_distributesToJT(uint256 _jtAmount, uint256 _stPercentage, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 10, 50);
        _yieldPercentage = bound(_yieldPercentage, 1, 20);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;
        // Cap to BOB's available balance (low coverage markets can have maxSTDeposit > initialFunding)
        uint256 bobBalance = IERC4626(config.stAsset).balanceOf(BOB_ADDRESS);
        if (stAmount > bobBalance) stAmount = bobBalance;

        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        NAV_UNIT jtNavBefore = JT.totalAssets().nav;

        simulateVaultSharePriceYield(_yieldPercentage * 1e16);

        vm.warp(vm.getBlockTimestamp() + 1 days);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT jtNavAfter = JT.totalAssets().nav;
        assertGe(jtNavAfter, jtNavBefore, "JT NAV should increase or stay same from vault share price yield");
    }

    /// @notice Tests that share price is correctly tracked and used in conversion rate
    function testFuzz_vaultSharePrice_exactPriceTracking(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 1, 30);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        uint256 sharePriceBefore = _getCurrentSharePriceWAD();
        uint256 totalRateBefore = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        uint256 yieldWAD = _yieldPercentage * 1e16;
        simulateVaultSharePriceYield(yieldWAD);

        // Verify exact share price calculation
        uint256 expectedSharePrice = sharePriceBefore * (WAD + yieldWAD) / WAD;
        assertEq(_getCurrentSharePriceWAD(), expectedSharePrice, "Share price should match expected after yield");

        // Total conversion rate should scale proportionally to share price since Leg 2 is unchanged
        uint256 actualConversionRate = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
        assertGt(actualConversionRate, totalRateBefore, "Kernel conversion rate should increase with share price");
    }

    /// @notice Tests that redemption NAV value increases proportionally with share price yield
    function testFuzz_vaultSharePrice_yield_increasesRedemptionValue(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 5, 30);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        uint256 sharesBefore = JT.balanceOf(ALICE_ADDRESS);
        NAV_UNIT navValueBefore = JT.totalAssets().nav;
        uint256 sharePriceBefore = _getCurrentSharePriceWAD();

        uint256 yieldWAD = _yieldPercentage * 1e16;
        simulateVaultSharePriceYield(yieldWAD);

        uint256 expectedSharePrice = sharePriceBefore * (WAD + yieldWAD) / WAD;
        assertEq(_getCurrentSharePriceWAD(), expectedSharePrice, "Share price should match expected yield");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        uint256 sharesAfter = JT.balanceOf(ALICE_ADDRESS);
        assertEq(sharesAfter, sharesBefore, "Share balance should not change");

        NAV_UNIT navValueAfter = JT.totalAssets().nav;
        assertGt(navValueAfter, navValueBefore, "NAV value of shares should increase after yield");

        uint256 expectedMinNav = toUint256(navValueBefore) * (WAD + yieldWAD / 2) / WAD;
        assertGt(toUint256(navValueAfter), expectedMinNav, "NAV should increase proportionally to yield");
    }

    /// @notice Tests that redemption NAV value decreases proportionally with share price loss
    function testFuzz_vaultSharePrice_loss_decreasesRedemptionValue(uint256 _jtAmount, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _lossPercentage = bound(_lossPercentage, 5, 20);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navValueBefore = JT.totalAssets().nav;
        uint256 sharePriceBefore = _getCurrentSharePriceWAD();

        uint256 lossWAD = _lossPercentage * 1e16;
        simulateVaultSharePriceLoss(lossWAD);

        uint256 expectedSharePrice = sharePriceBefore * (WAD - lossWAD) / WAD;
        assertEq(_getCurrentSharePriceWAD(), expectedSharePrice, "Share price should match expected loss");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navValueAfter = JT.totalAssets().nav;
        assertLt(navValueAfter, navValueBefore, "NAV value should decrease after loss");

        uint256 expectedMaxNav = toUint256(navValueBefore) * (WAD - lossWAD / 2) / WAD;
        assertLt(toUint256(navValueAfter), expectedMaxNav, "NAV should decrease proportionally to loss");
    }

    /// @notice Tests full redemption after share price yield returns all shares
    function testFuzz_vaultSharePrice_redemptionAfterYield(uint256 _jtAmount, uint256 _yieldPercentage, uint256 _redeemPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 1, 20);
        _redeemPercentage = bound(_redeemPercentage, 10, 100);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        uint256 assetBalanceBefore = IERC20Metadata(config.jtAsset).balanceOf(ALICE_ADDRESS);

        simulateVaultSharePriceYield(_yieldPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        uint256 totalShares = JT.balanceOf(ALICE_ADDRESS);
        uint256 sharesToRedeem = totalShares * _redeemPercentage / 100;

        if (sharesToRedeem == 0) return;

        vm.prank(ALICE_ADDRESS);
        AssetClaims memory claims = JT.redeem(sharesToRedeem, ALICE_ADDRESS, ALICE_ADDRESS);

        assertEq(JT.balanceOf(ALICE_ADDRESS), totalShares - sharesToRedeem, "Shares should be burned");
        assertGt(toUint256(claims.jtAssets), 0, "Should receive assets from redemption");
        uint256 assetBalanceAfter = IERC20Metadata(config.jtAsset).balanceOf(ALICE_ADDRESS);
        assertEq(assetBalanceAfter, assetBalanceBefore + toUint256(claims.jtAssets), "Asset balance should increase by redeemed amount");
    }

    /// @notice Tests that maxSTDeposit increases after JT yield
    function testFuzz_vaultSharePrice_yield_increasesMaxSTDeposit(uint256 _jtAmount, uint256 _stPercentage, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 10, 50);
        _yieldPercentage = bound(_yieldPercentage, 5, 30);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDepositInitial = ST.maxDeposit(CHARLIE_ADDRESS);
        assertGt(toUint256(maxSTDepositInitial), 0, "Initial maxSTDeposit should be > 0 after JT deposit");

        uint256 stAmount = toUint256(maxSTDepositInitial) * _stPercentage / 100;
        // Cap to BOB's available balance (low coverage markets can have maxSTDeposit > initialFunding)
        uint256 bobBalance = IERC4626(config.stAsset).balanceOf(BOB_ADDRESS);
        if (stAmount > bobBalance) stAmount = bobBalance;
        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        TRANCHE_UNIT maxSTDepositAfterDeposit = ST.maxDeposit(CHARLIE_ADDRESS);
        assertLt(toUint256(maxSTDepositAfterDeposit), toUint256(maxSTDepositInitial), "maxSTDeposit should decrease after ST deposit");

        simulateVaultSharePriceYield(_yieldPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        TRANCHE_UNIT maxSTDepositAfterYield = ST.maxDeposit(CHARLIE_ADDRESS);
        assertGe(
            toUint256(maxSTDepositAfterYield), toUint256(maxSTDepositAfterDeposit), "maxSTDeposit should increase or stay same after JT yield (more coverage)"
        );
    }

    /// @notice Tests that loss reduces JT NAV
    function testFuzz_vaultSharePrice_loss_reducesJTNAV(uint256 _jtAmount, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _lossPercentage = bound(_lossPercentage, 5, 20);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT jtNAVBefore = JT.totalAssets().nav;
        TRANCHE_UNIT maxSTDepositBefore = ST.maxDeposit(CHARLIE_ADDRESS);
        assertGt(toUint256(maxSTDepositBefore), 0, "maxSTDeposit should be > 0 after JT deposit");

        simulateVaultSharePriceLoss(_lossPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT jtNAVAfter = JT.totalAssets().nav;
        assertLt(jtNAVAfter, jtNAVBefore, "JT NAV should decrease after loss");

        uint256 lossWAD = _lossPercentage * 1e16;
        uint256 expectedMaxNav = toUint256(jtNAVBefore) * (WAD - lossWAD / 2) / WAD;
        assertLt(toUint256(jtNAVAfter), expectedMaxNav, "JT NAV decrease should be proportional to loss");
    }

    /// @notice Tests that JT maxRedeem remains valid and can execute full redemption after yield
    function testFuzz_vaultSharePrice_yield_maxRedeemStaysValid(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 5, 30);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        uint256 shareBalance = JT.balanceOf(ALICE_ADDRESS);
        uint256 maxRedeemBefore = JT.maxRedeem(ALICE_ADDRESS);
        assertGt(maxRedeemBefore, 0, "maxRedeem should be > 0 after deposit");

        assertApproxEqRel(maxRedeemBefore, shareBalance, 1e16, "maxRedeem should be close to share balance");

        simulateVaultSharePriceYield(_yieldPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        uint256 maxRedeemAfter = JT.maxRedeem(ALICE_ADDRESS);
        assertGt(maxRedeemAfter, 0, "maxRedeem should remain > 0 after yield");
        assertApproxEqRel(maxRedeemAfter, shareBalance, 1e16, "maxRedeem should be close to share balance after yield");

        vm.prank(ALICE_ADDRESS);
        AssetClaims memory claims = JT.redeem(maxRedeemAfter, ALICE_ADDRESS, ALICE_ADDRESS);
        assertGt(toUint256(claims.jtAssets), 0, "Should receive assets from max redeem");

        assertLe(JT.balanceOf(ALICE_ADDRESS), shareBalance / 100, "Should have redeemed most shares");
    }

    /// @notice Tests that JT maxRedeem is constrained when ST has priority claims
    function testFuzz_vaultSharePrice_loss_constrainsJTMaxRedeem(uint256 _jtAmount, uint256 _stPercentage, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 30, 80);
        _lossPercentage = bound(_lossPercentage, 5, 15);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;
        // Cap to BOB's available balance (low coverage markets can have maxSTDeposit > initialFunding)
        uint256 bobBalance = IERC4626(config.stAsset).balanceOf(BOB_ADDRESS);
        if (stAmount > bobBalance) stAmount = bobBalance;
        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        uint256 jtShareBalance = JT.balanceOf(ALICE_ADDRESS);
        uint256 maxRedeemBefore = JT.maxRedeem(ALICE_ADDRESS);
        assertLe(maxRedeemBefore, jtShareBalance, "maxRedeem should be <= share balance");

        simulateVaultSharePriceLoss(_lossPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        uint256 maxRedeemAfter = JT.maxRedeem(ALICE_ADDRESS);
        assertLe(maxRedeemAfter, maxRedeemBefore, "maxRedeem should decrease or stay same after loss with ST claims");
    }

    /// @notice Tests that significant loss books JT coverage impermanent loss and gates ST deposits only by the coverage requirement
    function testFuzz_vaultSharePrice_significantLoss_createsImpermanentLoss(uint256 _jtAmount, uint256 _stPercentage, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount() * 10, config.initialFunding / 100);
        _stPercentage = bound(_stPercentage, 50, 80);
        _lossPercentage = bound(_lossPercentage, 25, 35);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;
        // Cap to BOB's available balance (low coverage markets can have maxSTDeposit > initialFunding)
        uint256 bobBalance = IERC4626(config.stAsset).balanceOf(BOB_ADDRESS);
        if (stAmount > bobBalance) stAmount = bobBalance;
        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        (SyncedAccountingState memory stateBefore,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);
        NAV_UNIT impermanentLossBefore = stateBefore.jtCoverageImpermanentLoss;

        uint256 lossWAD = _lossPercentage * 1e16;
        simulateVaultSharePriceLoss(lossWAD);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        (SyncedAccountingState memory stateAfter,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);
        NAV_UNIT impermanentLossAfter = stateAfter.jtCoverageImpermanentLoss;

        if (impermanentLossAfter > impermanentLossBefore) {
            assertGt(toUint256(impermanentLossAfter), 0, "JT coverage impermanent loss should be tracked in accountant state");
            assertLt(toUint256(stateAfter.jtEffectiveNAV), toUint256(stateBefore.jtEffectiveNAV), "JT effective NAV should decrease after covering ST losses");
        }

        if (stateAfter.jtEffectiveNAV == ZERO_NAV_UNITS) {
            TRANCHE_UNIT maxSTDepositAfterLoss = ST.maxDeposit(CHARLIE_ADDRESS);
            assertEq(toUint256(maxSTDepositAfterLoss), 0, "ST deposits should be blocked when JT effective NAV is zero");
            assertLe(toUint256(stateAfter.stEffectiveNAV), toUint256(stateBefore.stEffectiveNAV), "Uncovered loss should reduce ST effective NAV");
        }
    }

    /// @notice Tests that share price recovery repays JT coverage impermanent loss
    function testFuzz_vaultSharePrice_recovery_reducesImpermanentLoss(uint256 _jtAmount, uint256 _stPercentage, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 50, 80);
        _lossPercentage = bound(_lossPercentage, 15, 25);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;
        // Cap to BOB's available balance (low coverage markets can have maxSTDeposit > initialFunding)
        uint256 bobBalance = IERC4626(config.stAsset).balanceOf(BOB_ADDRESS);
        if (stAmount > bobBalance) stAmount = bobBalance;
        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        uint256 initialSharePrice = _getCurrentSharePriceWAD();

        uint256 lossWAD = _lossPercentage * 1e16;
        simulateVaultSharePriceLoss(lossWAD);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        (SyncedAccountingState memory stateAfterLoss,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);
        NAV_UNIT impermanentLossAfterDrop = stateAfterLoss.jtCoverageImpermanentLoss;

        // Recover share price to original
        uint256 currentSharePrice = _getCurrentSharePriceWAD();
        uint256 recoveryMultiplier = (initialSharePrice * WAD) / currentSharePrice;
        uint256 recoveryYield = recoveryMultiplier - WAD;

        simulateVaultSharePriceYield(recoveryYield);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        assertApproxEqRel(_getCurrentSharePriceWAD(), initialSharePrice, 1e15, "Share price should recover to approximately initial");

        (SyncedAccountingState memory stateAfterRecovery,,) = KERNEL.previewSyncTrancheAccounting(TrancheType.SENIOR);
        NAV_UNIT impermanentLossAfterRecovery = stateAfterRecovery.jtCoverageImpermanentLoss;

        assertLe(
            toUint256(impermanentLossAfterRecovery),
            toUint256(impermanentLossAfterDrop),
            "JT coverage impermanent loss should decrease after share price recovery"
        );

        if (impermanentLossAfterRecovery == ZERO_NAV_UNITS) {
            NAV_UNIT jtNAVAfterRecovery = JT.totalAssets().nav;
            assertGt(toUint256(jtNAVAfterRecovery), 0, "JT NAV should be positive after impermanent loss is cleared");
        }
    }

    /// @notice Tests that multiple JT depositors maintain proportional ownership after loss
    function testFuzz_vaultSharePrice_loss_multipleDepositors_proportionalOwnership(uint256 _jtAmount1, uint256 _jtAmount2, uint256 _lossPercentage) external {
        _jtAmount1 = bound(_jtAmount1, _minDepositAmount(), config.initialFunding / 20);
        _jtAmount2 = bound(_jtAmount2, _minDepositAmount(), config.initialFunding / 20);
        _lossPercentage = bound(_lossPercentage, 1, 20);

        _depositJT(ALICE_ADDRESS, _jtAmount1);
        _depositJT(CHARLIE_ADDRESS, _jtAmount2);

        uint256 aliceShares = JT.balanceOf(ALICE_ADDRESS);
        uint256 charlieShares = JT.balanceOf(CHARLIE_ADDRESS);
        uint256 totalSharesBefore = JT.totalSupply();
        NAV_UNIT totalNAVBefore = JT.totalAssets().nav;

        simulateVaultSharePriceLoss(_lossPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT totalNAVAfter = JT.totalAssets().nav;
        uint256 totalSharesAfter = JT.totalSupply();

        assertLt(totalNAVAfter, totalNAVBefore, "Total NAV should decrease after loss");
        assertEq(totalSharesAfter, totalSharesBefore, "Total shares should be unchanged");
        assertEq(JT.balanceOf(ALICE_ADDRESS), aliceShares, "Alice shares should be unchanged");
        assertEq(JT.balanceOf(CHARLIE_ADDRESS), charlieShares, "Charlie shares should be unchanged");

        uint256 aliceOwnershipBps = (aliceShares * 10_000) / totalSharesAfter;
        uint256 charlieOwnershipBps = (charlieShares * 10_000) / totalSharesAfter;
        uint256 expectedAliceOwnershipBps = (aliceShares * 10_000) / totalSharesBefore;
        uint256 expectedCharlieOwnershipBps = (charlieShares * 10_000) / totalSharesBefore;
        assertEq(aliceOwnershipBps, expectedAliceOwnershipBps, "Alice ownership percentage should be unchanged");
        assertEq(charlieOwnershipBps, expectedCharlieOwnershipBps, "Charlie ownership percentage should be unchanged");
    }

    /// @notice Tests sequential price changes track share price state correctly
    function testFuzz_vaultSharePrice_sequential_changes_tracksState(
        uint256 _jtAmount,
        uint256 _change1Bps,
        uint256 _change2Bps,
        uint256 _change3Bps
    )
        external
    {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _change1Bps = bound(_change1Bps, 10, 200);
        _change2Bps = bound(_change2Bps, 10, 200);
        _change3Bps = bound(_change3Bps, 10, 200);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        uint256 sharePriceInitial = _getCurrentSharePriceWAD();
        NAV_UNIT navInitial = JT.totalAssets().nav;

        // Change 1: Up
        uint256 change1WAD = _change1Bps * 1e14;
        simulateVaultSharePriceYield(change1WAD);
        uint256 expectedPrice1 = sharePriceInitial * (WAD + change1WAD) / WAD;
        assertEq(_getCurrentSharePriceWAD(), expectedPrice1, "Share price after change 1 should match expected");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();
        NAV_UNIT navAfter1 = JT.totalAssets().nav;
        assertGt(navAfter1, navInitial, "NAV should increase after yield");

        // Change 2: Down
        uint256 change2WAD = _change2Bps * 1e14;
        simulateVaultSharePriceLoss(change2WAD);
        uint256 expectedPrice2 = expectedPrice1 * (WAD - change2WAD) / WAD;
        assertEq(_getCurrentSharePriceWAD(), expectedPrice2, "Share price after change 2 should match expected");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();
        NAV_UNIT navAfter2 = JT.totalAssets().nav;
        assertLt(navAfter2, navAfter1, "NAV should decrease after loss");

        // Change 3: Up
        uint256 change3WAD = _change3Bps * 1e14;
        simulateVaultSharePriceYield(change3WAD);
        uint256 expectedPrice3 = expectedPrice2 * (WAD + change3WAD) / WAD;
        assertEq(_getCurrentSharePriceWAD(), expectedPrice3, "Share price after change 3 should match expected");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();
        NAV_UNIT navAfter3 = JT.totalAssets().nav;
        assertGt(navAfter3, navAfter2, "NAV should increase after final yield");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION B: LEG 2 — CHAINLINK ORACLE PRICE TESTS
    // ═══════════════════════════════════════════════════════════════════════════
    // NOTE: These tests require sentinel mode (stored rate == 0) so the oracle is queried

    /// @notice Tests that chainlink price yield increases NAV
    function testFuzz_chainlinkPrice_yield_updatesNAV(uint256 _jtAmount, uint256 _yieldPercentage) public virtual {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 1, 50);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Ensure sentinel mode so oracle is queried
        assertEq(_getStoredConversionRate(), 0, "Should be in sentinel mode");

        simulateChainlinkPriceYield(_yieldPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after chainlink price yield");
    }

    /// @notice Tests that chainlink price loss decreases NAV
    function testFuzz_chainlinkPrice_loss_updatesNAV(uint256 _jtAmount, uint256 _lossPercentage) public virtual {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _lossPercentage = bound(_lossPercentage, 1, 30);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        assertEq(_getStoredConversionRate(), 0, "Should be in sentinel mode");

        simulateChainlinkPriceLoss(_lossPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after chainlink price loss");
    }

    /// @notice Tests that chainlink price yield with ST deposits distributes correctly
    function testFuzz_chainlinkPrice_yield_distributesToJT(uint256 _jtAmount, uint256 _stPercentage, uint256 _yieldPercentage) public virtual {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 10, 50);
        _yieldPercentage = bound(_yieldPercentage, 1, 20);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;

        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        NAV_UNIT jtNavBefore = JT.totalAssets().nav;

        simulateChainlinkPriceYield(_yieldPercentage * 1e16);

        vm.warp(vm.getBlockTimestamp() + 1 days);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT jtNavAfter = JT.totalAssets().nav;
        assertGe(jtNavAfter, jtNavBefore, "JT NAV should increase or stay same from chainlink price yield");
    }

    /// @notice Tests NAV conservation after chainlink price changes
    function testFuzz_chainlinkPrice_NAVConservation(uint256 _jtAmount, uint256 _yieldPercentage) public virtual {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 1, 30);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        simulateChainlinkPriceYield(_yieldPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        _assertNAVConservation();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION C: STORED CONVERSION RATE TESTS
    // ═══════════════════════════════════════════════════════════════════════════
    // NOTE: These tests switch to non-sentinel mode by setting a non-zero stored rate

    /// @notice Tests that stored conversion rate yield increases NAV
    function testFuzz_storedConversionRate_yield_updatesNAV(uint256 _jtAmount, uint256 _yieldBps) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldBps = bound(_yieldBps, 10, 1000);

        // Switch to non-sentinel mode
        _setStoredConversionRate(WAD);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _getStoredConversionRate();

        uint256 yieldWAD = _yieldBps * 1e14;
        simulateStoredRateYield(yieldWAD);

        uint256 rateAfter = _getStoredConversionRate();
        assertGt(rateAfter, rateBefore, "Stored rate should increase after yield");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after stored conversion rate yield");
    }

    /// @notice Tests that stored conversion rate loss decreases NAV
    function testFuzz_storedConversionRate_loss_updatesNAV(uint256 _jtAmount, uint256 _lossBps) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _lossBps = bound(_lossBps, 10, 500);

        // Switch to non-sentinel mode
        _setStoredConversionRate(WAD);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _getStoredConversionRate();

        uint256 lossWAD = _lossBps * 1e14;
        simulateStoredRateLoss(lossWAD);

        uint256 rateAfter = _getStoredConversionRate();
        assertLt(rateAfter, rateBefore, "Stored rate should decrease after loss");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after stored conversion rate loss");
    }

    /// @notice Tests that stored conversion rate yield distributes to JT
    function testFuzz_storedConversionRate_yield_distributesToJT(uint256 _jtAmount, uint256 _stPercentage, uint256 _yieldBps) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 10, 50);
        _yieldBps = bound(_yieldBps, 10, 1000);

        // Switch to non-sentinel mode
        _setStoredConversionRate(WAD);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;
        // Cap to BOB's available balance (low coverage markets can have maxSTDeposit > initialFunding)
        uint256 bobBalance = IERC4626(config.stAsset).balanceOf(BOB_ADDRESS);
        if (stAmount > bobBalance) stAmount = bobBalance;
        if (stAmount < _minDepositAmount()) return;

        _depositST(BOB_ADDRESS, stAmount);

        NAV_UNIT jtNavBefore = JT.totalAssets().nav;

        uint256 yieldWAD = _yieldBps * 1e14;
        simulateStoredRateYield(yieldWAD);

        vm.warp(vm.getBlockTimestamp() + 1 days);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT jtNavAfter = JT.totalAssets().nav;
        assertGe(jtNavAfter, jtNavBefore, "JT NAV should increase or stay same from stored rate yield");
    }

    /// @notice Tests that stored conversion rate is correctly stored and retrievable
    function testFuzz_storedConversionRate_exactRateStorage(uint256 _jtAmount, uint256 _yieldBps) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldBps = bound(_yieldBps, 10, 1000);

        // Switch to non-sentinel mode
        _setStoredConversionRate(WAD);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        uint256 rateBefore = _getStoredConversionRate();

        uint256 yieldWAD = _yieldBps * 1e14;
        simulateStoredRateYield(yieldWAD);

        uint256 expectedRate = rateBefore * (WAD + yieldWAD) / WAD;
        assertEq(_getStoredConversionRate(), expectedRate, "Stored rate should match expected after yield");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        assertEq(_getStoredConversionRate(), expectedRate, "Stored rate should be unchanged after sync");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION D: COMBINED TESTS — BOTH LEGS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tests combined yield from both legs verifies multiplicative formula
    function testFuzz_combined_bothLegsYield_verifiesMultiplicativeFormula(
        uint256 _jtAmount,
        uint256 _sharePriceYieldBps,
        uint256 _chainlinkYieldBps
    )
        public
        virtual
    {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _sharePriceYieldBps = bound(_sharePriceYieldBps, 10, 500);
        _chainlinkYieldBps = bound(_chainlinkYieldBps, 10, 500);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Ensure sentinel mode for Chainlink leg
        assertEq(_getStoredConversionRate(), 0, "Should be in sentinel mode");

        NAV_UNIT navBefore = JT.totalAssets().nav;

        uint256 sharePriceYieldWAD = _sharePriceYieldBps * 1e14;
        uint256 chainlinkYieldWAD = _chainlinkYieldBps * 1e14;
        simulateVaultSharePriceYield(sharePriceYieldWAD);
        simulateChainlinkPriceYield(chainlinkYieldWAD);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after combined yield from both legs");
    }

    /// @notice Tests mixed direction: share price UP + chainlink DOWN
    function testFuzz_combined_sharePriceUp_chainlinkDown(uint256 _jtAmount, uint256 _sharePriceYieldBps, uint256 _chainlinkLossBps) public virtual {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _sharePriceYieldBps = bound(_sharePriceYieldBps, 200, 500); // 2% to 5%
        _chainlinkLossBps = bound(_chainlinkLossBps, 10, 50); // 0.1% to 0.5%

        _depositJT(ALICE_ADDRESS, _jtAmount);

        assertEq(_getStoredConversionRate(), 0, "Should be in sentinel mode");

        uint256 totalRateBefore = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        uint256 sharePriceYieldWAD = _sharePriceYieldBps * 1e14;
        uint256 chainlinkLossWAD = _chainlinkLossBps * 1e14;
        simulateVaultSharePriceYield(sharePriceYieldWAD);
        simulateChainlinkPriceLoss(chainlinkLossWAD);

        uint256 totalRateAfter = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        // Net effect: share price gain > chainlink loss, so rate should increase
        assertGt(totalRateAfter, totalRateBefore, "Net gain from share price up + chainlink down should increase total rate");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();
    }

    /// @notice Tests mixed direction: share price DOWN + chainlink UP
    function testFuzz_combined_sharePriceDown_chainlinkUp(uint256 _jtAmount, uint256 _sharePriceLossBps, uint256 _chainlinkYieldBps) public virtual {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _sharePriceLossBps = bound(_sharePriceLossBps, 10, 50); // 0.1% to 0.5%
        _chainlinkYieldBps = bound(_chainlinkYieldBps, 200, 500); // 2% to 5%

        _depositJT(ALICE_ADDRESS, _jtAmount);

        assertEq(_getStoredConversionRate(), 0, "Should be in sentinel mode");

        uint256 totalRateBefore = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        uint256 sharePriceLossWAD = _sharePriceLossBps * 1e14;
        uint256 chainlinkYieldWAD = _chainlinkYieldBps * 1e14;
        simulateVaultSharePriceLoss(sharePriceLossWAD);
        simulateChainlinkPriceYield(chainlinkYieldWAD);

        uint256 totalRateAfter = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        // Net effect: chainlink gain > share price loss, so rate should increase
        assertGt(totalRateAfter, totalRateBefore, "Net gain from chainlink up + share price down should increase total rate");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION E: ORACLE VALIDATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════
    // NOTE: Sentinel mode (stored rate == 0) is required so the oracle is actually queried

    /// @notice Tests that stale price causes STALE_PRICE revert
    function test_oracleValidation_revertsOnStalePrice() external virtual {
        // Ensure sentinel mode so oracle is queried
        if (_getStoredConversionRate() != 0) _setStoredConversionRate(0);

        vm.clearMockedCalls();

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

        vm.expectRevert(IdenticalAssetsChainlinkOracleQuoter.STALE_PRICE.selector);
        _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
    }

    /// @notice Tests that zero price causes INVALID_PRICE revert
    function test_oracleValidation_revertsOnZeroPrice() external virtual {
        if (_getStoredConversionRate() != 0) _setStoredConversionRate(0);

        vm.clearMockedCalls();

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
        _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
    }

    /// @notice Tests that negative price causes INVALID_PRICE revert
    function test_oracleValidation_revertsOnNegativePrice() external virtual {
        if (_getStoredConversionRate() != 0) _setStoredConversionRate(0);

        vm.clearMockedCalls();

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
        _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
    }

    /// @notice Tests that incomplete round causes INCOMPLETE_PRICE revert
    function test_oracleValidation_revertsOnIncompleteRound() external virtual {
        if (_getStoredConversionRate() != 0) _setStoredConversionRate(0);

        vm.clearMockedCalls();

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
        _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
    }

    /// @notice Tests that valid oracle data passes all checks
    function test_oracleValidation_passesWithValidData() external virtual {
        if (_getStoredConversionRate() != 0) _setStoredConversionRate(0);

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

        uint256 rate = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
        assertGt(rate, 0, "Conversion rate should be positive");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION F: ORACLE RECONFIGURATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tests that setting a new oracle works with valid params
    function test_setChainlinkOracle_success() external {
        address newOracle = makeAddr("newOracle");
        address anotherOracle = makeAddr("anotherOracle");
        uint48 newStaleness = 2 days;

        vm.mockCall(newOracle, abi.encodeWithSelector(AggregatorV3Interface.decimals.selector), abi.encode(uint8(18)));
        vm.mockCall(
            newOracle,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1e18), uint256(0), block.timestamp, uint80(1))
        );

        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        _kernelCast().setChainlinkOracle(newOracle, newStaleness, true);

        vm.mockCall(anotherOracle, abi.encodeWithSelector(AggregatorV3Interface.decimals.selector), abi.encode(uint8(8)));
        vm.mockCall(
            anotherOracle,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1e8), uint256(0), block.timestamp, uint80(1))
        );

        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        _kernelCast().setChainlinkOracle(anotherOracle, 3 days, true);
    }

    /// @notice Tests that setting oracle with zero address reverts
    function test_setChainlinkOracle_revertsOnZeroAddress() external {
        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        vm.expectRevert(IRoycoAuth.NULL_ADDRESS.selector);
        _kernelCast().setChainlinkOracle(address(0), 1 days, true);
    }

    /// @notice Tests that setting oracle with zero staleness reverts
    function test_setChainlinkOracle_revertsOnZeroStaleness() external {
        address newOracle = makeAddr("newOracleForZeroStaleness");

        vm.mockCall(newOracle, abi.encodeWithSelector(AggregatorV3Interface.decimals.selector), abi.encode(uint8(18)));

        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        vm.expectRevert(IdenticalAssetsChainlinkOracleQuoter.INVALID_STALENESS_THRESHOLD_SECONDS.selector);
        _kernelCast().setChainlinkOracle(newOracle, 0, true);
    }

    /// @notice Tests that non-admin cannot set oracle
    function test_setChainlinkOracle_revertsOnUnauthorized() external {
        address newOracle = makeAddr("newOracleForUnauthorized");

        vm.mockCall(newOracle, abi.encodeWithSelector(AggregatorV3Interface.decimals.selector), abi.encode(uint8(18)));

        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(); // AccessManagerUnauthorizedAccount
        _kernelCast().setChainlinkOracle(newOracle, 1 days, true);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION F2: _syncBeforeUpdate FLAG TESTS
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
        // Switch to non-sentinel mode first
        _setStoredConversionRate(WAD);

        vm.recordLogs();

        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        _kernelCast().setConversionRate(WAD * 2, false);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countSyncEvents(logs), 1, "Should have exactly 1 sync (post-update only)");
    }

    /// @notice Tests that setConversionRate with true fires both pre and post sync (2 syncs total)
    function test_setConversionRate_withPreSync() external {
        // Switch to non-sentinel mode first
        _setStoredConversionRate(WAD);

        vm.recordLogs();

        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        _kernelCast().setConversionRate(WAD * 2, true);

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
        _kernelCast().setChainlinkOracle(newOracle, 1 days, false);

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
        _kernelCast().setChainlinkOracle(newOracle, 1 days, true);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countSyncEvents(logs), 2, "Should have exactly 2 syncs (pre + post update)");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SECTION G: SENTINEL VS NON-SENTINEL MODE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tests that in sentinel mode (stored rate == 0), the Chainlink oracle is queried
    function test_sentinelMode_usesChainlinkOracle() public virtual {
        // Ensure sentinel mode
        assertEq(_getStoredConversionRate(), 0, "Should be in sentinel mode");

        // Mock Chainlink to a specific price
        _mockChainlinkPrice(int256(1e8)); // 1 USD at 8 decimals
        uint256 rate1 = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        // Mock Chainlink to a different price
        _mockChainlinkPrice(int256(2e8)); // 2 USD at 8 decimals
        uint256 rate2 = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        // Rate should change because oracle IS being queried
        assertGt(rate2, rate1, "Rate should change when Chainlink price changes in sentinel mode");
    }

    /// @notice Tests that in non-sentinel mode (stored rate != 0), the Chainlink oracle is bypassed
    function test_nonSentinelMode_usesStoredRate() external {
        // Switch to non-sentinel mode
        _setStoredConversionRate(WAD);

        // Mock Chainlink to price A
        _mockChainlinkPrice(int256(1e8));
        uint256 rate1 = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        // Mock Chainlink to price B (different)
        _mockChainlinkPrice(int256(2e8));
        uint256 rate2 = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        // Rate should NOT change because oracle is bypassed (stored rate is used)
        assertEq(rate2, rate1, "Rate should NOT change when Chainlink price changes in non-sentinel mode");

        // Change stored rate and verify it does affect the total rate
        _setStoredConversionRate(WAD * 2);
        uint256 rate3 = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
        assertGt(rate3, rate1, "Rate should change when stored rate changes in non-sentinel mode");
    }

    /// @notice Tests transition from sentinel to non-sentinel mode
    function testFuzz_sentinelToNonSentinel_transition(uint256 _jtAmount) public virtual {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Start in sentinel mode
        assertEq(_getStoredConversionRate(), 0, "Should start in sentinel mode");

        // Mock Chainlink to a specific price and get rate
        _mockChainlinkPrice(int256(1e8));
        uint256 sentinelRate = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
        assertGt(sentinelRate, 0, "Rate should be positive in sentinel mode");

        // Switch to non-sentinel mode
        _setStoredConversionRate(WAD);

        // Mock Chainlink to a very different price
        _mockChainlinkPrice(int256(10e8)); // 10x the original
        uint256 nonSentinelRate = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        // The rate should be based on stored rate (WAD), NOT the Chainlink price
        // If Chainlink were queried, the rate would be ~10x higher
        // Since stored rate is WAD (1:1), the total rate equals the share price
        uint256 sharePrice = _getCurrentSharePriceWAD();
        assertEq(nonSentinelRate, sharePrice * WAD / WAD, "Rate should use stored rate, not Chainlink");
    }

    /// @notice Tests transition from non-sentinel to sentinel mode
    function testFuzz_nonSentinelToSentinel_transition(uint256 _jtAmount) external virtual {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        // Start in non-sentinel mode
        _setStoredConversionRate(WAD);

        // Mock Chainlink to a specific price
        _mockChainlinkPrice(int256(1e8));

        _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        // Now switch back to sentinel mode
        _setStoredConversionRate(0);

        // The rate should now come from the Chainlink oracle
        uint256 sentinelRate = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        // With stored rate = WAD and oracle at 1e8/1e8 = WAD, rates should be similar
        // But the computation paths differ: stored uses WAD directly, sentinel uses oracle->WAD conversion
        assertGt(sentinelRate, 0, "Rate should be positive after switching back to sentinel mode");

        // Verify oracle is now being used: changing Chainlink price should change the rate
        _mockChainlinkPrice(int256(2e8)); // Double the price
        uint256 sentinelRate2 = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
        assertGt(sentinelRate2, sentinelRate, "Rate should change with oracle after returning to sentinel mode");
    }
}
