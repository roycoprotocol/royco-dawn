// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IAccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";

import { RolesConfiguration } from "../../../src/factory/RolesConfiguration.sol";
import { RoycoFactory } from "../../../src/factory/RoycoFactory.sol";

import { UpgradeModuleBase } from "./UpgradeModuleBase.sol";

/**
 * @title UpgradeFactoryModule
 * @notice Module for upgrading the singleton `RoycoFactory` (AccessManager) proxy on a chain.
 *
 * @dev Payload schema (ABI-encoded by the orchestrator):
 *        abi.encode()  -- empty; factory address is `getFactory(chainId)` from `UpgradeConfig`
 *
 *      The factory has no constructor arguments (`constructor() { _disableInitializers(); }`),
 *      so creation code is just `type(RoycoFactory).creationCode`.
 *
 *      Verification focuses on ownership + permission continuity:
 *        - `expiration()` — scheduled operations expiry timeout
 *        - For every role declared in `src/factory/RolesConfiguration.sol`:
 *            * role admin, role guardian, role grant-delay
 *            * membership of `ROOT_MULTISIG` and `EXECUTOR_MULTISIG` (is-member + execution delay)
 *      If any of these drift across the upgrade, `verify()` reverts.
 *
 *      Inherits `RolesConfiguration` directly so role-id constants are read from the same source
 *      of truth used by `RoycoFactory`. This removes a previous duplication risk where renaming a
 *      role in `RolesConfiguration` would silently misalign the verifier.
 *
 *      ⚠ ROLE-LIST MAINTENANCE: `_allRoles()` enumerates the role IDs to check. If a new role
 *      is added to `RolesConfiguration`, it MUST also be added here — otherwise verify will
 *      silently skip checking the new role's admin/guardian/grant-delay/membership across the
 *      upgrade. There is no compile-time link between this list and the source enum because
 *      Solidity does not support constant enumeration; treat this list as a checked invariant
 *      to update whenever `RolesConfiguration` changes.
 */
contract UpgradeFactoryModule is UpgradeModuleBase, RolesConfiguration {
    error UpgradeFactoryModule__NotAFactoryProxy(address proxy);
    error UpgradeFactoryModule__NewImplIdenticalToOld(address impl);
    error UpgradeFactoryModule__ExpirationChanged(uint32 expected, uint32 actual);
    error UpgradeFactoryModule__RoleAdminChanged(uint64 role, uint64 expected, uint64 actual);
    error UpgradeFactoryModule__RoleGuardianChanged(uint64 role, uint64 expected, uint64 actual);
    error UpgradeFactoryModule__RoleGrantDelayChanged(uint64 role, uint32 expected, uint32 actual);
    error UpgradeFactoryModule__MembershipChanged(uint64 role, address account, bool expectedIsMember, bool actualIsMember);
    error UpgradeFactoryModule__MembershipDelayChanged(uint64 role, address account, uint32 expectedDelay, uint32 actualDelay);

    /// @dev All roles declared in `RolesConfiguration` + the AccessManager admin role (id 0).
    ///      Ordering is stable so snapshot encoding and verification stay aligned.
    ///      Add an entry here when a new role is introduced in `RolesConfiguration`.
    function _allRoles() internal pure returns (uint64[] memory roles) {
        roles = new uint64[](16);
        roles[0] = _ADMIN_ROLE; // OpenZeppelin AccessManager default
        roles[1] = ADMIN_PAUSER_ROLE;
        roles[2] = ADMIN_UPGRADER_ROLE;
        roles[3] = ST_LP_ROLE;
        roles[4] = JT_LP_ROLE;
        roles[5] = BURNER_ROLE;
        roles[6] = SYNC_ROLE;
        roles[7] = ADMIN_KERNEL_ROLE;
        roles[8] = TRANSFER_AGENT_ROLE;
        roles[9] = ADMIN_ACCOUNTANT_ROLE;
        roles[10] = ADMIN_PROTOCOL_FEE_SETTER_ROLE;
        roles[11] = ADMIN_ORACLE_QUOTER_ROLE;
        roles[12] = DEPLOYER_ROLE;
        roles[13] = LP_ROLE_ADMIN_ROLE;
        roles[14] = DEPLOYER_ROLE_ADMIN_ROLE;
        roles[15] = GUARDIAN_ROLE;
    }

    /// @dev Accounts whose membership we snapshot per-role. Both multisigs cover the protocol's
    ///      ownership structure: ROOT holds admin/upgrader/kernel/accountant roles; EXECUTOR holds
    ///      guardian-style roles.
    function _accountsChecked() internal pure returns (address[] memory accounts) {
        accounts = new address[](2);
        accounts[0] = ROOT_MULTISIG;
        accounts[1] = EXECUTOR_MULTISIG;
    }

    /// @inheritdoc UpgradeModuleBase
    function prepare(
        uint256 _chainId,
        string memory _saltVersion,
        bytes memory /*_payload*/
    )
        external
        view
        override
        returns (PreparedUpgrade memory prepared)
    {
        address proxy = getFactory(_chainId);

        // Validate it's actually a factory: `expiration()` is a RoycoFactory-specific override.
        //   `IAccessManager.expiration()` returning non-zero also confirms the AccessManager
        //   storage is initialized.
        uint32 exp = IAccessManager(proxy).expiration();
        require(exp > 0, UpgradeFactoryModule__NotAFactoryProxy(proxy));

        address oldImpl = _readImplementation(proxy);

        // Factory has no constructor args
        bytes memory creationCode = type(RoycoFactory).creationCode;
        bytes32 salt = keccak256(abi.encodePacked("ROYCO_FACTORY_IMPLEMENTATION_", _saltVersion));

        address newImpl = _predictImpl(salt, creationCode);
        require(newImpl != oldImpl, UpgradeFactoryModule__NewImplIdenticalToOld(newImpl));

        string memory label = "Factory";

        prepared = PreparedUpgrade({
            proxy: proxy,
            oldImpl: oldImpl,
            newImpl: newImpl,
            implSalt: salt,
            implCreationCode: creationCode,
            call: UpgradeCall({
                marketName: "",
                target: proxy,
                callData: _buildUpgradeCallData(newImpl),
                description: string.concat("Upgrade Factory (AccessManager) implementation to ", vm.toString(newImpl))
            }),
            label: label
        });
    }

    /// @inheritdoc UpgradeModuleBase
    function snapshotState(address _proxy) external view override returns (bytes memory) {
        IAccessManager am = IAccessManager(_proxy);
        uint64[] memory roles = _allRoles();
        address[] memory accts = _accountsChecked();

        uint32 expiration = am.expiration();
        uint64[] memory roleAdmins = new uint64[](roles.length);
        uint64[] memory roleGuardians = new uint64[](roles.length);
        uint32[] memory roleGrantDelays = new uint32[](roles.length);
        // membership[i][j] = (isMember, executionDelay) for roles[i] × accts[j]
        bool[][] memory isMember = new bool[][](roles.length);
        uint32[][] memory memberDelay = new uint32[][](roles.length);

        for (uint256 i = 0; i < roles.length; i++) {
            roleAdmins[i] = am.getRoleAdmin(roles[i]);
            roleGuardians[i] = am.getRoleGuardian(roles[i]);
            roleGrantDelays[i] = am.getRoleGrantDelay(roles[i]);

            isMember[i] = new bool[](accts.length);
            memberDelay[i] = new uint32[](accts.length);
            for (uint256 j = 0; j < accts.length; j++) {
                (bool m, uint32 d) = am.hasRole(roles[i], accts[j]);
                isMember[i][j] = m;
                memberDelay[i][j] = d;
            }
        }

        return abi.encode(expiration, roles, accts, roleAdmins, roleGuardians, roleGrantDelays, isMember, memberDelay);
    }

    /// @inheritdoc UpgradeModuleBase
    function verify(address _proxy, bytes memory _preStateSnapshot) external view override {
        (
            uint32 preExp,
            uint64[] memory roles,
            address[] memory accts,
            uint64[] memory preAdmins,
            uint64[] memory preGuardians,
            uint32[] memory preGrantDelays,
            bool[][] memory preIsMember,
            uint32[][] memory preMemberDelay
        ) = abi.decode(_preStateSnapshot, (uint32, uint64[], address[], uint64[], uint64[], uint32[], bool[][], uint32[][]));

        IAccessManager am = IAccessManager(_proxy);

        uint32 postExp = am.expiration();
        require(postExp == preExp, UpgradeFactoryModule__ExpirationChanged(preExp, postExp));

        for (uint256 i = 0; i < roles.length; i++) {
            uint64 role = roles[i];

            uint64 admin = am.getRoleAdmin(role);
            require(admin == preAdmins[i], UpgradeFactoryModule__RoleAdminChanged(role, preAdmins[i], admin));

            uint64 guardian = am.getRoleGuardian(role);
            require(guardian == preGuardians[i], UpgradeFactoryModule__RoleGuardianChanged(role, preGuardians[i], guardian));

            uint32 grantDelay = am.getRoleGrantDelay(role);
            require(grantDelay == preGrantDelays[i], UpgradeFactoryModule__RoleGrantDelayChanged(role, preGrantDelays[i], grantDelay));

            for (uint256 j = 0; j < accts.length; j++) {
                (bool isMem, uint32 delay) = am.hasRole(role, accts[j]);
                require(isMem == preIsMember[i][j], UpgradeFactoryModule__MembershipChanged(role, accts[j], preIsMember[i][j], isMem));
                require(delay == preMemberDelay[i][j], UpgradeFactoryModule__MembershipDelayChanged(role, accts[j], preMemberDelay[i][j], delay));
            }
        }
    }
}
