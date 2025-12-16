// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

interface IRoycoAuth {
    /// @notice Pauses the contract
    function pause() external;

    /// @notice Unpauses the contract
    function unpause() external;
}
