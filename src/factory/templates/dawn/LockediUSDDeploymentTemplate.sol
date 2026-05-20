// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDawnKernel } from "../../../interfaces/IRoycoDawnKernel.sol";
import { IRoycoFactory } from "../../../interfaces/factory/IRoycoFactory.sol";
import { Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle } from "../../../kernels/Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle.sol";
import { COMPONENT_ID_KERNEL_LOCKED_IUSD } from "../Components.sol";
import { DawnDeploymentTemplate } from "./base/DawnDeploymentTemplate.sol";

/// @notice Deployment template for Locked iUSD (exchange-rate → chainlink) markets.
contract LockediUSDDeploymentTemplate is DawnDeploymentTemplate {
    struct KernelParams {
        address infiniFiGateway;
        uint32 unwindingEpochs;
        uint256 initialConversionRateWAD;
        address iUSDToNavAssetOracle;
        uint48 stalenessThresholdSeconds;
    }

    constructor(IRoycoFactory _factory) DawnDeploymentTemplate(_factory) { }

    function _kernelComponentId() internal pure override returns (bytes32) {
        return COMPONENT_ID_KERNEL_LOCKED_IUSD;
    }

    function _kernelCtorArgs(IRoycoDawnKernel.RoycoDawnKernelConstructionParams memory _cp, bytes memory _ksp) internal pure override returns (bytes memory) {
        KernelParams memory k = abi.decode(_ksp, (KernelParams));
        return abi.encode(_cp, k.infiniFiGateway, k.unwindingEpochs);
    }

    function _kernelInitData(IRoycoDawnKernel.RoycoDawnKernelInitParams memory _kip, bytes memory _ksp) internal pure override returns (bytes memory) {
        KernelParams memory k = abi.decode(_ksp, (KernelParams));
        return abi.encodeCall(
            Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle.initialize, (_kip, k.initialConversionRateWAD, k.iUSDToNavAssetOracle, k.stalenessThresholdSeconds)
        );
    }
}
