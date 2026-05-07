// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { EnumerableSet } from "../../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import { RoycoBase } from "../base/RoycoBase.sol";
import { IRoycoDawnKernel } from "../interfaces/IRoycoDawnKernel.sol";
import { IRoycoFactory } from "../interfaces/IRoycoFactory.sol";
import { IRoycoVaultTranche } from "../interfaces/IRoycoVaultTranche.sol";

/**
 * @title RoycoMarketSyncer
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Periphery contract enabling batch NAV accounting synchronization across multiple Royco markets
 * @dev Only kernels deployed by the canonical Royco Factory can be registered with this syncer
 */
contract RoycoMarketSyncer is RoycoBase {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev Storage slot for RoycoMarketSyncerState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoMarketSyncerState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROYCO_MARKET_SYNCER_STORAGE_SLOT = 0x65f8145c32d6f7d600ded0f23ff9c2c2e262c975a2f7552b5c41fcd203e2aa00;

    /// @notice Storage state for the Royco market syncer
    /// @custom:field marketKernels An enumerable set of the configured market kernels
    struct RoycoMarketSyncerState {
        EnumerableSet.AddressSet marketKernels;
    }

    /// @notice Emitted when a market kernel is added to the syncer
    /// @param kernel The address of the market kernel that was added
    event MarketKernelAdded(address indexed kernel);

    /// @notice Emitted when a market kernel is removed from the syncer
    /// @param kernel The address of the market kernel that was removed
    event MarketKernelRemoved(address indexed kernel);

    /**
     * @notice Emitted when an accounting sync fails for a kernel
     * @param kernel The address of the market kernel that failed to sync
     * @param errorData The error data returned by the failed sync call
     */
    event AccountingSyncFailed(address indexed kernel, bytes errorData);

    /// @notice Thrown when attempting to add a kernel that was not deployed by the canonical Royco Factory
    /// @param kernel The address of the invalid kernel
    error INVALID_KERNEL(address kernel);

    /// @notice Thrown when attempting to add a kernel that is already registered with this syncer
    /// @param kernel The address of the kernel that already exists
    error KERNEL_ALREADY_REGISTERED(address kernel);

    /// @notice Thrown when attempting to remove a kernel that is not registered with this syncer
    /// @param kernel The address of the kernel that does not exist
    error KERNEL_IS_NOT_REGISTERED(address kernel);

    /**
     * @notice Initializes the market syncer state
     * @param _roycoFactory The canonical Royco factory responsible for deploying markets and acting as the singleton access manager
     * @param _marketKernels The initial kernels that this syncer will synchronize NAV accounting for
     */
    function initialize(address _roycoFactory, address[] calldata _marketKernels) external initializer {
        // Initialize the base syncer state
        __RoycoBase_init(_roycoFactory);
        // Initialize the syncer state with the market kernels
        _modifyMarketKernels(true, _marketKernels);
    }

    /**
     * @notice Executes a batch NAV accounting synchronization across all registered market kernels
     * @param _tolerateReversions A boolean indicating whether to tolerate downstream reversions or propagate them upstream
     */
    function executeBatchAccountingSync(bool _tolerateReversions) external whenNotPaused restricted {
        // Execute the NAV synchronization for each registered kernel
        RoycoMarketSyncerState storage $ = _getRoycoMarketSyncerStorage();
        uint256 numKernels = $.marketKernels.length();
        // Allocate the accounting sync function selector to memory once and retrieve its pointer
        uint256 syncSelectorPtr = _allocateSyncSelector();
        for (uint256 i = 0; i < numKernels; ++i) {
            _executeAccountingSync($.marketKernels.at(i), syncSelectorPtr, _tolerateReversions);
        }
    }

    /**
     * @notice Executes a batch NAV accounting synchronization across all specified market kernels
     * @param _marketKernels The market kernels to execute the NAV synchronizations for
     * @param _tolerateReversions A boolean indicating whether to tolerate downstream reversions or propagate them upstream
     */
    function executeBatchAccountingSyncFor(address[] calldata _marketKernels, bool _tolerateReversions) external whenNotPaused restricted {
        // Execute the NAV synchronization for each specified kernel
        uint256 numKernels = _marketKernels.length;
        // Allocate the accounting sync function selector to memory once and retrieve its pointer
        uint256 syncSelectorPtr = _allocateSyncSelector();
        for (uint256 i = 0; i < numKernels; ++i) {
            _executeAccountingSync(_marketKernels[i], syncSelectorPtr, _tolerateReversions);
        }
    }

    /**
     * @notice Adds new market kernels to the syncer
     * @dev Each kernel is validated to ensure it was deployed by the canonical Royco Factory before being added
     * @param _marketKernels The market kernels to add to the sync batch
     */
    function addMarketKernels(address[] calldata _marketKernels) external whenNotPaused restricted {
        _modifyMarketKernels(true, _marketKernels);
    }

    /**
     * @notice Removes market kernels from the syncer
     * @param _marketKernels The market kernels to remove from the sync batch
     */
    function removeMarketKernels(address[] calldata _marketKernels) external whenNotPaused restricted {
        _modifyMarketKernels(false, _marketKernels);
    }

    /// @notice Returns the kernels that are currently registered with this syncer
    function getMarketKernels() public view returns (address[] memory) {
        return _getRoycoMarketSyncerStorage().marketKernels.values();
    }

    /// @notice Returns if the specified kernel is currently registered with this syncer
    function isMarketKernelRegistered(address _marketKernel) public view returns (bool) {
        return _getRoycoMarketSyncerStorage().marketKernels.contains(_marketKernel);
    }

    /**
     * @notice Executes a NAV accounting synchronization for the specified market kernel
     * @dev Uses low-level calls to gracefully handle reversions
     * @param _marketKernel The market kernel to execute the NAV synchronizations for
     * @param _syncSelectorPtr Memory pointer to the pre-allocated syncTrancheAccounting selector
     * @param _tolerateReversion A boolean indicating whether to tolerate downstream reversions or propagate them upstream
     */
    function _executeAccountingSync(address _marketKernel, uint256 _syncSelectorPtr, bool _tolerateReversion) internal {
        assembly ("memory-safe") {
            let syncSucceeded := call(gas(), _marketKernel, 0, _syncSelectorPtr, 0x04, 0x00, 0x00)
            // If the sync reverted, handle it according to the specified tolerance
            if iszero(syncSucceeded) {
                // Retrieve the free memory pointer and the return data size
                let returnDataPtr := mload(0x40)
                let size := returndatasize()
                // Preemptively propagate the error if specified
                if iszero(_tolerateReversion) {
                    returndatacopy(returnDataPtr, 0x00, size)
                    revert(returnDataPtr, size)
                }
                // Emit the AccountingSyncFailed event if reversions are tolerated
                // NOTE: No need to update the free memory pointer because the log data will be used once
                // ABI encode the event data for emission
                // Store the offset of the return data bytes
                mstore(returnDataPtr, 0x20)
                // Store the length of the return data
                mstore(add(returnDataPtr, 0x20), size)
                // Store the return data itself
                returndatacopy(add(returnDataPtr, 0x40), 0x00, size)
                // Emit the event
                log2(
                    returnDataPtr,
                    // The size to copy includes the offset, length, and return data padded to 32 bytes
                    add(0x40, and(add(size, 0x1f), not(0x1f))),
                    // Keccak256 hash of the AccountingSyncFailed event's signature
                    0x1b6499ba89419ff3aa2cf89283a3c9a58e1146549fd35d8d6f1189a9c2107c9f,
                    _marketKernel
                )
            }
        }
    }

    /**
     * @notice Adds or removes market kernels from the syncer
     * @dev Validates each kernel before addition to ensure it was deployed by the canonical Royco Factory
     * @param _isAddition A boolean indicating whether to add or remove the specified kernels from the syncer
     * @param _marketKernels The market kernels to add or remove
     */
    function _modifyMarketKernels(bool _isAddition, address[] calldata _marketKernels) internal {
        // Execute the addition or removal of kernels
        RoycoMarketSyncerState storage $ = _getRoycoMarketSyncerStorage();
        uint256 numKernels = _marketKernels.length;
        for (uint256 i = 0; i < numKernels; ++i) {
            address marketKernel = _marketKernels[i];
            // If this is an addition, validate that the kernel was deployed by the Royco factory and add it if it doesn't exist
            if (_isAddition) {
                _validateMarketKernel(marketKernel);
                require($.marketKernels.add(marketKernel), KERNEL_ALREADY_REGISTERED(marketKernel));
                emit MarketKernelAdded(marketKernel);
            }
            // If this is a removal, remove the kernel if it exists
            else {
                require($.marketKernels.remove(marketKernel), KERNEL_IS_NOT_REGISTERED(marketKernel));
                emit MarketKernelRemoved(marketKernel);
            }
        }
    }

    /**
     * @notice Validates that a market kernel was deployed by the canonical Royco Factory
     * @dev Queries the kernel's senior tranche and verifies the factory mapping to ensure authenticity
     * @param _ostensibleMarketKernel The address of the ostensible market kernel to validate
     */
    function _validateMarketKernel(address _ostensibleMarketKernel) internal view {
        // Ensure that the kernel isn't the null address
        require(_ostensibleMarketKernel != address(0), NULL_ADDRESS());

        // Get the senior tranche for this kernel from the kernel itself and the corresponding junior tranche from the canonical factory mapping
        address seniorTranche = IRoycoDawnKernel(_ostensibleMarketKernel).SENIOR_TRANCHE();
        address juniorTranche = IRoycoFactory(authority()).seniorTrancheToJuniorTranche(seniorTranche);

        // Ensure that the kernel was deployed by the Royco factory
        require(juniorTranche != address(0) && _ostensibleMarketKernel == IRoycoVaultTranche(seniorTranche).KERNEL(), INVALID_KERNEL(_ostensibleMarketKernel));
    }

    /**
     * @notice Allocates memory and stores the syncTrancheAccounting selector for batch operations
     * @dev Stores the selector once to avoid repeated mstore operations in loops
     * @return syncSelectorPtr Memory pointer to the stored selector
     */
    function _allocateSyncSelector() internal pure returns (uint256 syncSelectorPtr) {
        bytes4 syncSelector = IRoycoDawnKernel.syncTrancheAccounting.selector;
        assembly ("memory-safe") {
            syncSelectorPtr := mload(0x40)
            mstore(0x40, add(syncSelectorPtr, 0x20))
            mstore(syncSelectorPtr, syncSelector)
        }
    }

    /**
     * @notice Returns a storage pointer to the RoycoMarketSyncerState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer to the kernel's state
     */
    function _getRoycoMarketSyncerStorage() internal pure returns (RoycoMarketSyncerState storage $) {
        assembly ("memory-safe") {
            $.slot := ROYCO_MARKET_SYNCER_STORAGE_SLOT
        }
    }
}
