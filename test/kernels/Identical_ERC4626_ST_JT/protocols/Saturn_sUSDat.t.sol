// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import { IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import { IStakedUSDat } from "../../../../src/interfaces/external/usdat/IStakedUSDat.sol";
import { sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel } from "../../../../src/kernels/sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";
import { WAD } from "../../../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../../../src/libraries/Units.sol";

import { DisabledChainlinkOracle_ERC4626_TestBase } from "../base/DisabledChainlinkOracle_ERC4626_TestBase.t.sol";

import { COMPONENT_ID_KERNEL_SUSDAT } from "../../../../src/factory/templates/Components.sol";
import { sUSDatDeploymentTemplate } from "../../../../src/factory/templates/dawn/sUSDatDeploymentTemplate.sol";

/// @title Saturn_sUSDat_Test
/// @notice Tests sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel with sUSDat (disabled oracle)
/// @dev Both ST and JT use sUSDat as the tranche asset on Ethereum mainnet
///
/// sUSDat is an ERC4626 staked vault where:
///   - Tranche Unit: sUSDat shares (18 decimals)
///   - NAV Unit: USD
/// The stored conversion rate is 1:1 (WAD), with the Chainlink oracle disabled (address(1)).
/// The kernel enforces sUSDat's own blacklist via IStakedUSDat.isBlacklisted().
contract Saturn_sUSDat_Test is DisabledChainlinkOracle_ERC4626_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice sUSDat on Ethereum mainnet
    address internal constant SUSDAT = 0xD166337499E176bbC38a1FBd113Ab144e5bd2Df7;

    /// @notice USDat (underlying asset of sUSDat), fetched from sUSDat.asset() in setUp
    address internal USDAT;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for sUSDat
    function getTestConfig() public pure override returns (TestConfig memory) {
        return
            TestConfig({
                forkBlock: 24_843_711,
                forkRpcUrlEnvVar: "MAINNET_RPC_URL",
                stAsset: SUSDAT,
                jtAsset: SUSDAT,
                initialFunding: 1_000_000e18 // 1M sUSDat
            });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses MarketDeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the sUSDat kernel and market using parameters from MarketDeploymentConfig
    function _deployKernelAndMarket() internal override returns (MarketDeployment memory) {
        sUSDatDeploymentTemplate template = new sUSDatDeploymentTemplate(FACTORY);
        DawnDeploymentParams memory p;
        p.marketId = keccak256("SUSDAT_TEST");
        p.template = address(template);
        p.kernelComponentId = COMPONENT_ID_KERNEL_SUSDAT;
        p.kernelCreationCode = type(sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel).creationCode;
        p.stAsset = config.stAsset;
        p.jtAsset = config.jtAsset;
        p.kernelSpecificParams = abi.encode(
            sUSDatDeploymentTemplate.KernelParams({ initialConversionRateWAD: WAD, baseAssetToNavAssetOracle: address(1), stalenessThresholdSeconds: 86_400 })
        );
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
    // SETUP
    // ═══════════════════════════════════════════════════════════════════════════

    function setUp() public override {
        super.setUp();
        // Mock convertToAssets with the real share price so that _refreshOraclesAfterWarp()
        // can re-apply the mock after vm.warp(). Without this, sUSDat's internal STRC oracle
        // becomes stale after time warps, causing convertToAssets() to revert with InvalidOraclePrice.
        _mockConvertToAssets(IERC4626(SUSDAT).convertToAssets(_getSharesToConvertToAssets()));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEAL OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Mints sUSDat by depositing USDat through the vault's real deposit flow.
    /// @dev Foundry's deal() on sUSDat corrupts its internal accounting (usdatBalance/strcBalance)
    ///      because sUSDat tracks assets separately from ERC20 balances. Instead, we deal() USDat
    ///      (a plain ERC20) and deposit it into the vault to get sUSDat shares legitimately.
    function dealSTAsset(address _to, uint256 _amount) public override {
        _mintSUSDatViaDeposit(_to, _amount);
    }

    /// @notice Mints sUSDat by depositing USDat through the vault's real deposit flow
    function dealJTAsset(address _to, uint256 _amount) public override {
        _mintSUSDatViaDeposit(_to, _amount);
    }

    /// @notice Deposits USDat into sUSDat vault to mint the requested shares
    function _mintSUSDatViaDeposit(address _to, uint256 _sharesWanted) private {
        if (USDAT == address(0)) {
            USDAT = IERC4626(SUSDAT).asset();
        }
        uint256 assetsNeeded = IERC4626(SUSDAT).previewMint(_sharesWanted) + 1;
        deal(USDAT, address(this), assetsNeeded);
        IERC20(USDAT).approve(SUSDAT, assetsNeeded);
        IERC4626(SUSDAT).mint(_sharesWanted, _to);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for sUSDat (18 decimals)
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e12)); // 0.000001 sUSDat tolerance
    }

    /// @notice Returns max NAV delta for sUSDat
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Mocks sUSDat isBlacklisted to return true for the given account
    function _mockBlacklisted(address _account) internal {
        vm.mockCall(SUSDAT, abi.encodeWithSelector(IStakedUSDat.isBlacklisted.selector, _account), abi.encode(true));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // sUSDat-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies that the sUSDat vault is correctly configured
    function test_sUSDat_vaultConfiguration() external view {
        uint8 decimals = IERC4626(SUSDAT).decimals();
        assertEq(decimals, 18, "sUSDat should have 18 decimals");

        uint256 sharePrice = IERC4626(SUSDAT).convertToAssets(1e18);
        assertGt(sharePrice, 0, "sUSDat share price should be > 0");
    }

    /// @notice Verifies initial stored conversion rate is WAD (1:1 for stablecoin)
    function test_sUSDat_initialConversionRate() external view {
        uint256 storedRate = _getConversionRate();
        assertEq(storedRate, WAD, "Stored rate should be WAD (1:1 for stablecoin)");
    }

    /// @notice Test that simulated yield works correctly for sUSDat
    function testFuzz_sUSDat_simulatedYield_increasesNAV(uint256 _amount, uint256 _yieldBps) external {
        _amount = bound(_amount, 1e18, 100_000e18);
        _yieldBps = bound(_yieldBps, 10, 1000);

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        uint256 yieldWAD = _yieldBps * 1e14;
        simulateJTYield(yieldWAD);

        uint256 rateAfter = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
        assertGt(rateAfter, rateBefore, "Rate should increase after yield");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after yield");
    }

    /// @notice Test loss simulation for sUSDat
    function testFuzz_sUSDat_simulatedLoss_decreasesNAV(uint256 _amount, uint256 _lossBps) external {
        _amount = bound(_amount, 1e18, 100_000e18);
        _lossBps = bound(_lossBps, 10, 500);

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        uint256 lossWAD = _lossBps * 1e14;
        simulateJTLoss(lossWAD);

        uint256 rateAfter = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
        assertLt(rateAfter, rateBefore, "Rate should decrease after loss");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after loss");
    }

    /// @notice Test vault share price yield affects NAV
    function testFuzz_sUSDat_vaultSharePriceYield(uint256 _jtAmount, uint256 _yieldPercentage) external {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _yieldPercentage = bound(_yieldPercentage, 1, 20);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        NAV_UNIT navBefore = JT.totalAssets().nav;

        simulateVaultSharePriceYield(_yieldPercentage * 1e16);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after vault share price yield");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BLACKLIST TESTS (sUSDat-specific)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that non-blacklisted accounts can deposit and redeem normally
    function test_sUSDat_nonBlacklistedAccount_canDepositAndRedeem() external {
        uint256 amount = _minDepositAmount();

        // Deposit should succeed (ALICE is not blacklisted on the fork)
        _depositJT(ALICE_ADDRESS, amount);

        uint256 shares = JT.balanceOf(ALICE_ADDRESS);
        assertGt(shares, 0, "Should have received shares");

        // Redeem should succeed
        vm.prank(ALICE_ADDRESS);
        JT.redeem(shares, ALICE_ADDRESS, ALICE_ADDRESS);
    }

    /// @notice Test that a blacklisted caller cannot deposit into the JT
    function test_sUSDat_blacklistedCaller_cannotDeposit_JT() external {
        uint256 amount = _minDepositAmount();

        // Fund ALICE and mock her as blacklisted on sUSDat
        deal(config.jtAsset, ALICE_ADDRESS, amount);
        _mockBlacklisted(ALICE_ADDRESS);

        vm.startPrank(ALICE_ADDRESS);
        IERC20(config.jtAsset).approve(address(JT), amount);
        vm.expectRevert(abi.encodeWithSelector(sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel.ACCOUNT_ON_STAKED_USDAT_BLACKLIST.selector, ALICE_ADDRESS));
        JT.deposit(toTrancheUnits(amount), ALICE_ADDRESS);
        vm.stopPrank();
    }

    /// @notice Test that a blacklisted caller cannot deposit into the ST
    function test_sUSDat_blacklistedCaller_cannotDeposit_ST() external {
        // First seed JT so ST deposits pass coverage
        _depositJT(ALICE_ADDRESS, _minDepositAmount() * 10);

        uint256 amount = _minDepositAmount();
        // BOB_ADDRESS = ST_BOB_ADDRESS, which has ST_LP_ROLE
        dealSTAsset(BOB_ADDRESS, amount);
        _mockBlacklisted(BOB_ADDRESS);

        vm.startPrank(BOB_ADDRESS);
        IERC20(config.stAsset).approve(address(ST), amount);
        vm.expectRevert(abi.encodeWithSelector(sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel.ACCOUNT_ON_STAKED_USDAT_BLACKLIST.selector, BOB_ADDRESS));
        ST.deposit(toTrancheUnits(amount), BOB_ADDRESS);
        vm.stopPrank();
    }

    /// @notice Test that a blacklisted recipient cannot receive shares on deposit
    function test_sUSDat_blacklistedRecipient_cannotReceiveShares() external {
        uint256 amount = _minDepositAmount();

        // Mock CHARLIE as blacklisted on sUSDat
        _mockBlacklisted(CHARLIE_ADDRESS);

        // ALICE deposits with CHARLIE as receiver — kernel should reject the blacklisted _to
        deal(config.jtAsset, ALICE_ADDRESS, amount);
        vm.startPrank(ALICE_ADDRESS);
        IERC20(config.jtAsset).approve(address(JT), amount);
        vm.expectRevert(abi.encodeWithSelector(sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel.ACCOUNT_ON_STAKED_USDAT_BLACKLIST.selector, CHARLIE_ADDRESS));
        JT.deposit(toTrancheUnits(amount), CHARLIE_ADDRESS);
        vm.stopPrank();
    }

    /// @notice Test that a blacklisted sender cannot redeem
    function test_sUSDat_blacklistedSender_cannotRedeem() external {
        uint256 amount = _minDepositAmount();

        // ALICE deposits normally
        _depositJT(ALICE_ADDRESS, amount);
        uint256 shares = JT.balanceOf(ALICE_ADDRESS);

        // Mock ALICE as blacklisted on sUSDat
        _mockBlacklisted(ALICE_ADDRESS);

        // Attempt to redeem should revert
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel.ACCOUNT_ON_STAKED_USDAT_BLACKLIST.selector, ALICE_ADDRESS));
        JT.redeem(shares, ALICE_ADDRESS, ALICE_ADDRESS);
    }

    /// @notice Test that a blacklisted share owner cannot have shares redeemed on their behalf
    function test_sUSDat_blacklistedOwner_cannotBeRedeemedFrom() external {
        uint256 amount = _minDepositAmount();

        // ALICE deposits normally
        _depositJT(ALICE_ADDRESS, amount);
        uint256 shares = JT.balanceOf(ALICE_ADDRESS);

        // ALICE approves BOB (JT-side) to redeem on her behalf
        vm.prank(ALICE_ADDRESS);
        IERC20(address(JT)).approve(JT_BOB_ADDRESS, shares);

        // Mock ALICE (the share owner / _from) as blacklisted on sUSDat
        _mockBlacklisted(ALICE_ADDRESS);

        // BOB tries to redeem ALICE's shares — should revert because _from (ALICE) is blacklisted
        vm.prank(JT_BOB_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel.ACCOUNT_ON_STAKED_USDAT_BLACKLIST.selector, ALICE_ADDRESS));
        JT.redeem(shares, JT_BOB_ADDRESS, ALICE_ADDRESS);
    }

    /// @notice Test that a blacklisted account cannot transfer tranche shares
    function test_sUSDat_blacklistedAccount_cannotTransferShares() external {
        uint256 amount = _minDepositAmount();

        // ALICE deposits normally
        _depositJT(ALICE_ADDRESS, amount);
        uint256 shares = JT.balanceOf(ALICE_ADDRESS);

        // Mock ALICE as blacklisted on sUSDat
        _mockBlacklisted(ALICE_ADDRESS);

        // Transfer from blacklisted sender should revert
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel.ACCOUNT_ON_STAKED_USDAT_BLACKLIST.selector, ALICE_ADDRESS));
        IERC20(address(JT)).transfer(BOB_ADDRESS, shares);
    }

    /// @notice Test that shares cannot be transferred to a blacklisted recipient
    function test_sUSDat_cannotTransferSharesToBlacklistedRecipient() external {
        uint256 amount = _minDepositAmount();

        // ALICE deposits normally
        _depositJT(ALICE_ADDRESS, amount);
        uint256 shares = JT.balanceOf(ALICE_ADDRESS);

        // Mock BOB as blacklisted on sUSDat
        _mockBlacklisted(BOB_ADDRESS);

        // Transfer to blacklisted recipient should revert
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel.ACCOUNT_ON_STAKED_USDAT_BLACKLIST.selector, BOB_ADDRESS));
        IERC20(address(JT)).transfer(BOB_ADDRESS, shares);
    }

    /// @notice Test that removing blacklist status restores normal operations
    function test_sUSDat_removingBlacklist_restoresAccess() external {
        uint256 amount = _minDepositAmount();

        // Mock ALICE as blacklisted on sUSDat
        _mockBlacklisted(ALICE_ADDRESS);

        // Deposit should fail
        deal(config.jtAsset, ALICE_ADDRESS, amount);
        vm.startPrank(ALICE_ADDRESS);
        IERC20(config.jtAsset).approve(address(JT), amount);
        vm.expectRevert(abi.encodeWithSelector(sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel.ACCOUNT_ON_STAKED_USDAT_BLACKLIST.selector, ALICE_ADDRESS));
        JT.deposit(toTrancheUnits(amount), ALICE_ADDRESS);
        vm.stopPrank();

        // Remove blacklist by mocking isBlacklisted to return false
        vm.mockCall(SUSDAT, abi.encodeWithSelector(IStakedUSDat.isBlacklisted.selector, ALICE_ADDRESS), abi.encode(false));

        // Now deposit should succeed
        vm.startPrank(ALICE_ADDRESS);
        JT.deposit(toTrancheUnits(amount), ALICE_ADDRESS);
        vm.stopPrank();

        assertGt(JT.balanceOf(ALICE_ADDRESS), 0, "Should have received shares after blacklist removal");
    }
}
