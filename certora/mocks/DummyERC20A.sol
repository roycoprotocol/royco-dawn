// Represents a symbolic/dummy ERC20 token

// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.8.28;
import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract DummyERC20A is IERC20 {
    uint256 t;
    mapping(address => uint256) b;
    mapping(address => mapping(address => uint256)) a;

    string public name;
    string public symbol;
    uint public decimals;

    function myAddress() external view returns (address) {
        return address(this);
    }
    
    function totalSupply() external view returns (uint256) {
        return t;
    }

    function balanceOf(address account) virtual public view returns (uint256) {
        return b[account];
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        b[msg.sender] -= amount;
        b[recipient] += amount;

        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return a[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        a[msg.sender][spender] = amount;

        return true;
    }

    function approveOverride(address owner, address spender, uint256 amount) public {
        a[owner][spender] = amount;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool) {
        b[sender] -= amount;
        b[recipient] += amount;
        a[sender][msg.sender] -= amount;

        return true;
    }

    function safeTransferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external {
        b[sender] -= amount;
        b[recipient] += amount;
        a[sender][msg.sender] -= amount;
    }
}