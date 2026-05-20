// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDawnKernel } from "../../../interfaces/IRoycoDawnKernel.sol";
import { IRoycoFactory } from "../../../interfaces/factory/IRoycoFactory.sol";
import { Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel } from "../../../kernels/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";
import { COMPONENT_ID_KERNEL_SUSDAT } from "../Components.sol";
import { DawnDeploymentTemplate } from "./base/DawnDeploymentTemplate.sol";

/// @notice Deployment template for `sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel` markets.
/// @dev sUSDat kernel reuses the `Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel` initialize signature.
contract sUSDatDeploymentTemplate is DawnDeploymentTemplate {
    struct KernelParams {
        uint256 initialConversionRateWAD;
        address baseAssetToNavAssetOracle;
        uint48 stalenessThresholdSeconds;
    }

    constructor(IRoycoFactory _factory) DawnDeploymentTemplate(_factory) { }

    function _kernelComponentId() internal pure override returns (bytes32) {
        return COMPONENT_ID_KERNEL_SUSDAT;
    }

    function _kernelCtorArgs(
        IRoycoDawnKernel.RoycoDawnKernelConstructionParams memory _cp,
        bytes memory /* _ksp */
    )
        internal
        pure
        override
        returns (bytes memory)
    {
        return abi.encode(_cp);
    }

    function _kernelInitData(IRoycoDawnKernel.RoycoDawnKernelInitParams memory _kip, bytes memory _ksp) internal pure override returns (bytes memory) {
        KernelParams memory k = abi.decode(_ksp, (KernelParams));
        return abi.encodeCall(
            Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.initialize,
            (_kip, k.initialConversionRateWAD, k.baseAssetToNavAssetOracle, k.stalenessThresholdSeconds)
        );
    }
}
