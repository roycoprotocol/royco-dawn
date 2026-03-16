// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { DeployScript } from "../Deploy.s.sol";

/**
 * @title DeploymentConfig
 * @notice Single configuration contract for all deployment parameters
 */
abstract contract DeploymentConfig {
    // ═══════════════════════════════════════════════════════════════════════════
    // CHAIN IDs
    // ═══════════════════════════════════════════════════════════════════════════

    uint256 internal constant MAINNET = 1;
    uint256 internal constant AVALANCHE = 43_114;
    uint256 internal constant ARBITRUM = 42_161;
    uint256 internal constant BASE = 8453;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONTROLLING MULTISIG ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    address internal constant EXECUTOR_MULTISIG = 0x77777Cc68b333a2256B436D675E8D257699Aa667;
    address internal constant DEPLOYER = 0x77777Cc68b333a2256B436D675E8D257699Aa667;
    address internal constant ROOT_MULTISIG = 0x77777Cc68b333a2256B436D675E8D257699Aa667;
    address internal constant PROTOCOL_FEE_RECIPIENT = 0x77777Cc68b333a2256B436D675E8D257699Aa667;

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET NAMES
    // ═══════════════════════════════════════════════════════════════════════════

    string public constant STCUSD = "stcUSD";
    string public constant SNUSD = "sNUSD";
    string public constant SAVUSD = "savUSD";
    string public constant AUTOUSD = "autoUSD";
    string public constant MFONE = "mF-ONE";
    string public constant PT_CUSD = "PT-cUSD";
    string public constant REUSD = "reUSD";
    string public constant AA_FALCONX_USDC = "AA-FalconXUSDC";
    string public constant ACRED = "ACRED";
    string public constant SMOKEHOUSE_USDC = "SmokehouseUSDC";
    string public constant GAUNTLET_USDC_FRONTIER = "GauntletUSDCFrontier";
    string public constant MAKINA_DUSD = "MakinaDUSD";
    string public constant SUSDAI = "sUSDai";
    string public constant YO_USD = "yoUSD";

    // ═══════════════════════════════════════════════════════════════════════════
    // CHAIN-SPECIFIC CONFIG (defined once per chain)
    // ═══════════════════════════════════════════════════════════════════════════

    struct ChainConfig {
        address factoryAdmin;
        address protocolFeeRecipient;
        address pauserAddress;
        address upgraderAddress;
        address syncRoleAddress;
        address adminKernelAddress;
        address adminAccountantAddress;
        address adminProtocolFeeSetterAddress;
        address adminOracleQuoterAddress;
        address lpRoleAdminAddress;
        address guardianAddress;
        address deployerAddress;
        address deployerAdminAddress;
        uint32 scheduledOperationsExpirySeconds;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET-SPECIFIC CONFIG
    // ═══════════════════════════════════════════════════════════════════════════

    struct MarketDeploymentConfig {
        // Market identification
        string marketName;
        uint256 chainId;
        // Tranche metadata
        string seniorTrancheName;
        string seniorTrancheSymbol;
        string juniorTrancheName;
        string juniorTrancheSymbol;
        // Assets
        address seniorAsset;
        address juniorAsset;
        // Dust tolerances
        uint256 stDustTolerance;
        uint256 jtDustTolerance;
        // Kernel
        DeployScript.KernelType kernelType;
        bytes kernelSpecificParams;
        uint64 stSelfLiquidationBonusWAD;
        bool enforceVaultSharesTransferWhitelist;
        // Accountant
        uint64 stProtocolFeeWAD;
        uint64 jtProtocolFeeWAD;
        uint64 jtYieldShareProtocolFeeWAD;
        uint64 coverageWAD;
        uint96 betaWAD;
        uint256 liquidationUtilizationWAD;
        uint24 fixedTermDurationSeconds;
        // YDM
        DeployScript.YDMType ydmType;
        bytes ydmSpecificParams;
        // Compliance
        address transferAgentAddress;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET CONFIG MAPPING
    // ═══════════════════════════════════════════════════════════════════════════

    mapping(string marketName => MarketDeploymentConfig) internal _marketConfigs;

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error MarketConfigNotFound(string marketName);
    error MarketChainIdMismatch(string marketName, uint256 expectedChainId, uint256 actualChainId);

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor() {
        _initializeMarketConfigs();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CHAIN CONFIG GETTER
    // ═══════════════════════════════════════════════════════════════════════════

    function getChainConfig(uint256) public pure returns (ChainConfig memory) {
        return ChainConfig({
            factoryAdmin: ROOT_MULTISIG,
            protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT,
            pauserAddress: ROOT_MULTISIG,
            upgraderAddress: ROOT_MULTISIG,
            syncRoleAddress: ROOT_MULTISIG,
            adminKernelAddress: ROOT_MULTISIG,
            adminAccountantAddress: ROOT_MULTISIG,
            adminProtocolFeeSetterAddress: ROOT_MULTISIG,
            adminOracleQuoterAddress: ROOT_MULTISIG,
            lpRoleAdminAddress: ROOT_MULTISIG,
            guardianAddress: EXECUTOR_MULTISIG,
            deployerAddress: DEPLOYER,
            deployerAdminAddress: ROOT_MULTISIG,
            scheduledOperationsExpirySeconds: 1 weeks
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET CONFIG GETTER
    // ═══════════════════════════════════════════════════════════════════════════

    function getMarketConfig(string memory marketName) public view returns (MarketDeploymentConfig memory) {
        MarketDeploymentConfig memory config = _marketConfigs[marketName];
        if (bytes(config.marketName).length == 0) {
            revert MarketConfigNotFound(marketName);
        }
        if (config.chainId != block.chainid) {
            revert MarketChainIdMismatch(marketName, config.chainId, block.chainid);
        }
        return config;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET CONFIG INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _initializeMarketConfigs() internal {
        _marketConfigs[STCUSD] = MarketDeploymentConfig({
            marketName: STCUSD,
            chainId: MAINNET,
            seniorTrancheName: _seniorTrancheName(STCUSD),
            seniorTrancheSymbol: _seniorTrancheSymbol(STCUSD),
            juniorTrancheName: _juniorTrancheName(STCUSD),
            juniorTrancheSymbol: _juniorTrancheSymbol(STCUSD),
            seniorAsset: 0x88887bE419578051FF9F4eb6C858A951921D8888,
            juniorAsset: 0x88887bE419578051FF9F4eb6C858A951921D8888,
            stDustTolerance: 5,
            jtDustTolerance: 5,
            kernelType: DeployScript.KernelType.Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel,
            kernelSpecificParams: abi.encode(
                DeployScript.IdenticalERC4626SharesToChainlinkOracleQuoterKernelParams({
                        // Disable the Oracle Leg by setting the initial conversion rate to 1e18
                        initialConversionRateWAD: 1e18,
                        baseAssetToNavAssetOracle: address(1),
                        stalenessThresholdSeconds: 86_400
                    })
            ),
            enforceVaultSharesTransferWhitelist: false,
            stSelfLiquidationBonusWAD: 0.05e18,
            stProtocolFeeWAD: 0.1e18,
            jtProtocolFeeWAD: 0.2e18,
            jtYieldShareProtocolFeeWAD: 0.2e18,
            coverageWAD: 0.1e18,
            betaWAD: 1e18,
            liquidationUtilizationWAD: 1.1111e18,
            fixedTermDurationSeconds: 0, // Market is not expected to have volatility, so no fixed term
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: abi.encode(
                DeployScript.AdaptiveCurveYDM_V2_Params({
                    jtYieldShareAtZeroUtilWAD: 0.05e18,
                    jtYieldShareAtTargetUtilWAD: 0.05e18,
                    jtYieldShareAtFullUtilWAD: 0.4e18,
                    maxAdaptationSpeedWAD: uint64(80e18 / uint256(365 days))
                })
            ),
            transferAgentAddress: address(0)
        });

        _marketConfigs[SNUSD] = MarketDeploymentConfig({
            marketName: SNUSD,
            chainId: MAINNET,
            seniorTrancheName: _seniorTrancheName(SNUSD),
            seniorTrancheSymbol: _seniorTrancheSymbol(SNUSD),
            juniorTrancheName: _juniorTrancheName(SNUSD),
            juniorTrancheSymbol: _juniorTrancheSymbol(SNUSD),
            seniorAsset: 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313,
            juniorAsset: 0x08EFCC2F3e61185D0EA7F8830B3FEc9Bfa2EE313,
            stDustTolerance: 5,
            jtDustTolerance: 5,
            kernelType: DeployScript.KernelType.Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel,
            kernelSpecificParams: abi.encode(
                DeployScript.IdenticalERC4626SharesToChainlinkOracleQuoterKernelParams({
                        // Enable the Oracle Leg by setting the initial conversion rate to the sentinel conversion rate
                        initialConversionRateWAD: 0,
                        // https://app.redstone.finance/app/feeds/ethereum-mainnet/nusd_fundamental/
                        baseAssetToNavAssetOracle: 0x5e7281f74e74D76347f0b8f4a36Fd3cb29c19d95,
                        // Updates to this oracle are pushed every 12 hours, so we set the staleness threshold to 48 hours for safety
                        stalenessThresholdSeconds: 48 hours
                    })
            ),
            enforceVaultSharesTransferWhitelist: false,
            stSelfLiquidationBonusWAD: 0.005e18,
            stProtocolFeeWAD: 0.1e18,
            jtProtocolFeeWAD: 0,
            jtYieldShareProtocolFeeWAD: 0.45e18,
            coverageWAD: 0.1e18,
            betaWAD: 1e18,
            liquidationUtilizationWAD: 1.0009009e18,
            fixedTermDurationSeconds: 0, // Market is not expected to have volatility, so no fixed term
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: abi.encode(
                DeployScript.AdaptiveCurveYDM_V2_Params({
                    jtYieldShareAtZeroUtilWAD: 0.11e18,
                    jtYieldShareAtTargetUtilWAD: 0.11e18,
                    jtYieldShareAtFullUtilWAD: 0.31e18,
                    maxAdaptationSpeedWAD: uint64(50e18 / uint256(365 days))
                })
            ),
            transferAgentAddress: address(0)
        });

        _marketConfigs[SAVUSD] = MarketDeploymentConfig({
            marketName: SAVUSD,
            chainId: AVALANCHE,
            seniorTrancheName: _seniorTrancheName(SAVUSD),
            seniorTrancheSymbol: _seniorTrancheSymbol(SAVUSD),
            juniorTrancheName: _juniorTrancheName(SAVUSD),
            juniorTrancheSymbol: _juniorTrancheSymbol(SAVUSD),
            seniorAsset: 0x06d47F3fb376649c3A9Dafe069B3D6E35572219E,
            juniorAsset: 0x06d47F3fb376649c3A9Dafe069B3D6E35572219E,
            stDustTolerance: 5,
            jtDustTolerance: 5,
            kernelType: DeployScript.KernelType.Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel,
            kernelSpecificParams: abi.encode(
                DeployScript.IdenticalERC4626SharesToChainlinkOracleQuoterKernelParams({
                        // Disable the Oracle Leg by setting the initial conversion rate to 1e18
                        initialConversionRateWAD: 1e18,
                        // Filler oracle address since the Oracle Leg is disabled
                        baseAssetToNavAssetOracle: address(1),
                        // Filler staleness threshold since the Oracle Leg is disabled
                        stalenessThresholdSeconds: 86_400
                    })
            ),
            enforceVaultSharesTransferWhitelist: false,
            stSelfLiquidationBonusWAD: 0.005e18,
            stProtocolFeeWAD: 0.1e18,
            jtProtocolFeeWAD: 0,
            jtYieldShareProtocolFeeWAD: 0.45e18,
            coverageWAD: 0.1e18,
            betaWAD: 1e18,
            liquidationUtilizationWAD: 1.0009009e18,
            fixedTermDurationSeconds: 0, // Market is not expected to have volatility, so no fixed term
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: abi.encode(
                DeployScript.AdaptiveCurveYDM_V2_Params({
                    jtYieldShareAtZeroUtilWAD: 0.11e18,
                    jtYieldShareAtTargetUtilWAD: 0.11e18,
                    jtYieldShareAtFullUtilWAD: 0.31e18,
                    maxAdaptationSpeedWAD: uint64(50e18 / uint256(365 days))
                })
            ),
            transferAgentAddress: address(0)
        });

        _marketConfigs[AUTOUSD] = MarketDeploymentConfig({
            marketName: AUTOUSD,
            chainId: MAINNET,
            seniorTrancheName: _seniorTrancheName(AUTOUSD),
            seniorTrancheSymbol: _seniorTrancheSymbol(AUTOUSD),
            juniorTrancheName: _juniorTrancheName(AUTOUSD),
            juniorTrancheSymbol: _juniorTrancheSymbol(AUTOUSD),
            seniorAsset: 0xa7569A44f348d3D70d8ad5889e50F78E33d80D35,
            juniorAsset: 0xa7569A44f348d3D70d8ad5889e50F78E33d80D35,
            stDustTolerance: 5,
            jtDustTolerance: 5,
            kernelType: DeployScript.KernelType.Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel,
            kernelSpecificParams: abi.encode(
                DeployScript.IdenticalERC4626SharesToChainlinkOracleQuoterKernelParams({
                        // Disable the Oracle Leg by setting the initial conversion rate to 1e18
                        initialConversionRateWAD: 1e18,
                        // Filler oracle address since the Oracle Leg is disabled
                        baseAssetToNavAssetOracle: address(1),
                        // Filler staleness threshold since the Oracle Leg is disabled
                        stalenessThresholdSeconds: 86_400
                    })
            ),
            enforceVaultSharesTransferWhitelist: false,
            stSelfLiquidationBonusWAD: 0,
            stProtocolFeeWAD: 0.1e18,
            jtProtocolFeeWAD: 0,
            jtYieldShareProtocolFeeWAD: 0.45e18,
            coverageWAD: 0.1e18,
            betaWAD: 1e18,
            liquidationUtilizationWAD: 1.225e18,
            fixedTermDurationSeconds: 2 days,
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: abi.encode(
                DeployScript.AdaptiveCurveYDM_V2_Params({
                    jtYieldShareAtZeroUtilWAD: 0.11e18,
                    jtYieldShareAtTargetUtilWAD: 0.11e18,
                    jtYieldShareAtFullUtilWAD: 0.31e18,
                    maxAdaptationSpeedWAD: uint64(75e18 / uint256(365 days))
                })
            ),
            transferAgentAddress: address(0)
        });

        _marketConfigs[MFONE] = MarketDeploymentConfig({
            marketName: MFONE,
            chainId: MAINNET,
            seniorTrancheName: _seniorTrancheName(MFONE),
            seniorTrancheSymbol: _seniorTrancheSymbol(MFONE),
            juniorTrancheName: _juniorTrancheName(MFONE),
            juniorTrancheSymbol: _juniorTrancheSymbol(MFONE),
            seniorAsset: 0x238a700eD6165261Cf8b2e544ba797BC11e466Ba,
            juniorAsset: 0x238a700eD6165261Cf8b2e544ba797BC11e466Ba,
            stDustTolerance: 5,
            jtDustTolerance: 5,
            kernelType: DeployScript.KernelType.Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel,
            kernelSpecificParams: abi.encode(
                DeployScript.IdenticalAssetsChainlinkToAdminOracleQuoterKernelParams({
                        initialConversionRateWAD: 1e18,
                        trancheAssetToReferenceAssetOracle: 0x8D51DBC85cEef637c97D02bdaAbb5E274850e68C,
                        stalenessThresholdSeconds: 1800 // TODO
                    })
            ),
            enforceVaultSharesTransferWhitelist: false,
            stSelfLiquidationBonusWAD: 0.05e18, // TODO
            stProtocolFeeWAD: 0.1e18,
            jtProtocolFeeWAD: 0.2e18,
            jtYieldShareProtocolFeeWAD: 0.2e18, // TODO
            coverageWAD: 0.1e18, // TODO
            betaWAD: 1e18,
            liquidationUtilizationWAD: 1.1111e18, // TODO
            fixedTermDurationSeconds: 2 days, // TODO
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: // TODO
            abi.encode(
                DeployScript.AdaptiveCurveYDM_V2_Params({
                    jtYieldShareAtZeroUtilWAD: 0.05e18,
                    jtYieldShareAtTargetUtilWAD: 0.05e18,
                    jtYieldShareAtFullUtilWAD: 0.4e18,
                    maxAdaptationSpeedWAD: uint64(80e18 / uint256(365 days))
                })
            ),
            transferAgentAddress: address(0)
        });

        _marketConfigs[PT_CUSD] = MarketDeploymentConfig({
            marketName: PT_CUSD,
            chainId: MAINNET,
            seniorTrancheName: _seniorTrancheName(PT_CUSD),
            seniorTrancheSymbol: _seniorTrancheSymbol(PT_CUSD),
            juniorTrancheName: _juniorTrancheName(PT_CUSD),
            juniorTrancheSymbol: _juniorTrancheSymbol(PT_CUSD),
            seniorAsset: 0x545A490f9ab534AdF409A2E682bc4098f49952e3,
            juniorAsset: 0x545A490f9ab534AdF409A2E682bc4098f49952e3,
            stDustTolerance: 5,
            jtDustTolerance: 5,
            kernelType: DeployScript.KernelType.Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel,
            kernelSpecificParams: abi.encode(
                DeployScript.IdenticalAssetsChainlinkToAdminOracleQuoterKernelParams({
                        initialConversionRateWAD: 1e18,
                        trancheAssetToReferenceAssetOracle: 0x6DA10958c691454BE7eb5f3e3B91b5713e542b17,
                        stalenessThresholdSeconds: 1800
                    })
            ),
            enforceVaultSharesTransferWhitelist: false,
            stSelfLiquidationBonusWAD: 0.05e18,
            stProtocolFeeWAD: 0.1e18,
            jtProtocolFeeWAD: 0.1e18,
            jtYieldShareProtocolFeeWAD: 0.1e18,
            coverageWAD: 0.2e18,
            betaWAD: 1e18,
            liquidationUtilizationWAD: 6.6667e18,
            fixedTermDurationSeconds: 2 weeks,
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: abi.encode(
                DeployScript.AdaptiveCurveYDM_V2_Params({
                    jtYieldShareAtZeroUtilWAD: 0.3e18,
                    jtYieldShareAtTargetUtilWAD: 0.3e18,
                    jtYieldShareAtFullUtilWAD: 1e18,
                    maxAdaptationSpeedWAD: uint64(30e18 / uint256(365 days))
                })
            ),
            transferAgentAddress: address(0)
        });

        _marketConfigs[REUSD] = MarketDeploymentConfig({
            marketName: REUSD,
            chainId: MAINNET,
            seniorTrancheName: _seniorTrancheName(REUSD),
            seniorTrancheSymbol: _seniorTrancheSymbol(REUSD),
            juniorTrancheName: _juniorTrancheName(REUSD),
            juniorTrancheSymbol: _juniorTrancheSymbol(REUSD),
            seniorAsset: 0x5086bf358635B81D8C47C66d1C8b9E567Db70c72,
            juniorAsset: 0x5086bf358635B81D8C47C66d1C8b9E567Db70c72,
            stDustTolerance: 5,
            jtDustTolerance: 5,
            kernelType: DeployScript.KernelType.ReUSD_ST_ReUSD_JT,
            enforceVaultSharesTransferWhitelist: false,
            kernelSpecificParams: abi.encode(
                DeployScript.ReUSDSTReUSDJTKernelParams({
                    reusd: 0x5086bf358635B81D8C47C66d1C8b9E567Db70c72,
                    reusdUsdQuoteToken: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
                    insuranceCapitalLayer: 0x4691C475bE804Fa85f91c2D6D0aDf03114de3093
                })
            ),
            stSelfLiquidationBonusWAD: 0.05e18,
            stProtocolFeeWAD: 0.1e18,
            jtProtocolFeeWAD: 0.1e18,
            jtYieldShareProtocolFeeWAD: 0.1e18,
            coverageWAD: 0.2e18,
            betaWAD: 1e18,
            liquidationUtilizationWAD: 6.6667e18,
            fixedTermDurationSeconds: 2 weeks,
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: abi.encode(
                DeployScript.AdaptiveCurveYDM_V2_Params({
                    jtYieldShareAtZeroUtilWAD: 0.3e18,
                    jtYieldShareAtTargetUtilWAD: 0.3e18,
                    jtYieldShareAtFullUtilWAD: 1e18,
                    maxAdaptationSpeedWAD: uint64(30e18 / uint256(365 days))
                })
            ),
            transferAgentAddress: address(0)
        });

        _marketConfigs[AA_FALCONX_USDC] = MarketDeploymentConfig({
            marketName: AA_FALCONX_USDC,
            chainId: MAINNET,
            seniorTrancheName: _seniorTrancheName(AA_FALCONX_USDC),
            seniorTrancheSymbol: _seniorTrancheSymbol(AA_FALCONX_USDC),
            juniorTrancheName: _juniorTrancheName(AA_FALCONX_USDC),
            juniorTrancheSymbol: _juniorTrancheSymbol(AA_FALCONX_USDC),
            seniorAsset: 0xC26A6Fa2C37b38E549a4a1807543801Db684f99C,
            juniorAsset: 0xC26A6Fa2C37b38E549a4a1807543801Db684f99C,
            stDustTolerance: 5 * (10 ** (18 - 6)),
            jtDustTolerance: 5 * (10 ** (18 - 6)),
            kernelType: DeployScript.KernelType.IdleCdoAA_ST_IdleCdoAA_JT,
            kernelSpecificParams: abi.encode(DeployScript.IdleAACdoSTCdoJTKernelParams({ idleCDO: 0x433D5B175148dA32Ffe1e1A37a939E1b7e79be4d })),
            enforceVaultSharesTransferWhitelist: false,
            stSelfLiquidationBonusWAD: 0.05e18,
            stProtocolFeeWAD: 0.1e18,
            jtProtocolFeeWAD: 0.1e18,
            jtYieldShareProtocolFeeWAD: 0.1e18,
            coverageWAD: 0.2e18,
            betaWAD: 1e18,
            liquidationUtilizationWAD: 6.6667e18,
            fixedTermDurationSeconds: 2 weeks,
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: abi.encode(
                DeployScript.AdaptiveCurveYDM_V2_Params({
                    jtYieldShareAtZeroUtilWAD: 0.225e18,
                    jtYieldShareAtTargetUtilWAD: 0.225e18,
                    jtYieldShareAtFullUtilWAD: 1e18,
                    maxAdaptationSpeedWAD: uint64(30e18 / uint256(365 days))
                })
            ),
            transferAgentAddress: address(0)
        });

        _marketConfigs[SMOKEHOUSE_USDC] = MarketDeploymentConfig({
            marketName: SMOKEHOUSE_USDC,
            chainId: MAINNET,
            seniorTrancheName: _seniorTrancheName(SMOKEHOUSE_USDC),
            seniorTrancheSymbol: _seniorTrancheSymbol(SMOKEHOUSE_USDC),
            juniorTrancheName: _juniorTrancheName(SMOKEHOUSE_USDC),
            juniorTrancheSymbol: _juniorTrancheSymbol(SMOKEHOUSE_USDC),
            seniorAsset: 0xBEeFFF209270748ddd194831b3fa287a5386f5bC,
            juniorAsset: 0xBEeFFF209270748ddd194831b3fa287a5386f5bC,
            stDustTolerance: 5 * (10 ** (18 - 6)),
            jtDustTolerance: 5 * (10 ** (18 - 6)),
            kernelType: DeployScript.KernelType.Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel,
            kernelSpecificParams: abi.encode(
                DeployScript.IdenticalERC4626SharesToChainlinkOracleQuoterKernelParams({
                        // Disable the Oracle Leg by setting the initial conversion rate to 1e18
                        initialConversionRateWAD: 1e18,
                        // Filler oracle address since the Oracle Leg is disabled
                        baseAssetToNavAssetOracle: address(1),
                        // Filler staleness threshold since the Oracle Leg is disabled
                        stalenessThresholdSeconds: 86_400
                    })
            ),
            enforceVaultSharesTransferWhitelist: false,
            stSelfLiquidationBonusWAD: 0,
            stProtocolFeeWAD: 0.1e18,
            jtProtocolFeeWAD: 0,
            jtYieldShareProtocolFeeWAD: 0.45e18,
            coverageWAD: 0.07e18,
            betaWAD: 1e18,
            liquidationUtilizationWAD: 1.0013305e18,
            fixedTermDurationSeconds: 0,
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: abi.encode(
                DeployScript.AdaptiveCurveYDM_V2_Params({
                    jtYieldShareAtZeroUtilWAD: 0.08e18,
                    jtYieldShareAtTargetUtilWAD: 0.08e18,
                    jtYieldShareAtFullUtilWAD: 0.21e18,
                    maxAdaptationSpeedWAD: uint64(75e18 / uint256(365 days))
                })
            ),
            transferAgentAddress: address(0)
        });

        _marketConfigs[GAUNTLET_USDC_FRONTIER] = MarketDeploymentConfig({
            marketName: GAUNTLET_USDC_FRONTIER,
            chainId: MAINNET,
            seniorTrancheName: _seniorTrancheName(GAUNTLET_USDC_FRONTIER),
            seniorTrancheSymbol: _seniorTrancheSymbol(GAUNTLET_USDC_FRONTIER),
            juniorTrancheName: _juniorTrancheName(GAUNTLET_USDC_FRONTIER),
            juniorTrancheSymbol: _juniorTrancheSymbol(GAUNTLET_USDC_FRONTIER),
            seniorAsset: 0x9a1D6bd5b8642C41F25e0958129B85f8E1176F3e,
            juniorAsset: 0x9a1D6bd5b8642C41F25e0958129B85f8E1176F3e,
            stDustTolerance: 5 * (10 ** (18 - 6)),
            jtDustTolerance: 5 * (10 ** (18 - 6)),
            kernelType: DeployScript.KernelType.Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel,
            kernelSpecificParams: abi.encode(
                DeployScript.IdenticalERC4626SharesToChainlinkOracleQuoterKernelParams({
                        // Disable the Oracle Leg by setting the initial conversion rate to 1e18
                        initialConversionRateWAD: 1e18,
                        baseAssetToNavAssetOracle: address(1),
                        stalenessThresholdSeconds: 86_400
                    })
            ),
            enforceVaultSharesTransferWhitelist: false,
            stSelfLiquidationBonusWAD: 0.05e18, // TODO
            stProtocolFeeWAD: 0.1e18,
            jtProtocolFeeWAD: 0.2e18,
            jtYieldShareProtocolFeeWAD: 0.2e18, // TODO
            coverageWAD: 0.075e18, // TODO
            betaWAD: 1e18,
            liquidationUtilizationWAD: 1.875e18, // TODO
            fixedTermDurationSeconds: 7 days, // TODO
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: // TODO
            abi.encode(
                DeployScript.AdaptiveCurveYDM_V2_Params({
                    jtYieldShareAtZeroUtilWAD: 0.052e18,
                    jtYieldShareAtTargetUtilWAD: 0.052e18,
                    jtYieldShareAtFullUtilWAD: 0.3e18,
                    maxAdaptationSpeedWAD: uint64(25e18 / uint256(365 days))
                })
            ),
            transferAgentAddress: address(0)
        });

        _marketConfigs[ACRED] = MarketDeploymentConfig({
            marketName: ACRED,
            chainId: MAINNET,
            seniorTrancheName: _seniorTrancheName(ACRED),
            seniorTrancheSymbol: _seniorTrancheSymbol(ACRED),
            juniorTrancheName: _juniorTrancheName(ACRED),
            juniorTrancheSymbol: _juniorTrancheSymbol(ACRED),
            seniorAsset: 0x17418038ecF73BA4026c4f428547BF099706F27B,
            juniorAsset: 0x17418038ecF73BA4026c4f428547BF099706F27B,
            stDustTolerance: 5,
            jtDustTolerance: 5,
            kernelType: DeployScript.KernelType.Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel,
            enforceVaultSharesTransferWhitelist: true,
            kernelSpecificParams: abi.encode(
                DeployScript.IdenticalAssetsChainlinkToAdminOracleQuoterKernelParams({
                    // Set the Reference Asset (USDC) to NAV Unit conversion rate to 1e18
                    initialConversionRateWAD: 1e18,
                    // https://app.redstone.finance/app/feeds/ethereum-mainnet/acred_fundamental/
                    trancheAssetToReferenceAssetOracle: 0xD6BcbbC87bFb6c8964dDc73DC3EaE6d08865d51C,
                    // This oracle is updated semi regularly, approximately once or twice every day. So we set the staleness threshold to 48 hours
                    stalenessThresholdSeconds: 48 hours
                })
            ),
            stSelfLiquidationBonusWAD: 0.01e18,
            // Setting the protocol fee to zero for now since we don't have a KYC-ed protocol fee recipient yet
            stProtocolFeeWAD: 0,
            jtProtocolFeeWAD: 0,
            jtYieldShareProtocolFeeWAD: 0,
            coverageWAD: 0.18e18,
            betaWAD: 1e18,
            liquidationUtilizationWAD: 1.1025e18,
            fixedTermDurationSeconds: 7 days,
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: abi.encode(
                DeployScript.AdaptiveCurveYDM_V2_Params({
                    jtYieldShareAtZeroUtilWAD: 0.22e18,
                    jtYieldShareAtTargetUtilWAD: 0.22e18,
                    jtYieldShareAtFullUtilWAD: 0.59e18,
                    maxAdaptationSpeedWAD: uint64(50e18 / uint256(365 days))
                })
            ),
            // Setting the transfer agent address to the zero address since we don't have a transfer agent yet
            transferAgentAddress: address(0)
        });

        _marketConfigs[MAKINA_DUSD] = MarketDeploymentConfig({
            marketName: MAKINA_DUSD,
            chainId: MAINNET,
            seniorTrancheName: _seniorTrancheName(MAKINA_DUSD),
            seniorTrancheSymbol: _seniorTrancheSymbol(MAKINA_DUSD),
            juniorTrancheName: _juniorTrancheName(MAKINA_DUSD),
            juniorTrancheSymbol: _juniorTrancheSymbol(MAKINA_DUSD),
            seniorAsset: 0x1e33E98aF620F1D563fcD3cfd3C75acE841204ef,
            juniorAsset: 0x1e33E98aF620F1D563fcD3cfd3C75acE841204ef,
            stDustTolerance: 5 * 10 ** 12,
            jtDustTolerance: 5 * 10 ** 12,
            kernelType: DeployScript.KernelType.Identical_Makina_ST_JT_MachineToAdminOracle_Kernel,
            enforceVaultSharesTransferWhitelist: false,
            kernelSpecificParams: abi.encode(
                DeployScript.IdenticalMakinaSTMakinaJTKernelParams({
                    makinaMachine: 0x6b006870C83b1Cd49E766Ac9209f8d68763Df721, initialConversionRateWAD: 1e18
                })
            ),
            stSelfLiquidationBonusWAD: 0.03e18, // TODO
            stProtocolFeeWAD: 0.1e18,
            jtProtocolFeeWAD: 0.2e18,
            jtYieldShareProtocolFeeWAD: 0.2e18, // TODO
            coverageWAD: 0.1e18, // TODO
            betaWAD: 1e18,
            liquidationUtilizationWAD: 1.1111e18, // TODO
            fixedTermDurationSeconds: 2 days, // TODO
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: // TODO
            abi.encode(
                DeployScript.AdaptiveCurveYDM_V2_Params({
                    jtYieldShareAtZeroUtilWAD: 0.07e18,
                    jtYieldShareAtTargetUtilWAD: 0.07e18,
                    jtYieldShareAtFullUtilWAD: 0.45e18,
                    maxAdaptationSpeedWAD: uint64(80e18 / uint256(365 days))
                })
            ),
            transferAgentAddress: address(0)
        });

        _marketConfigs[SUSDAI] = MarketDeploymentConfig({
            marketName: SUSDAI,
            chainId: ARBITRUM,
            seniorTrancheName: _seniorTrancheName(SUSDAI),
            seniorTrancheSymbol: _seniorTrancheSymbol(SUSDAI),
            juniorTrancheName: _juniorTrancheName(SUSDAI),
            juniorTrancheSymbol: _juniorTrancheSymbol(SUSDAI),
            seniorAsset: 0x0B2b2B2076d95dda7817e785989fE353fe955ef9,
            juniorAsset: 0x0B2b2B2076d95dda7817e785989fE353fe955ef9,
            stDustTolerance: 5,
            jtDustTolerance: 5,
            kernelType: DeployScript.KernelType.sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel,
            enforceVaultSharesTransferWhitelist: false,
            kernelSpecificParams: abi.encode(DeployScript.IdenticalAssetsAdminOracleQuoterKernelParams({ initialConversionRateWAD: 1e18 })),
            stSelfLiquidationBonusWAD: 0.01e18,
            stProtocolFeeWAD: 0.1e18,
            jtProtocolFeeWAD: 0,
            jtYieldShareProtocolFeeWAD: 0.45e18,
            coverageWAD: 0.1e18,
            betaWAD: 1e18,
            liquidationUtilizationWAD: 1.1e18,
            fixedTermDurationSeconds: 7 days,
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: abi.encode(
                DeployScript.AdaptiveCurveYDM_V2_Params({
                    jtYieldShareAtZeroUtilWAD: 0.11e18,
                    jtYieldShareAtTargetUtilWAD: 0.11e18,
                    jtYieldShareAtFullUtilWAD: 0.31e18,
                    maxAdaptationSpeedWAD: uint64(50e18 / uint256(365 days))
                })
            ),
            transferAgentAddress: address(0)
        });

        _marketConfigs[YO_USD] = MarketDeploymentConfig({
            marketName: YO_USD,
            chainId: BASE,
            seniorTrancheName: _seniorTrancheName(YO_USD),
            seniorTrancheSymbol: _seniorTrancheSymbol(YO_USD),
            juniorTrancheName: _juniorTrancheName(YO_USD),
            juniorTrancheSymbol: _juniorTrancheSymbol(YO_USD),
            seniorAsset: 0x0000000f2eB9f69274678c76222B35eEc7588a65,
            juniorAsset: 0x0000000f2eB9f69274678c76222B35eEc7588a65,
            stDustTolerance: 5,
            jtDustTolerance: 5,
            kernelType: DeployScript.KernelType.Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel,
            kernelSpecificParams: abi.encode(
                DeployScript.IdenticalERC4626SharesToChainlinkOracleQuoterKernelParams({
                        // Disable the Oracle Leg by setting the initial conversion rate to 1e18
                        initialConversionRateWAD: 1e18,
                        baseAssetToNavAssetOracle: address(1),
                        stalenessThresholdSeconds: 86_400
                    })
            ),
            enforceVaultSharesTransferWhitelist: false,
            stSelfLiquidationBonusWAD: 0.05e18, // TODO
            stProtocolFeeWAD: 0.1e18,
            jtProtocolFeeWAD: 0.2e18,
            jtYieldShareProtocolFeeWAD: 0.2e18, // TODO
            coverageWAD: 0.1e18, // TODO
            betaWAD: 1e18,
            liquidationUtilizationWAD: 1.1111e18, // TODO
            fixedTermDurationSeconds: 2 days, // TODO
            ydmType: DeployScript.YDMType.AdaptiveCurve_V2,
            ydmSpecificParams: // TODO
            abi.encode(
                DeployScript.AdaptiveCurveYDM_V2_Params({
                    jtYieldShareAtZeroUtilWAD: 0.07e18,
                    jtYieldShareAtTargetUtilWAD: 0.07e18,
                    jtYieldShareAtFullUtilWAD: 0.45e18,
                    maxAdaptationSpeedWAD: uint64(80e18 / uint256(365 days))
                })
            ),
            transferAgentAddress: address(0)
        });
    }

    /// @notice Returns the senior tranche name for a given market name
    /// @param marketName The name of the market
    /// @return The senior tranche name
    function _seniorTrancheName(string memory marketName) internal pure returns (string memory) {
        return string(abi.encodePacked("Royco Senior Tranche ", marketName));
    }

    /// @notice Returns the junior tranche name for a given market name
    /// @param marketName The name of the market
    /// @return The junior tranche name
    function _juniorTrancheName(string memory marketName) internal pure returns (string memory) {
        return string(abi.encodePacked("Royco Junior Tranche ", marketName));
    }

    /// @notice Returns the senior tranche symbol for a given market name
    /// @param marketName The name of the market
    /// @return The senior tranche symbol
    function _seniorTrancheSymbol(string memory marketName) internal pure returns (string memory) {
        return string(abi.encodePacked("ROY-ST-", marketName));
    }

    /// @notice Returns the junior tranche symbol for a given market name
    /// @param marketName The name of the market
    /// @return The junior tranche symbol
    function _juniorTrancheSymbol(string memory marketName) internal pure returns (string memory) {
        return string(abi.encodePacked("ROY-JT-", marketName));
    }
}

