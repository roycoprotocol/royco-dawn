// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { BaseTest } from "../base/BaseTest.t.sol";

/// @title DeploymentScriptRerunTest
/// @notice Tests that the deployment script can be run twice without reverting.
/// @dev Pre-migration this exercised the legacy `DeployScript`. That entrypoint is gone
///      now — market deployment is template-driven via `RoycoFactory.executeMarketDeployment`,
///      and idempotency is enforced by CREATE3 collision guards inside the factory
///      (e.g. `MARKET_COMPONENT_ALREADY_DEPLOYED`). Every test is currently skipped pending
///      a rewrite against that new surface.
contract DeploymentScriptRerunTest is BaseTest {
    function setUp() public {
        _setUpRoyco();
    }

    // ============================================
    // DEPLOYMENT RERUN TESTS
    // ============================================

    /// @notice Test that the deployment script can be run twice - first deploy, then deploy a new market
    function test_deploymentScript_canRunTwice_differentMarkets() public {
        // TODO(post-migration): rewrite to test factory.executeMarketDeployment idempotency
        // via CREATE3 collision guard (MARKET_COMPONENT_ALREADY_DEPLOYED).
        vm.skip(true);
    }

    /// @notice Test that the deployment script properly configures roles on both runs
    function test_deploymentScript_rolesConfiguredOnBothRuns() public {
        // TODO(post-migration): rewrite to test factory.executeMarketDeployment idempotency
        // via CREATE3 collision guard (MARKET_COMPONENT_ALREADY_DEPLOYED).
        vm.skip(true);
    }

    /// @notice Test that deployer can deploy multiple markets using the factory's deployMarket function
    function test_deployerCanDeployMultipleMarketsViaFactory() public {
        // TODO(post-migration): rewrite to test factory.executeMarketDeployment idempotency
        // via CREATE3 collision guard (MARKET_COMPONENT_ALREADY_DEPLOYED).
        vm.skip(true);
    }

    /// @notice Test that the same deployer can use the factory after ownership transfer
    function test_deployerRetainsRoleAfterOwnershipTransfer() public {
        // TODO(post-migration): rewrite to test factory.executeMarketDeployment idempotency
        // via CREATE3 collision guard (MARKET_COMPONENT_ALREADY_DEPLOYED).
        vm.skip(true);
    }
}
