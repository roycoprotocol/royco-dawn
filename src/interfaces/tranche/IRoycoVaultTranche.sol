// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC165 } from "../../../lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import { IERC7540 } from "./IERC7540.sol";
import { IERC7575 } from "./IERC7575.sol";
import { IERC7887 } from "./IERC7887.sol";

interface IRoycoVaultTranche is IERC165, IERC7540, IERC7575, IERC7887 {
    /// @notice Returns the raw net asset value of the tranche's invested assets
    /// @dev Excludes yield splits, coverage applications, etc.
    /// @dev The NAV is expressed in the tranche's base asset
    function getRawNAV() external view returns (uint256);

    /// @notice Returns the effective net asset value of the tranche's invested assets
    /// @dev Includes yield splits, coverage applications, etc.
    /// @dev The NAV is expressed in the tranche's base asset
    function getEffectiveNAV() external view returns (uint256);

    /// @notice Returns the address of the kernel contract handling strategy logic
    function kernel() external view returns (address);

    /// @notice Returns the identifier of the Royco market this tranche is linked to
    function marketId() external view returns (bytes32);

    /**
     * @notice Mints tranche shares to the protocol fee recipient, representing ownership over the fee assets of the tranche
     * @dev Must be called by the tranche's kernel everytime protocol fees are accrued in its pre-op synchronization
     * @param _protocolFeeAssets The fee accrued for this tranche as a result of the pre-op sync
     * @param _trancheTotalAssets The total effective assets controlled by this tranche as a result of the pre-op sync
     * @param _protocolFeeRecipient The address to receive the freshly minted protocol fee shares
     */
    function mintProtocolFeeShares(uint256 _protocolFeeAssets, uint256 _trancheTotalAssets, address _protocolFeeRecipient) external;
}
