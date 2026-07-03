// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { RoycoAuth } from "../auth/RoycoAuth.sol";

/**
 * @title RoycoBase
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Abstract base contract for upgradeable Royco protocol contracts
 * @dev Combines UUPS upgradeability with Royco's access control system
 * @dev All upgradeable Royco contracts (tranches, kernel, accountant) inherit from this base.
 */
abstract contract RoycoBase is UUPSUpgradeable, RoycoAuth {
    /// @dev Thrown when the new implementation for this contract is invalid
    error INVALID_IMPLEMENTATION();

    /// @dev Disable the initializers
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the Royco base contract
    /// @param _initialAuthority The initial authority for the contract
    function __RoycoBase_init(address _initialAuthority) internal onlyInitializing {
        __RoycoAuth_init(_initialAuthority);
    }

    /// @dev Restricts the upgrade to only the authorized roles
    function _authorizeUpgrade(address _newImplementation) internal override(UUPSUpgradeable) restricted {
        require(_newImplementation.code.length > 0, INVALID_IMPLEMENTATION());
    }
}
