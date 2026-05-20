// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRateProvider } from "../../../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { IERC20Metadata } from "../../../../../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { IRoycoDuskKernel } from "../../../../../../../interfaces/IRoycoDuskKernel.sol";
import { IRoycoVaultTranche } from "../../../../../../../interfaces/IRoycoVaultTranche.sol";
import { WAD } from "../../../../../../../libraries/Constants.sol";
import { toQuoteUnits, toUint256 } from "../../../../../../../libraries/Units.sol";

/**
 * @notice The constituent token of a Dusk junior tranche's Balancer V3 pool that this rate provider prices
 * @custom:type SENIOR_TRANCHE_SHARE - The senior tranche share for this kernel
 * @custom:type QUOTE_ASSET - The quote asset against the ST shares in the JT pool
 */
enum ConstituentTokenType {
    SENIOR_TRANCHE_SHARE,
    QUOTE_ASSET
}

/**
 * @title RoycoDuskBalancerV3RateProvider
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Balancer V3 rate provider that prices a Dusk junior tranche pool's constituent token in NAV units, sourced live from the Royco Dusk kernel
 * @dev Each constituent's rate provider MUST proxy the kernel's NAV oracle, keeping the pool and kernel's valuations symmetric
 */
contract RoycoDuskBalancerV3RateProvider is IRateProvider {
    /// @notice The Royco Dusk kernel whose NAV oracle this rate provider proxies
    IRoycoDuskKernel public immutable ROYCO_KERNEL;

    /// @notice The type of the constituent token of the junior tranche pool that this rate provider prices
    /// @dev All Dusk pools are composed of exactly two assets: the market's senior tranche share and a quote asset
    ConstituentTokenType public immutable CONSTITUENT_TOKEN_TYPE;

    /// @notice The kernel's senior tranche vault
    /// @dev This variable is only set if this rate provider is configured for the senior tranche share
    IRoycoVaultTranche internal immutable SENIOR_TRANCHE;

    /// @notice The value representing 1 whole unit of the constituent token that this rate provider prices: 10^(CONSTITUENT_TOKEN_DECIMALS)
    uint256 internal immutable ONE_CONSTITUENT_TOKEN;

    /// @notice Thrown when a provided address is the null address
    error NULL_ADDRESS();

    /**
     * @notice Constructs the rate provider for a single constituent of a Dusk junior tranche's Balancer V3 pool
     * @param _roycoKernel The Royco Dusk kernel whose NAV oracle this rate provider proxies
     * @param _constituentTokenType The constituent token whose rate this provider returns
     */
    constructor(address _roycoKernel, ConstituentTokenType _constituentTokenType) {
        require(_roycoKernel != address(0), NULL_ADDRESS());

        // Set the immutable state
        ROYCO_KERNEL = IRoycoDuskKernel(_roycoKernel);
        CONSTITUENT_TOKEN_TYPE = _constituentTokenType;

        // Resolve and cache the required immutables for this rate provider
        if (_constituentTokenType == ConstituentTokenType.SENIOR_TRANCHE_SHARE) {
            SENIOR_TRANCHE = IRoycoVaultTranche(IRoycoDuskKernel(_roycoKernel).SENIOR_TRANCHE());
            ONE_CONSTITUENT_TOKEN = WAD;
        } else {
            ONE_CONSTITUENT_TOKEN = 10 ** IERC20Metadata(IRoycoDuskKernel(_roycoKernel).QUOTE_ASSET()).decimals();
        }
    }

    /// @inheritdoc IRateProvider
    /// @notice The rate returned is the price of 1 whole unit of the configured Balancer V3 pool constituent in its NAV units (USD, BTC, ETH, etc.)
    /// @dev NAV units always have 18 decimals of precision
    function getRate() external view override(IRateProvider) returns (uint256 rate) {
        // For ST shares, get the fresh NAV per share after simulating a PNL synchronization
        // NOTE: This simulation is required because the rate is retrieved before the pool's pre-op hook (responsible for syncing tranche PNL) is executed
        if (CONSTITUENT_TOKEN_TYPE == ConstituentTokenType.SENIOR_TRANCHE_SHARE) return toUint256(SENIOR_TRANCHE.convertToAssets(ONE_CONSTITUENT_TOKEN).nav);
        // For quote assets, query the kernel's configured quoter directly
        return toUint256(ROYCO_KERNEL.lpConvertQuoteAssetsToNAVUnits(toQuoteUnits(ONE_CONSTITUENT_TOKEN)));
    }
}
