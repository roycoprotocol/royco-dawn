// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDawnKernel } from "../../../../src/interfaces/IRoycoDawnKernel.sol";
import { sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel } from "../../../../src/kernels/sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel.sol";

import { UpgradeKernelBaseModule } from "./UpgradeKernelBaseModule.sol";

/// @notice Reads the sUSDai-specific immutable + the admin-set conversion rate.
interface ISUSDaiKernel {
    function USDAI() external view returns (address);
    function getStoredConversionRateWAD() external view returns (uint256);
}

/**
 * @title UpgradeSUSDaiKernelModule
 * @notice Module for upgrading `sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel` proxies.
 *
 * @dev Kernel-specific verification:
 *        - `USDAI` immutable address (set in constructor from `IStakedUSDai(ST_ASSET).asset()`)
 *        - Admin-set USDai→USD conversion rate (`getStoredConversionRateWAD()`).
 *
 *      Uses an admin-set oracle (no Chainlink), so no oracle/staleness fields are tracked.
 */
contract UpgradeSUSDaiKernelModule is UpgradeKernelBaseModule {
    error UpgradeSUSDaiKernelModule__UsdaiChanged(address expected, address actual);
    error UpgradeSUSDaiKernelModule__StoredConversionRateChanged(uint256 expected, uint256 actual);

    function _kernelContractName() internal pure override returns (string memory) {
        return "sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel";
    }

    function _kernelCreationCodeWith(IRoycoDawnKernel.RoycoDawnKernelConstructionParams memory cp) internal pure override returns (bytes memory) {
        return abi.encodePacked(type(sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel).creationCode, abi.encode(cp));
    }

    function _snapshotKernelSpecific(address _proxy) internal view override returns (bytes memory) {
        ISUSDaiKernel k = ISUSDaiKernel(_proxy);
        return abi.encode(k.USDAI(), k.getStoredConversionRateWAD());
    }

    function _verifyKernelSpecific(address _proxy, bytes memory _snap) internal view override {
        (address usdai, uint256 storedRate) = abi.decode(_snap, (address, uint256));
        ISUSDaiKernel k = ISUSDaiKernel(_proxy);
        require(k.USDAI() == usdai, UpgradeSUSDaiKernelModule__UsdaiChanged(usdai, k.USDAI()));
        require(
            k.getStoredConversionRateWAD() == storedRate, UpgradeSUSDaiKernelModule__StoredConversionRateChanged(storedRate, k.getStoredConversionRateWAD())
        );
    }
}
