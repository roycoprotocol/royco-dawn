// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import {
    AddLiquidityKind,
    AfterSwapParams,
    HookFlags,
    LiquidityManagement,
    PoolSwapParams,
    RemoveLiquidityKind,
    RemoveLiquidityParams,
    TokenConfig
} from "../../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { ScalingHelpers } from "../../../../../../../lib/balancer-v3-monorepo/pkg/solidity-utils/contracts/helpers/ScalingHelpers.sol";
import { BalancerPoolToken } from "../../../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/BalancerPoolToken.sol";
import { BasePoolMath } from "../../../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/BasePoolMath.sol";
import { VaultGuard } from "../../../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/VaultGuard.sol";
import { IERC20Metadata } from "../../../../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { IERC20 } from "../../../../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Math, QUOTE_UNIT, TRANCHE_UNIT, UnitsMathLib, toQuoteUnits, toUint256 } from "../../../../../../libraries/Units.sol";
import { IRoycoDuskKernel, LiquidityPositionClaims, RoycoDuskKernel } from "../../../../RoycoDuskKernel.sol";

/**
 * @title JuniorAssetsBalancerV3PoolTokensQuoter
 * @notice A quoter for Dusk Kernels using Balancer V3 pools (ST share <> Quote asset) as their secondary liquidity venue
 * @notice The junior tranche asset is a Balancer Pool Token (BPT) between this kernel's senior tranche share and quote asset
 * @dev The Junior Tranche's BPT (Balancer Pool Token) represents its liquidity position in the pool
 *      This quoter reads the pool's current raw token balances from the Balancer V3 Vault and derives JT's pro-rata claim from the ratio of JT's BPT holdings to total BPT supply
 */
abstract contract JuniorAssetsBalancerV3PoolTokensQuoter is RoycoDuskKernel, VaultGuard {
    using UnitsMathLib for uint256;
    using UnitsMathLib for QUOTE_UNIT;
    using Math for uint256;
    using ScalingHelpers for uint256;

    /// @notice Index of the Senior Tranche share token in the pool's token registration order
    uint256 internal immutable ST_SHARE_POOL_INDEX;

    /// @notice Index of the quote asset in the pool's token registration order
    uint256 internal immutable QUOTE_ASSET_POOL_INDEX;

    /// @dev Decimal scaling factor for the quote asset token, cached at construction since it is fixed at pool registration: 10^(18 - tokenDecimals)
    uint256 internal immutable QUOTE_ASSET_POOL_DECIMAL_SCALING_FACTOR;

    /// @dev Thrown when the pool invoking a hook isn't this market's junior tranche pool
    error ONLY_JUNIOR_TRANCHE_BALANCER_POOL();

    /// @notice Thrown when the Balancer pool is not registered with the Balancer V3 Vault
    error POOL_NOT_REGISTERED();

    /// @notice Thrown when the Balancer pool is not configured with exactly two tokens (ST share and the kernel's quote asset)
    error POOL_MUST_HAVE_TWO_TOKENS();

    /// @notice Thrown when the pool's tokens don't match the kernel's configured ST asset and quote asset
    error INVALID_POOL_TOKEN_CONFIGURATION();

    /// @dev Ensures that the pool invoking a hook is this market's junior tranche pool
    /// @param _pool The pool invoking the hook
    modifier onlyJuniorTrancheBalancerPool(address _pool) {
        require(_pool == JT_ASSET, ONLY_JUNIOR_TRANCHE_BALANCER_POOL());
        _;
    }

    /**
     * @notice Constructs the Junior Assets Balancer V3 pool tokens quoter
     * @dev Derives the Vault address from JT_ASSET via `BalancerPoolToken.getVault()`
     * @dev Caches the constituent token indices and per-token decimal scaling factors as immutables since they are fixed at pool registration
     */
    constructor() VaultGuard(BalancerPoolToken(JT_ASSET).getVault()) {
        // Ensure that the Balancer V3 Pool is registered with the vault
        require(_vault.isPoolRegistered(JT_ASSET), POOL_NOT_REGISTERED());

        // Retrieve the constituent tokens of this kernel's Balancer V3 pool and ensure that their are exactly 2
        IERC20[] memory tokens = _vault.getPoolTokens(JT_ASSET);
        require(tokens.length == 2, POOL_MUST_HAVE_TWO_TOKENS());

        // Resolve and cache the indexes of the ST share and the kernel's quote asset in the pool configuration
        // Revert if the pool is not configured with ST share and the kernel's quote asset as its constituents
        if (address(tokens[0]) == SENIOR_TRANCHE && address(tokens[1]) == QUOTE_ASSET) QUOTE_ASSET_POOL_INDEX = 1;
        else if (address(tokens[0]) == QUOTE_ASSET && address(tokens[1]) == SENIOR_TRANCHE) ST_SHARE_POOL_INDEX = 1;
        else revert INVALID_POOL_TOKEN_CONFIGURATION();

        // Cache the quote asset's per-token decimal scaling factor: `10^(18 - tokenDecimals)` matches the Balancer V3 derivation
        // NOTE: The senior tranche share is always 18 decimals, so its scaling factor is implicitly 1 and does not need to be cached
        QUOTE_ASSET_POOL_DECIMAL_SCALING_FACTOR = 10 ** (18 - IERC20Metadata(QUOTE_ASSET).decimals());
    }

    // =============================
    // Junior Tranche Liquidity Position Quoter Functions
    // =============================

    /**
     * @inheritdoc IRoycoDuskKernel
     * @notice Converts the specificed amount of BPTs into their pro-rata claim on the pool's constituent tokens
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
        // Mirror the Balancer V3 Vault's proportional remove liquidity path so that the position returned contains the exact same constituent token amounts that our JT withdrawals will deliver
        // Preemptively return zero claims if the pool has no outstanding claims on its constituent tokens
        uint256 bptTotalSupply = _vault.totalSupply(JT_ASSET);
        if (bptTotalSupply == 0) return claims;

        // Delegate the proportional math across the constituent tokens to Balancer's library to guarantee bit-for-bit equivalence with the kernel's liquidity position unwrap logic
        // NOTE: The live balances are the raw token amounts scaled by their corresponding rates, net of yield fees, normalized to WAD decimals
        uint256[] memory constituentTokenAmountsOutWAD =
            BasePoolMath.computeProportionalAmountsOut(_vault.getCurrentLiveBalances(JT_ASSET), bptTotalSupply, toUint256(_jtAssets));

        // Get the constituent token rates in NAV units used by the junior tranche pool
        /// NOTE: The rate providers for the junior tranche pool proxy this kernel's NAV for ST shares and quote assets
        (, uint256[] memory constituentTokenRatesWAD) = _vault.getPoolTokenRates(JT_ASSET);

        // Revert the decimal scaling normalization done by Balancer to the actual token precision
        // NOTE: The senior tranche share is always 18 decimals so its decimal scaling factor is implicitly 1
        claims.stShares = constituentTokenAmountsOutWAD[ST_SHARE_POOL_INDEX].toRawUndoRateRoundDown(1, constituentTokenRatesWAD[ST_SHARE_POOL_INDEX]);
        claims.quoteAssets = toQuoteUnits(
            constituentTokenAmountsOutWAD[QUOTE_ASSET_POOL_INDEX].toRawUndoRateRoundDown(
                QUOTE_ASSET_POOL_DECIMAL_SCALING_FACTOR, constituentTokenRatesWAD[QUOTE_ASSET_POOL_INDEX]
            )
        );
    }

    // =============================
    // Balancer V3 Liquidity Position Callback Function
    // =============================

    /**
     * @notice Callback that performs the proportional BPT unwrap inside the unlocked Balancer V3 Vault's context
     * @dev Only callable by the Balancer V3 Vault
     * @dev This callback must settle all credit and debt created in the vault's accounting by the end of its execution
     * @param _jtAssets The exact BPT amount (JT assets) to burn from this contract's balance
     * @param _receiver The recipient of the claims on the internal ST shares and quote assets withdrawn
     */
    function jtUnwrapBalancerV3LiquidityPosition(TRANCHE_UNIT _jtAssets, address _receiver) external onlyVault returns (uint256 internalSTSharesWithdrawn) {
        // Debit this kernel with the proportional constituent claims tied to the specified amount of JT assets
        (, uint256[] memory amountsOut,) = _vault.removeLiquidity(
            RemoveLiquidityParams({
                pool: JT_ASSET, // The Balancer pool to remove liquidity from is the junior tranche's asset (BPT)
                from: address(this), // The kernel custodies the BPT balance of the entire junior tranche, so the BPT constituents are debited from its claims
                maxBptAmountIn: toUint256(_jtAssets), // For PROPORTIONAL removals the Vault treats this as the exact BPT amount to burn (not an upper bound)
                minAmountsOut: new uint256[](2), // No slippage floors needed: PROPORTIONAL removals preserve the pool's invariant under any composition, so the unwrap is sandwich-resistant by construction
                kind: RemoveLiquidityKind.PROPORTIONAL, // Mirrors the pro-rata math used by `jtConvertTrancheUnitsToLPClaims` so the unwrap matches the quote
                userData: "" // PROPORTIONAL removals skip the pool's compute callback and this kernel's hooks do not consume userData
            })
        );
        // Credit the internal ST shares withdrawn to this kernel: these will be burnt and their claim on ST assets will be remitted to the receiver upstream
        _vault.sendTo(IERC20(SENIOR_TRANCHE), address(this), (internalSTSharesWithdrawn = amountsOut[ST_SHARE_POOL_INDEX]));
        // Credit the quote assets withdrawn directly to the specified receiver
        _vault.sendTo(IERC20(QUOTE_ASSET), _receiver, amountsOut[QUOTE_ASSET_POOL_INDEX]);
        /// @dev All credit and debt created during this callback has been settled
    }

    // =============================
    // Internal Utility Functions
    // =============================

    /// @inheritdoc RoycoDuskKernel
    /// @dev Unlocks the Balancer V3 Vault and dispatches into the unwrap liquidity position callback
    /// @dev The vault is required to be unlocked with a callback in order to transition into a transient accounting state, expecting the callback to settle all credit and debt before returning
    function _jtUnwrapLiquidityPosition(
        TRANCHE_UNIT _jtAssets,
        address _receiver
    )
        internal
        override(RoycoDuskKernel)
        returns (uint256 internalSTSharesWithdrawn)
    {
        // Unlock the Balancer vault, execute the callback to unwrap the specified units of the liquidity position, and return the internal ST shares withdrawn in the process
        bytes memory callbackReturnData = _vault.unlock(abi.encodeCall(this.jtUnwrapBalancerV3LiquidityPosition, (_jtAssets, _receiver)));
        assembly ("memory-safe") {
            internalSTSharesWithdrawn := mload(add(callbackReturnData, 0x20))
        }
    }
}
