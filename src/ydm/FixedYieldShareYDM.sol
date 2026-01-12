// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IYDM } from "../interfaces/IYDM.sol";
import { WAD } from "../libraries/Constants.sol";
import { NAV_UNIT } from "../libraries/Units.sol";

/**
 * @title FixedYieldShareYDM
 * @notice Royco's fixed share yield distribution model (YDM)
 * @dev The YDM has a fixed yield split per market
 */
contract FixedYieldShareYDM is IYDM {
    /// @dev A mapping from market accountants to its market's fixed JT yield share, scaled to WAD precision
    mapping(address accountant => uint256 jtYieldShareWAD) public accountantToFixedJtYieldShareWAD;

    /**
     * @notice Emitted when the fixed share YDM is initialized for a market
     * @param accountant The accountant for the market that the YDM was initialized for
     * @param fixedJtYieldShareWAD The fixed JT yield share for this market, scaled to WAD precision
     */
    event FixedYieldShareYdmInitialized(address indexed accountant, uint256 fixedJtYieldShareWAD);

    /// @inheritdoc IYDM
    function initializeYDMForMarket(uint256 _jtYieldShareAtTargetUtilWAD, uint256 _jtYieldShareAtFullUtilWAD) external override(IYDM) {
        // Ensure that the YDM initialization parameters are valid
        require(_jtYieldShareAtTargetUtilWAD == _jtYieldShareAtFullUtilWAD && _jtYieldShareAtFullUtilWAD <= WAD, INVALID_YDM_INITIALIZATION());

        // Initialize the YDM for this market
        accountantToFixedJtYieldShareWAD[msg.sender] = _jtYieldShareAtTargetUtilWAD;

        emit FixedYieldShareYdmInitialized(msg.sender, _jtYieldShareAtTargetUtilWAD);
    }

    /// @inheritdoc IYDM
    function previewJTYieldShare(NAV_UNIT, NAV_UNIT, uint256, uint256, NAV_UNIT) external view override(IYDM) returns (uint256) {
        return accountantToFixedJtYieldShareWAD[msg.sender];
    }

    /// @inheritdoc IYDM
    function jtYieldShare(NAV_UNIT, NAV_UNIT, uint256, uint256, NAV_UNIT) external view override(IYDM) returns (uint256) {
        return accountantToFixedJtYieldShareWAD[msg.sender];
    }
}
