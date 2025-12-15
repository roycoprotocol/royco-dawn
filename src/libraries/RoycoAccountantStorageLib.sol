// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @notice Initialization parameters for the Royco Accountant
 * @custom:field kernel - The kernel that this accountant maintains accounting for
 * @custom:field protocolFeeWAD - The market's configured protocol fee percentage taken from yield earned by senior and junior tranches scaled by WAD
 * @custom:field coverageWAD - The coverage ratio that the senior tranche is expected to be protected by scaled by WAD
 * @custom:field betaWAD - The junior tranche's sensitivity to the same downside stress that affects the senior tranche
 *                For example, beta is 0 when JT is in the RFR and 1 when JT is in the same opportunity as senior
 * @custom:field rdm - The market's Reward Distribution Model (RDM), responsible for determining the ST's yield split between ST and JT
 * @custom:field protocolFeeRecipient - The market's configured protocol fee recipient
 */
struct RoycoAccountantInitParams {
    address kernel;
    uint64 protocolFeeWAD;
    uint64 coverageWAD;
    uint96 betaWAD;
    address rdm;
}

/**
 * @notice Storage state for the Royco Accountant
 * @custom:storage-location erc7201:Royco.storage.RoycoAccountantState
 * @custom:field kernel - The kernel that this accountant maintains accounting for
 * @custom:field coverageWAD - The coverage ratio that the senior tranche is expected to be protected by scaled by WAD
 * @custom:field betaWAD - The JT's sensitivity to the same downside stress that affects ST scaled by WAD
 *                         For example, beta is 0 when JT is in the RFR and 1 when JT is in the same opportunity as senior
 * @custom:field protocolFeeWAD - The market's configured protocol fee taken from yield earned by senior and junior tranches
 * @custom:field rdm - The market's Reward Distribution Model (RDM), responsible for determining the ST's yield split between ST and JT
 * @custom:field lastSTRawNAV - The last recorded raw NAV (excluding any losses, coverage, and yield accrual) of the senior tranche
 * @custom:field lastJTRawNAV - The last recorded raw NAV (excluding any losses, coverage, and yield accrual) of the junior tranche
 * @custom:field lastSTEffectiveNAV - The last recorded effective NAV (including any prior applied coverage, ST yield distributions, and uncovered losses) of the senior tranche
 * @custom:field lastJTEffectiveNAV - The last recorded effective NAV (including any prior provided coverage, JT yield, ST yield distribution, and JT losses) of the junior tranche
 * @custom:field lastJTCoverageDebt - The losses that ST incurred after exhausting the JT loss-absorption buffer: represents the first claim on capital the senior tranche has on future recoveries
 * @custom:field lastSTCoverageDebt - The coverage that has been applied to ST from the JT loss-absorption buffer : represents the second claim on capital the junior tranche has on future recoveries
 * @custom:field twJTYieldShareAccruedWAD - The time-weighted junior tranche yield share (RDM output) since the last yield distribution
 * @custom:field lastAccrualTimestamp - The last time the time-weighted JT yield share accumulator was updated
 * @custom:field lastDistributionTimestamp - The last time a yield distribution occurred
 */
struct RoycoAccountantState {
    address kernel;
    uint64 protocolFeeWAD;
    uint64 coverageWAD;
    uint96 betaWAD;
    address rdm;
    uint256 lastSTRawNAV;
    uint256 lastJTRawNAV;
    uint256 lastSTEffectiveNAV;
    uint256 lastJTEffectiveNAV;
    uint256 lastJTCoverageDebt;
    uint256 lastSTCoverageDebt;
    uint192 twJTYieldShareAccruedWAD;
    uint32 lastAccrualTimestamp;
    uint32 lastDistributionTimestamp;
}

/// @title RoycoAccountantStorageLib
/// @notice Library for managing Royco Accountant storage using the ERC7201 pattern
library RoycoAccountantStorageLib {
    /// @dev Storage slot for RoycoAccountantState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoAccountantState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROYCO_ACCOUNTANT_STORAGE_SLOT = 0x0e1123d8194dcf603de811512b2b6334f106b53313663d6b2df1a2b814038e00;

    /// @notice Returns a storage pointer to the RoycoAccountantState storage
    /// @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
    /// @return $ Storage pointer to the accountant's state
    function _getRoycoAccountantStorage() internal pure returns (RoycoAccountantState storage $) {
        assembly ("memory-safe") {
            $.slot := ROYCO_ACCOUNTANT_STORAGE_SLOT
        }
    }

    /// @notice Initializes the Royco Accountant state
    /// @param _params The initialization parameters for the royco accountant
    function __RoycoAccountant_init(RoycoAccountantInitParams memory _params) internal {
        // Set the initial state of the accountant
        RoycoAccountantState storage $ = _getRoycoAccountantStorage();
        $.kernel = _params.kernel;
        $.protocolFeeWAD = _params.protocolFeeWAD;
        $.coverageWAD = _params.coverageWAD;
        $.betaWAD = _params.betaWAD;
        $.rdm = _params.rdm;
    }
}
