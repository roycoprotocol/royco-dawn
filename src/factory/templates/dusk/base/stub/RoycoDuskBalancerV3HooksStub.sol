// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IHooks } from "../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IHooks.sol";
import {
    AddLiquidityKind,
    AfterSwapParams,
    HookFlags,
    LiquidityManagement,
    PoolSwapParams,
    RemoveLiquidityKind,
    TokenConfig
} from "../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { BaseHooks } from "../../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/BaseHooks.sol";
import { Initializable } from "../../../../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "../../../../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title RoycoDuskBalancerV3HooksStub
 * @author Waymont
 * @notice Stub Balancer V3 hook impl placed behind the hooks proxy at pool-registration time.
 *
 * @dev The hooks contract address is baked into the Balancer pool config at `pool.create()` time
 *      (immutable on the Balancer side). Since the real hooks impl needs the kernel address —
 *      which doesn't exist yet when the pool is being registered — we register the pool against
 *      a PROXY whose initial impl is this stub. Once the kernel is live, the deployment template
 *      upgrades the proxy to the real hooks impl.
 *
 *      This stub is a no-op on every hook callback (no `onlyVault` gating — it's only ever
 *      reachable during the brief pool-creation window before the upgrade replaces it).
 *      `getHookFlags()` must match the real hooks impl exactly, since the Balancer Vault
 *      reads the flags ONCE during pool registration (via `onRegister`) and caches them
 *      immutably on the pool. Any divergence between stub flags and real-impl flags would
 *      lock the pool into the wrong callback pattern.
 *
 *      `initialize(address)` mirrors the real hooks impl's signature so the same
 *      `abi.encodeCall` callsite works for both stub and real impl.
 */
contract RoycoDuskBalancerV3HooksStub is BaseHooks, Initializable, UUPSUpgradeable {
    /// @dev Stored authority — used to gate UUPS upgrades on the real hooks impl. The stub
    ///      itself doesn't gate upgrades (the template performs the upgrade-from-stub during
    ///      its active deployment window).
    address private _authority;

    constructor() {
        _disableInitializers();
    }

    /// @notice One-shot init. Same signature as the real hooks impl so the template can encode a
    ///         single `upgradeToAndCall` payload that targets either.
    function initialize(address _initialAuthority) external initializer {
        _authority = _initialAuthority;
    }

    /// @inheritdoc UUPSUpgradeable
    /// @dev Open in the stub — the upgrade-from-stub is performed by the deployment template
    ///      inside its active `executeMarketDeployment` window. The real hooks impl gates this.
    function _authorizeUpgrade(address) internal view override { }

    // =============================
    // Balancer V3 Pool Hook Callbacks — all no-ops on the stub.
    // =============================

    /// @inheritdoc IHooks
    function onRegister(address, address, TokenConfig[] memory, LiquidityManagement calldata) public override(BaseHooks) returns (bool) {
        return true;
    }

    /// @inheritdoc IHooks
    function onBeforeInitialize(uint256[] memory, bytes memory) public override(BaseHooks) returns (bool) {
        return true;
    }

    /// @inheritdoc IHooks
    function onAfterInitialize(uint256[] memory, uint256, bytes memory) public override(BaseHooks) returns (bool) {
        return true;
    }

    /// @inheritdoc IHooks
    function onBeforeAddLiquidity(
        address,
        address,
        AddLiquidityKind,
        uint256[] memory,
        uint256,
        uint256[] memory,
        bytes memory
    )
        public
        override(BaseHooks)
        returns (bool)
    {
        return true;
    }

    /// @inheritdoc IHooks
    function onAfterAddLiquidity(
        address,
        address,
        AddLiquidityKind,
        uint256[] memory,
        uint256[] memory amountsInRaw,
        uint256,
        uint256[] memory,
        bytes memory
    )
        public
        override(BaseHooks)
        returns (bool, uint256[] memory)
    {
        return (true, amountsInRaw);
    }

    /// @inheritdoc IHooks
    function onBeforeRemoveLiquidity(
        address,
        address,
        RemoveLiquidityKind,
        uint256,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    )
        public
        override(BaseHooks)
        returns (bool)
    {
        return true;
    }

    /// @inheritdoc IHooks
    function onAfterRemoveLiquidity(
        address,
        address,
        RemoveLiquidityKind,
        uint256,
        uint256[] memory,
        uint256[] memory amountsOutRaw,
        uint256[] memory,
        bytes memory
    )
        public
        override(BaseHooks)
        returns (bool, uint256[] memory)
    {
        return (true, amountsOutRaw);
    }

    /// @inheritdoc IHooks
    function onBeforeSwap(PoolSwapParams calldata, address) public override(BaseHooks) returns (bool) {
        return true;
    }

    /// @inheritdoc IHooks
    function onAfterSwap(AfterSwapParams calldata) public override(BaseHooks) returns (bool, uint256) {
        return (true, 0);
    }

    /// @inheritdoc IHooks
    function onComputeDynamicSwapFeePercentage(PoolSwapParams calldata, address, uint256) public view override(BaseHooks) returns (bool, uint256) {
        return (true, 0);
    }

    /// @inheritdoc IHooks
    /// @dev MUST match the real hooks impl (`RoycoDuskBalancerV3Hooks`) exactly. Balancer reads
    ///      these flags ONCE during pool registration and caches them immutably on the pool.
    /// TODO: Test to make sure that this is the same as the real hooks impl (`RoycoDuskBalancerV3Hooks`) exactly.
    function getHookFlags() public view virtual override(BaseHooks) returns (HookFlags memory) {
        return HookFlags({
            enableHookAdjustedAmounts: false,
            shouldCallBeforeInitialize: false,
            shouldCallAfterInitialize: false,
            shouldCallComputeDynamicSwapFee: false,
            shouldCallBeforeSwap: true,
            shouldCallAfterSwap: true,
            shouldCallBeforeAddLiquidity: true,
            shouldCallAfterAddLiquidity: true,
            shouldCallBeforeRemoveLiquidity: true,
            shouldCallAfterRemoveLiquidity: true
        });
    }
}
