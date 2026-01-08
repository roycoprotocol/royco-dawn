// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoAccountant } from "../interfaces/IRoycoAccountant.sol";
import { IRoycoKernel } from "../interfaces/kernel/IRoycoKernel.sol";
import { IRoycoVaultTranche } from "../interfaces/tranche/IRoycoVaultTranche.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "./Units.sol";

/**
 * @title AssetClaims
 * @dev A struct representing claims on senior tranche assets, junior tranche assets, and NAV
 * @custom:field stAssets - The claim on senior tranche assets denominated in ST's tranche units
 * @custom:field jtAssets - The claim on junior tranche assets denominated in JT's tranche units
 * @custom:field nav - The net asset value of these claims in NAV units
 */
struct AssetClaims {
    TRANCHE_UNIT stAssets;
    TRANCHE_UNIT jtAssets;
    NAV_UNIT nav;
}

/**
 * @title SyncedAccountingState
 * @dev Contains all current mark to market NAV accounting data for the market's tranches
 * @custom:field stRawNAV - The senior tranche's current raw NAV: the pure value of its invested assets
 * @custom:field jtRawNAV - The junior tranche's current raw NAV: the pure value of its invested assets
 * @custom:field stEffectiveNAV - Senior tranche effective NAV: includes applied coverage, its share of ST yield, and uncovered losses
 * @custom:field jtEffectiveNAV - Junior tranche effective NAV: includes provided coverage, JT yield, its share of ST yield, and JT losses
 * @custom:field stImpermanentLoss - The impermanent loss that ST has suffered after exhausting JT's loss-absorption buffer
 *                                   This represents the first claim on capital that the senior tranche has on future recoveries
 * @custom:field jtImpermanentLoss - The impermanent loss that JT has suffered after providing coverage for ST losses
 *                                   This represents the second claim on capital that the junior tranche has on future recoveries
 * @custom:field stProtocolFeeAccrued - Protocol fee taken on ST yield on this sync
 * @custom:field jtProtocolFeeAccrued - Protocol fee taken on JT yield on this sync
 */
struct SyncedAccountingState {
    NAV_UNIT stRawNAV;
    NAV_UNIT jtRawNAV;
    NAV_UNIT stEffectiveNAV;
    NAV_UNIT jtEffectiveNAV;
    NAV_UNIT stImpermanentLoss;
    NAV_UNIT jtImpermanentLoss;
    NAV_UNIT stProtocolFeeAccrued;
    NAV_UNIT jtProtocolFeeAccrued;
}

/**
 * @title Operation
 * @dev Defines the type of operation being executed by the user
 * @custom:type ST_INCREASE_NAV - An operation that will potentially increase the NAV of ST
 * @custom:type ST_DECREASE_NAV - An operation that will potentially decrease the NAV of ST
 * @custom:type JT_INCREASE_NAV - An operation that will potentially increase the NAV of JT
 * @custom:type JT_DECREASE_NAV - An operation that will potentially decrease the NAV of JT
 */
enum Operation {
    ST_INCREASE_NAV,
    ST_DECREASE_NAV,
    JT_INCREASE_NAV,
    JT_DECREASE_NAV
}

/**
 * @title Action
 * @dev Defines the action being executed by the user
 * @custom:type DEPOSIT Depositing assets into the tranche
 * @custom:type WITHDRAW Withdrawing assets from the tranche
 */
enum Action {
    DEPOSIT,
    WITHDRAW
}

/**
 * @title TrancheType
 * @dev Defines the two types of Royco tranches deployed per market.
 * @custom:type JUNIOR The identifier for the junior tranche (first-loss capital)
 * @custom:type SENIOR The identifier for the senior tranche (second-loss capital)
 */
enum TrancheType {
    JUNIOR,
    SENIOR
}

/**
 * @title SharesRedemptionModel
 * @dev Defines the behavior of the shares when a redeem request is made
 * @custom:type BURN_ON_REQUEST_REDEEM The shares are burned when calling requestRedeem
 * @custom:type BURN_ON_CLAIM_REDEEM The shares are burned when calling redeem
 */
enum SharesRedemptionModel {
    BURN_ON_REQUEST_REDEEM,
    BURN_ON_CLAIM_REDEEM
}

/**
 * @title ExecutionModel
 * @dev Defines the execution semantics for the deposit or withdrawal flow of a vault
 * @custom:type SYNC Refers to the flow being synchronous (the vault uses ERC4626 for this flow)
 * @custom:type ASYNC Refers to the flow being asynchronous (the vault uses ERC7540 for this flow)
 */
enum ExecutionModel {
    SYNC,
    ASYNC
}

/**
 * @title ActionMetadataFormat
 * @dev Defines the format of the metadata for the action
 * @custom:type REDEMPTION_CLAIMABLE_AT_TIMESTAMP is followed by a uint256 representing the claimable at timestamp of the redemption request
 */
enum ActionMetadataFormat {
    REDEMPTION_CLAIMABLE_AT_TIMESTAMP
}

/**
 * @notice Parameters for deploying a new market
 * @custom:field seniorTrancheName The name of the senior tranche
 * @custom:field seniorTrancheSymbol The symbol of the senior tranche
 * @custom:field juniorTrancheName The name of the junior tranche
 * @custom:field juniorTrancheSymbol The symbol of the junior tranche
 * @custom:field seniorAsset The underlying asset for the senior tranche
 * @custom:field juniorAsset The underlying asset for the junior tranche
 * @custom:field marketId The identifier of the Royco market
 * @custom:field kernelImplementation The implementation address for the kernel
 * @custom:field accountantImplementation The implementation address for the accountant
 * @custom:field seniorTrancheImplementation The implementation address for the senior tranche
 * @custom:field juniorTrancheImplementation The implementation address for the junior tranche
 * @custom:field kernelInitializationData The initialization data for the kernel
 * @custom:field accountantInitializationData The initialization data for the accountant
 * @custom:field seniorTrancheInitializationData The initialization data for the senior tranche
 * @custom:field juniorTrancheInitializationData The initialization data for the junior tranche
 * @custom:field seniorTrancheProxyDeploymentSalt The salt for the senior tranche proxy deployment
 * @custom:field juniorTrancheProxyDeploymentSalt The salt for the junior tranche proxy deployment
 * @custom:field kernelProxyDeploymentSalt The salt for the kernel proxy deployment
 * @custom:field accountantProxyDeploymentSalt The salt for the accountant proxy deployment
 */
struct MarketDeploymentParams {
    // Tranche Deployment Parameters
    string seniorTrancheName;
    string seniorTrancheSymbol;
    string juniorTrancheName;
    string juniorTrancheSymbol;
    address seniorAsset;
    address juniorAsset;
    bytes32 marketId;
    // Implementation Addresses
    IRoycoVaultTranche seniorTrancheImplementation;
    IRoycoVaultTranche juniorTrancheImplementation;
    IRoycoKernel kernelImplementation;
    IRoycoAccountant accountantImplementation;
    // Proxy Initialization Data
    bytes seniorTrancheInitializationData;
    bytes juniorTrancheInitializationData;
    bytes kernelInitializationData;
    bytes accountantInitializationData;
    // Create2 Salts
    bytes32 seniorTrancheProxyDeploymentSalt;
    bytes32 juniorTrancheProxyDeploymentSalt;
    bytes32 kernelProxyDeploymentSalt;
    bytes32 accountantProxyDeploymentSalt;
    // Initial Roles Configuration
    RolesConfiguration[] roles;
}

/**
 * @custom:field name - The name of the tranche (should be prefixed with "Royco-ST" or "Royco-JT") share token
 * @custom:field symbol - The symbol of the tranche (should be prefixed with "ST" or "JT") share token
 * @custom:field kernel - The tranche kernel responsible for defining the execution model and logic of the tranche
 */
struct TrancheDeploymentParams {
    string name;
    string symbol;
    address kernel;
}

/**
 * @notice The configuration for a role
 * @custom:field target The target address of the role
 * @custom:field selectors The selectors of the role
 * @custom:field roles The roles of the role
 */
struct RolesConfiguration {
    address target;
    bytes4[] selectors;
    uint64[] roles;
}

/**
 * @notice The deployed contracts for a new market
 * @custom:field seniorTranche The senior tranche contract
 * @custom:field juniorTranche The junior tranche contract
 * @custom:field accountant The accountant contract
 * @custom:field kernel The kernel contract
 */
struct DeployedContracts {
    IRoycoVaultTranche seniorTranche;
    IRoycoVaultTranche juniorTranche;
    IRoycoAccountant accountant;
    IRoycoKernel kernel;
}
