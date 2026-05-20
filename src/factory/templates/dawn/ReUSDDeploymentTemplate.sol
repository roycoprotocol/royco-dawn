// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDawnKernel } from "../../../interfaces/IRoycoDawnKernel.sol";
import { IRoycoFactory } from "../../../interfaces/factory/IRoycoFactory.sol";
import { ReUSD_ST_JT_ICLOracle_Kernel } from "../../../kernels/ReUSD_ST_JT_ICLOracle_Kernel.sol";
import { COMPONENT_ID_KERNEL_REUSD } from "../Components.sol";
import { DawnDeploymentTemplate } from "./base/DawnDeploymentTemplate.sol";

/// @notice Deployment template for ReUSD markets.
contract ReUSDDeploymentTemplate is DawnDeploymentTemplate {
    /// @notice Kernel-specific params decoded from `DawnParams.kernelSpecificParams`.
    struct KernelParams {
        address reusd;
        address reusdUsdQuoteToken;
        address insuranceCapitalLayer;
    }

    constructor(IRoycoFactory _factory) DawnDeploymentTemplate(_factory) { }

    function _kernelComponentId() internal pure override returns (bytes32) {
        return COMPONENT_ID_KERNEL_REUSD;
    }

    function _kernelCtorArgs(IRoycoDawnKernel.RoycoDawnKernelConstructionParams memory _cp, bytes memory _ksp) internal pure override returns (bytes memory) {
        KernelParams memory k = abi.decode(_ksp, (KernelParams));
        return abi.encode(_cp, k.reusd, k.reusdUsdQuoteToken, k.insuranceCapitalLayer);
    }

    function _kernelInitData(
        IRoycoDawnKernel.RoycoDawnKernelInitParams memory _kip,
        bytes memory /* _ksp */
    )
        internal
        pure
        override
        returns (bytes memory)
    {
        return abi.encodeCall(ReUSD_ST_JT_ICLOracle_Kernel.initialize, (_kip));
    }
}
