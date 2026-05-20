// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDawnKernel } from "../../../interfaces/IRoycoDawnKernel.sol";
import { IRoycoFactory } from "../../../interfaces/factory/IRoycoFactory.sol";
import { Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel } from "../../../kernels/Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel.sol";
import { COMPONENT_ID_KERNEL_IDENTICAL_ERC20_CHAINLINK_SBT } from "../Components.sol";
import { DawnDeploymentTemplate } from "./base/DawnDeploymentTemplate.sol";

/// @notice Deployment template for `Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel` markets.
/// @dev The SBT kernel inherits `initialize` from its non-SBT parent
///      (`Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel`), so init calldata is encoded
///      against the parent's signature.
contract IdenticalERC20ChainlinkSBTDeploymentTemplate is DawnDeploymentTemplate {
    struct KernelParams {
        uint256 initialConversionRateWAD;
        address trancheAssetToReferenceAssetOracle;
        uint48 stalenessThresholdSeconds;
    }

    constructor(IRoycoFactory _factory) DawnDeploymentTemplate(_factory) { }

    function _kernelComponentId() internal pure override returns (bytes32) {
        return COMPONENT_ID_KERNEL_IDENTICAL_ERC20_CHAINLINK_SBT;
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
            Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel.initialize,
            (_kip, k.initialConversionRateWAD, k.trancheAssetToReferenceAssetOracle, k.stalenessThresholdSeconds)
        );
    }
}
