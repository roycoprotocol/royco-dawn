// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDawnKernel } from "../../../interfaces/IRoycoDawnKernel.sol";
import { IRoycoFactory } from "../../../interfaces/factory/IRoycoFactory.sol";
import { Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_Kernel } from "../../../kernels/Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_Kernel.sol";
import { COMPONENT_ID_KERNEL_IDLECDOAA } from "../Components.sol";
import { DawnDeploymentTemplate } from "./base/DawnDeploymentTemplate.sol";

/// @notice Deployment template for IdleCDO AA-tranche markets.
contract IdleCdoAADeploymentTemplate is DawnDeploymentTemplate {
    struct KernelParams {
        address idleCDO;
    }

    constructor(IRoycoFactory _factory) DawnDeploymentTemplate(_factory) { }

    function _kernelComponentId() internal pure override returns (bytes32) {
        return COMPONENT_ID_KERNEL_IDLECDOAA;
    }

    function _kernelCtorArgs(IRoycoDawnKernel.RoycoDawnKernelConstructionParams memory _cp, bytes memory _ksp) internal pure override returns (bytes memory) {
        KernelParams memory k = abi.decode(_ksp, (KernelParams));
        return abi.encode(_cp, k.idleCDO);
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
        return abi.encodeCall(Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_Kernel.initialize, (_kip));
    }
}
