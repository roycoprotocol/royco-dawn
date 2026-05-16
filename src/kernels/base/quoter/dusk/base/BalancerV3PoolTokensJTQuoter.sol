// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { BalancerPoolToken, IVault } from "../../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/BalancerPoolToken.sol";
import { BaseHooks } from "../../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/BaseHooks.sol";
import { IERC20 } from "../../../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Math, QUOTE_UNIT, TRANCHE_UNIT, UnitsMathLib, toQuoteUnits, toUint256 } from "../../../../../libraries/Units.sol";
import { LiquidityPositionClaims, RoycoDuskKernel } from "../../../RoycoDuskKernel.sol";

/**
 * @title BalancerV3PoolTokensJTQuoter
 * @notice A quoter for Dusk Kernels using Balancer V3 pools (ST share <> Quote asset) as their secondary liquidity venue
 * @notice The junior tranche asset is a Balancer Pool Token (BPT) between this kernel's senior tranche share and quote asset
 * @dev The Junior Tranche's BPT (Balancer Pool Token) represents its liquidity position in the pool
 *      This quoter reads the pool's current raw token balances from the Balancer V3 Vault and derives JT's pro-rata claim from the ratio of JT's BPT holdings to total BPT supply
 */
abstract contract BalancerV3PoolTokensJTQuoter is RoycoDuskKernel, BaseHooks {
    using UnitsMathLib for uint256;
    using UnitsMathLib for QUOTE_UNIT;
    using Math for uint256;

    /// @notice The singleton Balancer V3 Vault that holds the pool's reserves
    IVault public immutable BALANCER_V3_VAULT;

    /// @notice Index of the Senior Tranche share token in the pool's token registration order
    uint256 internal immutable ST_SHARE_INDEX;

    /// @notice Index of the quote asset in the pool's token registration order
    uint256 internal immutable QUOTE_ASSET_INDEX;

    /// @notice Thrown when the Balancer pool is not registered with the Balancer V3 Vault
    error POOL_NOT_REGISTERED();

    /// @notice Thrown when the Balancer pool is not configured with exactly two tokens (ST share and the kernel's quote asset)
    error POOL_MUST_HAVE_TWO_TOKENS();

    /// @notice Thrown when the pool's tokens don't match the kernel's configured ST asset and quote asset
    error INVALID_POOL_TOKEN_CONFIGURATION();

    /**
     * @notice Constructs the Balancer V3 pool tokens JT quoter
     * @dev Derives the Vault address from the pool via BalancerPoolToken.getVault(), so the pool
     *      address (= JT_ASSET) is the only deployment parameter required
     * @dev Resolves token indices by matching the pool's registered tokens against ST_ASSET and
     *      the quote asset surfaced by the sibling quote-asset quoter mixin
     */
    constructor() {
        // Set the singleton Balancer V3 Vault
        BALANCER_V3_VAULT = BalancerPoolToken(JT_ASSET).getVault();
        // Ensure that the Balancer V3 Pool is registered with the vault
        require(BALANCER_V3_VAULT.isPoolRegistered(JT_ASSET), POOL_NOT_REGISTERED());

        // Retrieve the constituent tokens of this kernel's Balancer V3 pool and ensure that their are exactly 2
        IERC20[] memory tokens = BALANCER_V3_VAULT.getPoolTokens(JT_ASSET);
        require(tokens.length == 2, POOL_MUST_HAVE_TWO_TOKENS());

        // Resolve and cache the indexes of the ST share and the kernel's quote asset in the pool configuration
        // Revert if the pool is not configured with ST share and the kernel's quote asset as its constituents
        if (address(tokens[0]) == SENIOR_TRANCHE && address(tokens[1]) == QUOTE_ASSET) QUOTE_ASSET_INDEX = 1;
        else if (address(tokens[0]) == QUOTE_ASSET && address(tokens[1]) == SENIOR_TRANCHE) ST_SHARE_INDEX = 1;
        else revert INVALID_POOL_TOKEN_CONFIGURATION();
    }

    /**
     * @notice Converts the specificed amount of BPTs into their pro-rata claim on the pool's constituent tokens
     * @dev Pro-rata math against live Balancer V3 Vault state:
     *         stShares    = poolBalances[ST_SHARE] * jtBPTBalance / bptTotalSupply
     *         quoteAssets = poolBalances[QUOTE] * jtBPTBalance / bptTotalSupply
     * @dev Returns zero claims when the pool has no outstanding claims on its constituent tokens
     * @param _jtAssets The Balancer Pool Tokens to get the pro-rata constituent token claims for
     * @return claims The pro-rata claim on the pool's ST shares and quote assets
     */
    function jtConvertTrancheUnitsToLPClaims(TRANCHE_UNIT _jtAssets)
        public
        view
        virtual
        override(RoycoDuskKernel)
        returns (LiquidityPositionClaims memory claims)
    {
        // Get the total constituent token balances of the Balancer V3 pool and the total supply of BPT tokens
        (,, uint256[] memory constituentTokenBalances,) = BALANCER_V3_VAULT.getPoolTokenInfo(JT_ASSET);
        uint256 bptTotalSupply = BALANCER_V3_VAULT.totalSupply(JT_ASSET);
        // Preemptively return if the pool has no outstanding claims on its constituent tokens
        if (bptTotalSupply == 0) return claims;

        // Convert the specified BPTs (JT assets) to pro-rata claims of the pool's total constituent tokens
        claims.stShares = constituentTokenBalances[ST_SHARE_INDEX].mulDiv(toUint256(_jtAssets), bptTotalSupply, Math.Rounding.Floor);
        claims.quoteAssets = toQuoteUnits(constituentTokenBalances[QUOTE_ASSET_INDEX]).mulDiv(toUint256(_jtAssets), bptTotalSupply, Math.Rounding.Floor);
    }
}
