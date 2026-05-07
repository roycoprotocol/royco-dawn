// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDawnKernel } from "./IRoycoDawnKernel.sol";

/**
 * @title IRoycoDuskKernel
 * @notice Interface for the base Royco Dusk kernel contract
 * @dev The kernel contract is responsible for orchestrating all operations for both tranches in a Royco Dusk market
 */
interface IRoycoDuskKernel is IRoycoDawnKernel {
    /**
     * @notice Storage state for the Royco Dusk Kernel
     * @custom:storage-location erc7201:Royco.storage.RoycoDuskKernelState
     * @custom:field internalSeniorTrancheShares - The senior tranche shares owned by the junior tranche's AMM LP position
     */
    struct RoycoDuskKernelState {
        uint256 internalSeniorTrancheShares;
    }
}
