// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { LiquidityPositionClaims, SyncedAccountingState } from "../libraries/Types.sol";
import { NAV_UNIT, QUOTE_UNIT, TRANCHE_UNIT } from "../libraries/Units.sol";
import { IRoycoDawnKernel } from "./IRoycoDawnKernel.sol";

/**
 * @title IRoycoDuskKernel
 * @notice Interface for the base Royco Dusk kernel contract
 * @dev The kernel contract is responsible for orchestrating all operations for both tranches in a Royco Dusk market
 */
interface IRoycoDuskKernel is IRoycoDawnKernel {
    /**
     * @notice Construction parameters for the Royco Dusk Kernel
     * @custom:field dawnKernelParams - Construction parameters for the Royco Dawn Kernel
     * @custom:field quoteAsset - The address of the quote asset used by the junior tranche to buy/sell ST shares
     */
    struct RoycoDuskKernelConstructionParams {
        RoycoDawnKernelConstructionParams dawnKernelParams;
        address quoteAsset;
    }

    /**
     * @notice Initialization parameters for the Royco Dusk Kernel
     * @custom:field dawnKernelInitParams - Initialization parameters for the Royco Dawn Kernel
     */
    struct RoycoDuskKernelInitParams {
        RoycoDawnKernelInitParams dawnKernelInitParams;
    }

    /**
     * @notice Storage state for the Royco Dusk Kernel
     * @custom:storage-location erc7201:Royco.storage.RoycoDuskKernelState
     * @custom:field jtOwnedSTShares - The senior tranche shares owned by the junior tranche's LP position
     */
    struct RoycoDuskKernelState {
        uint256 lastJTOwnedSTShares;
    }

    /// @notice Thrown when the senior and junior tranche assets are identical (Dusk requires distinct assets)
    error TRANCHE_ASSETS_MUST_NOT_BE_IDENTICAL();

    /// @notice Thrown when the quote asset is set as the senior tranche share
    error QUOTE_ASSET_MUST_NOT_BE_SENIOR_TRANCHE_SHARE();

    /**
     * @notice Retrieves the quote asset address
     * @return quoteAsset The address of the quote asset used by the junior tranche to buy/sell ST shares
     */
    function QUOTE_ASSET() external view returns (address quoteAsset);

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

    /**
     * @notice Converts the specified amount of internal senior tranche shares to their pro-rata claim on the senior tranche's underlying yield-bearing assets
     * @dev Internal senior tranche shares are the senior tranche shares held by the junior tranche's liquidity position, as opposed to the external senior tranche shares held by senior tranche depositors
     * @param _internalSTShares The amount of internal senior tranche shares to convert
     * @return stAssets The pro-rata claim on the senior tranche's underlying yield-bearing assets, denominated in tranche units
     */
    function convertInternalSTSharesToSTAssets(uint256 _internalSTShares) external view returns (TRANCHE_UNIT stAssets);

    /**
     * @notice Synchronizes and persists the raw and effective NAVs of both tranches after an external operation on the JT's underlying liquidity position
     * @dev Reconciles the distribution of ST shares in circulation (internally and externally owned) into a recomposed tranche NAVs checkpoint before applying the PNL sync
     * @return state The synced NAV, JT coverage impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function postLiquidityPositionOpSyncTrancheAccounting() external returns (SyncedAccountingState memory state);
}
