// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

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
import { BaseHooks, IHooks } from "../../../../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/BaseHooks.sol";
import { VaultGuard } from "../../../../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/VaultGuard.sol";
import { RoycoBase } from "../../../../../../../base/RoycoBase.sol";

/**
 * @title RoycoDuskBalancerV3Hooks
 * @notice Balancer V3 hook contract for the Dusk junior tranche pool: bridges every external pool operation (initialize, add/remove liquidity, swap) to the kernel's tranche accounting synchronization
 * @dev Inherits from BaseHooks so only the callbacks the kernel actually consumes need to be overridden; all other IHooks callbacks fall through to BaseHooks' default no-op implementations
 * @dev Inherits from RoycoBase so this contract is UUPS-upgradeable and access-managed by the singleton AccessManager, consistent with other Royco protocol contracts (kernel, accountant, tranches)
 */
abstract contract RoycoDuskBalancerV3Hooks is RoycoBase, BaseHooks, VaultGuard {
    /// @notice Thrown when the pool invoking a hook isn't this market's junior tranche pool
    error ONLY_JUNIOR_TRANCHE_BALANCER_POOL();

    /// @dev Ensures that the pool invoking a hook is this market's junior tranche pool
    /// @param _pool The pool invoking the hook
    modifier onlyJuniorTrancheBalancerPool(address _pool) {
        require(_pool == _juniorTrancheBalancerPool(), ONLY_JUNIOR_TRANCHE_BALANCER_POOL());
        _;
    }

    // =============================
    // Construction and Initialization Functions
    // =============================

    /// @notice Constructs the Royco Dusk Balancer V3 hooks contract
    /// @dev Sets the immutable Vault reference via VaultGuard; concrete subclasses forward the Vault address from their own constructors
    /// @param _vault The Balancer V3 Vault that this hook contract is registered with
    constructor(IVault _vault, address _roycoKernel) VaultGuard(_vault) { }

    /// @notice Initializes the Royco Dusk Balancer V3 hooks contract
    /// @dev Concrete subclasses chain into this from their own `initialize` entrypoint
    /// @param _initialAuthority The initial authority for the contract
    function __RoycoDuskBalancerV3Hooks_init(address _initialAuthority) internal onlyInitializing {
        __RoycoBase_init(_initialAuthority);
    }

    // =============================
    // Balancer V3 Pool Hook Callbacks
    // =============================

    /// @inheritdoc IHooks
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
        onlyJuniorTrancheBalancerPool(_pool)
        returns (bool)
    { }

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
        onlyJuniorTrancheBalancerPool(_pool)
        returns (bool, uint256[] memory)
    { }

    /// @inheritdoc IHooks
    function onBeforeRemoveLiquidity(
        address,
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
        onlyJuniorTrancheBalancerPool(_pool)
        returns (bool)
    { }

    /// @inheritdoc IHooks
    function onAfterRemoveLiquidity(
        address,
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
        onlyJuniorTrancheBalancerPool(_pool)
        returns (bool, uint256[] memory)
    { }

    /// @inheritdoc IHooks
    function onBeforeSwap(PoolSwapParams calldata, address _pool) public override(BaseHooks) onlyVault onlyJuniorTrancheBalancerPool(_pool) returns (bool) { }

    /// @inheritdoc IHooks
    function onAfterSwap(AfterSwapParams calldata _params)
        public
        override(BaseHooks)
        onlyVault
        onlyJuniorTrancheBalancerPool(_params.pool)
        returns (bool, uint256)
    { }

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
        onlyJuniorTrancheBalancerPool(_pool)
        returns (bool, uint256)
    { }

    /// @inheritdoc IHooks
    function getHookFlags() public view override(BaseHooks) returns (HookFlags memory) { }

    /// @notice Returns the address of the junior tranche's Balancer V3 pool (the BPT) that this hook contract guards
    /// @return The junior tranche pool address
    function _juniorTrancheBalancerPool() internal view virtual returns (address);
}
