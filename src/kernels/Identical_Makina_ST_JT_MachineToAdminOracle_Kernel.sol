// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDawnKernel } from "../interfaces/IRoycoDawnKernel.sol";
import { RoycoDawnKernel } from "./base/RoycoDawnKernel.sol";
import { IdenticalMakinaSharesToAdminOracleQuoter } from "./base/quoter/IdenticalMakinaSharesToAdminOracleQuoter.sol";

/**
 * @title Identical_Makina_ST_JT_MachineToAdminOracle_Kernel
 * @author Waymont
 * @notice The senior and junior tranches transfer in the same yield bearing Makina machine shares (DUSD, DBIT, etc.)
 * @dev NAV computations convert tranche units (Makina machine shares) to base assets using the machine's exchange rate and then convert base assets to NAV units using an admin set exchange rate
 */
contract Identical_Makina_ST_JT_MachineToAdminOracle_Kernel is RoycoDawnKernel, IdenticalMakinaSharesToAdminOracleQuoter {
    /**
     * @notice Constructs the kernel state
     * @param _params The standard construction parameters for the Royco kernel
     * @param _makinaMachine The Makina machine for the Royco market's tranche tokens
     */
    constructor(
        RoycoDawnKernelConstructionParams memory _params,
        address _makinaMachine
    )
        RoycoDawnKernel(_params)
        IdenticalMakinaSharesToAdminOracleQuoter(_makinaMachine)
    { }

    /**
     * @notice Initializes the Royco Kernel
     * @param _params The standard initialization parameters for the Royco Kernel
     * @param _initialConversionRateWAD The initial reference asset to NAV unit conversion rate, scaled to WAD precision
     */
    function initialize(IRoycoDawnKernel.RoycoDawnKernelInitParams calldata _params, uint256 _initialConversionRateWAD) external initializer {
        // Initialize the base kernel state
        __RoycoDawnKernel_init(_params);
        // Initialize the identical Makina machine shares to admin oracle quoter
        __IdenticalMakinaSharesToAdminOracleQuoter_init(_initialConversionRateWAD);
    }
}
