// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC4626 } from "../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { RoycoKernelInitParams } from "../libraries/RoycoKernelStorageLib.sol";
import { AaveV3JTKernel } from "./base/junior/AaveV3JTKernel.sol";
import { ERC4626STKernel } from "./base/senior/ERC4626STKernel.sol";

contract ERC4626ST_AaveV3JT_Kernel is ERC4626STKernel, AaveV3JTKernel {
    /// @notice Thrown when the two tranches have a different base asset
    error TRANCHE_ASSETS_MUST_BE_IDENTICAL();

    function initialize(RoycoKernelInitParams calldata _params, address _initialAuthority, address _stVault, address _aaveV3Pool) external initializer {
        // Get the base assets for both tranches and ensure that they are identical
        address stAsset = IERC4626(_params.seniorTranche).asset();
        address jtAsset = IERC4626(_params.juniorTranche).asset();
        require(stAsset == jtAsset, TRANCHE_ASSETS_MUST_BE_IDENTICAL());

        // Initialize the base kernel state
        __RoycoKernel_init(_params, _initialAuthority);
        // Initialize the ERC4626 senior tranche state
        __ERC4626STKernel_init_unchained(_stVault, stAsset);
        // Initialize the Aave V3 junior tranche state
        __AaveV3JTKernel_init_unchained(_aaveV3Pool, jtAsset);
    }
}
