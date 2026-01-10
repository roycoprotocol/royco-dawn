// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TRANCHE_UNIT } from "../Units.sol";

/**
 * @notice Storage state for kernels that that hold yield bearing ERC20 compliant assets
 * @custom:storage-location erc7201:Royco.storage.YieldBearingERC20KernelState
 * @custom:field stOwnedYieldBearingAssets - The yield bearing assets held by the ST
 * @custom:field jtOwnedYieldBearingAssets - The yield bearing assets held by the ST
 */
struct YieldBearingERC20KernelState {
    TRANCHE_UNIT stOwnedYieldBearingAssets;
    TRANCHE_UNIT jtOwnedYieldBearingAssets;
}

/**
 * @title YieldBearingERC20StorageLib
 * @notice A lightweight storage library for reading and mutating state for kernels that hold yield bearing ERC20 compliant assets
 */
library YieldBearingERC20StorageLib {
    /// @dev Storage slot for YieldBearingERC20KernelState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.YieldBearingERC20KernelState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YIELD_BEARING_ERC20_KERNEL_STORAGE_SLOT = 0x31dcae1a6c8e7be3177d6c56be6f186dd279c19bdd7d7f4820a1be934a634800;

    /**
     * @notice Returns a storage pointer to the YieldBearingERC20KernelState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer yield bearing ERC20 kernel state
     */
    function _getYieldBearingERC20KernelStorage() internal pure returns (YieldBearingERC20KernelState storage $) {
        assembly ("memory-safe") {
            $.slot := YIELD_BEARING_ERC20_KERNEL_STORAGE_SLOT
        }
    }
}
