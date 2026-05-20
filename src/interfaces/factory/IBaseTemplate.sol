// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoFactory } from "./IRoycoFactory.sol";
import { IRoycoProtocolTemplate } from "./IRoycoProtocolTemplate.sol";

/**
 * @title IBaseTemplate
 * @notice External interface of every `BaseDeploymentTemplate`-derived contract.
 * @dev Extends `IRoycoProtocolTemplate` (the lifecycle interface — initialize / validateParams /
 *      deployMarket / verify) with the immutable factory binding and the SSTORE2 pointer
 *      introspection helper that every template author exposes.
 */
interface IBaseTemplate is IRoycoProtocolTemplate {
    /// @notice The factory this template is bound to. Set at construction; immutable for life.
    function ROYCO_FACTORY() external view returns (IRoycoFactory);

    /// @notice Returns the SSTORE2 pointer for a given component ID, or `address(0)` if unset.
    /// @dev Useful for off-chain tooling to verify which components are loaded into a template.
    function bytecodePointer(bytes32 _componentId) external view returns (address);
}
