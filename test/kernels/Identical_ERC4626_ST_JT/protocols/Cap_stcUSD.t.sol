// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import { IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { DeployScript } from "../../../../script/Deploy.s.sol";
import { FundamentalStablecoinChainlinkOracleDeploymentConfig } from "../../../../script/config/FundamentalStablecoinChainlinkOracleDeploymentConfig.sol";
import { MarketDeploymentConfig } from "../../../../script/config/MarketDeploymentConfig.sol";
import { DeployFundamentalStablecoinChainlinkOracleScript } from "../../../../script/independent/DeployFundamentalStablecoinChainlinkOracle.s.sol";
import { IRoycoFactory } from "../../../../src/interfaces/IRoycoFactory.sol";
import {
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel
} from "../../../../src/kernels/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../../src/libraries/Units.sol";
import { FundamentalStablecoinPeg_ERC4626_ChainlinkOracle_TestBase } from "../base/FundamentalStablecoinPeg_ERC4626_ChainlinkOracle_TestBase.t.sol";

/// @title stcUSD_stcUSD_Test
/// @notice Tests Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel with stcUSD
/// @dev Both ST and JT use stcUSD as the tranche asset on Ethereum mainnet
///
/// stcUSD is an ERC4626 vault where:
///   - Tranche Unit: stcUSD shares
///   - Vault Asset: cUSD (the underlying)
///   - NAV Unit: USD
/// The deployment uses initialConversionRateWAD: 0 (sentinel mode) so the cUSD→USD
/// FundamentalStablecoinChainlinkOracle provides the live rate.
contract stcUSD_stcUSD_Test is FundamentalStablecoinPeg_ERC4626_ChainlinkOracle_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice stcUSD vault on Ethereum mainnet
    address internal constant STCUSD = 0x88887bE419578051FF9F4eb6C858A951921D8888;

    /// @notice cUSD (underlying asset) on Ethereum mainnet
    /// @dev Referenced for documentation; the vault's asset() returns this
    address internal constant CUSD = 0xcCcc62962d17b8914c62D74FfB843d73B2a3cccC;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for stcUSD
    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({
            forkBlock: 24_372_719,
            forkRpcUrlEnvVar: "MAINNET_RPC_URL",
            stAsset: STCUSD,
            jtAsset: STCUSD,
            initialFunding: 1_000_000_000e18 // 1B stcUSD — matches the chainlink-base sizing used by other oracle-backed markets
        });
    }

    /// @notice Returns the Cap fundamental price oracle address from the deployed kernel
    function _getChainlinkOracle() internal view override returns (address) {
        return Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel(address(KERNEL)).getChainlinkOracleConfiguration().oracle;
    }

    /// @notice Returns the staleness threshold for the cUSD→USD oracle (matches MarketDeploymentConfig)
    function _getStalenessThreshold() internal pure override returns (uint48) {
        return 86_400; // 24 hours
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses MarketDeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the stcUSD kernel and market using parameters from MarketDeploymentConfig
    /// @dev Uses the Cap fundamental price oracle from the deployment config for cUSD→USD pricing
    function _deployKernelAndMarket() internal override returns (DeployScript.DeploymentResult memory) {
        MarketDeploymentConfig.MarketConfig memory marketConfig = DEPLOY_SCRIPT.getMarketConfig("stcUSD");

        uint32 scheduledOperationsExpirySeconds = DEPLOY_SCRIPT.getChainConfig(block.chainid).scheduledOperationsExpirySeconds;
        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        DeployFundamentalStablecoinChainlinkOracleScript ORACLE_DEPLOY_SCRIPT = new DeployFundamentalStablecoinChainlinkOracleScript();
        FundamentalStablecoinChainlinkOracleDeploymentConfig.OracleConfig memory oracleConfig =
            ORACLE_DEPLOY_SCRIPT.getOracleConfig(ORACLE_DEPLOY_SCRIPT.MAINNET_CUSD_USD());
        address cUSDOracle = ORACLE_DEPLOY_SCRIPT.deployOracle(oracleConfig.underlyingOracle, oracleConfig.minPegPrice, DEPLOYER.privateKey);

        marketConfig.kernelSpecificParams = abi.encode(
            DeployScript.IdenticalERC4626SharesToChainlinkOracleQuoterKernelParams({
                initialConversionRateWAD: 0, baseAssetToNavAssetOracle: cUSDOracle, stalenessThresholdSeconds: 86_400
            })
        );

        return DEPLOY_SCRIPT.deploy(
            marketConfig, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, scheduledOperationsExpirySeconds, roleAssignments, DEPLOYER.privateKey
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for stcUSD
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e12)); // Tolerance for 18 decimal token
    }

    /// @notice Returns max NAV delta for stcUSD
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // stcUSD-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies that the stcUSD vault is correctly configured
    function test_stcUSD_vaultConfiguration() external view {
        address underlying = IERC4626(STCUSD).asset();
        assertEq(underlying, CUSD, "stcUSD underlying should be cUSD");

        uint8 decimals = IERC4626(STCUSD).decimals();
        assertEq(decimals, 18, "stcUSD should have 18 decimals");

        uint256 sharePrice = IERC4626(STCUSD).convertToAssets(1e18);
        assertGt(sharePrice, 0, "stcUSD share price should be > 0");
    }

    /// @notice Verifies initial conversion rate is sentinel (0) and the oracle provides a positive effective rate
    function test_stcUSD_initialConversionRate() external view {
        uint256 storedRate = _getStoredConversionRate();
        assertEq(storedRate, 0, "Stored rate should be 0 (sentinel mode for live cUSD oracle)");

        uint256 effectiveRate = _kernelCast().getTrancheUnitToNAVUnitConversionRateWAD();
        assertGt(effectiveRate, 0, "Effective conversion rate should be positive from the cUSD oracle");
    }

    /// @notice Test that simulated yield works correctly for stcUSD
    function testFuzz_stcUSD_simulatedYield_increasesNAV(uint256 _amount, uint256 _yieldBps) external {
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

    /// @notice Test loss simulation for stcUSD
    function testFuzz_stcUSD_simulatedLoss_decreasesNAV(uint256 _amount, uint256 _lossBps) external {
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

    /// @notice Overrides the base `testFuzz_chainlinkPrice_yield_distributesToJT` to cap `stAmount`
    ///         at Bob's stcUSD balance. stcUSD has a very low coverage (3%), which makes
    ///         `ST.maxDeposit(BOB)` up to ~32× the seeded JT NAV — routinely exceeding Bob's
    ///         `initialFunding`. The base fuzz does not apply this cap and would revert with
    ///         `ERC20InsufficientBalance` during the ST deposit transfer. Mirrors the capping
    ///         pattern already used in `AbstractKernelTestSuite` (e.g. L194-196, L228-230).
    function testFuzz_chainlinkPrice_yield_distributesToJT(uint256 _jtAmount, uint256 _stPercentage, uint256 _yieldPercentage) public override {
        _jtAmount = bound(_jtAmount, _minDepositAmount(), config.initialFunding / 10);
        _stPercentage = bound(_stPercentage, 10, 50);
        _yieldPercentage = bound(_yieldPercentage, 1, 20);

        _depositJT(ALICE_ADDRESS, _jtAmount);

        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) * _stPercentage / 100;
        // Cap to BOB's available balance (3% coverage lets maxSTDeposit greatly exceed initialFunding)
        uint256 bobBalance = IERC20(config.stAsset).balanceOf(BOB_ADDRESS);
        if (stAmount > bobBalance) stAmount = bobBalance;

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

    /// @notice Test vault share price yield affects NAV
    function testFuzz_stcUSD_vaultSharePriceYield(uint256 _jtAmount, uint256 _yieldPercentage) external {
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
}
