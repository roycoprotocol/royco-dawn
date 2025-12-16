// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

library ConstantsLib {
    /// @dev Constant for the WAD scaling factor
    uint256 public constant WAD = 1e18;

    /// @dev Constant for the RAY scaling factor
    uint256 public constant RAY = 1e27;

    /// @dev The minimum configurable coverage percentage, scaled to WAD precision
    uint256 public constant MIN_COVERAGE_WAD = 0.01e18;

    /// @dev The max protocol fee percentage on tranche yields, scaled to WAD precision
    uint256 public constant MAX_PROTOCOL_FEE_WAD = 1e18;

    /// @dev The request ID for a purely controller-discriminated request in ERC-7540
    uint256 public constant ERC_7540_CONTROLLER_DISCRIMINATED_REQUEST_ID = 0;
}
