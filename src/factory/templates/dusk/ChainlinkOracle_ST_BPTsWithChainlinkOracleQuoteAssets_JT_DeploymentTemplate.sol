// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { GyroECLPPoolFactory } from "../../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/GyroECLPPoolFactory.sol";
import { IRoycoDuskKernel } from "../../../interfaces/IRoycoDuskKernel.sol";
import { IRoycoFactory } from "../../../interfaces/factory/IRoycoFactory.sol";
import {
    ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_Kernel
} from "../../../kernels/dusk/ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_Kernel.sol";
import { COMPONENT_ID_DUSK_KERNEL_CHAINLINK_ST_BPT_CHAINLINK_QUOTE } from "../Components.sol";
import { JuniorAssetsBalancerV3PoolTokensDeploymentTemplate } from "./base/JuniorAssetsBalancerV3PoolTokensDeploymentTemplate.sol";

/**
 * @title ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_DeploymentTemplate
 * @notice Deployment template for the Chainlink-ST / Chainlink-quote-asset Dusk-Balancer kernel.
 * @dev Concrete subclass of `JuniorAssetsBalancerV3PoolTokensDeploymentTemplate`. The senior
 *      side is priced by a single Chainlink oracle directly into NAV units; the junior side is
 *      a BPT pro-rata claim where the quote-asset leg is also priced by a Chainlink oracle.
 */
contract ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_DeploymentTemplate is JuniorAssetsBalancerV3PoolTokensDeploymentTemplate {
    /// @notice Kernel-specific params decoded from `DuskBalancerParams.kernelSpecificParams`.
    struct KernelParams {
        address seniorAssetOracle;
        uint48 seniorAssetStalenessThresholdSeconds;
        address quoteAssetOracle;
        uint48 quoteAssetStalenessThresholdSeconds;
    }

    constructor(
        IRoycoFactory _factory,
        GyroECLPPoolFactory _balancerV3PoolFactory
    )
        JuniorAssetsBalancerV3PoolTokensDeploymentTemplate(_factory, _balancerV3PoolFactory)
    { }

    function _kernelComponentId() internal pure override returns (bytes32) {
        return COMPONENT_ID_DUSK_KERNEL_CHAINLINK_ST_BPT_CHAINLINK_QUOTE;
    }

    function _kernelInitData(
        IRoycoDuskKernel.RoycoDuskKernelInitParams memory _kip,
        bytes memory _kernelSpecificParams
    )
        internal
        pure
        override
        returns (bytes memory)
    {
        KernelParams memory k = abi.decode(_kernelSpecificParams, (KernelParams));
        return abi.encodeCall(
            ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_Kernel.initialize,
            (_kip, k.seniorAssetOracle, k.seniorAssetStalenessThresholdSeconds, k.quoteAssetOracle, k.quoteAssetStalenessThresholdSeconds)
        );
    }
}
