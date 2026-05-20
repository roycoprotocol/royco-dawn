// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDawnKernel } from "../../../interfaces/IRoycoDawnKernel.sol";
import { IRoycoFactory } from "../../../interfaces/factory/IRoycoFactory.sol";
import { sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel } from "../../../kernels/sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel.sol";
import { COMPONENT_ID_KERNEL_SUSDAI } from "../Components.sol";
import { DawnDeploymentTemplate } from "./base/DawnDeploymentTemplate.sol";

/// @notice Deployment template for sUSDai (redemption-share-price → admin oracle) markets.
contract sUSDaiDeploymentTemplate is DawnDeploymentTemplate {
    struct KernelParams {
        uint256 initialConversionRateWAD;
    }

    constructor(IRoycoFactory _factory) DawnDeploymentTemplate(_factory) { }

    function _kernelComponentId() internal pure override returns (bytes32) {
        return COMPONENT_ID_KERNEL_SUSDAI;
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
        return abi.encodeCall(sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel.initialize, (_kip, k.initialConversionRateWAD));
    }
}
