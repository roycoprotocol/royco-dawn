// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IHooks } from "../../../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IHooks.sol";
import { IVault } from "../../../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import {
    AddLiquidityKind,
    AfterSwapParams,
    HookFlags,
    LiquidityManagement,
    PoolSwapParams,
    RemoveLiquidityKind,
    TokenConfig
} from "../../../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { BaseHooks } from "../../../../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/BaseHooks.sol";
import { VaultGuard } from "../../../../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/VaultGuard.sol";
import { RoycoBase } from "../../../../../../../base/RoycoBase.sol";
import { IRoycoDuskKernel } from "../../../../../../../interfaces/IRoycoDuskKernel.sol";

/**
 * @title RoycoDuskBalancerV3Hooks
 * @author Waymont
 * @notice Balancer V3 hook contract for a Dusk market's junior tranche pool that bridges the pool's liquidity operations into the kernel's tranche accounting
 * @notice Pre-op hooks (add liquidity, remove liquidity, swap) trigger a PNL sync on the kernel
 * @notice Post-op hooks trigger a NAV recomposition across internal and external ST shares followed by a PNL sync to apply trade-execution slippage and fees
 * @dev Kernel-initiated remove liquidity operations bypass both syncs since the outer JT redeem flow already brackets the unwrap with its own pre/post syncs and re-routing through this hook would corrupt the accounting checkpoint
 */
contract RoycoDuskBalancerV3Hooks is RoycoBase, BaseHooks, VaultGuard {
    /// @notice The Royco Dusk kernel this hook contract bridges Balancer V3 pool operations into
    address public immutable ROYCO_DUSK_KERNEL;

    /// @notice The junior tranche's Balancer V3 pool (the BPT) that this hook contract guards
    address public immutable JUNIOR_TRANCHE_BALANCER_V3_POOL;

    /// @notice Thrown when the pool invoking a hook isn't this market's junior tranche pool
    error ONLY_JUNIOR_TRANCHE_BALANCER_V3_POOL();

    /// @dev Ensures that the pool invoking a hook is this market's junior tranche pool
    /// @param _pool The pool invoking the hook
    modifier onlyJuniorTrancheBalancerV3Pool(address _pool) {
        require(_pool == JUNIOR_TRANCHE_BALANCER_V3_POOL, ONLY_JUNIOR_TRANCHE_BALANCER_V3_POOL());
        _;
    }

    // =============================
    // Construction and Initialization Functions
    // =============================

    /**
     * @notice Constructs the Royco Dusk Balancer V3 hooks contract
     * @dev Sets the immutable Vault reference via VaultGuard and pins the kernel address for this hook deployment; the junior tranche's Balancer V3 pool is derived from the kernel's `JT_ASSET`
     * @param _vault The Balancer V3 Vault that this hook contract is registered with
     * @param _roycoKernel The Royco Dusk kernel this hook contract bridges pool operations into
     */
    constructor(address _vault, address _roycoKernel) VaultGuard(IVault(_vault)) {
        require(_vault != address(0) && _roycoKernel != address(0), NULL_ADDRESS());
        ROYCO_DUSK_KERNEL = _roycoKernel;
        JUNIOR_TRANCHE_BALANCER_V3_POOL = IRoycoDuskKernel(_roycoKernel).JT_ASSET();
    }

    /**
     * @notice Initializes the Royco Dusk Balancer V3 hooks contract
     * @dev Concrete subclasses that need to layer in additional initialization may override this or chain via `__RoycoDuskBalancerV3Hooks_init`
     * @param _initialAuthority The initial authority for the contract
     */
    function initialize(address _initialAuthority) external virtual initializer {
        __RoycoDuskBalancerV3Hooks_init(_initialAuthority);
    }

    /**
     * @notice Initializes the base Royco Dusk Balancer V3 hooks state
     * @dev Concrete subclasses chain into this from their own `initialize` entrypoint if they need their own external initializer signature
     * @param _initialAuthority The initial authority for the contract
     */
    function __RoycoDuskBalancerV3Hooks_init(address _initialAuthority) internal onlyInitializing {
        __RoycoBase_init(_initialAuthority);
    }

    // =============================
    // Balancer V3 Pool Hook Callbacks
    // =============================

    /// @inheritdoc IHooks
    /// @dev The Royco Dusk Factory deploys the pool, which calls this function on the dummy implementation of this contract, prior to setting this implementation. Hence, this function is never called in normal operation.
    function onRegister(address, address, TokenConfig[] memory, LiquidityManagement calldata) public override(BaseHooks) onlyVault returns (bool) { }

    /// @inheritdoc IHooks
    function onBeforeInitialize(uint256[] memory, bytes memory) public override(BaseHooks) onlyVault returns (bool) { }

    /// @inheritdoc IHooks
    function onAfterInitialize(uint256[] memory, uint256, bytes memory) public override(BaseHooks) onlyVault returns (bool) { }

    /// @inheritdoc IHooks
    function onBeforeAddLiquidity(
        address,
        address _pool,
        AddLiquidityKind,
        uint256[] memory,
        uint256,
        uint256[] memory,
        bytes memory
    )
        public
        override(BaseHooks)
        onlyVault
        onlyJuniorTrancheBalancerV3Pool(_pool)
        returns (bool)
    {
        _preLiquidityOpertionSyncTrancheAccounting();
        return true;
    }

    /// @inheritdoc IHooks
    function onAfterAddLiquidity(
        address,
        address _pool,
        AddLiquidityKind,
        uint256[] memory,
        uint256[] memory amountsInRaw,
        uint256,
        uint256[] memory,
        bytes memory
    )
        public
        override(BaseHooks)
        onlyVault
        onlyJuniorTrancheBalancerV3Pool(_pool)
        returns (bool, uint256[] memory)
    {
        _postLiquidityOpertionSyncTrancheAccounting();
        return (true, amountsInRaw);
    }

    /// @inheritdoc IHooks
    /// @dev Skips the post-op sync when invoked by the Royco Kernel: the outer JT redeem flow already brackets them with its own pre/post syncs
    function onBeforeRemoveLiquidity(
        address _router,
        address _pool,
        RemoveLiquidityKind,
        uint256,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    )
        public
        override(BaseHooks)
        onlyVault
        onlyJuniorTrancheBalancerV3Pool(_pool)
        returns (bool)
    {
        if (_router != ROYCO_DUSK_KERNEL) _preLiquidityOpertionSyncTrancheAccounting();
        return true;
    }

    /// @inheritdoc IHooks
    /// @dev Skips the post-op sync when invoked by the Royco Kernel: the outer JT redeem flow already brackets them with its own pre/post syncs
    function onAfterRemoveLiquidity(
        address _router,
        address _pool,
        RemoveLiquidityKind,
        uint256,
        uint256[] memory,
        uint256[] memory amountsOutRaw,
        uint256[] memory,
        bytes memory
    )
        public
        override(BaseHooks)
        onlyVault
        onlyJuniorTrancheBalancerV3Pool(_pool)
        returns (bool, uint256[] memory)
    {
        if (_router != ROYCO_DUSK_KERNEL) _postLiquidityOpertionSyncTrancheAccounting();
        return (true, amountsOutRaw);
    }

    /// @inheritdoc IHooks
    function onBeforeSwap(PoolSwapParams calldata, address _pool) public override(BaseHooks) onlyVault onlyJuniorTrancheBalancerV3Pool(_pool) returns (bool) {
        _preLiquidityOpertionSyncTrancheAccounting();
        return true;
    }

    /// @inheritdoc IHooks
    function onAfterSwap(AfterSwapParams calldata _params)
        public
        override(BaseHooks)
        onlyVault
        onlyJuniorTrancheBalancerV3Pool(_params.pool)
        returns (bool, uint256)
    {
        _postLiquidityOpertionSyncTrancheAccounting();
        return (true, _params.amountCalculatedRaw);
    }

    /// @inheritdoc IHooks
    function onComputeDynamicSwapFeePercentage(
        PoolSwapParams calldata,
        address _pool,
        uint256
    )
        public
        view
        override(BaseHooks)
        onlyVault
        onlyJuniorTrancheBalancerV3Pool(_pool)
        returns (bool, uint256)
    { }

    /// @inheritdoc IHooks
    function getHookFlags() public view virtual override(BaseHooks) returns (HookFlags memory) {
        return HookFlags({
            enableHookAdjustedAmounts: false,
            shouldCallBeforeInitialize: false,
            shouldCallAfterInitialize: false,
            shouldCallComputeDynamicSwapFee: false,
            // All liquidity operations execute a PNL accounting sync to ensure that accounting is fresh before the operation
            // All liquidity operations execute a NAV recomposition, reconciling the new internal and external ST shares, and a PNL sync, applying trade execution slippage and fees, after the operation
            shouldCallBeforeSwap: true,
            shouldCallAfterSwap: true,
            shouldCallBeforeAddLiquidity: true,
            shouldCallAfterAddLiquidity: true,
            shouldCallBeforeRemoveLiquidity: true,
            shouldCallAfterRemoveLiquidity: true
        });
    }

    // =============================
    // Internal Tranche Accounting Synchronization Helpers
    // =============================

    /**
     * @notice Routes a pre-operation tranche accounting sync into the kernel
     * @dev Intended to be invoked from every `onBefore*` hook (add/remove liquidity, swap) so the kernel captures any oracle drift on the senior side before the operation mutates the pool's composition
     * @dev Requires this hook contract to hold the SYNCER role on the kernel
     * @dev Reverts if this hook contract is paused
     */
    function _preLiquidityOpertionSyncTrancheAccounting() internal whenNotPaused {
        IRoycoDuskKernel(ROYCO_DUSK_KERNEL).syncTrancheAccounting();
    }

    /**
     * @notice Routes a post-operation tranche accounting sync into the kernel
     * @dev Intended to be invoked from every `onAfter*` hook (add/remove liquidity, swap) so the kernel runs the recomposition checkpoint (reconciling the new internal vs external ST share distribution) and applies the post-op PNL waterfall
     * @dev Requires this hook contract to hold the SYNCER role on the kernel
     * @dev Reverts if this hook contract is paused
     */
    function _postLiquidityOpertionSyncTrancheAccounting() internal whenNotPaused {
        IRoycoDuskKernel(ROYCO_DUSK_KERNEL).postLiquidityPositionOpSyncTrancheAccounting();
    }
}
