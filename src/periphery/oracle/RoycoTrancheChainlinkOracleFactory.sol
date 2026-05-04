// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Create2 } from "../../../lib/openzeppelin-contracts/contracts/utils/Create2.sol";
import { IRoycoFactory } from "../../interfaces/IRoycoFactory.sol";
import { TrancheType } from "../../libraries/Types.sol";
import { IRoycoVaultTranche, RoycoTrancheChainlinkOracle } from "./RoycoTrancheChainlinkOracle.sol";

/**
 * @title RoycoTrancheChainlinkOracleFactory
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Permissionless factory that deploys Chainlink compatible oracles for Royco tranche share prices
 */
contract RoycoTrancheChainlinkOracleFactory {
    /// @dev The global deployment salt used for all oracles
    bytes32 private constant ORACLE_DEPLOYMENT_SALT = keccak256(abi.encode("ROYCO_TRANCHE_CHAINLINK_ORACLE"));

    /// @notice The canonical Royco Factory deployment
    address public immutable ROYCO_FACTORY;

    /// @notice The deployed share price oracle for each Royco tranche
    mapping(address tranche => address oracle) public trancheToOracle;

    /// @notice Emitted when an oracle is deployed for a tranche
    event OracleDeployed(address indexed tranche, address indexed oracle);

    /// @dev Thrown when an address is set to the null address
    error NULL_ADDRESS();

    /// @dev Thrown when the specified tranche wasn't deployed by the canonical Royco Factory
    error INVALID_TRANCHE();

    /// @notice Constructs the factory for deploying Chainlink compatible Royco tranche share price oracles
    /// @dev The canonical Royco Factory deployment
    constructor(address _roycoFactory) {
        require(_roycoFactory != address(0), NULL_ADDRESS());
        ROYCO_FACTORY = _roycoFactory;
    }

    /**
     * @notice Deploys a share-price oracle for the specified tranche
     * @param _tranche The Royco tranche to deploy the oracle for
     * @return oracle The deployed oracle's address
     */
    function deployOracle(address _tranche) external returns (address oracle) {
        // Validate that the tranche was deployed by the canonical Royco Factory
        _validateTranche(_tranche);
        // Deploy the share price oracle for this tranche
        trancheToOracle[_tranche] = oracle = address(new RoycoTrancheChainlinkOracle{ salt: ORACLE_DEPLOYMENT_SALT }(_tranche));
        emit OracleDeployed(_tranche, oracle);
    }

    /// @notice Predicts the oracle address that would be deployed for the specified tranche
    function predictOracleAddress(address _tranche) external view returns (address) {
        return Create2.computeAddress(ORACLE_DEPLOYMENT_SALT, keccak256(abi.encodePacked(type(RoycoTrancheChainlinkOracle).creationCode, abi.encode(_tranche))));
    }

    /// @dev Validates whether a tranche was deployed by the canonical Royco Factory
    /// @param _ostensibleRoycoTranche The ostensibly valid Royco tranche to validate
    function _validateTranche(address _ostensibleRoycoTranche) internal view {
        require(_ostensibleRoycoTranche != address(0), NULL_ADDRESS());
        // Get the paired tranche from the factory to validate the input tranche was factory-deployed
        address correspondingTranche = IRoycoVaultTranche(_ostensibleRoycoTranche).TRANCHE_TYPE() == TrancheType.SENIOR
            ? IRoycoFactory(ROYCO_FACTORY).seniorTrancheToJuniorTranche(_ostensibleRoycoTranche)
            : IRoycoFactory(ROYCO_FACTORY).juniorTrancheToSeniorTranche(_ostensibleRoycoTranche);
        require(correspondingTranche != address(0), INVALID_TRANCHE());
    }
}
