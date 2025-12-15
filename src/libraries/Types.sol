// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

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
 * @dev Contains all current mark to market NAV accounting data for the market's tranches
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
 * @title Operation
 * @dev Defines the operation being executed by the user
 * @custom:type ST_DEPOSIT Depositing assets into the senior tranche
 * @custom:type ST_WITHDRAW Withdrawing assets from the senior tranche
 * @custom:type JT_DEPOSIT Depositing assets into the junior tranche
 * @custom:type JT_WITHDRAW Withdrawing assets from the junior tranche
 * @custom:type ST_REQUEST_DEPOSIT Requesting a deposit for the senior tranche
 * @custom:type ST_REQUEST_REDEEM Requesting a redemption for the senior tranche
 * @custom:type JT_REQUEST_DEPOSIT Requesting a deposit for the junior tranche
 * @custom:type JT_REQUEST_REDEEM Requesting a redemption for the junior tranche
 */
enum Operation {
    ST_DEPOSIT,
    ST_WITHDRAW,
    ST_REQUEST_DEPOSIT,
    ST_REQUEST_REDEEM,
    JT_DEPOSIT,
    JT_WITHDRAW,
    JT_REQUEST_DEPOSIT,
    JT_REQUEST_REDEEM
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
