// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import { IRoycoDawnKernel } from "../interfaces/IRoycoDawnKernel.sol";
import { IIdleCDO } from "../interfaces/external/idle-finance/IIdleCDO.sol";
import { WAD_DECIMALS } from "../libraries/Constants.sol";
import { RoycoDawnKernel } from "./base/RoycoDawnKernel.sol";
import { IdenticalAssetsOracleQuoter } from "./base/quoter/base/IdenticalAssetsOracleQuoter.sol";

/**
 * @title Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_Kernel
 * @author Waymont
 * @notice The senior and junior tranches transfer in an IdleCDO's AA tranche
 * @dev Example: Pareto's Falconx's Prime Brokerage Vault at https://app.pareto.credit/vault#0xC26A6Fa2C37b38E549a4a1807543801Db684f99C
 * @dev https://docs.idle.finance/
 */
contract Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_Kernel is RoycoDawnKernel, IdenticalAssetsOracleQuoter {
    /// @notice The address of the IdleCDO
    address public immutable IDLE_CDO;

    /// @notice The virtual price multiplier for the IdleCDO's AA tranche to convert to WAD precision
    uint256 internal immutable IDLE_CDO_VIRTUAL_PRICE_MULTIPLIER_FOR_WAD_PRECISION;

    /// @notice Thrown when the AA CDO tranche token is different from the market's ST and JT asset
    error AA_CDO_TRANCHE_TOKEN_MISMATCH();

    /**
     * @notice Constructs the Royco kernel
     * @param _params The standard construction parameters for the Royco kernel
     * @param _idleCDO The address of the IdleCDO
     */
    constructor(RoycoDawnKernelConstructionParams memory _params, address _idleCDO) RoycoDawnKernel(_params) {
        require(_idleCDO != address(0), NULL_ADDRESS());
        IDLE_CDO = _idleCDO;

        // Ensure that the AA tranche token is the same as the ST and JT assets for the IdleCDO
        address aaTrancheToken = IIdleCDO(_idleCDO).AATranche();
        require(aaTrancheToken == ST_ASSET && aaTrancheToken == JT_ASSET, AA_CDO_TRANCHE_TOKEN_MISMATCH());

        // Compute the virtual price multiplier for the IdleCDO's AA tranche to convert to WAD precision
        uint256 quoteTokenDecimals = IERC20Metadata(IIdleCDO(_idleCDO).token()).decimals();
        IDLE_CDO_VIRTUAL_PRICE_MULTIPLIER_FOR_WAD_PRECISION = 10 ** (WAD_DECIMALS - quoteTokenDecimals);
    }

    /**
     * @notice Initializes the Royco Kernel
     * @param _params The standard initialization parameters for the Royco Kernel
     */
    function initialize(IRoycoDawnKernel.RoycoDawnKernelInitParams calldata _params) external initializer {
        // Initialize the base kernel state
        __RoycoDawnKernel_init(_params);
        // The initial conversion rate is set to the sentinel value so that the IdleCDO's AA tranche virtual price is queried directly from the IdleCDO
        __IdenticalAssetsOracleQuoter_init_unchained(SENTINEL_CONVERSION_RATE);
    }

    /// @inheritdoc IdenticalAssetsOracleQuoter
    function _getConversionRateFromOracleWAD() internal view override(IdenticalAssetsOracleQuoter) returns (uint256) {
        // The virtual price is returned in the Idle CDO quote token's decimals
        // We multiply the virtual price by the virtual price multiplier to convert it to WAD precision
        return IIdleCDO(IDLE_CDO).virtualPrice(ST_ASSET) * IDLE_CDO_VIRTUAL_PRICE_MULTIPLIER_FOR_WAD_PRECISION;
    }
}
