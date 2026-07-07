// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ERC4626 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract ERC4626Mock is ERC4626 {
    constructor(IERC20 asset_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(asset_)
    {}
}