// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IAccessManaged } from "../../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";

import { IStakedUSDai } from "../../../../src/interfaces/external/usdai/IStakedUSDai.sol";
import { IUSDai } from "../../../../src/interfaces/external/usdai/IUSDai.sol";
import { IdenticalAssetsAdminOracleQuoter } from "../../../../src/kernels/base/quoter/dawn/base/IdenticalAssetsAdminOracleQuoter.sol";
import { sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel } from "../../../../src/kernels/sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel.sol";
import { WAD } from "../../../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../../../src/libraries/Units.sol";

import { YieldBearingERC4626_TestBase } from "../base/YieldBearingERC4626_TestBase.t.sol";

import { COMPONENT_ID_KERNEL_SUSDAI } from "../../../../src/factory/templates/Components.sol";
import { sUSDaiDeploymentTemplate } from "../../../../src/factory/templates/dawn/sUSDaiDeploymentTemplate.sol";

/// @title Metastreet_sUSDai_Test
/// @notice Tests sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel with Metastreet's sUSDai on Arbitrum
/// @dev Both ST and JT use sUSDai (Staked USDai) as the tranche asset
///
/// sUSDai is a yield-bearing staked token where:
///   - Tranche Unit: sUSDai shares
///   - Accounting Asset: USDai (the underlying stablecoin)
///   - NAV Unit: USD
/// The quoter uses IStakedUSDai.redemptionSharePrice() for share-to-USDai conversion,
/// and an admin-set rate for USDai-to-USD (which is ~1:1 for stablecoins).
contract Metastreet_sUSDai_Test is YieldBearingERC4626_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // ARBITRUM ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice sUSDai on Arbitrum
    address internal constant SUSDAI = 0x0B2b2B2076d95dda7817e785989fE353fe955ef9;

    /// @notice USDai address (fetched from sUSDai.asset() in setUp)
    address internal USDAI;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for sUSDai
    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({
            forkBlock: 438_062_279,
            forkRpcUrlEnvVar: "ARBITRUM_RPC_URL",
            stAsset: SUSDAI,
            jtAsset: SUSDAI,
            initialFunding: 1_000_000_000e18 // 1B sUSDai
        });
    }

    /// @notice Returns the initial USDai->USD conversion rate (in WAD precision)
    /// @dev For USDai (a stablecoin), this is 1:1, so we return WAD (1e18)
    function _getInitialConversionRate() internal pure override returns (uint256) {
        return WAD; // 1:1 USDai to USD
    }

    /// @notice Additional setup to fetch USDai address
    function setUp() public virtual override {
        super.setUp();
        USDAI = IStakedUSDai(SUSDAI).asset();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses MarketDeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the sUSDai kernel and market using parameters from MarketDeploymentConfig
    function _deployKernelAndMarket() internal override returns (MarketDeployment memory) {
        sUSDaiDeploymentTemplate template = new sUSDaiDeploymentTemplate(FACTORY);
        DawnDeploymentParams memory p;
        p.marketId = keccak256("SUSDAI_TEST");
        p.template = address(template);
        p.kernelComponentId = COMPONENT_ID_KERNEL_SUSDAI;
        p.kernelCreationCode = type(sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel).creationCode;
        p.stAsset = config.stAsset;
        p.jtAsset = config.jtAsset;
        p.kernelSpecificParams = abi.encode(sUSDaiDeploymentTemplate.KernelParams({ initialConversionRateWAD: WAD }));
        p.stProtocolFeeWAD = ST_PROTOCOL_FEE_WAD;
        p.jtProtocolFeeWAD = JT_PROTOCOL_FEE_WAD;
        p.yieldShareProtocolFeeWAD = 0;
        p.coverageWAD = COVERAGE_WAD;
        p.betaWAD = BETA_WAD;
        p.liquidationUtilizationWAD = LIQUIDATION_UTILIZATION_WAD;
        p.fixedTermDurationSeconds = FIXED_TERM_DURATION_SECONDS;
        p.stNAVDustTolerance = DUST_TOLERANCE;
        p.jtNAVDustTolerance = DUST_TOLERANCE;
        p.enforceVaultSharesTransferWhitelist = false;
        p.stSelfLiquidationBonusWAD = 0;
        return _deployDawnMarket(p);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SHARE PRICE MOCKING (sUSDai redemptionSharePrice)
    // ═══════════════════════════════════════════════════════════════════════════

    // NOTE: simulateVaultSharePriceYield() and simulateVaultSharePriceLoss() are inherited from
    // YieldBearingERC4626_TestBase and work correctly because they call the overridden internal
    // functions _getCurrentSharePriceWAD() and _mockConvertToAssets() below.

    /// @notice sUSDai uses redemptionSharePrice() which returns WAD-scaled output directly
    /// @dev No need to compute shares to convert - redemptionSharePrice() returns the rate directly
    function _getSharesToConvertToAssets() internal pure override returns (uint256) {
        return WAD; // redemptionSharePrice() returns the price of 1 sUSDai in USDai (WAD-scaled)
    }

    /// @notice Gets the current share price (either mocked or from the actual sUSDai contract)
    /// @return The share price in WAD precision (sUSDai -> USDai rate)
    function _getCurrentSharePriceWAD() internal view override returns (uint256) {
        if (mockedSharePriceWAD != 0) {
            return mockedSharePriceWAD;
        }
        // Get the actual redemption share price from sUSDai
        return IStakedUSDai(SUSDAI).redemptionSharePrice();
    }

    /// @notice Mocks the redemptionSharePrice function on sUSDai
    /// @param _newSharePriceWAD The new share price in WAD precision
    function _mockConvertToAssets(uint256 _newSharePriceWAD) internal override {
        mockedSharePriceWAD = _newSharePriceWAD;

        // Mock redemptionSharePrice on sUSDai
        vm.mockCall(SUSDAI, abi.encodeWithSelector(IStakedUSDai.redemptionSharePrice.selector), abi.encode(_newSharePriceWAD));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for sUSDai (18 decimals)
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(3e12)); // 0.000003 sUSDai tolerance
    }

    /// @notice Returns max NAV delta for sUSDai
    /// @dev Converts the tranche unit tolerance to NAV using the kernel's conversion
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONVERSION RATE OVERRIDES (use sUSDai kernel)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Gets the current conversion rate using the sUSDai kernel's getter (in WAD precision)
    function _getConversionRate() internal view override returns (uint256) {
        return sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel(address(KERNEL)).getStoredConversionRateWAD();
    }

    /// @notice Sets the conversion rate using the sUSDai kernel's setter (in WAD precision)
    /// @dev Requires ADMIN_ORACLE_QUOTER_ROLE, which is granted to ORACLE_QUOTER_ADMIN_ADDRESS
    function _setConversionRate(uint256 _newRateWAD) internal override {
        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel(address(KERNEL)).setConversionRate(_newRateWAD, true);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // sUSDai-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies that sUSDai is correctly configured
    function test_sUSDai_configuration() external view {
        // Verify asset() returns USDai
        address asset = IStakedUSDai(SUSDAI).asset();
        assertTrue(asset != address(0), "sUSDai asset (USDai) should not be zero");

        // Verify the contract has a valid redemption share price
        uint256 sharePrice = IStakedUSDai(SUSDAI).redemptionSharePrice();
        assertGt(sharePrice, 0, "sUSDai redemption share price should be > 0");
    }

    /// @notice Verifies the kernel's USDAI immutable is set correctly
    function test_sUSDai_kernelConfiguration() external view {
        address kernelUsdai = sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel(address(KERNEL)).USDAI();
        assertEq(kernelUsdai, USDAI, "Kernel's USDAI should match expected");
    }

    /// @notice Verifies initial conversion rate is set correctly
    function test_sUSDai_initialConversionRate() external view {
        uint256 storedRate = _getConversionRate();
        assertEq(storedRate, WAD, "Stored rate should be WAD (1:1 for stablecoin)");
    }

    /// @notice Test that simulated yield works correctly for sUSDai
    function testFuzz_sUSDai_simulatedYield_increasesNAV(uint256 _amount, uint256 _yieldBps) external {
        _amount = bound(_amount, _minDepositAmount(), config.initialFunding / 10);
        _yieldBps = bound(_yieldBps, 10, 1000); // 0.1% to 10% yield

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _getConversionRate();

        // Simulate yield by increasing the USDai->USD rate
        uint256 yieldWAD = _yieldBps * 1e14;
        simulateJTYield(yieldWAD);

        uint256 rateAfter = _getConversionRate();
        assertGt(rateAfter, rateBefore, "Rate should increase after yield");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after yield");
    }

    /// @notice Test loss simulation for sUSDai
    function testFuzz_sUSDai_simulatedLoss_decreasesNAV(uint256 _amount, uint256 _lossBps) external {
        _amount = bound(_amount, _minDepositAmount(), config.initialFunding / 10);
        _lossBps = bound(_lossBps, 10, 500); // 0.1% to 5% loss

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _getConversionRate();

        uint256 lossWAD = _lossBps * 1e14;
        simulateJTLoss(lossWAD);

        uint256 rateAfter = _getConversionRate();
        assertLt(rateAfter, rateBefore, "Rate should decrease after loss");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after loss");
    }

    /// @notice Test sUSDai redemption share price yield affects NAV
    function testFuzz_sUSDai_redemptionSharePriceYield(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 1, 20);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        simulateVaultSharePriceYield(_yieldPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after sUSDai redemption share price yield");
    }

    /// @notice Test sUSDai redemption share price loss affects NAV
    function testFuzz_sUSDai_redemptionSharePriceLoss(uint256 _jtAmount, uint256 _lossPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _lossPercentage = bound(_lossPercentage, 1, 20);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        simulateVaultSharePriceLoss(_lossPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after sUSDai redemption share price loss");
    }

    /// @notice Test combined yield: both redemption share price AND stored rate increase
    function testFuzz_sUSDai_combinedYield_bothComponents(uint256 _jtAmount, uint256 _sharePriceYieldBps, uint256 _rateYieldBps) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _sharePriceYieldBps = bound(_sharePriceYieldBps, 10, 500); // 0.1% to 5%
        _rateYieldBps = bound(_rateYieldBps, 10, 500); // 0.1% to 5%

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Apply both yields
        simulateVaultSharePriceYield(_sharePriceYieldBps * 1e14);
        _simulateYield(_rateYieldBps * 1e14);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after combined yield");
    }

    /// @notice Test that getTrancheUnitToNAVUnitConversionRateWAD returns expected value
    function test_sUSDai_conversionRateCalculation() external view {
        uint256 redemptionSharePriceWAD = IStakedUSDai(SUSDAI).redemptionSharePrice();
        uint256 storedRateWAD = _getConversionRate();

        uint256 expectedConversionRate = (redemptionSharePriceWAD * storedRateWAD) / WAD;
        uint256 actualConversionRate = sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel(address(KERNEL)).getTrancheUnitToNAVUnitConversionRateWAD();

        assertEq(actualConversionRate, expectedConversionRate, "Conversion rate should equal redemptionSharePrice * storedRate / WAD");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BLACKLIST TESTS (sUSDai-specific)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that the kernel's USDAI immutable is set from sUSDai.asset()
    function test_sUSDai_blacklistIntegration() external view {
        // Verify kernel has correct USDai address (set from sUSDai.asset() in constructor)
        address kernelUsdai = sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel(address(KERNEL)).USDAI();
        address expectedUsdai = IStakedUSDai(SUSDAI).asset();
        assertEq(kernelUsdai, expectedUsdai, "Kernel's USDAI should equal sUSDai.asset()");
    }

    /// @notice Test that non-blacklisted accounts can deposit and redeem normally
    function test_sUSDai_nonBlacklistedAccount_canDepositAndRedeem() external {
        uint256 amount = _minDepositAmount();

        // Deposit should succeed (ALICE is not blacklisted on the fork)
        _depositJT(ALICE_ADDRESS, amount);

        uint256 shares = JT.balanceOf(ALICE_ADDRESS);
        assertGt(shares, 0, "Should have received shares");

        // Redeem should succeed
        vm.prank(ALICE_ADDRESS);
        JT.redeem(shares, ALICE_ADDRESS, ALICE_ADDRESS);
    }

    /// @notice Test that blacklisted sender cannot redeem (reverts from either kernel or sUSDai)
    /// @dev Both the kernel and sUSDai enforce blacklist checks - either can reject the transaction
    function test_sUSDai_blacklistedSender_cannotRedeem() external {
        uint256 amount = _minDepositAmount();

        // First deposit normally
        _depositJT(ALICE_ADDRESS, amount);
        uint256 shares = JT.balanceOf(ALICE_ADDRESS);

        // Mock ALICE as blacklisted on USDai
        vm.mockCall(USDAI, abi.encodeWithSelector(IUSDai.isBlacklisted.selector, ALICE_ADDRESS), abi.encode(true));

        // Attempt to redeem should revert (either from kernel or sUSDai's own check)
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(); // Any revert is acceptable - blacklist is enforced
        JT.redeem(shares, ALICE_ADDRESS, ALICE_ADDRESS);
    }

    /// @notice Test that blacklisted receiver cannot receive redemption assets
    /// @dev Both the kernel and sUSDai enforce blacklist checks - either can reject the transaction
    function test_sUSDai_blacklistedRedeemReceiver_cannotReceive() external {
        uint256 amount = _minDepositAmount();

        // ALICE deposits normally
        _depositJT(ALICE_ADDRESS, amount);
        uint256 shares = JT.balanceOf(ALICE_ADDRESS);

        // Mock BOB as blacklisted on USDai
        vm.mockCall(USDAI, abi.encodeWithSelector(IUSDai.isBlacklisted.selector, BOB_ADDRESS), abi.encode(true));

        // ALICE tries to redeem to BOB (blacklisted receiver) - should revert
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(); // Any revert is acceptable - blacklist is enforced
        JT.redeem(shares, BOB_ADDRESS, ALICE_ADDRESS);
    }

    /// @notice Test that blacklisted recipient cannot receive deposit shares
    /// @dev Tests the kernel's _preTrancheBalanceUpdate check on mint
    function test_sUSDai_blacklistedRecipient_cannotReceiveShares() external {
        uint256 amount = _minDepositAmount();

        // Mock CHARLIE as blacklisted on USDai
        vm.mockCall(USDAI, abi.encodeWithSelector(IUSDai.isBlacklisted.selector, CHARLIE_ADDRESS), abi.encode(true));

        // Try to deposit to CHARLIE (blacklisted recipient) - should revert
        deal(config.jtAsset, ALICE_ADDRESS, amount);
        vm.startPrank(ALICE_ADDRESS);
        IERC20(config.jtAsset).approve(address(JT), amount);
        vm.expectRevert(); // Kernel's _preTrancheBalanceUpdate should reject blacklisted _to
        JT.deposit(toTrancheUnits(amount), CHARLIE_ADDRESS);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONVERSION RATE PRECISION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that conversion rate uses floor rounding (mulDiv with Floor)
    function test_sUSDai_conversionRate_usesFloorRounding() external {
        // Set up values where floor vs ceil rounding would produce different results
        // redemptionSharePrice = 1.000000000000000001e18 (WAD + 1)
        // storedRate = 1.000000000000000001e18 (WAD + 1)
        // Expected with floor: (WAD+1) * (WAD+1) / WAD = WAD + 2 (floor division truncates)

        uint256 sharePriceWithSmallFraction = WAD + 1;
        uint256 storedRateWithSmallFraction = WAD + 1;

        // Mock the share price
        _mockConvertToAssets(sharePriceWithSmallFraction);

        // Set the stored rate
        _setConversionRate(storedRateWithSmallFraction);

        // Calculate expected with floor: (WAD+1) * (WAD+1) / WAD
        // = (WAD^2 + 2*WAD + 1) / WAD = WAD + 2 + 1/WAD = WAD + 2 (floor truncates the 1/WAD)
        uint256 expectedFloor = (sharePriceWithSmallFraction * storedRateWithSmallFraction) / WAD;

        uint256 actual = sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel(address(KERNEL)).getTrancheUnitToNAVUnitConversionRateWAD();

        assertEq(actual, expectedFloor, "Conversion rate should use floor rounding");
        assertEq(actual, WAD + 2, "Floor should truncate to WAD + 2");
    }

    /// @notice Test conversion rate with large values (no overflow)
    function testFuzz_sUSDai_conversionRate_noOverflow(uint256 _sharePrice, uint256 _storedRate) external {
        // Bound to reasonable values that won't overflow: sqrt(type(uint256).max / WAD) ≈ 1.34e29
        _sharePrice = bound(_sharePrice, WAD / 2, 1e29);
        _storedRate = bound(_storedRate, WAD / 2, 1e29);

        _mockConvertToAssets(_sharePrice);
        _setConversionRate(_storedRate);

        // Should not revert
        uint256 rate = sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel(address(KERNEL)).getTrancheUnitToNAVUnitConversionRateWAD();

        // Verify the calculation is correct
        uint256 expected = (_sharePrice * _storedRate) / WAD;
        assertEq(rate, expected, "Rate should equal sharePrice * storedRate / WAD");
    }

    /// @notice Test that conversion rate components are independent (share price affects rate proportionally)
    function testFuzz_sUSDai_conversionRate_componentsIndependent(uint256 _sharePrice1, uint256 _sharePrice2, uint256 _storedRate) external {
        _sharePrice1 = bound(_sharePrice1, WAD / 2, WAD * 2);
        _sharePrice2 = bound(_sharePrice2, WAD / 2, WAD * 2);
        _storedRate = bound(_storedRate, WAD / 2, WAD * 2);

        // Set stored rate (constant for this test)
        _setConversionRate(_storedRate);

        // Test with first share price
        _mockConvertToAssets(_sharePrice1);
        uint256 rate1 = sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel(address(KERNEL)).getTrancheUnitToNAVUnitConversionRateWAD();

        // Test with second share price
        _mockConvertToAssets(_sharePrice2);
        uint256 rate2 = sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel(address(KERNEL)).getTrancheUnitToNAVUnitConversionRateWAD();

        // Verify formula: rate = sharePrice * storedRate / WAD
        uint256 expectedRate1 = (_sharePrice1 * _storedRate) / WAD;
        uint256 expectedRate2 = (_sharePrice2 * _storedRate) / WAD;
        assertEq(rate1, expectedRate1, "Rate1 should equal sharePrice1 * storedRate / WAD");
        assertEq(rate2, expectedRate2, "Rate2 should equal sharePrice2 * storedRate / WAD");

        // Rates should be monotonic with share prices (allowing for equal due to floor rounding)
        if (_sharePrice1 > _sharePrice2) {
            assertGe(rate1, rate2, "Higher share price should give >= rate");
        } else if (_sharePrice1 < _sharePrice2) {
            assertLe(rate1, rate2, "Lower share price should give <= rate");
        } else {
            assertEq(rate1, rate2, "Equal share prices should give equal rates");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ACCESS CONTROL TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that only authorized role can call setConversionRate
    function test_sUSDai_setConversionRate_onlyAuthorizedRole() external {
        // Unauthorized user should not be able to set rate
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ALICE_ADDRESS));
        sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel(address(KERNEL)).setConversionRate(WAD * 2, true);
    }

    /// @notice Test that authorized role can successfully set conversion rate
    function test_sUSDai_setConversionRate_authorizedRoleSucceeds() external {
        uint256 newRate = WAD * 2;

        // ORACLE_QUOTER_ADMIN_ADDRESS has the required role
        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel(address(KERNEL)).setConversionRate(newRate, true);

        // Verify rate was updated
        assertEq(_getConversionRate(), newRate, "Rate should be updated to new value");
    }

    /// @notice Test that setConversionRate reverts when setting to zero (sentinel value)
    function test_sUSDai_setConversionRate_revertsOnZero() external {
        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IdenticalAssetsAdminOracleQuoter.INVALID_CONVERSION_RATE.selector));
        sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel(address(KERNEL)).setConversionRate(0, true);
    }

    /// @notice Test that setConversionRate updates state correctly
    function testFuzz_sUSDai_setConversionRate_updatesState(uint256 _newRate) external {
        // Rate must be non-zero (sentinel value)
        _newRate = bound(_newRate, 1, type(uint128).max);

        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel(address(KERNEL)).setConversionRate(_newRate, true);

        assertEq(_getConversionRate(), _newRate, "Stored rate should match set value");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test conversion rate with minimum non-zero values
    function test_sUSDai_conversionRate_minimumValues() external {
        // Set minimum valid rate (1 wei)
        _setConversionRate(1);
        _mockConvertToAssets(1);

        // Should not revert, but rate will be very small (1 * 1 / WAD = 0 due to floor)
        uint256 rate = sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel(address(KERNEL)).getTrancheUnitToNAVUnitConversionRateWAD();
        assertEq(rate, 0, "Very small inputs should floor to 0");
    }

    /// @notice Test conversion rate with WAD values (1:1 conversion)
    function test_sUSDai_conversionRate_wadValues() external {
        _setConversionRate(WAD);
        _mockConvertToAssets(WAD);

        uint256 rate = sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel(address(KERNEL)).getTrancheUnitToNAVUnitConversionRateWAD();
        assertEq(rate, WAD, "WAD * WAD / WAD should equal WAD");
    }

    /// @notice Test that getStoredConversionRateWAD returns the admin-set rate
    function test_sUSDai_getStoredConversionRateWAD_returnsAdminSetRate() external {
        uint256 newRate = 1.5e18; // 1.5 WAD

        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel(address(KERNEL)).setConversionRate(newRate, true);

        uint256 storedRate = sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel(address(KERNEL)).getStoredConversionRateWAD();
        assertEq(storedRate, newRate, "getStoredConversionRateWAD should return admin-set rate");
    }
}
