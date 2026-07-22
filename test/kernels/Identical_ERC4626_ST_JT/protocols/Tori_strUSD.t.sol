// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IAccessControl } from "../../../../lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";
import { IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import { DeployScript } from "../../../../script/Deploy.s.sol";
import { MarketDeploymentConfig } from "../../../../script/config/MarketDeploymentConfig.sol";
import { IRoycoFactory } from "../../../../src/interfaces/IRoycoFactory.sol";
import { AggregatorV3Interface } from "../../../../src/interfaces/external/chainlink/AggregatorV3Interface.sol";
import {
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel
} from "../../../../src/kernels/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../../src/libraries/Units.sol";

import { YieldBearingERC4626_ChainlinkOracle_TestBase } from "../base/YieldBearingERC4626_ChainlinkOracle_TestBase.t.sol";

/// @notice Minimal interface for Tori's StakedTrUSD (Ethena StakedUSDeV2 fork) native mechanics
interface IStakedTrUSD {
    function transferInRewards(uint256 amount) external;
    function reportLoss(uint256 amount) external;
    function getUnvestedAmount() external view returns (uint256);
    function cooldownDuration() external view returns (uint24);
}

/// @title Tori_strUSD_Test
/// @notice Tests Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel with Tori strUSD
/// @dev Both ST and JT use strUSD as the tranche asset on Ethereum mainnet
///
/// strUSD (Staked trUSD, Ethena StakedUSDeV2 fork) is an ERC4626 vault where:
///   - Tranche Unit: strUSD shares (18 decimals)
///   - Vault Asset: trUSD (Tori synthetic dollar, 18 decimals)
///   - NAV Unit: USD (trUSD priced via the RedStone trUSD_FUNDAMENTAL push feed, 8 decimals)
/// The deployment uses initialConversionRateWAD: 0 (sentinel mode — live RedStone oracle).
///
/// Tori-specific properties exercised here:
///   - Yield is admin-pushed via transferInRewards() with 8h linear vesting
///   - Losses CAN pass through on-chain via reportLoss() (burns vault trUSD)
///   - Direct vault withdraw()/redeem() revert while cooldownDuration > 0 (7d live; Dawn never calls
///     them — redemptions transfer the strUSD token itself)
contract Tori_strUSD_Test is YieldBearingERC4626_ChainlinkOracle_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice strUSD on Ethereum mainnet
    address internal constant STRUSD = 0x280839980a7eD0D7717F64125fE241012E5F5815;

    /// @notice trUSD (the vault asset) on Ethereum mainnet
    address internal constant TRUSD = 0xd0580192E98eA6CEB9c7b6191Ed2E27560911697;

    /// @notice RedStone trUSD_FUNDAMENTAL push feed on Ethereum mainnet (8 decimals, 12h heartbeat)
    address internal constant TRUSD_USD_FEED = 0x33c6F75916Db4267e52209A8E6B270b22d983B53;

    /// @notice Tori 3/5 Safe — DEFAULT_ADMIN_ROLE on strUSD (can grant REWARDER_ROLE)
    address internal constant TORI_ADMIN_SAFE = 0x0C6Bbfd2d5666d44bf28580eDEec0263692C8316;

    /// @notice StakedTrUSD role for reward pushes and loss reporting
    bytes32 internal constant REWARDER_ROLE = keccak256("REWARDER_ROLE");

    /// @notice StakedTrUSD linear reward vesting period
    uint256 internal constant VESTING_PERIOD = 8 hours;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for strUSD
    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({
            forkBlock: 25_540_000,
            forkRpcUrlEnvVar: "MAINNET_RPC_URL",
            stAsset: STRUSD,
            jtAsset: STRUSD,
            initialFunding: 10_000_000e18 // 10M strUSD
        });
    }

    /// @notice Returns the Chainlink-compatible oracle address from the deployed kernel configuration
    function _getChainlinkOracle() internal view override returns (address) {
        return Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel(address(KERNEL)).getChainlinkOracleConfiguration().oracle;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses MarketDeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the strUSD kernel and market using parameters from MarketDeploymentConfig
    /// @dev Uses the RedStone trUSD_FUNDAMENTAL feed from the deployment config for trUSD->USD pricing
    function _deployKernelAndMarket() internal override returns (DeployScript.DeploymentResult memory) {
        require(TRUSD_USD_FEED.code.length > 0, "trUSD feed not deployed at fork block");

        MarketDeploymentConfig.MarketConfig memory marketConfig = DEPLOY_SCRIPT.getMarketConfig("strUSD");

        uint32 scheduledOperationsExpirySeconds = DEPLOY_SCRIPT.getChainConfig(block.chainid).scheduledOperationsExpirySeconds;
        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        return DEPLOY_SCRIPT.deploy(
            marketConfig, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, scheduledOperationsExpirySeconds, roleAssignments, DEPLOYER.privateKey
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for strUSD (18 decimals)
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e12)); // 0.000001 strUSD tolerance
    }

    /// @notice Returns max NAV delta for strUSD
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // strUSD-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies that the strUSD vault is correctly configured
    function test_strUSD_vaultConfiguration() external view {
        assertEq(IERC4626(STRUSD).decimals(), 18, "strUSD should have 18 decimals");
        assertEq(IERC4626(STRUSD).asset(), TRUSD, "strUSD asset should be trUSD");

        uint256 sharePrice = IERC4626(STRUSD).convertToAssets(1e18);
        assertGe(sharePrice, 1e18, "strUSD share price should be >= 1:1");
    }

    /// @notice Verifies initial conversion rate is sentinel (0) for live oracle mode
    function test_strUSD_initialConversionRate() external view {
        assertEq(_getStoredConversionRate(), 0, "Stored rate should be 0 (sentinel mode for live RedStone oracle)");

        uint256 effectiveRate = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
        assertGt(effectiveRate, 0, "Effective conversion rate should be positive from RedStone oracle");
    }

    /// @notice Verifies the effective rate equals share price x trUSD/USD feed price (normalized to WAD)
    function test_strUSD_effectiveRate_matchesSharePriceTimesFeed() external view {
        uint256 sharePrice = IERC4626(STRUSD).convertToAssets(1e18); // trUSD per strUSD, 18 dec
        (, int256 answer,,,) = AggregatorV3Interface(TRUSD_USD_FEED).latestRoundData();
        uint8 feedDecimals = AggregatorV3Interface(TRUSD_USD_FEED).decimals();

        uint256 expectedRate = (sharePrice * uint256(answer)) / (10 ** feedDecimals);
        uint256 effectiveRate = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();

        assertApproxEqRel(effectiveRate, expectedRate, 1e12, "Effective rate should equal share price x trUSD/USD");
    }

    /// @notice Native yield path: admin-pushed rewards vest linearly over 8h and raise Dawn NAV
    function test_strUSD_transferInRewards_increasesNAV() external {
        _depositJT(ALICE_ADDRESS, 1_000_000e18);

        // Let the currently active on-chain vesting window fully vest, then checkpoint
        vm.warp(vm.getBlockTimestamp() + VESTING_PERIOD + 1);
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();
        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Grant REWARDER_ROLE to a test rewarder via the real DEFAULT_ADMIN (the Tori Safe)
        address rewarder = makeAddr("TORI_REWARDER");
        vm.prank(TORI_ADMIN_SAFE);
        IAccessControl(STRUSD).grantRole(REWARDER_ROLE, rewarder);

        // Push rewards: 0.1% of current vault assets
        uint256 rewardAmount = IERC4626(STRUSD).totalAssets() / 1000;
        deal(TRUSD, rewarder, rewardAmount);
        vm.startPrank(rewarder);
        IERC20(TRUSD).approve(STRUSD, rewardAmount);
        IStakedTrUSD(STRUSD).transferInRewards(rewardAmount);
        vm.stopPrank();

        // Rewards vest linearly; warp through the full vesting period
        vm.warp(vm.getBlockTimestamp() + VESTING_PERIOD + 1);
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(toUint256(navAfter), toUint256(navBefore), "NAV should increase after rewards vest");
    }

    /// @notice Native loss path: reportLoss burns vault trUSD, dropping the share price and Dawn NAV
    /// @dev This is the key difference vs monotonic staked tokens — strUSD losses pass through on-chain,
    ///      so JT coverage is genuinely triggerable by the asset itself.
    function test_strUSD_reportLoss_decreasesNAV() external {
        _depositJT(ALICE_ADDRESS, 1_000_000e18);

        // Fully vest the active window first so reportLoss burns principal rather than unvested rewards
        vm.warp(vm.getBlockTimestamp() + VESTING_PERIOD + 1);
        assertEq(IStakedTrUSD(STRUSD).getUnvestedAmount(), 0, "vesting window should be exhausted");
        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();
        NAV_UNIT navBefore = JT.totalAssets().nav;

        // Report a 1% loss via a test rewarder granted by the real DEFAULT_ADMIN
        address rewarder = makeAddr("TORI_REWARDER");
        vm.prank(TORI_ADMIN_SAFE);
        IAccessControl(STRUSD).grantRole(REWARDER_ROLE, rewarder);

        uint256 lossAmount = IERC4626(STRUSD).totalAssets() / 100;
        vm.prank(rewarder);
        IStakedTrUSD(STRUSD).reportLoss(lossAmount);

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(toUint256(navAfter), toUint256(navBefore), "NAV should decrease after reportLoss");
    }

    /// @notice Dawn's redemption path (token transfer) works even though the vault's own redeem is
    ///         cooldown-gated
    function test_strUSD_transferWorksWhileVaultRedeemGated() external {
        assertGt(IStakedTrUSD(STRUSD).cooldownDuration(), 0, "cooldown should be active on-chain");

        // Direct vault redemption reverts while cooldown is on
        dealSTAsset(ALICE_ADDRESS, 10e18);
        vm.startPrank(ALICE_ADDRESS);
        vm.expectRevert();
        IERC4626(STRUSD).redeem(1e18, ALICE_ADDRESS, ALICE_ADDRESS);

        // Plain ERC20 transfers (Dawn's redemption mechanism) work fine
        uint256 bobBalanceBefore = IERC20(STRUSD).balanceOf(BOB_ADDRESS);
        IERC20(STRUSD).transfer(BOB_ADDRESS, 1e18);
        vm.stopPrank();
        assertEq(IERC20(STRUSD).balanceOf(BOB_ADDRESS), bobBalanceBefore + 1e18, "transfer should succeed");
    }
}
