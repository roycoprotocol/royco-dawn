// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDawnKernel } from "../../../../src/interfaces/IRoycoDawnKernel.sol";
import { MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel } from "../../../../src/kernels/MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel.sol";

import { UpgradeIdenticalErc4626KernelModule } from "./UpgradeIdenticalErc4626KernelModule.sol";

/// @notice Reads the additional Maple-specific immutable.
interface IMaplePoolKernel {
    function MAPLE_POOL_MANAGER() external view returns (address);
}

/**
 * @title UpgradeMaplePoolV2KernelModule
 * @notice Module for upgrading `MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel` proxies
 *         (used by markets like syrupUSDC).
 *
 * @dev Inherits from `UpgradeIdenticalErc4626KernelModule` because the Maple kernel itself extends
 *      the identical-ERC4626-chainlink kernel. Adds the `MAPLE_POOL_MANAGER` immutable to both the
 *      contract-name + creation-code resolution (so we get the right CREATE2 address) and to the
 *      kernel-specific snapshot/verify pair.
 */
contract UpgradeMaplePoolV2KernelModule is UpgradeIdenticalErc4626KernelModule {
    error UpgradeMaplePoolV2KernelModule__MaplePoolManagerChanged(address expected, address actual);

    function _kernelContractName() internal pure override returns (string memory) {
        return "MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel";
    }

    function _kernelCreationCodeWith(IRoycoDawnKernel.RoycoDawnKernelConstructionParams memory cp) internal pure override returns (bytes memory) {
        return abi.encodePacked(type(MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel).creationCode, abi.encode(cp));
    }

    function _snapshotKernelSpecific(address _proxy) internal view override returns (bytes memory) {
        // Pack the parent (Identical-ERC4626) snapshot with the Maple-specific immutable.
        bytes memory parentSnap = super._snapshotKernelSpecific(_proxy);
        return abi.encode(parentSnap, IMaplePoolKernel(_proxy).MAPLE_POOL_MANAGER());
    }

    function _verifyKernelSpecific(address _proxy, bytes memory _snap) internal view override {
        (bytes memory parentSnap, address maplePoolManager) = abi.decode(_snap, (bytes, address));
        super._verifyKernelSpecific(_proxy, parentSnap);
        require(
            IMaplePoolKernel(_proxy).MAPLE_POOL_MANAGER() == maplePoolManager,
            UpgradeMaplePoolV2KernelModule__MaplePoolManagerChanged(maplePoolManager, IMaplePoolKernel(_proxy).MAPLE_POOL_MANAGER())
        );
    }
}
