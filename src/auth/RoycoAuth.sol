// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AccessManagedUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/access/manager/AccessManagedUpgradeable.sol";
import { PausableUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import { IRoycoAuth } from "../interfaces/IRoycoAuth.sol";

/**
 * @title RoycoAuth
 * @notice Abstract contract that provides access control and pausability functionality for Royco contracts
 */
abstract contract RoycoAuth is AccessManagedUpgradeable, PausableUpgradeable, IRoycoAuth {
    function __RoycoAuth_init(address _initialAuthority) internal onlyInitializing {
        __AccessManaged_init(_initialAuthority);
        __Pausable_init();
    }

    /// @inheritdoc IRoycoAuth
    function pause() external virtual restricted {
        _pause();
    }

    /// @inheritdoc IRoycoAuth
    function unpause() external virtual restricted {
        _unpause();
    }
}
