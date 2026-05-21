// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoProtocolTemplate } from "./IRoycoProtocolTemplate.sol";

/**
 * @title IRoycoFactory
 * @notice External interface for the canonical Royco factory.
 *
 * @dev The factory is a singleton AccessManager that owns all Royco protocol roles AND drives
 *      market deployment through pluggable "templates" (recipes). It exposes:
 *        - **Admin entrypoints** for registering and disabling templates (gated by the
 *          factory's admin role).
 *        - **Deployer entrypoint** `executeMarketDeployment` which runs a registered
 *          template's deploy sequence atomically (deploy → verify → return).
 *        - **Template-callable primitives** that templates call back into during their
 *          deployment sequence (CREATE3 deploys + role wiring). All such primitives are
 *          gated by an "active template" check — only the template currently being executed
 *          can call them, and only during the active executeMarketDeployment window.
 */
interface IRoycoFactory {
    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Thrown when an action requires an enabled template but the template isn't registered.
    error TEMPLATE_NOT_ENABLED();
    /// @notice Thrown when attempting to register a template that's already enabled.
    error TEMPLATE_ALREADY_REGISTERED();
    /// @notice Thrown when the template was constructed pointing at a different factory.
    error TEMPLATE_BOUND_TO_DIFFERENT_FACTORY();
    /// @notice Thrown when a template-callable primitive is invoked outside an active deployment window.
    error NO_ACTIVE_TEMPLATE();
    /// @notice Thrown when a template-callable primitive is called by a contract that isn't the active template.
    error ONLY_ACTIVE_TEMPLATE();
    /// @notice Thrown when a candidate template address has no contract code at it.
    error TEMPLATE_HAS_NO_CODE();
    /// @notice Thrown when a candidate template address is the zero address.
    error TEMPLATE_CANNOT_BE_ZERO_ADDRESS();
    /// @notice Thrown when `initialize` is called with a zero `_roycoAccessManager`.
    error ACCESS_MANAGER_CANNOT_BE_ZERO_ADDRESS();
    /// @notice Thrown when the supplied `_roycoAccessManager` address has no contract code.
    error ACCESS_MANAGER_HAS_NO_CODE();
    /// @notice Thrown when the supplied AM does not have the factory as an `ADMIN_ROLE` holder at init time.
    error FACTORY_NOT_ADMIN_ON_ACCESS_MANAGER();
    /// @notice Thrown when a factory call fails.
    error FACTORY_CALL_FAILED(bytes result);

    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Persistent factory storage.
     * @dev Layout is ERC-7201 namespaced inside the factory implementation. The struct is
     *      declared on the interface so external tooling can read its shape.
     * @custom:storage-location erc7201:Royco.storage.RoycoFactoryV2State
     * @custom:field isTemplateEnabled - Set of registered + enabled templates.
     * @custom:field seniorTrancheToJuniorTranche - Mapping of senior tranche to junior tranche.
     * @custom:field juniorTrancheToSeniorTranche - Mapping of junior tranche to senior tranche.
     */
    struct RoycoFactoryState {
        mapping(address template => bool isEnabled) isTemplateEnabled;
        mapping(address st => address jt) seniorTrancheToJuniorTranche;
        mapping(address jt => address st) juniorTrancheToSeniorTranche;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a template is registered + initialized + enabled.
    event TemplateRegistered(address indexed template);
    /// @notice Emitted when a template is disabled (emergency hatch). Does NOT un-initialize.
    event TemplateDisabled(address indexed template);
    /// @notice Emitted at the start of `executeMarketDeployment` after auth + active-slot setup.
    event MarketDeploymentStarted(address indexed template, address indexed caller);
    /// @notice Emitted on successful end of `executeMarketDeployment` (after verify).
    event MarketDeploymentCompleted(address indexed template, IRoycoProtocolTemplate.DeploymentResult deployment);

    /// @notice Returns the non-upgradeable `AccessManager` that the factory deployed during
    ///         init. Every Royco market contract uses this as its authority.
    function ROYCO_AUTHORITY() external view returns (address);

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Atomically initialize a deployed template contract and add it to the enabled set.
     * @dev Admin-only (gated by the factory's `_ADMIN_ROLE`).
     *      Calls `template.initialize(_componentIds, _creationCodes)` and then flips the
     *      template's enabled bit in storage. Both steps happen in the same transaction —
     *      if `initialize` reverts, the template is NOT marked enabled.
     * @param _template Address of a deployed template contract bound to this factory.
     * @param _componentIds Parallel array of component IDs to load (see the template's
     *        documented ID space).
     * @param _creationCodes Parallel array of creation-code blobs for each component.
     */
    function registerTemplate(address _template, bytes32[] calldata _componentIds, bytes[] calldata _creationCodes) external;

    /**
     * @notice Emergency disable of a previously-registered template.
     * @dev Admin-only. Does NOT un-initialize the template — it just removes the enabled
     *      bit, preventing future deployments through it. Already-deployed markets are
     *      unaffected.
     * @param _template The template to disable.
     */
    function disableTemplate(address _template) external;

    /// @notice Returns whether a template is currently registered + enabled.
    function isTemplateEnabled(address _template) external view returns (bool);

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYER ENTRYPOINT
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Runs a registered template's full deployment + verification sequence.
     * @dev Gated by the deployer role on the factory (canonical `DEPLOYER_ROLE`).
     *      The factory:
     *        1. Sets `_activeTemplate = template` (templates can now call factory primitives).
     *        2. Calls `template.deployMarket(params)`.
     *        3. Calls `template.verify(deployment)` — any revert aborts the whole tx.
     *        4. Clears `_activeTemplate`.
     * @param _template The registered template to execute.
     * @param _params ABI-encoded template-specific params.
     * @return result The deployed market addresses.
     */
    function executeMarketDeployment(address _template, bytes calldata _params) external returns (IRoycoProtocolTemplate.DeploymentResult memory result);

    // ═══════════════════════════════════════════════════════════════════════════
    // TEMPLATE-CALLABLE PRIMITIVES
    // (gated by onlyActiveTemplate: only callable by the currently-running template,
    //  and only during the active executeMarketDeployment window)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice CREATE3-deploys a contract, idempotently.
     * @dev If a contract already exists at the predicted CREATE3 address for `_salt`, this
     *      function returns that address with `alreadyDeployed = true` and performs no
     *      deployment. Otherwise it deploys via `CREATE3.deployDeterministic`.
     * @param _creationCode Constructor-arg-bearing creation code.
     * @param _salt CREATE3 salt — pure function of `(deployer = this factory, salt)`.
     * @return deployed The CREATE3-deterministic address.
     * @return alreadyDeployed True iff the deployment was skipped because the contract was
     *         already at that address.
     */
    function deployDeterministicContract(bytes calldata _creationCode, bytes32 _salt) external returns (address deployed, bool alreadyDeployed);

    /**
     * @notice CREATE3-deploys an ERC1967 proxy pointing at `_implementation`, idempotently.
     * @dev Builds the standard ERC1967Proxy creation code with `(impl, initData)` then
     *      delegates to `deployDeterministicContract`. Same idempotency semantics.
     */
    function deployDeterministicProxy(
        address _implementation,
        bytes calldata _initData,
        bytes32 _salt
    )
        external
        returns (address deployed, bool alreadyDeployed);

    /// @notice Predicts the CREATE3-deterministic address for `_salt`.
    function predictDeterministicAddress(bytes32 _salt) external view returns (address);

    /**
     * @notice Template-side wrapper for `AccessManager.setTargetFunctionRole`.
     * @dev Templates call this during `deployMarket` to wire selector → role bindings on
     *      market contracts they just deployed. No target whitelist — templates can wire
     *      bindings on any contract they're authorized to bind for.
     */
    function setMarketTargetFunctionRole(address _target, bytes4 _selector, uint64 _roleId) external;

    /**
     * @notice Template-side wrapper for `AccessManager._grantRole`.
     * @dev Templates call this to grant a role to a market contract or address as part of
     *      deployment (e.g. SYNC_ROLE → accountant). Replaces the hardcoded SYNC_ROLE
     *      auto-grant in `RoycoDawnFactory`.
     */
    function grantMarketRole(uint64 _roleId, address _account, uint32 _executionDelay) external;

    /**
     * @notice Generic forwarder — invokes `_data` on `_target` from the factory's address.
     * @dev Active-template-only. Lets templates piggyback on roles the factory holds
     *      (e.g. `ADMIN_ENTRY_POINT_ROLE`, granted to the factory during init) to call into
     *      protocol-specific admin surfaces (entry points, oracle quoters, hook contracts,
     *      etc.) WITHOUT enshrining any of those contracts in the factory's ABI. The factory
     *      does not inspect or validate the payload — each template owns its own contract-by-
     *      contract calldata encoding.
     *
     *      Bubbles up the target's revert reason on failure.
     * @param _target The contract to call.
     * @param _data ABI-encoded calldata for the target.
     * @return result The raw return bytes from `_target`.
     */
    function executeAsFactory(address _target, bytes calldata _data) external returns (bytes memory result);

    /**
     * @notice Returns the junior tranche for a given senior tranche
     * @param _seniorTranche The senior tranche address
     * @return juniorTranche The junior tranche address
     */
    function seniorTrancheToJuniorTranche(address _seniorTranche) external view returns (address juniorTranche);

    /**
     * @notice Returns the senior tranche for a given junior tranche
     * @param _juniorTranche The junior tranche address
     * @return seniorTranche The senior tranche address
     */
    function juniorTrancheToSeniorTranche(address _juniorTranche) external view returns (address seniorTranche);
}
