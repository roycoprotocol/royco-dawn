// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoKernel } from "../../../../src/interfaces/IRoycoKernel.sol";

/// @title MockKernel
/// @notice A minimal mock implementation of IRoycoKernel for testing dual-asset transfers
contract MockKernel {
    address public stAsset;
    address public jtAsset;

    constructor(address _stAsset, address _jtAsset) {
        stAsset = _stAsset;
        jtAsset = _jtAsset;
    }

    function ST_ASSET() external view returns (address) {
        return stAsset;
    }

    function JT_ASSET() external view returns (address) {
        return jtAsset;
    }

    /// @notice Update assets for testing different scenarios
    function setAssets(address _stAsset, address _jtAsset) external {
        stAsset = _stAsset;
        jtAsset = _jtAsset;
    }
}
