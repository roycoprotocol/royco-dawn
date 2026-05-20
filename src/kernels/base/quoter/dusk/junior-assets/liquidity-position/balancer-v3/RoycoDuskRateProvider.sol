// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRateProvider } from "../../../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";

/**
 * @title RoycoDuskRateProvider
 * @author Waymont
 * @notice Balancer V3 rate provider that proxies a Royco Dusk kernel's NAV oracle for one of its junior tranche pool's constituent tokens
 * @dev Mandated invariant for any Dusk JT pool: each constituent token's pool-registered rate provider MUST proxy the kernel's NAV oracle for that token, so the Balancer invariant math is denominated in NAV and the kernel's view-side quote stays bit-exact to the unwrap
 */
contract RoycoDuskRateProvider is IRateProvider {
    /// @inheritdoc IRateProvider
    function getRate() external view override(IRateProvider) returns (uint256 rate) { }
}
