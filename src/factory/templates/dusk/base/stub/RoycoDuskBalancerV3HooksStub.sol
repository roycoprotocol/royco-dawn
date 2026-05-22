// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { HookFlags, LiquidityManagement, TokenConfig } from "../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { BaseHooks } from "../../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/BaseHooks.sol";
import { UUPSUpgradeable } from "../../../../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title RoycoDuskBalancerV3HooksStub
 * @notice Stateless stub Balancer V3 hook impl placed behind the hooks proxy at pool-registration time.
 *
 * @dev Surface area pared down to what Balancer reads + caches at pool registration:
 *      - `onRegister` callback
 *      - `getHookFlags` (cached immutably on the pool — MUST match the real hooks impl exactly)
 */
contract RoycoDuskBalancerV3HooksStub is BaseHooks, UUPSUpgradeable {
    function initialize(address) external { }

    function _authorizeUpgrade(address) internal view override { }

    function onRegister(address, address, TokenConfig[] memory, LiquidityManagement calldata) public override(BaseHooks) returns (bool) {
        return true;
    }

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
