// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDawnKernel } from "../../../interfaces/IRoycoDawnKernel.sol";
import { IRoycoFactory } from "../../../interfaces/factory/IRoycoFactory.sol";
import { Identical_Makina_ST_JT_MachineToAdminOracle_Kernel } from "../../../kernels/Identical_Makina_ST_JT_MachineToAdminOracle_Kernel.sol";
import { COMPONENT_ID_KERNEL_IDENTICAL_MAKINA } from "../Components.sol";
import { DawnDeploymentTemplate } from "./base/DawnDeploymentTemplate.sol";

/// @notice Deployment template for Makina-machine-backed markets.
contract IdenticalMakinaDeploymentTemplate is DawnDeploymentTemplate {
    struct KernelParams {
        address makinaMachine;
        uint256 initialConversionRateWAD;
    }

    constructor(IRoycoFactory _factory) DawnDeploymentTemplate(_factory) { }

    function _kernelComponentId() internal pure override returns (bytes32) {
        return COMPONENT_ID_KERNEL_IDENTICAL_MAKINA;
    }

    function _kernelCtorArgs(IRoycoDawnKernel.RoycoDawnKernelConstructionParams memory _cp, bytes memory _ksp) internal pure override returns (bytes memory) {
        KernelParams memory k = abi.decode(_ksp, (KernelParams));
        return abi.encode(_cp, k.makinaMachine);
    }

    function _kernelInitData(IRoycoDawnKernel.RoycoDawnKernelInitParams memory _kip, bytes memory _ksp) internal pure override returns (bytes memory) {
        KernelParams memory k = abi.decode(_ksp, (KernelParams));
        return abi.encodeCall(Identical_Makina_ST_JT_MachineToAdminOracle_Kernel.initialize, (_kip, k.initialConversionRateWAD));
    }
}
