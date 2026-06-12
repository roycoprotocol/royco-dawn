// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IHooks } from "../../../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IHooks.sol";
import { IVault } from "../../../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import {
    AddLiquidityKind,
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
 * @dev Kernel-initiated remove liquidity operations bypass the sync since the outer JT redeem flow already brackets the unwrap with its own pre/post syncs and re-routing through this hook would corrupt the accounting checkpoint
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
    function onBeforeInitialize(uint256[] memory, bytes memory) public override(BaseHooks) onlyVault returns (bool) {
        return _preLiquidityOpertionSyncTrancheAccounting();
    }

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
        return _preLiquidityOpertionSyncTrancheAccounting();
    }

    /// @inheritdoc IHooks
    /// @dev Skips the sync when invoked by the Royco Kernel: the outer JT redeem flow already brackets the unwrap with its own pre/post syncs
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
        return (_router == ROYCO_DUSK_KERNEL || _preLiquidityOpertionSyncTrancheAccounting());
    }

    /// @inheritdoc IHooks
    function onBeforeSwap(PoolSwapParams calldata, address _pool) public override(BaseHooks) onlyVault onlyJuniorTrancheBalancerV3Pool(_pool) returns (bool) {
        return _preLiquidityOpertionSyncTrancheAccounting();
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

    /**
     * @inheritdoc IHooks
     * @dev All liquidity operations execute a PNL accounting sync to ensure that accounting is fresh before the operation
     */
    function getHookFlags() public view virtual override(BaseHooks) returns (HookFlags memory) {
        return HookFlags({
            enableHookAdjustedAmounts: false,
            shouldCallBeforeInitialize: true,
            shouldCallAfterInitialize: false,
            shouldCallComputeDynamicSwapFee: false,
            shouldCallBeforeSwap: true,
            shouldCallAfterSwap: false,
            shouldCallBeforeAddLiquidity: true,
            shouldCallAfterAddLiquidity: false,
            shouldCallBeforeRemoveLiquidity: true,
            shouldCallAfterRemoveLiquidity: false
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
     * @return synced Always true on success; lets callers forward the result directly as the hook's required `bool` return
     */
    function _preLiquidityOpertionSyncTrancheAccounting() internal whenNotPaused returns (bool synced) {
        IRoycoDuskKernel(ROYCO_DUSK_KERNEL).syncTrancheAccounting();
        return true;
    }
}

