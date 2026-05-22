// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IGyroECLPPool } from "../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/pool-gyro/IGyroECLPPool.sol";
import { IVault } from "../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { GyroECLPPoolFactory } from "../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { RoycoAccountant } from "../../src/accountant/RoycoAccountant.sol";
import { BaseDeploymentTemplate } from "../../src/factory/templates/BaseDeploymentTemplate.sol";
import {
    COMPONENT_ID_ACCOUNTANT_IMPL,
    COMPONENT_ID_DUSK_BALANCER_HOOKS,
    COMPONENT_ID_DUSK_BALANCER_RATE_PROVIDER,
    COMPONENT_ID_DUSK_KERNEL_CHAINLINK_ST_BPT_CHAINLINK_QUOTE,
    COMPONENT_ID_JUNIOR_TRANCHE_IMPL,
    COMPONENT_ID_SENIOR_TRANCHE_IMPL,
    COMPONENT_ID_YDM_ADAPTIVE_CURVE_V2
} from "../../src/factory/templates/Components.sol";
import {
    ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_DeploymentTemplate
} from "../../src/factory/templates/dusk/ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_DeploymentTemplate.sol";
import {
    JuniorAssetsBalancerV3PoolTokensDeploymentTemplate
} from "../../src/factory/templates/dusk/base/JuniorAssetsBalancerV3PoolTokensDeploymentTemplate.sol";
import { IRoycoAccountant } from "../../src/interfaces/IRoycoAccountant.sol";
import { IRoycoDawnKernel } from "../../src/interfaces/IRoycoDawnKernel.sol";
import { IRoycoVaultTranche } from "../../src/interfaces/IRoycoVaultTranche.sol";
import { IYDM } from "../../src/interfaces/IYDM.sol";
import { IRoycoProtocolTemplate } from "../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { RoycoDuskBalancerV3Hooks } from "../../src/kernels/base/quoter/dusk/junior-assets/liquidity-position/balancer-v3/RoycoDuskBalancerV3Hooks.sol";
import { RoycoDuskBalancerV3RateProvider } from "../../src/kernels/base/quoter/dusk/junior-assets/liquidity-position/balancer-v3/RoycoDuskRateProvider.sol";
import {
    ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_Kernel
} from "../../src/kernels/dusk/ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_Kernel.sol";
import { NAV_UNIT } from "../../src/libraries/Units.sol";
import { RoycoJuniorTranche } from "../../src/tranches/RoycoJuniorTranche.sol";
import { RoycoSeniorTranche } from "../../src/tranches/RoycoSeniorTranche.sol";
import { AdaptiveCurveYDM_V2 } from "../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { BaseTest } from "./BaseTest.t.sol";

/**
 * @title DuskBaseTest
 * @notice Dusk-flavored counterpart to `BaseTest`. Adds Ethereum mainnet fork setup with
 *         pinned addresses for the Balancer V3 Gyro E-CLP factory + a default ST/quote asset
 *         pair, plus a `_deployDuskMarket(...)` helper that registers the dusk template (all 7
 *         components) and runs `executeMarketDeployment` end-to-end against the forked chain.
 *
 *         Pure production-parity setup - no mocks. Subclasses pin the fork block (or accept the
 *         default), supply an `ECLP_PARAMS` / `DERIVED_ECLP_PARAMS` pair (default is the
 *         known-good mainnet pool extract from Balancer's own test suite), and call
 *         `_deployDuskMarket(...)`.
 */
abstract contract DuskBaseTest is BaseTest {
    // ─── Ethereum mainnet pinned addresses ──────────────────────────────────────

    /// @dev Gyro E-CLP pool factory on Ethereum mainnet (user-supplied).
    address internal constant ETH_MAINNET_GYRO_ECLP_POOL_FACTORY = 0x04d584195a96DFfc7F8B695aA3C9D3c1606b69d1;

    /// @dev Default ST asset for the test market - Ethena sUSDe (yield-bearing staked USDe).
    address internal constant ETH_MAINNET_SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;

    /// @dev Default quote asset for the test market - native Circle USDC.
    address internal constant ETH_MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @dev Chainlink USDC/USD aggregator on Ethereum mainnet. 8-decimal feed, ~24-hour heartbeat.
    address internal constant ETH_MAINNET_CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    /// @dev Chainlink sUSDe/USD aggregator on Ethereum mainnet.
    /// @notice TODO: verify this exact address against Chainlink's docs - the staleness threshold
    ///         set below assumes a ~24-hour heartbeat. The test will revert with a clear oracle
    ///         error if the address is stale / non-existent at the fork block.
    address internal constant ETH_MAINNET_CHAINLINK_SUSDE_USD = 0xFF3BC18cCBd5999CE63E788A1c250a88626aD099;

    /// @dev Generous staleness window so a recent-but-not-current fork block doesn't trip the
    ///      Chainlink staleness check. 7 days covers heartbeat + occasional deviation-triggered
    ///      updates and is what most Royco production markets currently use.
    uint48 internal constant ORACLE_STALENESS_THRESHOLD_SECONDS = 7 days;

    // ─── Fork configuration ─────────────────────────────────────────────────────

    /// @dev Default fork block. Override via `DUSK_MAINNET_FORK_BLOCK` env var. The default is
    ///      a recent-enough block that the Gyro E-CLP factory + Chainlink feeds are all live.
    ///      Mainnet HEAD at time of test authorship was ~25_150_329.
    uint256 internal constant DEFAULT_FORK_BLOCK = 25_100_000;

    /// @dev Env var name for the RPC URL. Same convention dawn BaseTest uses.
    string internal constant MAINNET_RPC_URL_ENV_VAR = "MAINNET_RPC_URL";

    // ─── ECLP params - mainnet pool 0x2191df821c198600499aa1f0031b1a7514d7a7d9 ──
    //
    // Source: `lib/balancer-v3-monorepo/.../GyroEclpPoolDeployer.sol`. These are the live-on-
    // mainnet ECLP shape parameters Balancer's own test suite uses. Using them here means the
    // test pool's invariant geometry matches a real production pool and `factory.create(...)`
    // accepts the params without hitting any off-chain-derivation-precision checks.

    int256 internal constant ECLP_PARAM_ALPHA = 998_502_246_630_054_917;
    int256 internal constant ECLP_PARAM_BETA = 1_000_200_040_008_001_600;
    int256 internal constant ECLP_PARAM_C = 707_106_781_186_547_524;
    int256 internal constant ECLP_PARAM_S = 707_106_781_186_547_524;
    int256 internal constant ECLP_PARAM_LAMBDA = 4_000_000_000_000_000_000_000;

    int256 internal constant ECLP_DERIVED_TAU_ALPHA_X = -94_861_212_813_096_057_289_512_505_574_275_160_547;
    int256 internal constant ECLP_DERIVED_TAU_ALPHA_Y = 31_644_119_574_235_279_926_451_292_677_567_331_630;
    int256 internal constant ECLP_DERIVED_TAU_BETA_X = 37_142_269_533_113_549_537_591_131_345_643_981_951;
    int256 internal constant ECLP_DERIVED_TAU_BETA_Y = 92_846_388_265_400_743_995_957_747_409_218_517_601;
    int256 internal constant ECLP_DERIVED_U = 66_001_741_173_104_803_338_721_745_994_955_553_010;
    int256 internal constant ECLP_DERIVED_V = 62_245_253_919_818_011_890_633_399_060_291_020_887;
    int256 internal constant ECLP_DERIVED_W = 30_601_134_345_582_732_000_058_913_853_921_008_022;
    int256 internal constant ECLP_DERIVED_Z = -28_859_471_639_991_253_843_240_999_485_797_747_790;
    int256 internal constant ECLP_DERIVED_D_SQ = 99_999_999_999_999_999_886_624_093_342_106_115_200;

    // ─── Deployed deps surfaced to subclasses ───────────────────────────────────

    GyroECLPPoolFactory internal GYRO_ECLP_FACTORY;
    IVault internal BALANCER_V3_VAULT;

    // ═══════════════════════════════════════════════════════════════════════════
    // FORK CONFIG OVERRIDE (so any subclass that doesn't override gets the default)
    // ═══════════════════════════════════════════════════════════════════════════

    function _forkConfiguration() internal virtual override returns (uint256 forkBlock, string memory forkRpcUrl) {
        forkBlock = vm.envOr("DUSK_MAINNET_FORK_BLOCK", DEFAULT_FORK_BLOCK);
        forkRpcUrl = vm.envString(MAINNET_RPC_URL_ENV_VAR);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Inherits `BaseTest._setUpRoyco` (fork + wallets + factory bootstrap) and adds
    ///         the Dusk-specific Balancer V3 pinning. Asserts the factory address has live code
    ///         at the fork block so misconfiguration fails fast with a clear message.
    function _setUpRoyco() internal virtual override {
        super._setUpRoyco();

        require(ETH_MAINNET_GYRO_ECLP_POOL_FACTORY.code.length > 0, "GyroECLPPoolFactory has no code at fork block");
        GYRO_ECLP_FACTORY = GyroECLPPoolFactory(ETH_MAINNET_GYRO_ECLP_POOL_FACTORY);
        BALANCER_V3_VAULT = IVault(address(GYRO_ECLP_FACTORY.getVault()));

        vm.label(address(GYRO_ECLP_FACTORY), "GyroECLPPoolFactory");
        vm.label(address(BALANCER_V3_VAULT), "BalancerV3Vault");
        vm.label(ETH_MAINNET_SUSDE, "sUSDe");
        vm.label(ETH_MAINNET_USDC, "USDC");
        vm.label(ETH_MAINNET_CHAINLINK_SUSDE_USD, "Chainlink_sUSDe_USD");
        vm.label(ETH_MAINNET_CHAINLINK_USDC_USD, "Chainlink_USDC_USD");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET DEPLOYMENT HELPER
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Configuration knobs for the standard Dusk-Balancer market deployment helper.
    /// @dev Mirrors the shape of `BaseTest.DawnDeploymentParams` but is Dusk-specific.
    struct DuskDeploymentParams {
        bytes32 marketId;
        // Senior side
        address stAsset;
        address stAssetChainlinkOracle;
        uint48 stAssetStalenessThresholdSeconds;
        // Junior pool quote-asset side
        address quoteAsset;
        address quoteAssetChainlinkOracle;
        uint48 quoteAssetStalenessThresholdSeconds;
        // Pool geometry
        IGyroECLPPool.EclpParams eclpParams;
        IGyroECLPPool.DerivedEclpParams derivedEclpParams;
        uint256 swapFeePercentage;
        // Accountant tunables (optional overrides; defaults come from BaseTest storage)
        uint64 stProtocolFeeWAD;
        uint64 jtProtocolFeeWAD;
        uint64 yieldShareProtocolFeeWAD;
        uint64 coverageWAD;
        uint96 betaWAD;
        uint256 liquidationUtilizationWAD;
        uint24 fixedTermDurationSeconds;
        NAV_UNIT stNAVDustTolerance;
        NAV_UNIT jtNAVDustTolerance;
        bool enforceVaultSharesTransferWhitelist;
        uint64 stSelfLiquidationBonusWAD;
    }

    /// @notice Deploys + registers a fresh dusk template against `FACTORY` and runs the full
    ///         end-to-end market deployment in a single call.
    function _deployDuskMarket(DuskDeploymentParams memory _p) internal returns (MarketDeployment memory) {
        // 1. Deploy a fresh template instance bound to FACTORY + the pinned Gyro E-CLP factory.
        ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_DeploymentTemplate template =
            new ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_DeploymentTemplate(FACTORY, GYRO_ECLP_FACTORY);

        // 2. Register the template with all 7 components (5 standard + hooks + rate provider).
        _registerDuskTemplate(address(template));

        // 3. Encode the params and ship them through `executeMarketDeployment` as DEPLOYER.
        bytes memory encodedParams = _encodeDuskParams(_p);
        vm.prank(DEPLOYER_ADDRESS);
        IRoycoProtocolTemplate.DeploymentResult memory r = FACTORY.executeMarketDeployment(address(template), encodedParams);

        return MarketDeployment({
            seniorTranche: IRoycoVaultTranche(r.seniorTranche),
            juniorTranche: IRoycoVaultTranche(r.juniorTranche),
            kernel: IRoycoDawnKernel(r.kernel),
            accountant: IRoycoAccountant(r.accountant),
            ydm: IYDM(r.ydm)
        });
    }

    function _registerDuskTemplate(address _template) internal {
        bytes32[] memory ids = new bytes32[](7);
        bytes[] memory codes = new bytes[](7);

        ids[0] = COMPONENT_ID_SENIOR_TRANCHE_IMPL;
        codes[0] = type(RoycoSeniorTranche).creationCode;
        ids[1] = COMPONENT_ID_JUNIOR_TRANCHE_IMPL;
        codes[1] = type(RoycoJuniorTranche).creationCode;
        ids[2] = COMPONENT_ID_ACCOUNTANT_IMPL;
        codes[2] = type(RoycoAccountant).creationCode;
        ids[3] = COMPONENT_ID_YDM_ADAPTIVE_CURVE_V2;
        codes[3] = type(AdaptiveCurveYDM_V2).creationCode;
        ids[4] = COMPONENT_ID_DUSK_KERNEL_CHAINLINK_ST_BPT_CHAINLINK_QUOTE;
        codes[4] = type(ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_Kernel).creationCode;
        ids[5] = COMPONENT_ID_DUSK_BALANCER_HOOKS;
        codes[5] = type(RoycoDuskBalancerV3Hooks).creationCode;
        ids[6] = COMPONENT_ID_DUSK_BALANCER_RATE_PROVIDER;
        codes[6] = type(RoycoDuskBalancerV3RateProvider).creationCode;

        vm.prank(OWNER_ADDRESS);
        FACTORY.registerTemplate(_template, ids, codes);
    }

    function _encodeDuskParams(DuskDeploymentParams memory _p) internal view returns (bytes memory) {
        return abi.encode(
            JuniorAssetsBalancerV3PoolTokensDeploymentTemplate.DuskBalancerParams({
                marketId: _p.marketId,
                st: BaseDeploymentTemplate.SeniorTrancheParams({ name: SENIOR_TRANCHE_NAME, symbol: SENIOR_TRANCHE_SYMBOL, asset: _p.stAsset }),
                jt: JuniorAssetsBalancerV3PoolTokensDeploymentTemplate.BPTJuniorTrancheParams({ name: JUNIOR_TRANCHE_NAME, symbol: JUNIOR_TRANCHE_SYMBOL }),
                accountant: BaseDeploymentTemplate.AccountantParams({
                    stProtocolFeeWAD: _p.stProtocolFeeWAD,
                    jtProtocolFeeWAD: _p.jtProtocolFeeWAD,
                    yieldShareProtocolFeeWAD: _p.yieldShareProtocolFeeWAD,
                    coverageWAD: _p.coverageWAD,
                    betaWAD: _p.betaWAD,
                    liquidationUtilizationWAD: _p.liquidationUtilizationWAD,
                    fixedTermDurationSeconds: _p.fixedTermDurationSeconds,
                    stNAVDustTolerance: _p.stNAVDustTolerance,
                    jtNAVDustTolerance: _p.jtNAVDustTolerance,
                    ydmInitializationData: abi.encodeCall(
                        AdaptiveCurveYDM_V2.initializeYDMForMarket, (uint64(0.06e18), uint64(0.06e18), uint64(0.18e18), uint64(0))
                    )
                }),
                gyroECLPPoolParams: JuniorAssetsBalancerV3PoolTokensDeploymentTemplate.GyroECLPPoolParams({
                    name: string(abi.encodePacked("Royco Dusk BPT - ", vm.toString(_p.marketId))),
                    symbol: "RDUSK-BPT",
                    eclpParams: _p.eclpParams,
                    derivedEclpParams: _p.derivedEclpParams,
                    swapFeePercentage: _p.swapFeePercentage,
                    enableDonation: false,
                    disableUnbalancedLiquidity: false,
                    jtBalancerPoolStShareShouldPayYieldFees: true,
                    jtBalancerPoolQuoteToken: _p.quoteAsset,
                    jtBalancerPoolQuotePaysYieldFees: false
                }),
                ydm: BaseDeploymentTemplate.YDMParams({ componentTag: YDM_COMPONENT_TAG, version: YDM_VERSION }),
                protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT_ADDRESS,
                stSelfLiquidationBonusWAD: _p.stSelfLiquidationBonusWAD,
                kernelSpecificParams: abi.encode(
                    ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_DeploymentTemplate.KernelParams({
                        seniorAssetOracle: _p.stAssetChainlinkOracle,
                        seniorAssetStalenessThresholdSeconds: _p.stAssetStalenessThresholdSeconds,
                        quoteAssetOracle: _p.quoteAssetChainlinkOracle,
                        quoteAssetStalenessThresholdSeconds: _p.quoteAssetStalenessThresholdSeconds
                    })
                ),
                enforceVaultSharesTransferWhitelist: _p.enforceVaultSharesTransferWhitelist
            })
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONVENIENCE: default sUSDe/USDC params for the standard test market
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns a fully-populated `DuskDeploymentParams` struct for the canonical
    ///         sUSDe / USDC mainnet test market: Chainlink USD feeds on both legs, the mainnet-
    ///         extracted ECLP geometry, and the default accountant tunables from BaseTest.
    function _defaultSusdeUsdcParams(bytes32 _marketId) internal view returns (DuskDeploymentParams memory) {
        return DuskDeploymentParams({
            marketId: _marketId,
            stAsset: ETH_MAINNET_SUSDE,
            stAssetChainlinkOracle: ETH_MAINNET_CHAINLINK_SUSDE_USD,
            stAssetStalenessThresholdSeconds: ORACLE_STALENESS_THRESHOLD_SECONDS,
            quoteAsset: ETH_MAINNET_USDC,
            quoteAssetChainlinkOracle: ETH_MAINNET_CHAINLINK_USDC_USD,
            quoteAssetStalenessThresholdSeconds: ORACLE_STALENESS_THRESHOLD_SECONDS,
            eclpParams: IGyroECLPPool.EclpParams({
                alpha: ECLP_PARAM_ALPHA, beta: ECLP_PARAM_BETA, c: ECLP_PARAM_C, s: ECLP_PARAM_S, lambda: ECLP_PARAM_LAMBDA
            }),
            derivedEclpParams: IGyroECLPPool.DerivedEclpParams({
                tauAlpha: IGyroECLPPool.Vector2(ECLP_DERIVED_TAU_ALPHA_X, ECLP_DERIVED_TAU_ALPHA_Y),
                tauBeta: IGyroECLPPool.Vector2(ECLP_DERIVED_TAU_BETA_X, ECLP_DERIVED_TAU_BETA_Y),
                u: ECLP_DERIVED_U,
                v: ECLP_DERIVED_V,
                w: ECLP_DERIVED_W,
                z: ECLP_DERIVED_Z,
                dSq: ECLP_DERIVED_D_SQ
            }),
            swapFeePercentage: 0.001e18, // 10 bps
            stProtocolFeeWAD: ST_PROTOCOL_FEE_WAD,
            jtProtocolFeeWAD: JT_PROTOCOL_FEE_WAD,
            yieldShareProtocolFeeWAD: 0,
            coverageWAD: COVERAGE_WAD,
            betaWAD: BETA_WAD,
            liquidationUtilizationWAD: LIQUIDATION_UTILIZATION_WAD,
            fixedTermDurationSeconds: 0, // perpetual market
            stNAVDustTolerance: DUST_TOLERANCE,
            jtNAVDustTolerance: DUST_TOLERANCE,
            enforceVaultSharesTransferWhitelist: false,
            stSelfLiquidationBonusWAD: 0
        });
    }
}
