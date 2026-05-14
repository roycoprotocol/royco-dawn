// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AccessManagedUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";

/**
 * @title MockRestrictedTarget
 * @notice One restricted no-op function per role. Each function gets a unique selector,
 *         so the factory can map it to a different role via setTargetFunctionRole.
 * @dev Used by RoleDelaysTest to validate AccessManager delay enforcement on `restricted`
 *      functions for every role declared in RolesConfiguration.
 */
contract MockRestrictedTarget is AccessManagedUpgradeable {
    function initialize(address _authority) external initializer {
        __AccessManaged_init(_authority);
    }

    function callAdminPauser() external restricted { }
    function callAdminUnpauser() external restricted { }
    function callAdminUpgrader() external restricted { }
    function callAdminKernel() external restricted { }
    function callAdminAccountant() external restricted { }
    function callAdminProtocolFeeSetter() external restricted { }
    function callAdminOracleQuoter() external restricted { }
    function callStLp() external restricted { }
    function callJtLp() external restricted { }
    function callLpRoleAdmin() external restricted { }
    function callSync() external restricted { }
    function callTransferAgent() external restricted { }
    function callDeployer() external restricted { }
    function callDeployerAdmin() external restricted { }
    function callGuardian() external restricted { }
}
