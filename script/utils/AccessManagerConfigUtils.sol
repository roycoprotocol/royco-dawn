// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IAccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { Script } from "lib/forge-std/src/Script.sol";

/**
 * @title AccessManagerConfigUtils
 * @notice Reusable utilities for generating Safe-compatible transaction batches for AccessManager configuration
 * @dev Inherit from this contract in deployment scripts to generate Safe transaction JSON files
 *      for configuring access control on AccessManager-based contracts.
 *
 * Usage:
 *   1. Inherit this contract in your deployment script
 *   2. Build transactions using the helper functions
 *   3. Call `writeSafeTransactionJson` to output the JSON file
 *
 * Example:
 *   SafeTransaction[] memory txs = new SafeTransaction[](2);
 *   txs[0] = buildSetTargetFunctionRole(factory, target, selectors, role);
 *   txs[1] = buildGrantRole(factory, role, account, 0);
 *   writeSafeTransactionJson(txs, "output/config.json", "My Config");
 */
abstract contract AccessManagerConfigUtils is Script {
    /// @dev Output path for the Safe transaction JSON
    string constant SAFE_TX_OUTPUT_DIRECTORY = "output/";

    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Represents a transaction to be executed via Safe
    struct SafeTransaction {
        address to;
        uint256 value;
        bytes data;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TRANSACTION BUILDERS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Builds a setTargetFunctionRole transaction
     * @param _accessManager The AccessManager contract address
     * @param _target The target contract whose functions are being configured
     * @param _selectors Array of function selectors to assign the role to
     * @param _role The role ID to assign to these functions
     * @return transaction The Safe transaction to execute
     */
    function buildSetTargetFunctionRole(
        address _accessManager,
        address _target,
        bytes4[] memory _selectors,
        uint64 _role
    )
        internal
        pure
        returns (SafeTransaction memory transaction)
    {
        transaction =
            SafeTransaction({ to: _accessManager, value: 0, data: abi.encodeCall(IAccessManager.setTargetFunctionRole, (_target, _selectors, _role)) });
    }

    /**
     * @notice Builds a grantRole transaction
     * @param _accessManager The AccessManager contract address
     * @param _role The role ID to grant
     * @param _account The account to grant the role to
     * @param _executionDelay The delay before the account can execute functions requiring this role
     * @return transaction The Safe transaction to execute
     */
    function buildGrantRole(
        address _accessManager,
        uint64 _role,
        address _account,
        uint32 _executionDelay
    )
        internal
        pure
        returns (SafeTransaction memory transaction)
    {
        transaction = SafeTransaction({ to: _accessManager, value: 0, data: abi.encodeCall(IAccessManager.grantRole, (_role, _account, _executionDelay)) });
    }

    /**
     * @notice Builds a revokeRole transaction
     * @param _accessManager The AccessManager contract address
     * @param _role The role ID to revoke
     * @param _account The account to revoke the role from
     * @return transaction The Safe transaction to execute
     */
    function buildRevokeRole(address _accessManager, uint64 _role, address _account) internal pure returns (SafeTransaction memory transaction) {
        transaction = SafeTransaction({ to: _accessManager, value: 0, data: abi.encodeCall(IAccessManager.revokeRole, (_role, _account)) });
    }

    /**
     * @notice Builds a setTargetClosed transaction to enable/disable a target
     * @param _accessManager The AccessManager contract address
     * @param _target The target contract to close/open
     * @param _closed True to close (disable) the target, false to open (enable)
     * @return transaction The Safe transaction to execute
     */
    function buildSetTargetClosed(address _accessManager, address _target, bool _closed) internal pure returns (SafeTransaction memory transaction) {
        transaction = SafeTransaction({ to: _accessManager, value: 0, data: abi.encodeCall(IAccessManager.setTargetClosed, (_target, _closed)) });
    }

    /**
     * @notice Builds a labelRole transaction
     * @param _accessManager The AccessManager contract address
     * @param _role The role ID to label
     * @param _label The human-readable label for the role
     * @return transaction The Safe transaction to execute
     */
    function buildLabelRole(address _accessManager, uint64 _role, string memory _label) internal pure returns (SafeTransaction memory transaction) {
        transaction = SafeTransaction({ to: _accessManager, value: 0, data: abi.encodeCall(IAccessManager.labelRole, (_role, _label)) });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BATCH BUILDERS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Builds multiple grantRole transactions for the same role
     * @param _accessManager The AccessManager contract address
     * @param _role The role ID to grant
     * @param _accounts Array of accounts to grant the role to
     * @param _executionDelay The delay for all accounts
     * @return transactions Array of Safe transactions
     */
    function buildGrantRoleBatch(
        address _accessManager,
        uint64 _role,
        address[] memory _accounts,
        uint32 _executionDelay
    )
        internal
        pure
        returns (SafeTransaction[] memory transactions)
    {
        transactions = new SafeTransaction[](_accounts.length);
        for (uint256 i = 0; i < _accounts.length; i++) {
            transactions[i] = buildGrantRole(_accessManager, _role, _accounts[i], _executionDelay);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // JSON WRITERS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Writes a Safe Transaction Builder compatible JSON file with custom description
     * @param _transactions Array of transactions to include in the batch
     * @param _outputFileName Output file name (e.g., "safe_config")
     * @param _name Name for the transaction batch (shown in Safe UI)
     * @param _description Description for the transaction batch
     */
    function writeSafeTransactionJson(
        SafeTransaction[] memory _transactions,
        string memory _outputFileName,
        string memory _name,
        string memory _description
    )
        internal
    {
        // Build each transaction object and collect into an array
        string[] memory txJsons = new string[](_transactions.length);
        for (uint256 i = 0; i < _transactions.length; i++) {
            string memory key = string.concat("tx", vm.toString(i));
            vm.serializeAddress(key, "to", _transactions[i].to);
            vm.serializeString(key, "value", vm.toString(_transactions[i].value));
            txJsons[i] = vm.serializeBytes(key, "data", _transactions[i].data);
        }

        // Build the root object
        string memory root = "root";
        vm.serializeString(root, "version", "1.0");
        vm.serializeString(root, "chainId", vm.toString(block.chainid));
        vm.serializeUint(root, "createdAt", vm.getBlockTimestamp());

        // Meta object
        string memory meta = "meta";
        vm.serializeString(meta, "name", _name);
        string memory metaJson = vm.serializeString(meta, "description", _description);
        vm.serializeString(root, "meta", metaJson);

        // Serialize transactions array
        string memory finalJson = vm.serializeString(root, "transactions", txJsons);

        // Write to file
        vm.writeJson(finalJson, string(abi.encodePacked(SAFE_TX_OUTPUT_DIRECTORY, _outputFileName, ".json")));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ARRAY UTILITIES
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Concatenates two SafeTransaction arrays
     * @param _a First array
     * @param _b Second array
     * @return result Combined array
     */
    function concatTransactions(SafeTransaction[] memory _a, SafeTransaction[] memory _b) internal pure returns (SafeTransaction[] memory result) {
        result = new SafeTransaction[](_a.length + _b.length);
        for (uint256 i = 0; i < _a.length; i++) {
            result[i] = _a[i];
        }
        for (uint256 i = 0; i < _b.length; i++) {
            result[_a.length + i] = _b[i];
        }
    }

    /**
     * @notice Creates a single-element SafeTransaction array
     * @param _tx The transaction to wrap
     * @return result Array containing just the transaction
     */
    function singleTransaction(SafeTransaction memory _tx) internal pure returns (SafeTransaction[] memory result) {
        result = new SafeTransaction[](1);
        result[0] = _tx;
    }
}
