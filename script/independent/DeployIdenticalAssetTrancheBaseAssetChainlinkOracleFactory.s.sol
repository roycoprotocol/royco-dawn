// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {
    RoycoIdenticalAssetTrancheBaseAssetChainlinkOracleFactory
} from "../../src/periphery/oracle/RoycoIdenticalAssetTrancheBaseAssetChainlinkOracleFactory.sol";

import { Create2DeployUtils } from "../utils/Create2DeployUtils.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

/**
 * @title DeployIdenticalAssetTrancheBaseAssetChainlinkOracleFactoryScript
 * @notice Deploys the RoycoIdenticalAssetTrancheBaseAssetChainlinkOracleFactory deterministically via CREATE2.
 *         Same factory address on every chain.
 *
 * Environment variables:
 *   DEPLOYER_PRIVATE_KEY - Key for the deployer account
 */
contract DeployIdenticalAssetTrancheBaseAssetChainlinkOracleFactoryScript is Create2DeployUtils {
    address internal ROYCO_FACTORY = block.chainid == 8453 ? 0x568c9709DaA2f7B7cc66AbC3E41DA0f0A339551A : 0x7cC6fB28eC7b5e7afC3cB3986141797ffc27253C;

    /// @dev CREATE2 salt for the oracle factory
    bytes32 internal constant ORACLE_FACTORY_SALT = keccak256("ROYCO_IDENTICAL_ASSET_TRANCHE_BASE_ASSET_CHAINLINK_ORACLE_FACTORY");

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        bytes memory creationCode = abi.encodePacked(type(RoycoIdenticalAssetTrancheBaseAssetChainlinkOracleFactory).creationCode, abi.encode(ROYCO_FACTORY));

        vm.startBroadcast(deployerPrivateKey);
        (address oracleFactory, bool alreadyDeployed) = deployWithSanityChecks(ORACLE_FACTORY_SALT, creationCode, false);
        vm.stopBroadcast();

        console2.log(alreadyDeployed ? "Oracle Factory already deployed at:" : "Oracle Factory deployed at:", oracleFactory);
    }
}
