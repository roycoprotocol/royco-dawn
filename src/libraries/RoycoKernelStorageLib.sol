// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @notice Initialization parameters for the Royco Kernel
 * @custom:field seniorTranche - The address of the Royco senior tranche associated with this kernel
 * @custom:field juniorTranche - The address of the Royco junior tranche associated with this kernel
 * @custom:field accountant - The address of the Royco accountant used to perform per operation accounting for this kernel
 * @custom:field protocolFeeRecipient - The market's configured protocol fee recipient
 */
struct RoycoKernelInitParams {
    address seniorTranche;
    address juniorTranche;
    address accountant;
    address protocolFeeRecipient;
}

/**
 * @notice Storage state for the Royco Kernel
 * @custom:storage-location erc7201:Royco.storage.RoycoKernelState
 * @custom:field seniorTranche - The address of the Royco senior tranche associated with this kernel
 * @custom:field juniorTranche - The address of the Royco junior tranche associated with this kernel
 * @custom:field accountant - The address of the Royco accountant used to perform per operation accounting for this kernel
 * @custom:field protocolFeeRecipient - The market's configured protocol fee recipient
 */
struct RoycoKernelState {
    address seniorTranche;
    address juniorTranche;
    address accountant;
    address protocolFeeRecipient;
}

/// @title RoycoKernelStorageLib
/// @notice Library for managing Royco Kernel storage using the ERC7201 pattern
library RoycoKernelStorageLib {
    /// @dev Storage slot for RoycoKernelState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoKernelState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BASE_KERNEL_STORAGE_SLOT = 0x0e1123d8194dcf603de811512b2b6334f106b53313663d6b2df1a2b814038e00;

    /// @notice Returns a storage pointer to the RoycoKernelState storage
    /// @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
    /// @return $ Storage pointer to the kernel's state
    function _getRoycoKernelStorage() internal pure returns (RoycoKernelState storage $) {
        assembly ("memory-safe") {
            $.slot := BASE_KERNEL_STORAGE_SLOT
        }
    }

    /// @notice Initializes the kernel state
    /// @param _params The initialization parameters for the kernel
    function __RoycoKernel_init(RoycoKernelInitParams memory _params) internal {
        // Set the initial state of the kernel
        RoycoKernelState storage $ = _getRoycoKernelStorage();
        $.seniorTranche = _params.seniorTranche;
        $.juniorTranche = _params.juniorTranche;
        $.accountant = _params.accountant;
        $.protocolFeeRecipient = _params.protocolFeeRecipient;
    }
}
