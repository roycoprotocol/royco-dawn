// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title DeployScript (types-only shim)
 * @notice Backwards-compatibility container holding the enums + param structs that the legacy
 *         `script/Deploy.s.sol` exposed under `DeployScript.X`. The script itself is gone; this
 *         shim keeps the existing per-market config in `MarketDeploymentConfig.sol` parseable
 *         while we migrate consumers to the new template-driven factory.
 *
 *         No runtime behavior — pure type definitions. Equality with old enum positions is
 *         preserved so any deployed-state references that index by `uint256(KernelType)` keep
 *         resolving to the same variant.
 *
 *         New code should NOT reference `DeployScript.*` — use per-template param structs
 *         (e.g. `ReUSDDeploymentTemplate.KernelParams`) instead.
 */
contract DeployScript {
    enum KernelType {
        ReUSD_ST_ReUSD_JT,
        Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel,
        Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel,
        Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel,
        Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel,
        IdleCdoAA_ST_IdleCdoAA_JT,
        Identical_Makina_ST_JT_MachineToAdminOracle_Kernel,
        sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel,
        MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel,
        apyUSD_ST_JT_SharePriceToChainlinkOracle_Kernel,
        Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle_Kernel,
        sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel
    }

    enum YDMType {
        StaticCurve,
        AdaptiveCurve_V1,
        AdaptiveCurve_V2
    }

    struct IdleAACdoSTCdoJTKernelParams {
        address idleCDO;
    }

    struct ReUSDSTReUSDJTKernelParams {
        address reusd;
        address reusdUsdQuoteToken;
        address insuranceCapitalLayer;
    }

    struct IdenticalMakinaSTMakinaJTKernelParams {
        address makinaMachine;
        uint256 initialConversionRateWAD;
    }

    struct IdenticalAssetsChainlinkToAdminOracleQuoterKernelParams {
        uint256 initialConversionRateWAD;
        address trancheAssetToReferenceAssetOracle;
        uint48 stalenessThresholdSeconds;
    }

    struct IdenticalERC4626SharesToAdminOracleQuoterKernelParams {
        uint256 initialConversionRateWAD;
    }

    struct IdenticalERC4626SharesToChainlinkOracleQuoterKernelParams {
        uint256 initialConversionRateWAD;
        address baseAssetToNavAssetOracle;
        uint48 stalenessThresholdSeconds;
    }

    struct IdenticalAssetsAdminOracleQuoterKernelParams {
        uint256 initialConversionRateWAD;
    }

    struct LockedIUSDKernelParams {
        address infiniFiGateway;
        uint32 unwindingEpochs;
        uint256 initialConversionRateWAD;
        address iUSDToNavAssetOracle;
        uint48 stalenessThresholdSeconds;
    }

    struct StaticCurveYDMParams {
        uint64 jtYieldShareAtZeroUtilWAD;
        uint64 jtYieldShareAtTargetUtilWAD;
        uint64 jtYieldShareAtFullUtilWAD;
    }

    struct AdaptiveCurveYDM_V1_Params {
        uint64 jtYieldShareAtTargetUtilWAD;
        uint64 jtYieldShareAtFullUtilWAD;
    }

    struct AdaptiveCurveYDM_V2_Params {
        uint64 jtYieldShareAtZeroUtilWAD;
        uint64 jtYieldShareAtTargetUtilWAD;
        uint64 jtYieldShareAtFullUtilWAD;
        uint64 maxAdaptationSpeedWAD;
    }
}
