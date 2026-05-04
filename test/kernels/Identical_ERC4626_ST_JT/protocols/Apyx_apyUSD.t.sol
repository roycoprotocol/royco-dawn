// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import { IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import { DeployScript } from "../../../../script/Deploy.s.sol";
import { MarketDeploymentConfig } from "../../../../script/config/MarketDeploymentConfig.sol";
import { IRoycoFactory } from "../../../../src/interfaces/IRoycoFactory.sol";
import { IAddressList } from "../../../../src/interfaces/external/apyx/IAddressList.sol";
import { IApyUSD } from "../../../../src/interfaces/external/apyx/IApyUSD.sol";
import {
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel
} from "../../../../src/kernels/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";
import { apyUSD_ST_JT_SharePriceToChainlinkOracle_Kernel } from "../../../../src/kernels/apyUSD_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../../../src/libraries/Units.sol";

import { YieldBearingERC4626_ChainlinkOracle_TestBase } from "../base/YieldBearingERC4626_ChainlinkOracle_TestBase.t.sol";

/// @title apyUSD_apyUSD_Test
/// @notice Tests apyUSD_ST_JT_SharePriceToChainlinkOracle_Kernel with apyUSD
/// @dev Both ST and JT use apyUSD as the tranche asset on Ethereum mainnet
///
/// apyUSD is an ERC4626 vault where:
///   - Tranche Unit: apyUSD shares
///   - Vault Asset: underlying stablecoin
///   - NAV Unit: USD
/// The deployment uses initialConversionRateWAD: 0 (sentinel mode — live Chainlink oracle for the base->NAV leg).
contract apyUSD_apyUSD_Test is YieldBearingERC4626_ChainlinkOracle_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice apyUSD on Ethereum mainnet
    address internal constant APYUSD = 0x38EEb52F0771140d10c4E9A9a72349A329Fe8a6A;

    /// @notice Dummy deny list address used to mock IApyUSD.denyList()
    /// @dev We pick a non-zero address (its code is irrelevant — every call to it is mocked).
    address internal constant MOCK_DENY_LIST = address(uint160(uint256(keccak256("apyUSD.mockDenyList"))));

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for apyUSD
    function getTestConfig() public pure override returns (TestConfig memory) {
        return
            TestConfig({
                forkBlock: 24_836_062,
                forkRpcUrlEnvVar: "MAINNET_RPC_URL",
                stAsset: APYUSD,
                jtAsset: APYUSD,
                initialFunding: 1_000_000e18 // 1M apyUSD
            });
    }

    /// @notice Returns the Chainlink oracle address from the deployed kernel configuration
    function _getChainlinkOracle() internal view override returns (address) {
        return Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel(address(KERNEL)).getChainlinkOracleConfiguration().oracle;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses MarketDeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the apyUSD kernel and market using parameters from MarketDeploymentConfig
    /// @dev Uses the Chainlink oracle from the deployment config for the base-asset->USD leg
    function _deployKernelAndMarket() internal override returns (DeployScript.DeploymentResult memory) {
        MarketDeploymentConfig.MarketConfig memory marketConfig = DEPLOY_SCRIPT.getMarketConfig("apyUSD");

        // The Redstone NUSD/USD-style feed used by apyUSD pushes infrequently. The pinned fork block can
        // therefore be older than the prod 48h staleness threshold; relax it for tests so the inherited
        // suite can read the live oracle without tripping STALE_PRICE.
        marketConfig.kernelSpecificParams = abi.encode(
            DeployScript.IdenticalERC4626SharesToChainlinkOracleQuoterKernelParams({
                initialConversionRateWAD: 0, baseAssetToNavAssetOracle: 0x2037a5Eb67aa9B2FBF50042B724D8c4dB80F23b4, stalenessThresholdSeconds: 365 days
            })
        );

        uint32 scheduledOperationsExpirySeconds = DEPLOY_SCRIPT.getChainConfig(block.chainid).scheduledOperationsExpirySeconds;
        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        return DEPLOY_SCRIPT.deploy(
            marketConfig, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, scheduledOperationsExpirySeconds, roleAssignments, DEPLOYER.privateKey
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for apyUSD (18 decimals)
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e12)); // 0.000001 apyUSD tolerance
    }

    /// @notice Returns max NAV delta for apyUSD
    /// @dev Converts the tranche unit tolerance to NAV using the kernel's conversion
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // apyUSD-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies that the apyUSD vault is correctly configured
    function test_apyUSD_vaultConfiguration() external view {
        uint8 decimals = IERC4626(APYUSD).decimals();
        assertEq(decimals, 18, "apyUSD should have 18 decimals");

        uint256 sharePrice = IERC4626(APYUSD).convertToAssets(1e18);
        assertGt(sharePrice, 0, "apyUSD share price should be > 0");
    }

    /// @notice Verifies initial conversion rate is sentinel (0) for live oracle mode
    function test_apyUSD_initialConversionRate() external view {
        uint256 storedRate = _getStoredConversionRate();

        // The stored rate should be 0 (sentinel) — the live Chainlink oracle provides the base->USD rate
        assertEq(storedRate, 0, "Stored rate should be 0 (sentinel mode for live Chainlink oracle)");

        // The effective conversion rate should be positive (from the Chainlink oracle)
        uint256 effectiveRate = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
        assertGt(effectiveRate, 0, "Effective conversion rate should be positive from Chainlink oracle");
    }

    /// @notice Test that simulated yield works correctly for apyUSD
    function testFuzz_apyUSD_simulatedYield_increasesNAV(uint256 _amount, uint256 _yieldBps) external {
        _amount = bound(_amount, 1e18, 100_000e18); // 1 to 100k apyUSD
        _yieldBps = bound(_yieldBps, 10, 1000); // 0.1% to 10% yield

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        // Simulate yield (randomly picks Leg 1 or Leg 2)
        uint256 yieldWAD = _yieldBps * 1e14;
        simulateJTYield(yieldWAD);

        uint256 rateAfter = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
        assertGt(rateAfter, rateBefore, "Effective rate should increase after yield");

        // Sync accounting
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after yield");
    }

    /// @notice Test loss simulation for apyUSD
    function testFuzz_apyUSD_simulatedLoss_decreasesNAV(uint256 _amount, uint256 _lossBps) external {
        _amount = bound(_amount, 1e18, 100_000e18);
        _lossBps = bound(_lossBps, 10, 500); // 0.1% to 5% loss

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        // Simulate loss (randomly picks Leg 1 or Leg 2)
        uint256 lossWAD = _lossBps * 1e14;
        simulateJTLoss(lossWAD);

        uint256 rateAfter = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
        assertLt(rateAfter, rateBefore, "Effective rate should decrease after loss");

        // Sync accounting
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after loss");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BLACKLIST TESTS (apyUSD-specific)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Mock IApyUSD.denyList() so it returns our fake list address.
    function _mockDenyList(address _list) internal {
        vm.mockCall(APYUSD, abi.encodeWithSelector(IApyUSD.denyList.selector), abi.encode(_list));
    }

    /// @notice Mock IAddressList.contains(account) on the fake list address.
    function _mockBlacklisted(address _account, bool _isBlacklisted) internal {
        vm.mockCall(MOCK_DENY_LIST, abi.encodeWithSelector(IAddressList.contains.selector, _account), abi.encode(_isBlacklisted));
    }

    /// @notice Default-mock the deny list with everyone non-blacklisted, used to ensure unrelated checks pass
    function _setupCleanDenyList() internal {
        _mockDenyList(MOCK_DENY_LIST);
        _mockBlacklisted(ALICE_ADDRESS, false);
        _mockBlacklisted(BOB_ADDRESS, false);
        _mockBlacklisted(CHARLIE_ADDRESS, false);
    }

    /// @notice When apyUSD's deny list is unset (address(0)), the kernel must skip all blacklist checks
    function test_apyUSD_denyListUnset_allowsAll() external {
        // Force denyList() to return the zero address - should early-return inside _preTrancheBalanceUpdate
        _mockDenyList(address(0));

        uint256 amount = _minDepositAmount();

        // Deposit and full redeem should both succeed
        _depositJT(ALICE_ADDRESS, amount);
        uint256 shares = JT.balanceOf(ALICE_ADDRESS);
        assertGt(shares, 0, "Should have received shares");

        vm.prank(ALICE_ADDRESS);
        JT.redeem(shares, ALICE_ADDRESS, ALICE_ADDRESS);
    }

    /// @notice Non-blacklisted accounts can deposit and redeem when the deny list is configured
    function test_apyUSD_nonBlacklistedAccount_canDepositAndRedeem() external {
        _setupCleanDenyList();

        uint256 amount = _minDepositAmount();
        _depositJT(ALICE_ADDRESS, amount);

        uint256 shares = JT.balanceOf(ALICE_ADDRESS);
        assertGt(shares, 0, "Should have received shares");

        vm.prank(ALICE_ADDRESS);
        JT.redeem(shares, ALICE_ADDRESS, ALICE_ADDRESS);
    }

    /// @notice Blacklisted recipient cannot receive deposit shares (mint path)
    function test_apyUSD_blacklistedRecipient_cannotReceiveDepositShares() external {
        _setupCleanDenyList();

        uint256 amount = _minDepositAmount();

        // Mark CHARLIE as blacklisted
        _mockBlacklisted(CHARLIE_ADDRESS, true);

        deal(config.jtAsset, ALICE_ADDRESS, amount);
        vm.startPrank(ALICE_ADDRESS);
        IERC20(config.jtAsset).approve(address(JT), amount);
        vm.expectRevert(abi.encodeWithSelector(apyUSD_ST_JT_SharePriceToChainlinkOracle_Kernel.ACCOUNT_ON_APYUSD_BLACKLIST.selector, CHARLIE_ADDRESS));
        JT.deposit(toTrancheUnits(amount), CHARLIE_ADDRESS);
        vm.stopPrank();
    }

    /// @notice Blacklisted caller cannot deposit even when the recipient is clean
    function test_apyUSD_blacklistedCaller_cannotDeposit() external {
        _setupCleanDenyList();

        uint256 amount = _minDepositAmount();

        // ALICE is blacklisted (caller)
        _mockBlacklisted(ALICE_ADDRESS, true);

        deal(config.jtAsset, ALICE_ADDRESS, amount);
        vm.startPrank(ALICE_ADDRESS);
        IERC20(config.jtAsset).approve(address(JT), amount);
        vm.expectRevert(abi.encodeWithSelector(apyUSD_ST_JT_SharePriceToChainlinkOracle_Kernel.ACCOUNT_ON_APYUSD_BLACKLIST.selector, ALICE_ADDRESS));
        JT.deposit(toTrancheUnits(amount), BOB_ADDRESS);
        vm.stopPrank();
    }

    /// @notice Blacklisted owner (sender) cannot redeem
    function test_apyUSD_blacklistedSender_cannotRedeem() external {
        _setupCleanDenyList();

        uint256 amount = _minDepositAmount();

        // First deposit normally
        _depositJT(ALICE_ADDRESS, amount);
        uint256 shares = JT.balanceOf(ALICE_ADDRESS);

        // Now blacklist ALICE
        _mockBlacklisted(ALICE_ADDRESS, true);

        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(apyUSD_ST_JT_SharePriceToChainlinkOracle_Kernel.ACCOUNT_ON_APYUSD_BLACKLIST.selector, ALICE_ADDRESS));
        JT.redeem(shares, ALICE_ADDRESS, ALICE_ADDRESS);
    }

    /// @notice Blacklisted holder cannot transfer their tranche shares to a clean recipient
    function test_apyUSD_blacklistedSender_cannotTransferShares() external {
        _setupCleanDenyList();

        uint256 amount = _minDepositAmount();

        _depositJT(ALICE_ADDRESS, amount);
        uint256 shares = JT.balanceOf(ALICE_ADDRESS);

        // Now blacklist ALICE
        _mockBlacklisted(ALICE_ADDRESS, true);

        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(apyUSD_ST_JT_SharePriceToChainlinkOracle_Kernel.ACCOUNT_ON_APYUSD_BLACKLIST.selector, ALICE_ADDRESS));
        JT.transfer(BOB_ADDRESS, shares);
    }

    /// @notice Clean holder cannot transfer their tranche shares to a blacklisted recipient
    function test_apyUSD_blacklistedRecipient_cannotReceiveTransferredShares() external {
        _setupCleanDenyList();

        uint256 amount = _minDepositAmount();

        _depositJT(ALICE_ADDRESS, amount);
        uint256 shares = JT.balanceOf(ALICE_ADDRESS);

        // Mark BOB as blacklisted
        _mockBlacklisted(BOB_ADDRESS, true);

        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(apyUSD_ST_JT_SharePriceToChainlinkOracle_Kernel.ACCOUNT_ON_APYUSD_BLACKLIST.selector, BOB_ADDRESS));
        JT.transfer(BOB_ADDRESS, shares);
    }
}
