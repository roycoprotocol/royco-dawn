// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDawnKernel } from "../interfaces/IRoycoDawnKernel.sol";
import { RoycoDawnKernel } from "./base/RoycoDawnKernel.sol";
import { IdenticalERC4626SharesToAdminOracleQuoter } from "./base/quoter/IdenticalERC4626SharesToAdminOracleQuoter.sol";

/**
 * @title Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel
 * @author Waymont
 * @notice The senior and junior tranches transfer in the same yield bearing ERC4626 shares (sUSDS, sUSDe, etc.)
 * @dev NAV computations convert tranche units (ERC4626 shares) to base assets using the vault's exchange rate and then convert base assets to NAV units using an admin set exchange rate
 */
contract Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel is RoycoDawnKernel, IdenticalERC4626SharesToAdminOracleQuoter {
    /// @notice Constructs the kernel state
    /// @param _params The standard construction parameters for the Royco kernel
    constructor(RoycoDawnKernelConstructionParams memory _params) RoycoDawnKernel(_params) { }

    /**
     * @notice Initializes the Royco Kernel
     * @param _params The standard initialization parameters for the Royco Kernel
     * @param _initialConversionRateWAD The initial reference asset to NAV unit conversion rate, scaled to WAD precision
     */
    function initialize(IRoycoDawnKernel.RoycoDawnKernelInitParams calldata _params, uint256 _initialConversionRateWAD) external initializer {
        // Initialize the base kernel state
        __RoycoDawnKernel_init(_params);
        // Initialize the identical ERC4626 shares to admin oracle quoter
        __IdenticalERC4626SharesToAdminOracleQuoter_init(_initialConversionRateWAD);
    }
}
