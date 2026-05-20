// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title IRoycoProtocolTemplate
 * @notice Interface every market-deployment template must implement.
 * @dev Templates are pluggable "recipes" registered with `RoycoFactory`. They own:
 *      - per-recipe params encoding (taken/returned as `bytes` blobs by the factory)
 *      - the deployment sequence (calls back into factory primitives)
 *      - role-binding configuration produced as part of `deployMarket`
 *      - a post-deployment verification hook the factory runs atomically
 *
 *      Templates are one-shot initialized (via `initialize`) by the factory at registration
 *      time; their creation codes are loaded into SSTORE2-backed storage and frozen.
 */
interface IRoycoProtocolTemplate {
    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error ROYCO_FACTORY_CANNOT_BE_ZERO_ADDRESS();
    error ONLY_ROYCO_FACTORY();
    error INVALID_PARAMS();
    error LENGTH_MISMATCH();
    error CREATION_CODE_NOT_SET(bytes32 componentId);
    error CREATION_CODE_ALREADY_SET(bytes32 componentId);
    error CREATION_CODE_CANNOT_BE_EMPTY(bytes32 componentId);

    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice The outcome of a successful market deployment, returned by `deployMarket` and
     *         consumed by the factory's atomic `verify(...)` call.
     * @custom:field seniorTranche - Senior tranche proxy address
     * @custom:field juniorTranche - Junior tranche proxy address
     * @custom:field kernel - Kernel proxy address
     * @custom:field accountant - Accountant proxy address
     * @custom:field ydm - YDM singleton (may be shared across markets / templates)
     * @custom:field extras - Template-specific extra data (e.g. Dusk encodes Balancer pool + hooks here)
     */
    struct DeploymentResult {
        address seniorTranche;
        address juniorTranche;
        address kernel;
        address accountant;
        address ydm;
        bytes extras;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice One-shot initialization called by the factory at template registration time.
     * @dev Stores each `(componentId, creationCode)` pair via SSTORE2. Guarded by OZ's
     *      `initializer` modifier + a `msg.sender == ROYCO_FACTORY` check, so it can be
     *      called exactly once and only by the factory.
     * @param _componentIds Parallel array of component identifiers. Each template documents
     *        its own ID space; common IDs (ST/JT/Accountant/Kernel/YDM) are declared in
     *        `BaseDeploymentTemplate`.
     * @param _creationCodes Parallel array of creation-code blobs (constructor-arg-free —
     *        constructor args are appended at deploy time by the template).
     */
    function initialize(bytes32[] calldata _componentIds, bytes[] calldata _creationCodes) external;

    /**
     * @notice Validates a params payload without performing any deployment.
     * @dev Must revert with `INVALID_PARAMS()` (or a more specific error) on any invalid
     *      field. Used by tooling to pre-check a deployment before submitting it.
     * @param _params ABI-encoded template-specific params struct.
     */
    function validateParams(bytes calldata _params) external view;

    /**
     * @notice Orchestrates the full market deployment.
     * @dev Only callable by the factory via `executeMarketDeployment`. Templates call back
     *      into the factory's primitives (`deployDeterministicContract`,
     *      `deployDeterministicProxy`, `setMarketTargetFunctionRole`, `grantMarketRole`,
     *      `predictDeterministicAddress`) to perform the actual deployments and role wiring.
     * @param _params ABI-encoded template-specific params struct.
     * @return result The deployed addresses + any template-specific extras.
     */
    function deployMarket(bytes calldata _params) external returns (DeploymentResult memory result);

    /**
     * @notice Atomic post-deployment verification hook.
     * @dev Called by the factory immediately after `deployMarket` returns, in the same tx.
     *      Must revert if any cross-wiring or invariant is violated; the revert aborts the
     *      whole deployment. Should NOT have side effects.
     * @param _deployment The DeploymentResult returned by `deployMarket`.
     */
    function verify(DeploymentResult calldata _deployment) external view;
}
