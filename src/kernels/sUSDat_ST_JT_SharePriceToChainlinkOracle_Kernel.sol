// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoKernel } from "../interfaces/IRoycoKernel.sol";
import { IStakedUSDat } from "../interfaces/external/usdat/IStakedUSDat.sol";
import { WAD } from "../libraries/Constants.sol";
import { Math } from "../libraries/Units.sol";
import { Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel } from "./Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";
import { RoycoKernel } from "./base/RoycoKernel.sol";

/**
 * @title sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel
 * @author Waymont
 * @notice The senior and junior tranches transfer in sUSDat
 * @notice Tranche share transfers are restricted to addresses not blacklisted by sUSDat
 */
contract sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel is Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel {
    /// @dev Thrown when an account is blacklisted by sUSDat
    error ACCOUNT_ON_STAKED_USDAT_BLACKLIST(address account);

    /// @notice Constructs the kernel state
    /// @param _params The standard construction parameters for the Royco kernel
    constructor(RoycoKernelConstructionParams memory _params) Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel(_params) { }

    /// @inheritdoc RoycoKernel
    function _preTrancheBalanceUpdate(address _caller, address _from, address _to, uint256) internal view override(RoycoKernel) {
        // Check if the caller is blacklisted
        require(!IStakedUSDat(ST_ASSET).isBlacklisted(_caller), ACCOUNT_ON_STAKED_USDAT_BLACKLIST(_caller));
        // Only check blacklisted status for the sender on redeem and recipient on mint
        // Check that the sender is not blacklisted by USDai
        require(_from == address(0) || !IStakedUSDat(ST_ASSET).isBlacklisted(_from), ACCOUNT_ON_STAKED_USDAT_BLACKLIST(_from));
        // Check that the recipient is not blacklisted by USDai
        require(_to == address(0) || !IStakedUSDat(ST_ASSET).isBlacklisted(_to), ACCOUNT_ON_STAKED_USDAT_BLACKLIST(_to));
    }
}
