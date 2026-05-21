// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IIdleCDO } from "../../../../src/interfaces/external/idle-finance/IIdleCDO.sol";
import { Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_Kernel } from "../../../../src/kernels/dawn/Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_Kernel.sol";
import { WAD_DECIMALS } from "../../../../src/libraries/Constants.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../../../src/libraries/Units.sol";
import { IdleCdoAA_TestBase } from "../base/IdleCdoAA_TestBase.t.sol";

/// @title ParetoFalconx_Test
/// @notice Tests Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_Kernel with Pareto's Falconx Prime Brokerage Vault
/// @dev Both ST and JT use the AA tranche token as the tranche asset
///
/// Pareto Falconx is an IdleCDO where:
///   - Tranche Unit: AA tranche tokens (18 decimals)
///   - NAV Unit: USD (via virtualPrice from the CDO)
/// The conversion rate is fetched from the IdleCDO virtualPrice function.
contract ParetoFalconx_Test is IdleCdoAA_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev IdleCDO contract address (Pareto Falconx Prime Brokerage Vault)
    address internal constant PARETO_FALCONX_CDO = 0x433D5B175148dA32Ffe1e1A37a939E1b7e79be4d;

    /// @dev AA Tranche token address (the asset for both ST and JT)
    address internal constant AA_TRANCHE_TOKEN = 0xC26A6Fa2C37b38E549a4a1807543801Db684f99C;

    /// @dev Whale address holding AA tranche tokens for funding test accounts
    address internal constant AA_TRANCHE_WHALE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    /// @dev Fork block for mainnet
    uint256 internal constant FORK_BLOCK = 24_187_000;

    /// @dev AA tranche token decimals (18 for Pareto AA tranche)
    uint8 internal constant AA_TRANCHE_DECIMALS = 18;

    /// @dev Scale factor to convert from AA tranche token decimals to WAD precision
    uint256 internal constant SCALE_FACTOR = 10 ** (WAD_DECIMALS - 6);

    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for Pareto Falconx
    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({
            forkBlock: FORK_BLOCK,
            forkRpcUrlEnvVar: "MAINNET_RPC_URL",
            stAsset: AA_TRANCHE_TOKEN,
            jtAsset: AA_TRANCHE_TOKEN,
            initialFunding: 800_000 * (10 ** AA_TRANCHE_DECIMALS)
        });
    }

    /// @inheritdoc IdleCdoAA_TestBase
    function _getIdleCDO() internal pure override returns (address) {
        return PARETO_FALCONX_CDO;
    }

    /// @inheritdoc IdleCdoAA_TestBase
    function _getAATrancheToken() internal pure override returns (address) {
        return AA_TRANCHE_TOKEN;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses MarketDeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the Pareto Falconx kernel + market via the IdleCdoAA template.
    function _deployKernelAndMarket() internal override returns (MarketDeployment memory) {
        AA_TRANCHE = IERC20(AA_TRANCHE_TOKEN);
        CDO = IIdleCDO(PARETO_FALCONX_CDO);

        return _deployMarketFromConfig(DEPLOY_SCRIPT.AA_FALCONX_USDC());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUNDING OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deals ST asset (AA tranche tokens) from whale
    function dealSTAsset(address _to, uint256 _amount) public override {
        vm.prank(AA_TRANCHE_WHALE);
        IERC20(AA_TRANCHE_TOKEN).transfer(_to, _amount);
    }

    /// @notice Deals JT asset (AA tranche tokens) from whale
    function dealJTAsset(address _to, uint256 _amount) public override {
        vm.prank(AA_TRANCHE_WHALE);
        IERC20(AA_TRANCHE_TOKEN).transfer(_to, _amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the maximum delta tolerance for tranche unit comparisons
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(3);
    }

    /// @notice Returns the maximum delta tolerance for NAV comparisons
    function maxNAVDelta() public pure override returns (NAV_UNIT) {
        return toNAVUnits(3 * SCALE_FACTOR);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PARETO FALCONX-SPECIFIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Test that kernel is deployed with correct CDO address
    function test_paretoFalconx_hasCorrectIdleCDOAddress() public view {
        Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_Kernel kernel = Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_Kernel(address(KERNEL));
        assertEq(kernel.IDLE_CDO(), PARETO_FALCONX_CDO, "Kernel should have correct IdleCDO address");
    }

    /// @notice Test that virtual price multiplier is calculated correctly
    function test_paretoFalconx_hasCorrectVirtualPriceMultiplier() public view {
        assertEq(_getVirtualPriceMultiplier(), SCALE_FACTOR, "Virtual price multiplier should match expected scale factor");
    }

    /// @notice Test that ST and JT assets are both the AA tranche token
    function test_paretoFalconx_assetsAreAATranche() public view {
        assertEq(ST.asset(), AA_TRANCHE_TOKEN, "ST asset should be AA tranche token");
        assertEq(JT.asset(), AA_TRANCHE_TOKEN, "JT asset should be AA tranche token");
    }

    /// @notice Test that conversion rate matches IdleCDO virtual price
    function test_paretoFalconx_conversionRateMatchesCDOVirtualPrice() public view {
        uint256 virtualPrice = CDO.virtualPrice(AA_TRANCHE_TOKEN);
        uint256 expectedConversionRateWAD = virtualPrice * _getVirtualPriceMultiplier();

        TRANCHE_UNIT oneUnit = toTrancheUnits(10 ** AA_TRANCHE_DECIMALS);
        NAV_UNIT navUnits = KERNEL.stConvertTrancheUnitsToNAVUnits(oneUnit);

        assertApproxEqRel(toUint256(navUnits), expectedConversionRateWAD, 0.001e18, "Conversion should match CDO virtual price");
    }
}
