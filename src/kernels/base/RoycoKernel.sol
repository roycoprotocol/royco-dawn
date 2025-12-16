// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import { IERC20Metadata, IERC4626 } from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { RoycoAuth, RoycoRoles } from "../../auth/RoycoAuth.sol";
import { IRDM } from "../../interfaces/IRDM.sol";
import { IRoycoKernel } from "../../interfaces/kernel/IRoycoKernel.sol";
import { IRoycoVaultTranche } from "../../interfaces/tranche/IRoycoVaultTranche.sol";
import { RoycoKernelInitParams, RoycoKernelState, RoycoKernelStorageLib } from "../../libraries/RoycoKernelStorageLib.sol";
import { SyncedNAVsPacket, SyncedNAVsPacketRAY } from "../../libraries/Types.sol";
import { ConstantsLib, Math, UtilsLib } from "../../libraries/UtilsLib.sol";
import { IRoycoAccountant, Operation } from "./../../interfaces/IRoycoAccountant.sol";

/**
 * @title RoycoKernel
 * @notice Abstract contract for Royco kernel implementations
 * @dev Provides the foundational logic for kernel contracts including pre and post operation NAV reconciliation, coverage enforcement logic,
 *      and base wiring for tranche synchronization. All concrete kernel implementations should inherit from the Royco Kernel.
 */
abstract contract RoycoKernel is IRoycoKernel, UUPSUpgradeable, RoycoAuth {
    using Math for uint256;

    /// @dev Permissions the function to only the market's senior tranche
    /// @dev Should be placed on all ST deposit and withdraw functions
    modifier onlySeniorTranche() {
        require(msg.sender == RoycoKernelStorageLib._getRoycoKernelStorage().seniorTranche, ONLY_SENIOR_TRANCHE());
        _;
    }

    /// @dev Permissions the function to only the market's junior tranche
    /// @dev Should be placed on all JT deposit and withdraw functions
    modifier onlyJuniorTranche() {
        require(msg.sender == RoycoKernelStorageLib._getRoycoKernelStorage().juniorTranche, ONLY_JUNIOR_TRANCHE());
        _;
    }

    /**
     * @notice Initializes the base kernel state
     * @dev Initializes any parent contracts and the base kernel state
     * @param _params The initialization parameters for the Royco kernel
     * @param _owner The initial owner of the base kernel
     * @param _pauser The initial pauser of the base kernel
     */
    function __RoycoKernel_init(RoycoKernelInitParams memory _params, address _owner, address _pauser) internal onlyInitializing {
        // Initialize the auth state of the kernel
        __RoycoAuth_init(_owner, _pauser);
        // Initialize the base kernel state
        __RoycoKernel_init_unchained(_params);
    }

    /**
     * @notice Initializes the base kernel state
     * @dev Checks the initial market's configuration and initializes the base kernel state
     * @param _params The initialization parameters for the base kernel
     */
    function __RoycoKernel_init_unchained(RoycoKernelInitParams memory _params) internal onlyInitializing {
        // Ensure that the tranche addresses, accountant, and protocol fee recipient are not null
        require(
            _params.seniorTranche != address(0) && _params.juniorTranche != address(0) && _params.accountant != address(0)
                && _params.protocolFeeRecipient != address(0),
            NULL_ADDRESS()
        );

        // Get the decimals for each tranche's base asset and ensure they are less than or equal to RAY decimals of precision
        uint8 stDecimals = IERC20Metadata(IERC4626(_params.seniorTranche).asset()).decimals();
        uint8 jtDecimals = IERC20Metadata(IERC4626(_params.juniorTranche).asset()).decimals();
        require(stDecimals <= ConstantsLib.RAY_DECIMALS && jtDecimals <= ConstantsLib.RAY_DECIMALS, UNSUPPORTED_DECIMALS());

        // Compute the scaling factor that will scale each tranche's asset quantities to RAY precision
        // These will be used to interface with the accountant and the tranches
        // All accounting is done in RAY precision and all tranche operations are done on the base asset's native precision
        uint96 stScaleFactorToRAY = uint96(10 ** (ConstantsLib.RAY_DECIMALS - stDecimals));
        uint96 jtScaleFactorToRAY = uint96(10 ** (ConstantsLib.RAY_DECIMALS - jtDecimals));

        // Initialize the base kernel state
        RoycoKernelStorageLib.__RoycoKernel_init(_params, stScaleFactorToRAY, jtScaleFactorToRAY);
    }

    /// @inheritdoc IRoycoKernel
    function stMaxDeposit(address, address _receiver) external view override(IRoycoKernel) returns (uint256) {
        // Get each tranche's raw NAV scaled to RAY precision
        (uint256 stRawNavRAY, uint256 jtRawNavRAY, uint96 stScaleFactorToRAY,) = _getTrancheRawNAVsRAY();
        // Get the max ST deposit amount scaled to RAY precision
        uint256 maxSTDepositRAY = _accountant().maxSTDepositGivenCoverage(stRawNavRAY, jtRawNavRAY);
        // Return the minimum of the max globally depositable and the max depositable without violating the coverage requirement (scaled to the base asset's precision)
        return Math.min(_maxSTDepositGlobally(_receiver), UtilsLib.scaleFromRAY(maxSTDepositRAY, stScaleFactorToRAY));
    }

    /// @inheritdoc IRoycoKernel
    function stMaxWithdraw(address, address _owner) external view override(IRoycoKernel) returns (uint256) {
        return _maxSTWithdrawalGlobally(_owner);
    }

    /// @inheritdoc IRoycoKernel
    function jtMaxDeposit(address, address _receiver) external view override(IRoycoKernel) returns (uint256) {
        return _maxJTDepositGlobally(_receiver);
    }

    /// @inheritdoc IRoycoKernel
    function jtMaxWithdraw(address, address _owner) external view override(IRoycoKernel) returns (uint256) {
        // Get each tranche's raw NAV scaled to RAY precision
        (uint256 stRawNavRAY, uint256 jtRawNavRAY,, uint96 jtScaleFactorToRAY) = _getTrancheRawNAVsRAY();
        // Get the max JT withdrawal amount scaled to RAY precision
        uint256 maxJTWithdrawalRAY = _accountant().maxJTWithdrawalGivenCoverage(stRawNavRAY, jtRawNavRAY);
        // Return the minimum of the max globally withdrawable and the max withdrawable without violating the coverage requirement (scaled to the base asset's precision)
        return Math.min(_maxJTWithdrawalGlobally(_owner), UtilsLib.scaleFromRAY(maxJTWithdrawalRAY, jtScaleFactorToRAY));
    }

    /// @inheritdoc IRoycoKernel
    function getSTRawNAV() external view override(IRoycoKernel) returns (uint256) {
        return _getSeniorTrancheRawNAV();
    }

    /// @inheritdoc IRoycoKernel
    function getJTRawNAV() external view override(IRoycoKernel) returns (uint256) {
        return _getJuniorTrancheRawNAV();
    }

    /**
     * @notice Synchronizes and persists the raw and effective NAVs of both tranches
     * @dev Only executes a pre-op sync because there is no operation being executed in the same call as this sync
     * @return packet The synced NAV packet containing all mark to market accounting data scaled to RAY precision
     */
    function syncTrancheNAVs() external override(IRoycoKernel) onlyRole(RoycoRoles.SYNC_ROLE) whenNotPaused returns (SyncedNAVsPacket memory packet) {
        return _preOpSyncTrancheNAVs();
    }

    /**
     * @notice Previews a synchronization of the raw and effective NAVs of both tranches
     * @dev Does not mutate any state
     * @return packet The synced NAV packet containing all mark to market accounting data scaled to RAY precision
     */
    function previewSyncTrancheNAVs() public view override(IRoycoKernel) returns (SyncedNAVsPacket memory packet) {
        // Get each tranche's raw NAV scaled to RAY precision
        (uint256 stRawNavRAY, uint256 jtRawNavRAY, uint96 stScaleFactorToRAY, uint96 jtScaleFactorToRAY) = _getTrancheRawNAVsRAY();
        return UtilsLib.scaleSyncedNAVsPacketFromRAY(_accountant().previewSyncTrancheNAVs(stRawNavRAY, jtRawNavRAY), stScaleFactorToRAY, jtScaleFactorToRAY);
    }

    /**
     * @notice Invokes the accountant to do a pre-operation (deposit and withdrawal) NAV sync
     * @dev Should be called on every NAV mutating user operation
     * @return packet The synced NAV packet containing all mark to market accounting data scaled to RAY precision
     */
    function _preOpSyncTrancheNAVs() internal returns (SyncedNAVsPacket memory packet) {
        // Get each tranche's raw NAV scaled to RAY precision
        (uint256 stRawNavRAY, uint256 jtRawNavRAY, uint96 stScaleFactorToRAY, uint96 jtScaleFactorToRAY) = _getTrancheRawNAVsRAY();
        // Execute the pre-op sync via the accountant
        packet = UtilsLib.scaleSyncedNAVsPacketFromRAY(_accountant().preOpSyncTrancheNAVs(stRawNavRAY, jtRawNavRAY), stScaleFactorToRAY, jtScaleFactorToRAY);
        // Collect any protocol fees accrued
        _collectProtocolFees(packet);
    }

    /**
     * @notice Invokes the accountant to do a post-operation (deposit and withdrawal) NAV sync
     * @dev Should be called on every NAV mutating user operation that doesn't require a coverage check
     * @param _op The operation being executed in between the pre and post synchronizations
     */
    function _postOpSyncTrancheNAVs(Operation _op) internal {
        // Get each tranche's raw NAV scaled to RAY precision
        (uint256 stRawNavRAY, uint256 jtRawNavRAY,,) = _getTrancheRawNAVsRAY();
        // Execute the post-op sync on the accountant
        _accountant().postOpSyncTrancheNAVs(stRawNavRAY, jtRawNavRAY, _op);
    }

    /**
     * @notice Invokes the accountant to do a post-operation (deposit and withdrawal) NAV sync and checks the market's coverage requirement is satisfied
     * @dev Should be called on every NAV mutating user operation that requires a coverage check: ST deposit and JT withdrawal
     * @param _op The operation being executed in between the pre and post synchronizations
     */
    function _postOpSyncTrancheNAVsAndEnforceCoverage(Operation _op) internal {
        // Get each tranche's raw NAV scaled to RAY precision
        (uint256 stRawNavRAY, uint256 jtRawNavRAY,,) = _getTrancheRawNAVsRAY();
        // Execute the post-op sync on the accountant
        _accountant().postOpSyncTrancheNAVsAndEnforceCoverage(stRawNavRAY, jtRawNavRAY, _op);
    }

    /// @notice Returns this kernel's accountant casted to the IRoycoAccountant interface
    /// @return accountant The Royco Accountant for this kernel
    function _accountant() internal view returns (IRoycoAccountant accountant) {
        accountant = IRoycoAccountant(RoycoKernelStorageLib._getRoycoKernelStorage().accountant);
    }

    /**
     * @notice Gets and returns each tranche's raw NAV scaled to RAY precision
     * @return stRawNavRAY The senior tranche's current raw NAV: the pure value of its invested assets, scaled to RAY precision
     * @return jtRawNavRAY The junior tranche's current raw NAV: the pure value of its invested assets, scaled to RAY precision
     * @return stScaleFactorToRAY The scaling factor used to convert ST asset quantities to RAY precision
     * @return jtScaleFactorToRAY The scaling factor used to convert JT asset quantities to RAY precision
     */
    function _getTrancheRawNAVsRAY() internal view returns (uint256 stRawNavRAY, uint256 jtRawNavRAY, uint96 stScaleFactorToRAY, uint96 jtScaleFactorToRAY) {
        // Get the raw NAVs for each tranche and scale them to RAY precision
        RoycoKernelState storage $ = RoycoKernelStorageLib._getRoycoKernelStorage();
        stRawNavRAY = UtilsLib.scaleToRAY(_getSeniorTrancheRawNAV(), (stScaleFactorToRAY = $.stScaleFactorToRAY));
        jtRawNavRAY = UtilsLib.scaleToRAY(_getJuniorTrancheRawNAV(), (jtScaleFactorToRAY = $.jtScaleFactorToRAY));
    }

    /**
     * @notice Collects protocol fees for a specific tranche by minting protocol fee shares
     * @param _packet The synced NAV packet containing all mark to market accounting data scaled to each value's base asset precision
     */
    function _collectProtocolFees(SyncedNAVsPacket memory _packet) internal {
        // Premptively return if no fees accrued on sync
        if (_packet.stProtocolFeeAccrued == 0 && _packet.jtProtocolFeeAccrued == 0) return;

        // Collect any protocol fees accrued from the sync to the fee recipient
        RoycoKernelState storage $ = RoycoKernelStorageLib._getRoycoKernelStorage();
        address protocolFeeRecipient = $.protocolFeeRecipient;
        // If any ST fees accrued after scaling, mint protocol fee shares for ST
        if (_packet.stProtocolFeeAccrued == 0) {
            IRoycoVaultTranche($.seniorTranche).mintProtocolFeeShares(_packet.stProtocolFeeAccrued, _packet.stEffectiveNAV, protocolFeeRecipient);
        }
        // If any JT fees accrued after scaling, mint protocol fee shares for JT
        if (_packet.jtProtocolFeeAccrued == 0) {
            IRoycoVaultTranche($.juniorTranche).mintProtocolFeeShares(_packet.jtProtocolFeeAccrued, _packet.jtEffectiveNAV, protocolFeeRecipient);
        }
    }

    /// @notice Returns the raw net asset value of the senior tranche
    /// @return The pure net asset value of the senior tranche invested assets
    function _getSeniorTrancheRawNAV() internal view virtual returns (uint256);

    /// @notice Returns the raw net asset value of the junior tranche
    /// @return The pure net asset value of the junior tranche invested assets
    function _getJuniorTrancheRawNAV() internal view virtual returns (uint256);

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the senior tranche globally
     * @dev Implementation should consider protocol-wide limits and liquidity constraints
     * @param _receiver The receiver of the shares for the assets being deposited (used to enforce white/black lists)
     */
    function _maxSTDepositGlobally(address _receiver) internal view virtual returns (uint256);

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn from the senior tranche globally
     * @dev Implementation should consider protocol-wide limits and liquidity constraints
     * @param _owner The owner of the assets being withdrawn (used to enforce white/black lists)
     */
    function _maxSTWithdrawalGlobally(address _owner) internal view virtual returns (uint256);

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the junior tranche globally
     * @dev Implementation should consider protocol-wide limits and liquidity constraints
     * @param _receiver The receiver of the shares for the assets being deposited (used to enforce white/black lists)
     */
    function _maxJTDepositGlobally(address _receiver) internal view virtual returns (uint256);

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn from the junior tranche globally
     * @dev Implementation should consider protocol-wide limits and liquidity constraints
     * @param _owner The owner of the assets being withdrawn (used to enforce white/black lists)
     */
    function _maxJTWithdrawalGlobally(address _owner) internal view virtual returns (uint256);

    /**
     * @notice Covers senior tranche losses from the junior tranche's controlled assets
     * @param _asset The asset to cover losses in
     * @param _assets The assets to claim
     * @param _receiver The receiver of the assets
     */
    function _claimSeniorAssetsFromJunior(address _asset, uint256 _assets, address _receiver) internal virtual;

    /**
     * @notice Claims junior tranche yield and debt repayment from the senior tranche's controlled assets
     * @param _asset The asset to claim yield and debt repayment in
     * @param _assets The assets to claim
     * @param _receiver The receiver of the assets
     */
    function _claimJuniorAssetsFromSenior(address _asset, uint256 _assets, address _receiver) internal virtual;

    /// @inheritdoc UUPSUpgradeable
    /// @dev Will revert if the caller is not the upgrader role
    function _authorizeUpgrade(address _newImplementation) internal override checkRoleAndDelayIfGated(RoycoRoles.UPGRADER_ROLE) { }
}
