// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20, IERC4626 } from "../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { IRoycoVaultTranche } from "../interfaces/tranche/IRoycoVaultTranche.sol";
import { RoycoKernelInitParams } from "../libraries/RoycoKernelStorageLib.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../libraries/Units.sol";
import { IRoycoKernel, RoycoKernel } from "./base/RoycoKernel.sol";
import { AaveV3JTKernel, AaveV3KernelStorageLib } from "./base/junior/AaveV3JTKernel.sol";
import { ERC4626STKernel, ERC4626STKernelStorageLib } from "./base/senior/ERC4626STKernel.sol";

contract ERC4626ST_AaveV3JT_Kernel is ERC4626STKernel, AaveV3JTKernel {
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
    }

    /// @inheritdoc IRoycoKernel
    function stConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _stAssets) public view virtual override(IRoycoKernel, RoycoKernel) returns (NAV_UNIT) { }

    /// @inheritdoc IRoycoKernel
    function jtConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _jtAssets) public view virtual override(IRoycoKernel, RoycoKernel) returns (NAV_UNIT) { }

    /// @inheritdoc IRoycoKernel
    function stConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) public view virtual override(IRoycoKernel, RoycoKernel) returns (TRANCHE_UNIT) { }

    /// @inheritdoc IRoycoKernel
    function jtConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) public view virtual override(IRoycoKernel, RoycoKernel) returns (TRANCHE_UNIT) { }

    /// @inheritdoc RoycoKernel
    function _getJuniorTrancheRawNAV() internal view override(RoycoKernel) returns (NAV_UNIT) {
        // The tranche's balance of the AToken is the total assets it is owed from the Aave pool
        /// @dev This does not treat illiquidity in the Aave pool as a loss: we assume that total lent will be withdrawable at some point
        return jtConvertTrancheUnitsToNAVUnits(toTrancheUnits(IERC20(AaveV3KernelStorageLib._getAaveV3KernelStorage().aToken).balanceOf(address(this))));
    }

    /// @inheritdoc RoycoKernel
    function _getSeniorTrancheRawNAV() internal view override(RoycoKernel) returns (NAV_UNIT) {
        // Must use preview redeem for the tranche owned shares
        // Max withdraw will mistake illiquidity for NAV losses
        address vault = ERC4626STKernelStorageLib._getERC4626STKernelStorage().vault;
        uint256 trancheSharesBalance = IERC4626(vault).balanceOf(address(this));
        return stConvertTrancheUnitsToNAVUnits(toTrancheUnits(IERC4626(vault).previewRedeem(trancheSharesBalance)));
    }
}
