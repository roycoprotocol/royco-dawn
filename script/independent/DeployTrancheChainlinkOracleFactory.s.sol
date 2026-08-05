// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoTrancheChainlinkOracleFactory } from "../../src/periphery/oracle/RoycoTrancheChainlinkOracleFactory.sol";

import { Create2DeployUtils } from "../utils/Create2DeployUtils.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

/**
 * @title DeployTrancheChainlinkOracleFactoryScript
 * @notice Deploys the RoycoTrancheChainlinkOracleFactory deterministically via CREATE2.
 *         Same factory address on every chain.
 *
 * Environment variables:
 *   DEPLOYER_PRIVATE_KEY - Key for the deployer account
 */
contract DeployTrancheChainlinkOracleFactoryScript is Create2DeployUtils {
    /// @dev The canonical Royco Factory address (same on every chain via CREATE2)
    address internal constant ROYCO_FACTORY = 0x7cC6fB28eC7b5e7afC3cB3986141797ffc27253C;

    /// @dev CREATE2 salt for the oracle factory
    bytes32 internal constant ORACLE_FACTORY_SALT = keccak256("ROYCO_TRANCHE_CHAINLINK_ORACLE_FACTORY");

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        bytes memory creationCode = abi.encodePacked(type(RoycoTrancheChainlinkOracleFactory).creationCode, abi.encode(ROYCO_FACTORY));

        vm.startBroadcast(deployerPrivateKey);
        (address oracleFactory, bool alreadyDeployed) = deployWithSanityChecks(ORACLE_FACTORY_SALT, creationCode, false);
        vm.stopBroadcast();

        console2.log(alreadyDeployed ? "Oracle Factory already deployed at:" : "Oracle Factory deployed at:", oracleFactory);
    }
}
