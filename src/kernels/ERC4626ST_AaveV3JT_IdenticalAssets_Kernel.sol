// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20, IERC4626 } from "../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { IRoycoVaultTranche } from "../interfaces/tranche/IRoycoVaultTranche.sol";
import { RoycoKernelInitParams } from "../libraries/RoycoKernelStorageLib.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits } from "../libraries/Units.sol";
import { IRoycoKernel, RoycoKernel } from "./base/RoycoKernel.sol";
import { AaveV3JTKernel } from "./base/junior/AaveV3JTKernel.sol";
import { IdenticalAssetsQuoter } from "./base/quoter/IdenticalAssetsQuoter.sol";
import { ERC4626STKernel } from "./base/senior/ERC4626STKernel.sol";

contract ERC4626ST_AaveV3JT_IdenticalAssets_Kernel is ERC4626STKernel, AaveV3JTKernel, IdenticalAssetsQuoter {
    function initialize(RoycoKernelInitParams calldata _params, address _initialAuthority, address _stVault, address _aaveV3Pool) external initializer {
        // Get the base assets for both tranches and ensure that they are identical
        address stAsset = IRoycoVaultTranche(_params.seniorTranche).asset();
        address jtAsset = IRoycoVaultTranche(_params.juniorTranche).asset();

        // Initialize the base kernel state
        __RoycoKernel_init(_params, stAsset, jtAsset, _initialAuthority);
        // Initialize the ERC4626 senior tranche state
        __ERC4626STKernel_init_unchained(_stVault, stAsset);
        // Initialize the Aave V3 junior tranche state
        __AaveV3JTKernel_init_unchained(_aaveV3Pool, jtAsset);
        // Initialize the identical assets quoter
        __IdenticalAssetQuoter_init_unchained(stAsset, jtAsset);
    }
}
