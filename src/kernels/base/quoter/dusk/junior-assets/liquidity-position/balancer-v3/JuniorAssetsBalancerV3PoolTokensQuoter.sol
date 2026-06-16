// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RemoveLiquidityKind, RemoveLiquidityParams } from "../../../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { BalancerPoolToken } from "../../../../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/BalancerPoolToken.sol";
import { VaultGuard } from "../../../../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/VaultGuard.sol";
import { IERC20Metadata } from "../../../../../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { IERC20 } from "../../../../../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { QUOTE_UNIT, TRANCHE_UNIT, toUint256 } from "../../../../../../../libraries/Units.sol";
import { SyncedAccountingState } from "../../../../../../../libraries/Types.sol";
import { RoycoDuskKernel } from "../../../../../RoycoDuskKernel.sol";

/**
 * @title JuniorAssetsBalancerV3PoolTokensQuoter
 * @notice A quoter for Dusk Kernels using Balancer V3 pools (ST share <> Quote asset) as their secondary liquidity venue
 * @notice The junior tranche asset is a Balancer Pool Token (BPT) between this kernel's senior tranche share and quote asset
 * @dev The Junior Tranche's BPT (Balancer Pool Token) represents its liquidity position in the pool
 */
abstract contract JuniorAssetsBalancerV3PoolTokensQuoter is RoycoDuskKernel, VaultGuard {
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
     * @dev Takes the JT pool address as a direct constructor argument - the immutable JT_ASSET is not initialized yet at construction header-evaluation time.
     * @param _jtAssetForVault The JT pool (BPT) address - must match the inherited `JT_ASSET` immutable.
     */
    constructor(address _jtAssetForVault) VaultGuard(BalancerPoolToken(_jtAssetForVault).getVault()) {
        // Sanity-check the param matches the inherited immutable so callers can't supply
        // a different pool to back the VaultGuard from the one configured in the kernel.
        require(_jtAssetForVault == JT_ASSET, POOL_NOT_REGISTERED());
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
    // JT Deposit Helper Functions
    // =============================
    function jtBuildPositionFromSTUnderlyingAndQuoteAsset(
        TRANCHE_UNIT _stUnderlying,
        QUOTE_UNIT _quoteAsset
    )
        external
        restricted
        whenNotPaused
        nonReentrant
        withQuoterCache
        returns (uint256 jtShares)
    {
        // Execute an accounting sync to reconcile underlying PNL
        SyncedAccountingState memory state = _preOpSyncTrancheAccounting();
    }

    // =============================
    // Balancer V3 Liquidity Position Callback Function
    // =============================

    /**
     * @notice Callback that performs the proportional BPT unwrap inside the unlocked Balancer V3 Vault's context
     * @dev Only callable by the Balancer V3 Vault
     * @dev This callback must settle all credit and debt created in the vault's accounting by the end of its execution
     * @param _jtAssets The exact BPT amount (JT assets) to burn from this contract's balance
     * @param _receiver The recipient of the quote assets withdrawn
     * @return stSharesWithdrawn The senior tranche shares withdrawn back to this kernel by the unwrap
     */
    function jtUnwrapBalancerV3LiquidityPosition(TRANCHE_UNIT _jtAssets, address _receiver) external onlyVault returns (uint256 stSharesWithdrawn) {
        // Debit this kernel with the proportional constituent claims tied to the specified amount of JT assets
        (, uint256[] memory amountsOut,) = _vault.removeLiquidity(
            RemoveLiquidityParams({
                pool: JT_ASSET, // The Balancer pool to remove liquidity from is the junior tranche's asset (BPT)
                from: address(this), // The kernel custodies the BPT balance of the entire junior tranche, so the BPT constituents are debited from its claims
                maxBptAmountIn: toUint256(_jtAssets), // For PROPORTIONAL removals the Vault treats this as the exact BPT amount to burn (not an upper bound)
                minAmountsOut: new uint256[](2), // No slippage floors needed: PROPORTIONAL removals preserve the pool's invariant under any composition, so the unwrap is sandwich-resistant by construction
                kind: RemoveLiquidityKind.PROPORTIONAL, // Proportional removals preserve the pool's composition, so the unwrap requires no pricing
                userData: "" // PROPORTIONAL removals skip the pool's compute callback and this kernel's hooks do not consume userData
            })
        );
        // Credit the ST shares withdrawn to this kernel: their handling is wired by the Dusk redemption flow
        _vault.sendTo(IERC20(SENIOR_TRANCHE), address(this), (stSharesWithdrawn = amountsOut[ST_SHARE_POOL_INDEX]));
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
        returns (uint256 stSharesWithdrawn)
    {
        // Unlock the Balancer vault, execute the callback to unwrap the specified units of the liquidity position, and return the ST shares withdrawn in the process
        bytes memory callbackReturnData = _vault.unlock(abi.encodeCall(this.jtUnwrapBalancerV3LiquidityPosition, (_jtAssets, _receiver)));
        assembly ("memory-safe") {
            stSharesWithdrawn := mload(add(callbackReturnData, 0x20))
        }
    }
}
