// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { DeployScript } from "../../script/Deploy.s.sol";
import { MarketDeploymentConfig } from "../../script/config/MarketDeploymentConfig.sol";
import { IRoycoFactory } from "../../src/interfaces/IRoycoFactory.sol";
import { IInsuranceCapitalLayer } from "../../src/interfaces/external/reUSD/IInsuranceCapitalLayer.sol";
import { ReUSD_ST_JT_ICLOracle_Kernel } from "../../src/kernels/ReUSD_ST_JT_ICLOracle_Kernel.sol";
import { IdenticalAssetsOracleQuoter } from "../../src/kernels/base/quoter/dawn/base/IdenticalAssetsOracleQuoter.sol";
import { WAD, WAD } from "../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../src/libraries/Units.sol";

import { AbstractKernelTestSuite } from "./abstract/AbstractKernelTestSuite.t.sol";

/// @title reUSD_Test
/// @notice Tests ReUSD_ST_JT_ICLOracle_Kernel with reUSD on Ethereum mainnet
/// @dev Both ST and JT use reUSD as the tranche asset
///
/// reUSD is a yield-bearing token where:
///   - Tranche Unit: reUSD tokens
///   - NAV Unit: USD (via USDC quote token)
/// The conversion rate is fetched from the Insurance Capital Layer (ICL).
contract reUSD_Test is AbstractKernelTestSuite {
    // ═══════════════════════════════════════════════════════════════════════════
    // ETHEREUM MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice reUSD on Ethereum mainnet
    address internal constant REUSD = 0x5086bf358635B81D8C47C66d1C8b9E567Db70c72;

    /// @notice Insurance Capital Layer on Ethereum mainnet
    address internal constant ICL = 0x4691C475bE804Fa85f91c2D6D0aDf03114de3093;

    /// @notice USDC on Ethereum mainnet (quote token for ICL)
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE FOR MOCKED ICL
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Tracks the mocked ICL conversion rate
    uint256 internal mockedICLConversionRate;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for reUSD
    function getTestConfig() public pure override returns (TestConfig memory) {
        return
            TestConfig({
                forkBlock: 24_187_000,
                forkRpcUrlEnvVar: "MAINNET_RPC_URL",
                stAsset: REUSD,
                jtAsset: REUSD,
                initialFunding: 1_000_000e18 // 1M reUSD
            });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // NAV MANIPULATION HOOKS IMPLEMENTATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Simulates yield for ST by increasing the ICL conversion rate
    function simulateSTYield(uint256 _percentageWAD) public virtual override {
        _simulateICLYield(_percentageWAD);
    }

    /// @notice Simulates yield for JT by increasing the ICL conversion rate
    function simulateJTYield(uint256 _percentageWAD) public virtual override {
        _simulateICLYield(_percentageWAD);
    }

    /// @notice Simulates loss for ST by decreasing the ICL conversion rate
    function simulateSTLoss(uint256 _percentageWAD) public virtual override {
        _simulateICLLoss(_percentageWAD);
    }

    /// @notice Simulates loss for JT by decreasing the ICL conversion rate
    function simulateJTLoss(uint256 _percentageWAD) public virtual override {
        _simulateICLLoss(_percentageWAD);
    }

    /// @notice Deals ST asset to an address
    function dealSTAsset(address _to, uint256 _amount) public virtual override {
        deal(config.stAsset, _to, _amount);
    }

    /// @notice Deals JT asset to an address
    function dealJTAsset(address _to, uint256 _amount) public virtual override {
        deal(config.jtAsset, _to, _amount);
    }

    /// @notice Returns max tranche unit delta for reUSD (18 decimals)
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e12));
    }

    /// @notice Returns max NAV delta for reUSD
    /// @dev Converts the tranche unit tolerance to NAV using the kernel's conversion
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ICL CONVERSION RATE MANIPULATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Gets the current ICL conversion rate (either mocked or from the actual ICL)
    function _getCurrentICLConversionRate() internal view returns (uint256) {
        if (mockedICLConversionRate != 0) {
            return mockedICLConversionRate;
        }
        return IdenticalAssetsOracleQuoter(address(KERNEL)).getTrancheUnitToNAVUnitConversionRateWAD();
    }

    /// @notice Mocks the convertFromShares function on the ICL
    function _mockICLConversionRate(uint256 _newRateWAD) internal {
        mockedICLConversionRate = _newRateWAD;
        vm.mockCall(ICL, IInsuranceCapitalLayer.convertFromShares.selector, abi.encode(_newRateWAD));
    }

    /// @notice Simulates yield by increasing the ICL conversion rate
    function _simulateICLYield(uint256 _percentageWAD) internal {
        uint256 currentRate = _getCurrentICLConversionRate();
        uint256 newRate = currentRate * (WAD + _percentageWAD) / WAD;
        _mockICLConversionRate(newRate);
    }

    /// @notice Simulates loss by decreasing the ICL conversion rate
    function _simulateICLLoss(uint256 _percentageWAD) internal {
        uint256 currentRate = _getCurrentICLConversionRate();
        uint256 newRate = currentRate * (WAD - _percentageWAD) / WAD;
        _mockICLConversionRate(newRate);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // reUSD-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies that the reUSD token is correctly configured
    function test_reUSD_tokenConfiguration() external view {
        uint8 decimals = IERC20Metadata(REUSD).decimals();
        assertEq(decimals, 18, "reUSD should have 18 decimals");

        string memory name = IERC20Metadata(REUSD).name();
        string memory symbol = IERC20Metadata(REUSD).symbol();
        assertTrue(bytes(name).length > 0, "reUSD should have a name");
        assertTrue(bytes(symbol).length > 0, "reUSD should have a symbol");
    }

    /// @notice Verifies that the ICL is correctly configured
    function test_reUSD_ICLConfiguration() external view {
        uint256 rate = IInsuranceCapitalLayer(ICL).convertFromShares(USDC, WAD);
        assertGt(rate, 0, "ICL should return positive conversion rate");
    }

    /// @notice Verifies initial conversion rate is set correctly (from ICL)
    function test_reUSD_initialConversionRate() external view {
        // The stored rate should be 0 (sentinel) meaning it queries ICL
        uint256 storedRate = ReUSD_ST_JT_ICLOracle_Kernel(address(KERNEL)).getStoredConversionRateWAD();
        assertEq(storedRate, 0, "Stored rate should be 0 (sentinel, queries ICL)");

        // The actual conversion rate should be fetched from ICL
        uint256 conversionRate = ReUSD_ST_JT_ICLOracle_Kernel(address(KERNEL)).getTrancheUnitToNAVUnitConversionRateWAD();
        assertGt(conversionRate, 0, "Conversion rate should be positive");
    }

    /// @notice Test that simulated yield works correctly for reUSD
    function testFuzz_reUSD_simulatedYield_increasesNAV(uint256 _amount, uint256 _yieldBps) external {
        _amount = bound(_amount, 1e18, 100_000e18);
        _yieldBps = bound(_yieldBps, 10, 1000);

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _getCurrentICLConversionRate();

        uint256 yieldWAD = _yieldBps * 1e14;
        _simulateICLYield(yieldWAD);

        uint256 rateAfter = _getCurrentICLConversionRate();
        assertGt(rateAfter, rateBefore, "Rate should increase after yield");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertGt(navAfter, navBefore, "NAV should increase after yield");
    }

    /// @notice Test loss simulation for reUSD
    function testFuzz_reUSD_simulatedLoss_decreasesNAV(uint256 _amount, uint256 _lossBps) external {
        _amount = bound(_amount, 1e18, 100_000e18);
        _lossBps = bound(_lossBps, 10, 500);

        _depositJT(ALICE_ADDRESS, _amount);

        NAV_UNIT navBefore = JT.totalAssets().nav;
        uint256 rateBefore = _getCurrentICLConversionRate();

        uint256 lossWAD = _lossBps * 1e14;
        _simulateICLLoss(lossWAD);

        uint256 rateAfter = _getCurrentICLConversionRate();
        assertLt(rateAfter, rateBefore, "Rate should decrease after loss");

        vm.prank(SYNC_ROLE_ADDRESS);
        KERNEL.syncTrancheAccounting();

        NAV_UNIT navAfter = JT.totalAssets().nav;
        assertLt(navAfter, navBefore, "NAV should decrease after loss");
    }

    /// @notice Tests that admin can set conversion rate override
    function test_setConversionRate_success() external {
        uint256 newRate = 1.05e18;

        vm.prank(ORACLE_QUOTER_ADMIN_ADDRESS);
        ReUSD_ST_JT_ICLOracle_Kernel(address(KERNEL)).setConversionRate(newRate, true);

        uint256 storedRate = ReUSD_ST_JT_ICLOracle_Kernel(address(KERNEL)).getStoredConversionRateWAD();
        assertEq(storedRate, newRate, "Stored rate should match set rate");
    }

    /// @notice Tests that non-admin cannot set conversion rate
    function test_setConversionRate_revertsOnUnauthorized() external {
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert();
        ReUSD_ST_JT_ICLOracle_Kernel(address(KERNEL)).setConversionRate(1e18, true);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the ReUSD kernel and market using parameters from MarketDeploymentConfig
    function _deployKernelAndMarket() internal override returns (DeployScript.DeploymentResult memory) {
        MarketDeploymentConfig.MarketConfig memory marketConfig = DEPLOY_SCRIPT.getMarketConfig("reUSD");

        uint32 scheduledOperationsExpirySeconds = DEPLOY_SCRIPT.getChainConfig(block.chainid).scheduledOperationsExpirySeconds;
        IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments = _generateRoleAssignments();

        return DEPLOY_SCRIPT.deploy(
            marketConfig, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, scheduledOperationsExpirySeconds, roleAssignments, DEPLOYER.privateKey
        );
    }
}
