// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IAccessManager } from "../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { RoycoRoles } from "../src/auth/RoycoRoles.sol";
import { Script } from "lib/forge-std/src/Script.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

contract GrantRolesScript is Script, RoycoRoles {
    function run() external {
        // Read deployer private key
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Read AccessManager address (factory address)
        address accessManagerAddress = vm.envAddress("ACCESS_MANAGER_ADDRESS");
        IAccessManager accessManager = IAccessManager(accessManagerAddress);

        // Read role addresses
        address pauser = vm.envAddress("PAUSER_ADDRESS");
        address upgrader = vm.envAddress("UPGRADER_ADDRESS");
        address depositRole = vm.envAddress("DEPOSIT_ROLE_ADDRESS");
        address redeemRole = vm.envAddress("REDEEM_ROLE_ADDRESS");
        address cancelDepositRole = vm.envAddress("CANCEL_DEPOSIT_ROLE_ADDRESS");
        address cancelRedeemRole = vm.envAddress("CANCEL_REDEEM_ROLE_ADDRESS");
        address syncRole = vm.envAddress("SYNC_ROLE_ADDRESS");
        address kernelAdmin = vm.envAddress("KERNEL_ADMIN_ROLE_ADDRESS");

        console2.log("Granting roles on AccessManager:", accessManagerAddress);

        // Grant all roles on the shared AccessManager
        _grantAllRoles(accessManager, pauser, upgrader, depositRole, redeemRole, cancelDepositRole, cancelRedeemRole, syncRole, kernelAdmin);

        console2.log("All roles granted successfully!");

        vm.stopBroadcast();
    }

    function _grantAllRoles(
        IAccessManager accessManager,
        address pauser,
        address upgrader,
        address depositRole,
        address redeemRole,
        address cancelDepositRole,
        address cancelRedeemRole,
        address syncRole,
        address kernelAdmin
    )
        internal
    {
        // Grant PAUSER_ROLE (used by ST, JT, Kernel, Accountant)
        accessManager.grantRole(PAUSER_ROLE, pauser, 0);
        console2.log("  - PAUSER_ROLE granted to:", pauser);

        // Grant UPGRADER_ROLE (used by ST, JT, Kernel, Accountant for UUPS upgrades)
        accessManager.grantRole(UPGRADER_ROLE, upgrader, 0);
        console2.log("  - UPGRADER_ROLE granted to:", upgrader);

        // Grant DEPOSIT_ROLE (used by ST, JT)
        accessManager.grantRole(DEPOSIT_ROLE, depositRole, 0);
        console2.log("  - DEPOSIT_ROLE granted to:", depositRole);

        // Grant REDEEM_ROLE (used by ST, JT)
        accessManager.grantRole(REDEEM_ROLE, redeemRole, 0);
        console2.log("  - REDEEM_ROLE granted to:", redeemRole);

        // Grant CANCEL_DEPOSIT_ROLE (used by ST, JT)
        accessManager.grantRole(CANCEL_DEPOSIT_ROLE, cancelDepositRole, 0);
        console2.log("  - CANCEL_DEPOSIT_ROLE granted to:", cancelDepositRole);

        // Grant CANCEL_REDEEM_ROLE (used by ST, JT)
        accessManager.grantRole(CANCEL_REDEEM_ROLE, cancelRedeemRole, 0);
        console2.log("  - CANCEL_REDEEM_ROLE granted to:", cancelRedeemRole);

        // Grant SYNC_ROLE (used by Kernel)
        accessManager.grantRole(SYNC_ROLE, syncRole, 0);
        console2.log("  - SYNC_ROLE granted to:", syncRole);

        // Grant KERNEL_ADMIN_ROLE (used by Kernel, Accountant)
        accessManager.grantRole(KERNEL_ADMIN_ROLE, kernelAdmin, 0);
        console2.log("  - KERNEL_ADMIN_ROLE granted to:", kernelAdmin);
    }
}
