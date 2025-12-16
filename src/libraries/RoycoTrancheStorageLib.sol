// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ExecutionModel, IRoycoKernel, RequestRedeemSharesBehavior } from "../interfaces/kernel/IRoycoKernel.sol";
import { TrancheType } from "./Types.sol";

/// @notice Storage state for Royco Tranche contracts
/// @custom:storage-location erc7201:Royco.storage.RoycoTrancheState
/// @custom:field kernel - The address of the kernel contract handling strategy logic
/// @custom:field marketId - The identifier of the Royco market this tranche is linked to
/// @custom:field decimalsOffset - Decimals offset for share token precision
/// @custom:field DEPOSIT_EXECUTION_MODEL - The kernel execution model for deposit operations
/// @custom:field WITHDRAW_EXECUTION_MODEL - The kernel execution model for withdrawal operations
/// @custom:field REQUEST_REDEEM_SHARES_ST_BEHAVIOR - The behavior of the shares when a redeem request is made for the senior tranche
/// @custom:field REQUEST_REDEEM_SHARES_JT_BEHAVIOR - The behavior of the shares when a redeem request is made for the junior tranche
/// @custom:field isOperator - Nested mapping tracking operator approvals for owners
struct RoycoTrancheState {
    address kernel;
    bytes32 marketId;
    uint8 decimalsOffset;
    ExecutionModel DEPOSIT_EXECUTION_MODEL;
    ExecutionModel WITHDRAW_EXECUTION_MODEL;
    RequestRedeemSharesBehavior REQUEST_REDEEM_SHARES_ST_BEHAVIOR;
    RequestRedeemSharesBehavior REQUEST_REDEEM_SHARES_JT_BEHAVIOR;
    mapping(address owner => mapping(address operator => bool isOperator)) isOperator;
}

/// @title RoycoTrancheStorageLib
/// @notice Library for managing Royco Tranche storage using ERC-7201 pattern
/// @dev Provides functions to safely access and modify tranche state
library RoycoTrancheStorageLib {
    /// @dev Storage slot for RoycoTrancheState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoTrancheState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROYCO_TRANCHE_STORAGE_SLOT = 0x25265df6fdb5acadb02f38e62cea4bba666d308120ed42c208a4ef005c50ec00;

    /// @notice Returns a reference to the RoycoTrancheState storage
    /// @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
    /// @return $ Storage reference to the tranche state
    function _getRoycoTrancheStorage() internal pure returns (RoycoTrancheState storage $) {
        assembly ("memory-safe") {
            $.slot := ROYCO_TRANCHE_STORAGE_SLOT
        }
    }

    /// @notice Initializes the tranche storage state
    /// @dev Sets up all initial parameters and validates fee constraints
    /// @param _kernel The address of the kernel contract handling strategy logic
    /// @param _marketId The identifier of the Royco market this tranche is linked to
    /// @param _decimalsOffset Decimals offset for share token precision
    /// @param _trancheType The type of the tranche
    function __RoycoTranche_init(address _kernel, bytes32 _marketId, uint8 _decimalsOffset, TrancheType _trancheType) internal {
        // Set the initial state of the tranche
        RoycoTrancheState storage $ = _getRoycoTrancheStorage();
        $.kernel = _kernel;
        $.marketId = _marketId;
        $.decimalsOffset = _decimalsOffset;
        $.REQUEST_REDEEM_SHARES_ST_BEHAVIOR = IRoycoKernel(_kernel).ST_REQUEST_REDEEM_SHARES_BEHAVIOR();
        $.REQUEST_REDEEM_SHARES_JT_BEHAVIOR = IRoycoKernel(_kernel).JT_REQUEST_REDEEM_SHARES_BEHAVIOR();
        if (_trancheType == TrancheType.SENIOR) {
            $.DEPOSIT_EXECUTION_MODEL = IRoycoKernel(_kernel).ST_INCREASE_NAV_EXECUTION_MODEL();
            $.WITHDRAW_EXECUTION_MODEL = IRoycoKernel(_kernel).ST_DECREASE_NAVAL_EXECUTION_MODEL();
        } else {
            $.DEPOSIT_EXECUTION_MODEL = IRoycoKernel(_kernel).JT_INCREASE_NAV_EXECUTION_MODEL();
            $.WITHDRAW_EXECUTION_MODEL = IRoycoKernel(_kernel).JT_DECREASE_NAVAL_EXECUTION_MODEL();
        }
    }
}
