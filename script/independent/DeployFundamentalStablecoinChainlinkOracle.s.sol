// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { FundamentalStablecoinChainlinkOracle } from "../../src/periphery/oracle/FundamentalStablecoinChainlinkOracle.sol";
import { FundamentalStablecoinChainlinkOracleDeploymentConfig } from "../config/FundamentalStablecoinChainlinkOracleDeploymentConfig.sol";
import { Create2DeployUtils } from "../utils/Create2DeployUtils.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

/**
 * @title DeployFundamentalStablecoinChainlinkOracleScript
 * @notice Deploys a FundamentalStablecoinChainlinkOracle deterministically via CREATE2.
 * Environment variables:
 *   DEPLOYER_PRIVATE_KEY - Key for the deployer account
 *   FUNDAMENTAL_STABLECOIN_CHAINLINK_ORACLE_CONFIG_NAME - Named config to deploy (e.g., MAINNET_USDC_USD, MAINNET_CUSD_USD)
 */
contract DeployFundamentalStablecoinChainlinkOracleScript is FundamentalStablecoinChainlinkOracleDeploymentConfig, Create2DeployUtils {
    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev CREATE2 salt base for the fundamental stablecoin peg oracle
    bytes32 internal constant FUNDAMENTAL_STABLECOIN_CHAINLINK_ORACLE_SALT = keccak256("ROYCO_FUNDAMENTAL_STABLECOIN_CHAINLINK_ORACLE");

    // ═══════════════════════════════════════════════════════════════════════════
    // ENTRY POINT
    // ═══════════════════════════════════════════════════════════════════════════

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        string memory oracleConfigName = vm.envString("FUNDAMENTAL_STABLECOIN_CHAINLINK_ORACLE_CONFIG_NAME");

        OracleConfig memory config = getOracleConfig(oracleConfigName);
        address oracle = deployOracle(config.underlyingOracle, config.minPegPrice, deployerPrivateKey);

        console2.log("");
        console2.log("========================================");
        console2.log("Fundamental Stablecoin Oracle deployed");
        console2.log("  Config:", oracleConfigName);
        console2.log("  Oracle:", oracle);
        console2.log("  Underlying oracle:", config.underlyingOracle);
        console2.log("  Min peg price:", config.minPegPrice);
        console2.log("  Chain ID:", config.chainId);
        console2.log("========================================");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deploys a FundamentalStablecoinChainlinkOracle via CREATE2
     * @param _underlyingOracle The underlying stablecoin Chainlink (compatible) oracle to wrap
     * @param _minPegPrice The minimum price at which the underlying stablecoin is considered pegged to 1 quote asset
     * @param _deployerPrivateKey The private key for executing the deployment
     * @return oracle The address of the deployed oracle
     */
    function deployOracle(address _underlyingOracle, int256 _minPegPrice, uint256 _deployerPrivateKey) public returns (address oracle) {
        bytes memory creationCode = abi.encodePacked(type(FundamentalStablecoinChainlinkOracle).creationCode, abi.encode(_underlyingOracle, _minPegPrice));

        vm.startBroadcast(_deployerPrivateKey);
        (oracle,) = deployWithSanityChecks(FUNDAMENTAL_STABLECOIN_CHAINLINK_ORACLE_SALT, creationCode, false);
        vm.stopBroadcast();
    }
}
