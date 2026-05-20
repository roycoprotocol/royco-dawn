// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IHooks } from "../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IHooks.sol";
import { IVault } from "../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
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
import { VaultGuard } from "../../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/VaultGuard.sol";
import { RoycoBase } from "../../../../../base/RoycoBase.sol";
import { IRoycoDuskKernel } from "../../../../../interfaces/IRoycoDuskKernel.sol";

/**
 * @title RoycoDuskBalancerV3HooksStub
 * @author Waymont
 * @notice Balancer V3 hook contract for a Dusk market's junior tranche pool that does nothing
 */
contract RoycoDuskBalancerV3HooksStub is BaseHooks, VaultGuard {
    constructor(IVault _vault) VaultGuard(_vault) { }

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
        returns (bool, uint256[] memory)
    { }

    /// @inheritdoc IHooks
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
        returns (bool)
    { }

    /// @inheritdoc IHooks
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
        returns (bool, uint256[] memory)
    { }

    /// @inheritdoc IHooks
    function onBeforeSwap(PoolSwapParams calldata, address _pool) public override(BaseHooks) returns (bool) {
        return true;
    }

    /// @inheritdoc IHooks
    function onAfterSwap(AfterSwapParams calldata _params) public override(BaseHooks) returns (bool, uint256) { }

    /// @inheritdoc IHooks
    function onComputeDynamicSwapFeePercentage(PoolSwapParams calldata, address _pool, uint256) public view override(BaseHooks) returns (bool, uint256) { }

    /// @inheritdoc IHooks
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
