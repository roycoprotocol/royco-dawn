// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDuskKernel } from "../../interfaces/IRoycoDuskKernel.sol";
import { KernelType } from "../../libraries/Types.sol";
import { IRoycoDawnKernel, RoycoDawnKernel } from "./RoycoDawnKernel.sol";

/**
 * @title RoycoDuskKernel
 */
abstract contract RoycoDuskKernel is IRoycoDuskKernel, RoycoDawnKernel {
    /// @dev Storage slot for RoycoDuskKernelState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoDuskKernelState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROYCO_DUSK_KERNEL_STORAGE_SLOT = 0xe95dd20a4d0edb62fc02826796060a0e1d8e3ce973dfc64f20cdf50cf478ef00;

    /// @inheritdoc IRoycoDawnKernel
    function KERNEL_TYPE() external pure override(IRoycoDawnKernel, RoycoDawnKernel) returns (KernelType kernelType) {
        return KernelType.DUSK;
    }

    /**
     * @notice Returns a storage pointer to the RoycoDuskKernelState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer to the kernel's state
     */
    function _getRoycoDuskKernelStorage() internal pure returns (RoycoDuskKernelState storage $) {
        assembly ("memory-safe") {
            $.slot := ROYCO_DUSK_KERNEL_STORAGE_SLOT
        }
    }
}
