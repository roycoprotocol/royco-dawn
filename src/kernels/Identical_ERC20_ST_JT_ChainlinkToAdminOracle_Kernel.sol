// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoKernel } from "../interfaces/IRoycoKernel.sol";
import { RoycoKernel } from "./base/RoycoKernel.sol";
import { IdenticalAssetsChainlinkToAdminOracleQuoter } from "./base/quoter/IdenticalAssetsChainlinkToAdminOracleQuoter.sol";

/**
 * @title Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel
 * @author Waymont
 * @notice The senior and junior tranches transfer in the same yield bearing ERC20 asset (PT-cUSD, mF-ONE, etc.)
 * @dev NAV computations use a Chainlink (compatible) oracle to convert tranche units to the oracle's quote asset and an admin oracle set rate to convert from quote assets to NAV units
 */
contract Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel is RoycoKernel, IdenticalAssetsChainlinkToAdminOracleQuoter {
    /// @notice Constructs the kernel state
    /// @param _params The standard construction parameters for the Royco kernel
    constructor(RoycoKernelConstructionParams memory _params) RoycoKernel(_params) { }

    /**
     * @notice Initializes the Royco Kernel
     * @param _params The standard initialization parameters for the Royco Kernel
     * @param _initialConversionRateWAD The initial reference asset to NAV unit conversion rate, scaled to WAD precision
     * @param _trancheAssetToReferenceAssetOracle The tranche asset to reference asset oracle
     * @param _stalenessThresholdSeconds The staleness threshold in seconds
     */
    function initialize(
        IRoycoKernel.RoycoKernelInitParams calldata _params,
        uint256 _initialConversionRateWAD,
        address _trancheAssetToReferenceAssetOracle,
        uint48 _stalenessThresholdSeconds
    )
        external
        initializer
    {
        // Initialize the base kernel state
        __RoycoKernel_init(_params);
        // Initialize the identical assets chainlink to admin oracle quoter
        __IdenticalAssetsChainlinkToAdminOracleQuoter_init(_initialConversionRateWAD, _trancheAssetToReferenceAssetOracle, _stalenessThresholdSeconds);
    }
}
