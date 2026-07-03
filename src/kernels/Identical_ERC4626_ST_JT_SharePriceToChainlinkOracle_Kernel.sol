// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoKernel } from "../interfaces/IRoycoKernel.sol";
import { RoycoKernel } from "./base/RoycoKernel.sol";
import { IdenticalERC4626SharesToChainlinkOracleQuoter } from "./base/quoter/IdenticalERC4626SharesToChainlinkOracleQuoter.sol";

/**
 * @title Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel
 * @author Waymont
 * @notice The senior and junior tranches transfer in the same yield bearing ERC4626 shares (sUSDS, sUSDe, etc.)
 * @dev NAV computations convert tranche units (ERC4626 shares) to base assets using the vault's exchange rate and then convert base assets to NAV units using a Chainlink (compatible) oracle or an admin set exchange rate
 */
contract Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel is RoycoKernel, IdenticalERC4626SharesToChainlinkOracleQuoter {
    /// @notice Constructs the kernel state
    /// @param _params The standard construction parameters for the Royco kernel
    constructor(RoycoKernelConstructionParams memory _params) RoycoKernel(_params) { }

    /**
     * @notice Initializes the Royco Kernel
     * @param _params The standard initialization parameters for the Royco Kernel
     * @param _initialConversionRateWAD The initial ERC4626 base asset to NAV unit conversion rate, scaled to WAD precision (should be set to 0 unless oracle rate should be overridden)
     * @param _baseAssetToNavAssetOracle The ERC4626 base asset to NAV accounting asset oracle
     * @param _stalenessThresholdSeconds The staleness threshold in seconds
     */
    function initialize(
        IRoycoKernel.RoycoKernelInitParams calldata _params,
        uint256 _initialConversionRateWAD,
        address _baseAssetToNavAssetOracle,
        uint48 _stalenessThresholdSeconds
    )
        external
        initializer
    {
        // Initialize the base kernel state
        __RoycoKernel_init(_params);
        // Initialize the identical ERC4626 shares to Chainlink (compatible) oracle quoter
        __IdenticalERC4626SharesToChainlinkOracleQuoter_init(_initialConversionRateWAD, _baseAssetToNavAssetOracle, _stalenessThresholdSeconds);
    }
}
