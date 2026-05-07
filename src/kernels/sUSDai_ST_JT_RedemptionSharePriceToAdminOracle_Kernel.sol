// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoDawnKernel } from "../interfaces/IRoycoDawnKernel.sol";
import { IStakedUSDai } from "../interfaces/external/usdai/IStakedUSDai.sol";
import { IUSDai } from "../interfaces/external/usdai/IUSDai.sol";
import { WAD } from "../libraries/Constants.sol";
import { Math } from "../libraries/Units.sol";
import { RoycoDawnKernel } from "./base/RoycoDawnKernel.sol";
import { IdenticalAssetsAdminOracleQuoter, IdenticalAssetsOracleQuoter } from "./base/quoter/base/IdenticalAssetsAdminOracleQuoter.sol";

/**
 * @title sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel
 * @author Waymont
 * @notice The senior and junior tranches transfer in sUSDai
 * @notice Tranche share transfers are restricted to addresses not blacklisted by USDai
 * @dev NAV computations employ the conservative valuation methodology used for valuing sUSDai redemptions in terms of USDai and convert the USDai to USD using an admin set exchange rate
 */
contract sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel is RoycoDawnKernel, IdenticalAssetsAdminOracleQuoter {
    using Math for uint256;

    /// @notice The address of the USDai token
    address public immutable USDAI;

    /// @dev Thrown when an account is blacklisted by USDai
    error ACCOUNT_ON_USDAI_BLACKLIST(address account);

    /// @notice Constructs the kernel state
    /// @param _params The standard construction parameters for the Royco kernel
    constructor(RoycoDawnKernelConstructionParams memory _params) RoycoDawnKernel(_params) {
        // Set the address of USDai (the base asset of sUSDai)
        USDAI = IStakedUSDai(ST_ASSET).asset();
    }

    /**
     * @notice Initializes the Royco Kernel
     * @param _params The standard initialization parameters for the Royco Kernel
     * @param _initialConversionRateWAD The initial USDai to USD conversion rate, scaled to WAD precision
     */
    function initialize(IRoycoDawnKernel.RoycoDawnKernelInitParams calldata _params, uint256 _initialConversionRateWAD) external initializer {
        // Initialize the base kernel state
        __RoycoDawnKernel_init(_params);
        // Initialize the identical assets admin oracle quoter
        __IdenticalAssetsAdminOracleQuoter_init(_initialConversionRateWAD);
    }

    /// @notice Returns the conversion rate from sUSDai (tranche units) to USD (NAV units), scaled to WAD precision
    /// @return sUSDaiToUSDConversionRateWAD The conversion rate from sUSDai (tranche units) to USD (NAV units), scaled to WAD precision
    function getTrancheUnitToNAVUnitConversionRateWAD() public view override(IdenticalAssetsOracleQuoter) returns (uint256 sUSDaiToUSDConversionRateWAD) {
        // Fetch the conversion rate from one sUSDai to USDai
        // NOTE: The output is already scaled to WAD precision since USDai has 18 decimals of precision
        uint256 sUSDaiToUSDaiConversionRateWAD = IStakedUSDai(ST_ASSET).redemptionSharePrice();

        // Fetch the USDai to USD conversion rate from the admin set oracle, scaled to WAD precision
        uint256 usdaiToUSDConversionRateWAD = getStoredConversionRateWAD();

        // Calculate the conversion rate from sUSDai to USD, scaled to WAD precision
        sUSDaiToUSDConversionRateWAD = sUSDaiToUSDaiConversionRateWAD.mulDiv(usdaiToUSDConversionRateWAD, WAD, Math.Rounding.Floor);
    }

    /// @inheritdoc RoycoDawnKernel
    function _preTrancheBalanceUpdate(address _caller, address _from, address _to, uint256) internal view override(RoycoDawnKernel) {
        // Check if the caller is blacklisted
        require(!IUSDai(USDAI).isBlacklisted(_caller), ACCOUNT_ON_USDAI_BLACKLIST(_caller));
        // Only check blacklisted status for the sender on redeem and recipient on mint
        // Check that the sender is not blacklisted by USDai
        require(_from == address(0) || !IUSDai(USDAI).isBlacklisted(_from), ACCOUNT_ON_USDAI_BLACKLIST(_from));
        // Check that the recipient is not blacklisted by USDai
        require(_to == address(0) || !IUSDai(USDAI).isBlacklisted(_to), ACCOUNT_ON_USDAI_BLACKLIST(_to));
    }
}
