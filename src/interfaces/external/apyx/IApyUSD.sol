// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IAddressList } from "./IAddressList.sol";

/**
 * @title IAPYUSD
 * @author Apyx Protocol
 */
interface IApyUSD {
    /// @notice Returns the configured deny list address for apyUSD
    function denyList() external view returns (IAddressList);
}
