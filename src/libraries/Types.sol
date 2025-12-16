// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoAccountant } from "../interfaces/IRoycoAccountant.sol";
import { IRoycoKernel } from "../interfaces/kernel/IRoycoKernel.sol";
import { IRoycoVaultTranche } from "../interfaces/tranche/IRoycoVaultTranche.sol";

/// @custom:field name - The name of the tranche (should be prefixed with "Royco-ST" or "Royco-JT") share token
/// @custom:field symbol - The symbol of the tranche (should be prefixed with "ST" or "JT") share token
/// @custom:field kernel - The tranche kernel responsible for defining the execution model and logic of the tranche
struct TrancheDeploymentParams {
    string name;
    string symbol;
    address kernel;
}

/**
 * @title SyncedNAVsPacket
 * @dev Contains all current mark to market NAV accounting data for the market's tranches, scaled to asset precision
 * @custom:field stRawNAV - The senior tranche's current raw NAV: the pure value of its invested assets
 * @custom:field jtRawNAV - The junior tranche's current raw NAV: the pure value of its invested assets
 * @custom:field stEffectiveNAV - Senior tranche effective NAV: includes applied coverage, its share of ST yield, and uncovered losses
 * @custom:field jtEffectiveNAV - Junior tranche effective NAV: includes provided coverage, JT yield, its share of ST yield, and JT losses
 * @custom:field stCoverageDebt - Coverage that has currently been applied to ST from the JT loss-absorption buffer
 * @custom:field jtCoverageDebt - Losses that ST incurred after exhausting the JT loss-absorption buffer
 * @custom:field stProtocolFeeAccrued - Protocol fee taken on ST yield on this sync
 * @custom:field jtProtocolFeeAccrued - Protocol fee taken on JT yield on this sync
 */
struct SyncedNAVsPacket {
    uint256 stRawNAV;
    uint256 jtRawNAV;
    uint256 stEffectiveNAV;
    uint256 jtEffectiveNAV;
    uint256 stCoverageDebt;
    uint256 jtCoverageDebt;
    uint256 stProtocolFeeAccrued;
    uint256 jtProtocolFeeAccrued;
}

/**
 * @title SyncedNAVsPacketRAY
 * @dev Contains all current mark to market NAV accounting data for the market's tranches, scaled to RAY precision
 * @custom:field stRawNavRAY - The senior tranche's current raw NAV: the pure value of its invested assets, scaled to RAY precision
 * @custom:field jtRawNavRAY - The junior tranche's current raw NAV: the pure value of its invested assets, scaled to RAY precision
 * @custom:field stEffectiveNavRAY - Senior tranche effective NAV: includes applied coverage, its share of ST yield, and uncovered losses, scaled to RAY precision
 * @custom:field jtEffectiveNavRAY - Junior tranche effective NAV: includes provided coverage, JT yield, its share of ST yield, and JT losses, scaled to RAY precision
 * @custom:field stCoverageDebtRAY - Coverage that has currently been applied to ST from the JT loss-absorption buffer, scaled to RAY precision
 * @custom:field jtCoverageDebtRAY - Losses that ST incurred after exhausting the JT loss-absorption buffer, scaled to RAY precision
 * @custom:field stProtocolFeeAccruedRAY - Protocol fee taken on ST yield on this sync, scaled to RAY precision
 * @custom:field jtProtocolFeeAccruedRAY - Protocol fee taken on JT yield on this sync, scaled to RAY precision
 */
struct SyncedNAVsPacketRAY {
    uint256 stRawNavRAY;
    uint256 jtRawNavRAY;
    uint256 stEffectiveNavRAY;
    uint256 jtEffectiveNavRAY;
    uint256 stCoverageDebtRAY;
    uint256 jtCoverageDebtRAY;
    uint256 stProtocolFeeAccruedRAY;
    uint256 jtProtocolFeeAccruedRAY;
}

/**
 * @title Operation
 * @dev Defines the operation being executed by the user
 * @custom:type ST_INCREASE_NAV - Depositing assets into the senior tranche NAV
 * @custom:type ST_DECREASE_NAV - Withdrawing assets from the senior tranche NAV
 * @custom:type JT_INCREASE_NAV - Depositing assets into the junior tranche NAV
 * @custom:type JT_DECREASE_NAV - Withdrawing assets from the junior tranche NAV
 */
enum Operation {
    ST_INCREASE_NAV,
    ST_DECREASE_NAV,
    JT_INCREASE_NAV,
    JT_DECREASE_NAV
}

/// @title Action
/// @dev Defines the action being executed by the user
/// @custom:type DEPOSIT Depositing assets into the tranche
/// @custom:type WITHDRAW Withdrawing assets from the tranche
enum Action {
    DEPOSIT,
    WITHDRAW
}

/// @title TrancheType
/// @dev Defines the two types of Royco tranches deployed per market.
/// @custom:type JUNIOR The identifier for the junior tranche (first-loss capital)
/// @custom:type SENIOR The identifier for the senior tranche (second-loss capital)
enum TrancheType {
    JUNIOR,
    SENIOR
}

/// @title RequestRedeemSharesBehavior
/// @dev Defines the behavior of the shares when a redeem request is made
/// @custom:type BURN_ON_REQUEST The shares are burned when calling requestRedeem
/// @custom:type BURN_ON_REDEEM The shares are burned when calling redeem
enum RequestRedeemSharesBehavior {
    BURN_ON_REQUEST,
    BURN_ON_REDEEM
}

/// @title ExecutionModel
/// @dev Defines the execution semantics for the deposit or withdrawal flow of a vault
/// @custom:type SYNC Refers to the flow being synchronous (the vault uses ERC4626 for this flow)
/// @custom:type ASYNC Refers to the flow being asynchronous (the vault uses ERC7540 for this flow)
enum ExecutionModel {
    SYNC,
    ASYNC
}

/// @notice Parameters for deploying a new market
/// @custom:field seniorTrancheName The name of the senior tranche
/// @custom:field seniorTrancheSymbol The symbol of the senior tranche
/// @custom:field juniorTrancheName The name of the junior tranche
/// @custom:field juniorTrancheSymbol The symbol of the junior tranche
/// @custom:field seniorAsset The underlying asset for the senior tranche
/// @custom:field juniorAsset The underlying asset for the junior tranche
/// @custom:field marketId The identifier of the Royco market
/// @custom:field kernelImplementation The implementation address for the kernel
/// @custom:field accountantImplementation The implementation address for the accountant
/// @custom:field seniorTrancheImplementation The implementation address for the senior tranche
/// @custom:field juniorTrancheImplementation The implementation address for the junior tranche
/// @custom:field kernelInitializationData The initialization data for the kernel
/// @custom:field accountantInitializationData The initialization data for the accountant
/// @custom:field seniorTrancheInitializationData The initialization data for the senior tranche
/// @custom:field juniorTrancheInitializationData The initialization data for the junior tranche
/// @custom:field seniorTrancheProxyDeploymentSalt The salt for the senior tranche proxy deployment
/// @custom:field juniorTrancheProxyDeploymentSalt The salt for the junior tranche proxy deployment
/// @custom:field kernelProxyDeploymentSalt The salt for the kernel proxy deployment
/// @custom:field accountantProxyDeploymentSalt The salt for the accountant proxy deployment
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
}

/// @notice The deployed contracts for a new market
/// @custom:field seniorTranche The senior tranche contract
/// @custom:field juniorTranche The junior tranche contract
/// @custom:field accountant The accountant contract
/// @custom:field kernel The kernel contract
struct DeployedContracts {
    IRoycoVaultTranche seniorTranche;
    IRoycoVaultTranche juniorTranche;
    IRoycoAccountant accountant;
    IRoycoKernel kernel;
}
