// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { LiquidityPositionClaims } from "../libraries/Types.sol";
import { NAV_UNIT, QUOTE_UNIT, TRANCHE_UNIT } from "../libraries/Units.sol";
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
     * @custom:field jtOwnedSTShares - The senior tranche shares owned by the junior tranche's AMM LP position
     */
    struct RoycoDuskKernelState {
        uint256 jtOwnedSTShares;
    }

    /**
     * @notice Converts the specified JT assets (LP tokens) denominated in its tranche units to the liquidity postion's claims
     * @param _jtAssets The JT assets (LP tokens) denominated in tranche units to convert to the liquidity postion's claims
     * @return lpClaims The liquidity position claims for the specified amount of JT assets (LP tokens)
     */
    function jtConvertTrancheUnitsToLPClaims(TRANCHE_UNIT _jtAssets) external view returns (LiquidityPositionClaims memory lpClaims);

    /**
     * @notice Converts the specified quote assets for the ST share of  denominated in its tranche units to the liquidity postion's claims
     * @param _quoteAssets The quote assets denominated in quote units to convert to the kernel's NAV units
     * @return nav The specified quote assets denominated in quote units converted to the kernel's NAV units
     */
    function lpConvertQuoteAssetsToNAVUnits(QUOTE_UNIT _quoteAssets) external view returns (NAV_UNIT nav);
}
