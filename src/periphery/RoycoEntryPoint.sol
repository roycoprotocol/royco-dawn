// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ERC20BurnableUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import { IERC20, SafeERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { RoycoBase } from "../base/RoycoBase.sol";
import { IRoycoEntryPoint } from "../interfaces/IRoycoEntryPoint.sol";
import { IRoycoFactory } from "../interfaces/IRoycoFactory.sol";
import { IRoycoKernel } from "../interfaces/IRoycoKernel.sol";
import { IRoycoVaultTranche, TrancheType } from "../interfaces/IRoycoVaultTranche.sol";
import { MAX_NAV_UNITS, MAX_TRANCHE_UNITS, WAD, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../libraries/Constants.sol";
import { AssetClaims } from "../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, UnitsMathLib, toUint256 } from "../libraries/Units.sol";
import { UtilsLib } from "../libraries/UtilsLib.sol";

/**
 * @title RoycoEntryPoint
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Periphery contract enabling asynchronous deposit and redemption flows on Royco Tranches
 * @dev Enforces configurable delays between request and execution to prevent oracle front-running attacks
 *      Supports third-party executors (keepers) with configurable bonus incentives
 *      Partial execution is supported, allowing requests to be fulfilled incrementally
 */
contract RoycoEntryPoint is RoycoBase, IRoycoEntryPoint {
    using SafeERC20 for IERC20;
    using UnitsMathLib for NAV_UNIT;
    using UnitsMathLib for TRANCHE_UNIT;
    using UnitsMathLib for uint256;

    /// @dev Storage slot for RoycoEntryPointState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoEntryPoint")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROYCO_ENTRY_POINT_STORAGE_SLOT = 0x97dbcf4566a2e818822a3079c61056404fedac337d5f1e2910e98e13410bdb00;

    /**
     * @notice Storage state for the Royco entry point
     * @custom:field lastRequestNonce - The last assigned request nonce
     * @custom:field trancheToConfig - A mapping of tranches to their enriched entry point configurations
     * @custom:field userToNonceToDepositRequest - A mapping tracking each user's deposit requests by nonce
     * @custom:field userToNonceToRedemptionRequest - A mapping tracking each user's redemption requests by nonce
     * @custom:field trancheToProtocolFeeShares - A mapping tracking the protocol fee shares accrued for each tranche
     */
    struct RoycoEntryPointState {
        uint256 lastRequestNonce;
        mapping(address tranche => EnrichedTrancheConfig config) trancheToConfig;
        mapping(address user => mapping(uint256 requestNonce => DepositRequest request)) userToNonceToDepositRequest;
        mapping(address user => mapping(uint256 requestNonce => RedemptionRequest request)) userToNonceToRedemptionRequest;
        mapping(address tranche => uint256 protocolFeeShares) trancheToProtocolFeeShares;
    }

    /**
     * @notice Initializes the entry point state
     * @param _roycoFactory The canonical Royco factory responsible for deploying markets and acting as the singleton access manager
     * @param _tranches The tranches to enable for this entry point on initialization
     * @param _configs The configurations for each tranche
     */
    function initialize(address _roycoFactory, address[] calldata _tranches, TrancheConfig[] calldata _configs) external initializer {
        // Initialize the base entry point state
        __RoycoBase_init(_roycoFactory);

        // Initialize the entry point with the initial enabled tranches and their initial configurations
        _modifyTrancheConfigs(_tranches, _configs);
    }

    /// =============================
    /// Entry Point Deposit Functions
    /// =============================

    /// @inheritdoc IRoycoEntryPoint
    function requestDeposit(
        address _tranche,
        TRANCHE_UNIT _assets,
        address _receiver,
        uint64 _executorBonusWAD
    )
        external
        override(IRoycoEntryPoint)
        whenNotPaused
        restricted
        returns (uint256 requestNonce, uint32 executableAtTimestamp)
    {
        // Validate the deposit request
        require(_assets != ZERO_TRANCHE_UNITS, ZERO_AMOUNT());
        require(_tranche != address(0) && _receiver != address(0), NULL_ADDRESS());
        require(_executorBonusWAD <= WAD || _executorBonusWAD == type(uint64).max, INVALID_EXECUTOR_BONUS());

        // Ensure that the tranche is enabled on this entry point
        RoycoEntryPointState storage $ = _getRoycoEntryPointStorage();
        EnrichedTrancheConfig memory config = $.trancheToConfig[_tranche];
        require(config.baseConfig.enabled, TRANCHE_NOT_ENABLED());

        // Register the user's deposit request with a fresh nonce
        DepositRequest storage request = $.userToNonceToDepositRequest[msg.sender][requestNonce = ++$.lastRequestNonce];
        request.assets = _assets;
        request.baseRequest = BaseRequest({
            tranche: _tranche,
            receiver: _receiver,
            executableAtTimestamp: (executableAtTimestamp = uint32(block.timestamp + config.baseConfig.depositDelaySeconds)),
            executorBonusWAD: _executorBonusWAD
        });

        // Transfer the requested amount of tranche assets into the entry point to queue the deposit
        IERC20(config.asset).safeTransferFrom(msg.sender, address(this), toUint256(_assets));

        // Emit the deposit request event
        emit DepositRequested(msg.sender, requestNonce, _tranche, _assets, executableAtTimestamp, _executorBonusWAD);
    }

    /// @inheritdoc IRoycoEntryPoint
    function executeDeposits(
        address[] calldata _users,
        uint256[] calldata _requestNonces,
        TRANCHE_UNIT[] calldata _assetsToDeposit
    )
        external
        override(IRoycoEntryPoint)
        whenNotPaused
        restricted
        returns (uint256[] memory trancheSharesMinted)
    {
        // Execute the user specified deposit requests
        uint256 numRequestsToExecute = _requestNonces.length;
        require(numRequestsToExecute == _users.length && numRequestsToExecute == _assetsToDeposit.length, ARRAY_LENGTH_MISMATCH());
        trancheSharesMinted = new uint256[](numRequestsToExecute);
        for (uint256 i = 0; i < numRequestsToExecute; ++i) {
            trancheSharesMinted[i] = _executeDeposit(_users[i], _requestNonces[i], _assetsToDeposit[i]);
        }
    }

    /// @inheritdoc IRoycoEntryPoint
    function executeDeposit(
        address _user,
        uint256 _requestNonce,
        TRANCHE_UNIT _assetsToDeposit
    )
        external
        override(IRoycoEntryPoint)
        whenNotPaused
        restricted
        returns (uint256 trancheSharesMinted)
    {
        return _executeDeposit(_user, _requestNonce, _assetsToDeposit);
    }

    /// @inheritdoc IRoycoEntryPoint
    function cancelDepositRequests(uint256[] calldata _requestNonces, address _receiver) external override(IRoycoEntryPoint) {
        // Execute the user specified deposit request cancellations
        uint256 numRequestsToCancel = _requestNonces.length;
        for (uint256 i = 0; i < numRequestsToCancel; ++i) {
            cancelDepositRequest(_requestNonces[i], _receiver);
        }
    }

    /// @inheritdoc IRoycoEntryPoint
    function cancelDepositRequest(uint256 _requestNonce, address _receiver) public override(IRoycoEntryPoint) whenNotPaused restricted {
        // Ensure the receiver isn't null
        require(_receiver != address(0), NULL_ADDRESS());
        // Retrieve the user's specified deposit request and assert that it exists
        RoycoEntryPointState storage $ = _getRoycoEntryPointStorage();
        DepositRequest memory request = $.userToNonceToDepositRequest[msg.sender][_requestNonce];
        require(request.assets != ZERO_TRANCHE_UNITS, INVALID_REQUEST(_requestNonce));

        // Mark the request as cancelled
        delete $.userToNonceToDepositRequest[msg.sender][_requestNonce];

        // Return the assets from the cancelled request to the specified receiver
        address asset = $.trancheToConfig[request.baseRequest.tranche].asset;
        IERC20(asset).safeTransfer(_receiver, toUint256(request.assets));

        // Emit the deposit request cancellation event
        emit DepositRequestCancelled(msg.sender, _requestNonce, _receiver, request.assets);
    }

    /// =============================
    /// Entry Point Redemption Functions
    /// =============================

    /// @inheritdoc IRoycoEntryPoint
    function requestRedemption(
        address _tranche,
        uint256 _shares,
        address _receiver,
        uint64 _executorBonusWAD
    )
        external
        override(IRoycoEntryPoint)
        whenNotPaused
        restricted
        returns (uint256 requestNonce, uint32 executableAtTimestamp)
    {
        // Validate the redemption request
        require(_shares != 0, ZERO_AMOUNT());
        require(_tranche != address(0) && _receiver != address(0), NULL_ADDRESS());
        require(_executorBonusWAD <= WAD || _executorBonusWAD == type(uint64).max, INVALID_EXECUTOR_BONUS());

        // Ensure that the tranche is enabled on this entry point
        RoycoEntryPointState storage $ = _getRoycoEntryPointStorage();
        EnrichedTrancheConfig memory config = $.trancheToConfig[_tranche];
        require(config.baseConfig.enabled, TRANCHE_NOT_ENABLED());

        // Register the user's redemption request with a fresh nonce
        RedemptionRequest storage request = $.userToNonceToRedemptionRequest[msg.sender][requestNonce = ++$.lastRequestNonce];
        request.shares = _shares;
        // If the redeeming LP receives the yield accrued, set to MAX_NAV_UNITS so that navAtExecutionTime is never greater, effectively disabling yield forfeiture
        request.navAtRequestTime =
        (config.baseConfig.yieldRecipient != AccruedYieldRecipient.REDEEMING_LP ? IRoycoVaultTranche(_tranche).convertToAssets(_shares).nav : MAX_NAV_UNITS);
        request.baseRequest = BaseRequest({
            tranche: _tranche,
            receiver: _receiver,
            executableAtTimestamp: (executableAtTimestamp = uint32(block.timestamp + config.baseConfig.redemptionDelaySeconds)),
            executorBonusWAD: _executorBonusWAD
        });

        // Transfer the requested amount of tranche shares into the entry point to queue the redemption
        IERC20(_tranche).safeTransferFrom(msg.sender, address(this), _shares);

        // Emit the redemption request event
        emit RedemptionRequested(msg.sender, requestNonce, _tranche, _shares, executableAtTimestamp, _executorBonusWAD);
    }

    /// @inheritdoc IRoycoEntryPoint
    function executeRedemptions(
        address[] calldata _users,
        uint256[] calldata _requestNonces,
        uint256[] calldata _sharesToRedeem
    )
        external
        override(IRoycoEntryPoint)
        whenNotPaused
        restricted
        returns (AssetClaims[] memory userClaims)
    {
        // Execute the user specified redemption requests
        uint256 numRequestsToExecute = _requestNonces.length;
        require(numRequestsToExecute == _users.length && numRequestsToExecute == _sharesToRedeem.length, ARRAY_LENGTH_MISMATCH());
        userClaims = new AssetClaims[](numRequestsToExecute);
        for (uint256 i = 0; i < numRequestsToExecute; ++i) {
            userClaims[i] = _executeRedemption(_users[i], _requestNonces[i], _sharesToRedeem[i]);
        }
    }

    /// @inheritdoc IRoycoEntryPoint
    function executeRedemption(
        address _user,
        uint256 _requestNonce,
        uint256 _sharesToRedeem
    )
        external
        override(IRoycoEntryPoint)
        whenNotPaused
        restricted
        returns (AssetClaims memory userClaims)
    {
        return _executeRedemption(_user, _requestNonce, _sharesToRedeem);
    }

    /// @inheritdoc IRoycoEntryPoint
    function cancelRedemptionRequests(uint256[] calldata _requestNonces, address _receiver) external override(IRoycoEntryPoint) {
        // Execute the user specified redemption request cancellations
        uint256 numRequestsToCancel = _requestNonces.length;
        for (uint256 i = 0; i < numRequestsToCancel; ++i) {
            cancelRedemptionRequest(_requestNonces[i], _receiver);
        }
    }

    /// @inheritdoc IRoycoEntryPoint
    function cancelRedemptionRequest(uint256 _requestNonce, address _receiver) public override(IRoycoEntryPoint) whenNotPaused restricted {
        // Ensure the receiver isn't null
        require(_receiver != address(0), NULL_ADDRESS());
        // Retrieve the user's specified redemption request and assert that it exists
        RoycoEntryPointState storage $ = _getRoycoEntryPointStorage();
        RedemptionRequest memory request = $.userToNonceToRedemptionRequest[msg.sender][_requestNonce];
        require(request.shares != 0, INVALID_REQUEST(_requestNonce));

        // Mark the request as cancelled
        delete $.userToNonceToRedemptionRequest[msg.sender][_requestNonce];

        // Return the shares from the cancelled request to the specified receiver
        IERC20(request.baseRequest.tranche).safeTransfer(_receiver, request.shares);

        // Emit the redemption request cancellation event
        emit RedemptionRequestCancelled(msg.sender, _requestNonce, _receiver, request.shares);
    }

    /// =============================
    /// Admin Functions
    /// =============================

    /// @inheritdoc IRoycoEntryPoint
    function modifyTrancheConfigs(address[] calldata _tranches, TrancheConfig[] calldata _configs) external override(IRoycoEntryPoint) restricted {
        _modifyTrancheConfigs(_tranches, _configs);
    }

    /// @inheritdoc IRoycoEntryPoint
    function collectProtocolFees(
        address[] calldata _tranches,
        uint256[] calldata _sharesToClaim,
        address _receiver
    )
        external
        override(IRoycoEntryPoint)
        restricted
    {
        require(_receiver != address(0), NULL_ADDRESS());
        // Ensure that each tranche has a specified amount of protocol fee shares to claim
        uint256 numTranches = _tranches.length;
        require(numTranches == _sharesToClaim.length, ARRAY_LENGTH_MISMATCH());

        // Claim the specified protocol fee shares for each specified tranche
        RoycoEntryPointState storage $ = _getRoycoEntryPointStorage();
        for (uint256 i = 0; i < numTranches; ++i) {
            address tranche = _tranches[i];
            uint256 sharesToClaim = (_sharesToClaim[i] == type(uint256).max) ? $.trancheToProtocolFeeShares[tranche] : _sharesToClaim[i];
            if (sharesToClaim == 0) continue;
            $.trancheToProtocolFeeShares[tranche] -= sharesToClaim;
            IERC20(tranche).safeTransfer(_receiver, sharesToClaim);
            emit ProtocolFeeSharesCollected(tranche, _receiver, sharesToClaim);
        }
    }

    /// =============================
    /// State Accessor Functions
    /// =============================

    /// @inheritdoc IRoycoEntryPoint
    function getLastRequestNonce() external view override(IRoycoEntryPoint) returns (uint256 nonce) {
        return _getRoycoEntryPointStorage().lastRequestNonce;
    }

    /// @inheritdoc IRoycoEntryPoint
    function getTrancheConfig(address _tranche) external view override(IRoycoEntryPoint) returns (EnrichedTrancheConfig memory config) {
        return _getRoycoEntryPointStorage().trancheToConfig[_tranche];
    }

    /// @inheritdoc IRoycoEntryPoint
    function getDepositRequest(address _user, uint256 _requestNonce) external view override(IRoycoEntryPoint) returns (DepositRequest memory request) {
        return _getRoycoEntryPointStorage().userToNonceToDepositRequest[_user][_requestNonce];
    }

    /// @inheritdoc IRoycoEntryPoint
    function getRedemptionRequest(address _user, uint256 _requestNonce) external view override(IRoycoEntryPoint) returns (RedemptionRequest memory request) {
        return _getRoycoEntryPointStorage().userToNonceToRedemptionRequest[_user][_requestNonce];
    }

    /// @inheritdoc IRoycoEntryPoint
    function getProtocolFeeSharesPendingCollection(address _tranche) external view override(IRoycoEntryPoint) returns (uint256 shares) {
        return _getRoycoEntryPointStorage().trancheToProtocolFeeShares[_tranche];
    }

    /// =============================
    /// Internal Utility Functions
    /// =============================

    /**
     * @notice Executes a pending deposit request for the specified user
     * @dev The request must exist and the configured delay period must have elapsed
     *      If executed by a third party, the executor bonus is paid in assets before depositing the remainder
     * @param _user The user whose deposit request should be executed
     * @param _requestNonce The nonce of the deposit request to execute
     * @param _assetsToDeposit The amount of assets to deposit (use MAX_TRANCHE_UNITS to deposit the maximum possible)
     * @return trancheSharesMinted The amount of tranche shares minted to the receiver
     */
    function _executeDeposit(address _user, uint256 _requestNonce, TRANCHE_UNIT _assetsToDeposit) internal returns (uint256 trancheSharesMinted) {
        require(_assetsToDeposit != ZERO_TRANCHE_UNITS, ZERO_AMOUNT());
        // Retrieve the user's specified deposit request and assert its validity
        RoycoEntryPointState storage $ = _getRoycoEntryPointStorage();
        DepositRequest memory request = $.userToNonceToDepositRequest[_user][_requestNonce];
        _validateRequestExecution(_requestNonce, request.baseRequest.executableAtTimestamp);

        // Ensure the tranche is still enabled
        address tranche = request.baseRequest.tranche;
        EnrichedTrancheConfig memory config = $.trancheToConfig[tranche];
        require(config.baseConfig.enabled, TRANCHE_NOT_ENABLED());

        // Resolve the actual amount of assets to deposit
        _assetsToDeposit = (_assetsToDeposit == MAX_TRANCHE_UNITS)
            ? UnitsMathLib.min(IRoycoVaultTranche(tranche).maxDeposit(request.baseRequest.receiver), request.assets)
            : _assetsToDeposit;
        // Return early without reverting if maxDeposit is 0 due to market conditions
        if (_assetsToDeposit == ZERO_TRANCHE_UNITS) return 0;

        // Mark the assets as deposited
        TRANCHE_UNIT assetsLeftToDeposit = request.assets - _assetsToDeposit;
        if (assetsLeftToDeposit == ZERO_TRANCHE_UNITS) delete $.userToNonceToDepositRequest[_user][_requestNonce];
        else $.userToNonceToDepositRequest[_user][_requestNonce].assets = assetsLeftToDeposit;

        // Execute the deposit on the underlying tranche
        TRANCHE_UNIT bonusAssets;
        // If this is a self-deposit or there is no executor bonus configured, mint shares directly to the specified recipient
        if (_user == msg.sender || request.baseRequest.executorBonusWAD == 0) {
            IERC20(config.asset).forceApprove(tranche, toUint256(_assetsToDeposit));
            trancheSharesMinted = IRoycoVaultTranche(tranche).deposit(_assetsToDeposit, request.baseRequest.receiver);
        }
        // If this is an third party execution, remit the executor bonus and deposit the remaining assets
        else {
            // Ensure that the user has opted into third party execution
            require(request.baseRequest.executorBonusWAD != type(uint64).max, THIRD_PARTY_EXECUTION_DISABLED());
            // Compute and transfer bonus assets to the executor
            bonusAssets = _assetsToDeposit.mulDiv(request.baseRequest.executorBonusWAD, WAD, Math.Rounding.Floor);
            if (bonusAssets != ZERO_TRANCHE_UNITS) IERC20(config.asset).safeTransfer(msg.sender, toUint256(bonusAssets));
            // Deposit assets and mint shares directly to the specified receiver
            _assetsToDeposit = _assetsToDeposit - bonusAssets;
            IERC20(config.asset).forceApprove(tranche, toUint256(_assetsToDeposit));
            trancheSharesMinted = IRoycoVaultTranche(tranche).deposit(_assetsToDeposit, request.baseRequest.receiver);
        }

        // Emit the deposit execution event
        emit DepositExecuted(_user, _requestNonce, msg.sender, _assetsToDeposit, trancheSharesMinted, bonusAssets);
    }

    /**
     * @notice Executes a pending redemption request for the specified user
     * @dev The request must exist and the configured delay period must have elapsed
     * @param _user The user whose redemption request should be executed
     * @param _requestNonce The nonce of the redemption request to execute
     * @param _sharesToRedeem The amount of shares to redeem (use type(uint256).max to redeem the maximum possible)
     * @return userClaims The assets withdrawn to the request-specific receiver upon executing this redemption request
     */
    function _executeRedemption(address _user, uint256 _requestNonce, uint256 _sharesToRedeem) internal returns (AssetClaims memory userClaims) {
        require(_sharesToRedeem != 0, ZERO_AMOUNT());
        // Retrieve the user's specified redemption request and assert its validity
        RoycoEntryPointState storage $ = _getRoycoEntryPointStorage();
        RedemptionRequest memory request = $.userToNonceToRedemptionRequest[_user][_requestNonce];
        _validateRequestExecution(_requestNonce, request.baseRequest.executableAtTimestamp);

        // Ensure the tranche is still enabled
        address tranche = request.baseRequest.tranche;
        EnrichedTrancheConfig memory config = $.trancheToConfig[tranche];
        require(config.baseConfig.enabled, TRANCHE_NOT_ENABLED());

        // Resolve the actual amount of shares to redeem
        _sharesToRedeem =
            (_sharesToRedeem == type(uint256).max) ? Math.min(IRoycoVaultTranche(tranche).maxRedeem(address(this)), request.shares) : _sharesToRedeem;
        // Return early without reverting if maxRedeem is 0 due to market conditions
        if (_sharesToRedeem == 0) return AssetClaims(ZERO_TRANCHE_UNITS, ZERO_TRANCHE_UNITS, ZERO_NAV_UNITS);

        // Mark the shares as redeemed
        uint256 sharesLeftToRedeem = request.shares - _sharesToRedeem;
        if (sharesLeftToRedeem == 0) {
            delete $.userToNonceToRedemptionRequest[_user][_requestNonce];
        } else {
            $.userToNonceToRedemptionRequest[_user][_requestNonce].shares = sharesLeftToRedeem;
            // Scale the NAV of the remaining shares in the request by the shares left to redeem
            if (request.navAtRequestTime != MAX_NAV_UNITS) {
                NAV_UNIT navOfSharesLeftToRedeem = request.navAtRequestTime.mulDiv(sharesLeftToRedeem, request.shares, Math.Rounding.Floor);
                $.userToNonceToRedemptionRequest[_user][_requestNonce].navAtRequestTime = navOfSharesLeftToRedeem;
                request.navAtRequestTime = request.navAtRequestTime - navOfSharesLeftToRedeem;
            }
        }

        // If this is a self-redemption or there is no executor bonus configured, withdraw assets directly to the specified recipient
        uint256 userSharesRedeemed;
        uint256 forfeitedYieldShares;
        AssetClaims memory bonusClaims;
        if (_user == msg.sender || request.baseRequest.executorBonusWAD == 0) {
            // Redeem shares and route yield directly to the receiver
            (userSharesRedeemed, forfeitedYieldShares, userClaims) =
                _redeemWithYieldRouting(tranche, config, _sharesToRedeem, request.navAtRequestTime, request.baseRequest.receiver);
        }
        // If this is a third party execution, withdraw the assets, handle any yield as configured, and remit the executor bonus
        else {
            // Ensure that the user has opted into third party execution
            require(request.baseRequest.executorBonusWAD != type(uint64).max, THIRD_PARTY_EXECUTION_DISABLED());

            // Redeem shares and route yield to this contract for bonus calculation
            (userSharesRedeemed, forfeitedYieldShares, userClaims) =
                _redeemWithYieldRouting(tranche, config, _sharesToRedeem, request.navAtRequestTime, address(this));

            // Scale the asset claims to compute the executor bonus and the receiver's portion
            bonusClaims = UtilsLib.scaleAssetClaims(userClaims, request.baseRequest.executorBonusWAD, WAD);
            userClaims.stAssets = userClaims.stAssets - bonusClaims.stAssets;
            userClaims.jtAssets = userClaims.jtAssets - bonusClaims.jtAssets;
            userClaims.nav = userClaims.nav - bonusClaims.nav;

            // Transfer bonus and remaining assets to executor and receiver respectively
            address kernel = IRoycoVaultTranche(tranche).KERNEL();
            address stAsset = IRoycoKernel(kernel).ST_ASSET();
            address jtAsset = IRoycoKernel(kernel).JT_ASSET();
            if (stAsset == jtAsset) {
                // Batch transfer if same asset
                TRANCHE_UNIT totalBonus = bonusClaims.stAssets + bonusClaims.jtAssets;
                TRANCHE_UNIT totalUserAssets = userClaims.stAssets + userClaims.jtAssets;
                if (totalBonus != ZERO_TRANCHE_UNITS) IERC20(stAsset).safeTransfer(msg.sender, toUint256(totalBonus));
                if (totalUserAssets != ZERO_TRANCHE_UNITS) IERC20(stAsset).safeTransfer(request.baseRequest.receiver, toUint256(totalUserAssets));
            } else {
                // Transfer each asset separately
                if (bonusClaims.stAssets != ZERO_TRANCHE_UNITS) IERC20(stAsset).safeTransfer(msg.sender, toUint256(bonusClaims.stAssets));
                if (bonusClaims.jtAssets != ZERO_TRANCHE_UNITS) IERC20(jtAsset).safeTransfer(msg.sender, toUint256(bonusClaims.jtAssets));
                if (userClaims.stAssets != ZERO_TRANCHE_UNITS) IERC20(stAsset).safeTransfer(request.baseRequest.receiver, toUint256(userClaims.stAssets));
                if (userClaims.jtAssets != ZERO_TRANCHE_UNITS) IERC20(jtAsset).safeTransfer(request.baseRequest.receiver, toUint256(userClaims.jtAssets));
            }
        }

        // Emit the redemption execution event
        emit RedemptionExecuted(_user, _requestNonce, msg.sender, userSharesRedeemed, forfeitedYieldShares, userClaims, bonusClaims);
    }

    /**
     * @dev Asserts that a request exists and is executable (not executed already or cancelled)
     * @param _requestNonce The nonce of the request being validated
     * @param _executableAtTimestamp The timestamp after which the request can be executed
     */
    function _validateRequestExecution(uint256 _requestNonce, uint256 _executableAtTimestamp) internal view {
        require(_executableAtTimestamp != 0 && _executableAtTimestamp <= block.timestamp, INVALID_REQUEST(_requestNonce));
    }

    /**
     * @dev Redeems shares and routes accrued yield based on the tranche's configuration
     * @param _tranche The tranche to redeem shares from
     * @param _config The enriched tranche configuration
     * @param _shares The amount of shares to redeem from the tranche
     * @param _navAtRequestTime The NAV of the shares being redeemed at the time the redemption was requested
     * @param _receiver The address to receive the redeemed assets
     * @return userSharesRedeemed The shares actually redeemed for the user (total minus forfeited)
     * @return forfeitedYieldShares The shares forfeited equating to the yield accrued during the request lifecycle (zero if NAV decreased or the redeeming LP keeps the yield for this tranche)
     * @return userClaims The assets withdrawn from the tranche for the user after routing yield as configured
     */
    function _redeemWithYieldRouting(
        address _tranche,
        EnrichedTrancheConfig memory _config,
        uint256 _shares,
        NAV_UNIT _navAtRequestTime,
        address _receiver
    )
        internal
        returns (uint256 userSharesRedeemed, uint256 forfeitedYieldShares, AssetClaims memory userClaims)
    {
        // Initialize the user's shares redeemed as the input
        userSharesRedeemed = _shares;
        // If the entire value of the shares goes to the LP, redeem all the shares
        if (_config.baseConfig.yieldRecipient == AccruedYieldRecipient.REDEEMING_LP) {
            userClaims = IRoycoVaultTranche(_tranche).redeem(_shares, _receiver, address(this));
        } else {
            // Compute the tranche shares equivalent to the value of the yield accrued since placing the request
            NAV_UNIT navAtExecutionTime = IRoycoVaultTranche(_tranche).convertToAssets(_shares).nav;
            if (navAtExecutionTime > _navAtRequestTime) {
                forfeitedYieldShares = _shares.mulDiv((navAtExecutionTime - _navAtRequestTime), navAtExecutionTime, Math.Rounding.Floor);
            }
            // Redeem the shares the user is entitled to after deducting the forfeited yield shares
            userClaims = IRoycoVaultTranche(_tranche).redeem((userSharesRedeemed -= forfeitedYieldShares), _receiver, address(this));
            // If yield was accrued, handle it using the configured method
            if (forfeitedYieldShares != 0) {
                // If accrued yield is sent to the protocol, add them to the protocol accounting
                if (_config.baseConfig.yieldRecipient == AccruedYieldRecipient.PROTOCOL) {
                    _getRoycoEntryPointStorage().trancheToProtocolFeeShares[_tranche] += forfeitedYieldShares;
                    emit ProtocolFeeSharesAccrued(_tranche, forfeitedYieldShares);
                }
                // If accrued yield should be distributed to the remaining LPs, burn the shares, effectively donating the yield to the pool
                else {
                    ERC20BurnableUpgradeable(_tranche).burn(forfeitedYieldShares);
                }
            }
        }
    }

    /**
     * @dev Modifies the entry point configuration for the specified tranches
     * @param _tranches The tranches to modify configurations for
     * @param _configs The new configurations for each tranche
     */
    function _modifyTrancheConfigs(address[] calldata _tranches, TrancheConfig[] calldata _configs) internal {
        // Ensure that each tranche has a specified config
        uint256 numTranches = _tranches.length;
        require(numTranches == _configs.length, ARRAY_LENGTH_MISMATCH());

        // Ensure that each tranche was deployed by the Royco factory and update their configurations
        RoycoEntryPointState storage $ = _getRoycoEntryPointStorage();
        for (uint256 i = 0; i < numTranches; ++i) {
            address tranche = _tranches[i];
            _validateTranche(tranche);
            $.trancheToConfig[tranche] = EnrichedTrancheConfig({ asset: IRoycoVaultTranche(tranche).asset(), baseConfig: _configs[i] });
            emit TrancheConfigUpdated(tranche, _configs[i]);
        }
    }

    /// @dev Validates whether a tranche was deployed by the canonical Royco Factory
    /// @param _ostensibleRoycoTranche The ostensibly valid Royco tranche to validate
    function _validateTranche(address _ostensibleRoycoTranche) internal view {
        require(_ostensibleRoycoTranche != address(0), NULL_ADDRESS());
        // Get the paired tranche from the factory to validate the input tranche was factory-deployed
        address correspondingTranche = IRoycoVaultTranche(_ostensibleRoycoTranche).TRANCHE_TYPE() == TrancheType.SENIOR
            ? IRoycoFactory(authority()).seniorTrancheToJuniorTranche(_ostensibleRoycoTranche)
            : IRoycoFactory(authority()).juniorTrancheToSeniorTranche(_ostensibleRoycoTranche);
        require(correspondingTranche != address(0), INVALID_TRANCHE());
    }

    /**
     * @notice Returns a storage pointer to the RoycoEntryPointState storage
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer to the entry point's state
     */
    function _getRoycoEntryPointStorage() internal pure returns (RoycoEntryPointState storage $) {
        assembly ("memory-safe") {
            $.slot := ROYCO_ENTRY_POINT_STORAGE_SLOT
        }
    }
}
