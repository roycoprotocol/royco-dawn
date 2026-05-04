// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ILockingController
/// @notice Abridged interface for the Infinifi Locking Controller contract
interface ILockingController {
    /// @notice Returns the exchange rate of receipt tokens per share token for a given lock duration
    /// @param _unwindingEpochs The lock duration in epochs (1-13 weeks)
    /// @return Exchange rate in WAD (18 decimals), e.g., 1.05e18 means 1 share = 1.05 receipt tokens
    function exchangeRate(uint32 _unwindingEpochs) external view returns (uint256);

    /// @notice Returns the share token (LockedPositionToken) address for a given lock duration
    /// @param _unwindingEpochs The lock duration in epochs (1-13 weeks)
    /// @return The LockedPositionToken address, or address(0) if bucket not enabled
    function shareToken(uint32 _unwindingEpochs) external view returns (address);
}
