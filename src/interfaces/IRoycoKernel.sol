// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AssetClaims, SyncedAccountingState, TrancheType } from "../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../libraries/Units.sol";

/**
 * @title IRoycoKernel
 * @notice Interface for the base Royco kernel contract
 * @dev The kernel contract is responsible for orchestrating all operations for both tranches in a Royco market
 */
interface IRoycoKernel {
    /**
     * @notice Construction parameters for the Royco Kernel
     * @custom:field seniorTranche - The address of the Royco senior tranche associated with this kernel
     * @custom:field stAsset - The address of the base asset of the senior tranche
     * @custom:field juniorTranche - The address of the Royco junior tranche associated with this kernel
     * @custom:field jtAsset - The address of the base asset of the junior tranche
     * @custom:field accountant - The address of the accountant for the Royco market
     * @custom:field enforceVaultSharesTransferWhitelist Whether to enforce the vault shares transfer whitelist
     */
    struct RoycoKernelConstructionParams {
        address seniorTranche;
        address stAsset;
        address juniorTranche;
        address jtAsset;
        address accountant;
        bool enforceVaultSharesTransferWhitelist;
    }

    /**
     * @notice Initialization parameters for the Royco Kernel
     * @custom:field initialAuthority - The access manager for this kernel
     * @custom:field protocolFeeRecipient - The market's protocol fee recipient
     * @custom:field stSelfLiquidationBonusWAD - The market's configured ST self-liquidation bonus remitted to redeeming ST LPs when liquidation utilization threshold has been breached, scaled to WAD precision
     */
    struct RoycoKernelInitParams {
        address initialAuthority;
        address protocolFeeRecipient;
        uint64 stSelfLiquidationBonusWAD;
    }

    /**
     * @notice Storage state for the Royco Kernel
     * @custom:storage-location erc7201:Royco.storage.RoycoKernelState
     * @custom:field protocolFeeRecipient - The market's configured protocol fee recipient
     * @custom:field stSelfLiquidationBonusWAD - The market's configured ST self-liquidation bonus remitted to redeeming ST LPs when liquidation utilization threshold has been breached, scaled to WAD precision
     * @custom:field stOwnedYieldBearingAssets - The yield bearing assets held by the ST, in ST's asset units
     * @custom:field jtOwnedYieldBearingAssets - The yield bearing assets held by the JT, in JT's asset units
     * @custom:field isBlacklistEnabled - A boolean indicating whether the blacklist is enforced for this market
     * @custom:field isBlacklisted - A mapping of accounts to a boolean indicating if they are blacklisted
     */
    struct RoycoKernelState {
        address protocolFeeRecipient;
        uint64 stSelfLiquidationBonusWAD;
        TRANCHE_UNIT stOwnedYieldBearingAssets;
        TRANCHE_UNIT jtOwnedYieldBearingAssets;
        bool isBlacklistEnabled;
        mapping(address account => bool isBlacklisted) isBlacklisted;
    }

    /// @notice Viewable state for the Royco Kernel
    struct RoycoKernelStateView {
        bool isBlacklistEnabled;
        address protocolFeeRecipient;
        uint64 stSelfLiquidationBonusWAD;
        TRANCHE_UNIT stOwnedYieldBearingAssets;
        TRANCHE_UNIT jtOwnedYieldBearingAssets;
    }

    /**
     * @notice Emitted when the protocol fee recipient is updated
     * @param protocolFeeRecipient The new protocol fee recipient
     */
    event ProtocolFeeRecipientUpdated(address protocolFeeRecipient);

    /**
     * @notice Emitted when the ST self-liquidation bonus is updated
     * @param stSelfLiquidationBonusWAD The new ST self-liquidation bonus remitted to redeeming ST LPs when liquidation utilization threshold has been breached
     */
    event SeniorTrancheSelfLiquidationBonusUpdated(uint64 stSelfLiquidationBonusWAD);

    /**
     * @notice Emitted when an account is blacklisted
     * @param account The address of the account
     */
    event AccountBlacklisted(address indexed account);

    /**
     * @notice Emitted when an account is unblacklisted
     * @param account The address of the account
     */
    event AccountUnblacklisted(address indexed account);

    /**
     * @notice Emitted when the blacklist status is updated
     * @param isBlacklistEnabled The new blacklist enabled state
     */
    event BlacklistStatusUpdated(bool isBlacklistEnabled);

    /// @notice Thrown when the tranche and the kernel's corresponding tranche assets don't match
    error TRANCHE_AND_KERNEL_ASSETS_MISMATCH();

    /// @notice Thrown when the caller of a permissioned function isn't the market's senior tranche
    error ONLY_SENIOR_TRANCHE();

    /// @notice Thrown when the caller of a permissioned function isn't the market's junior tranche
    error ONLY_JUNIOR_TRANCHE();

    /// @notice Thrown when a ST LP is attempting to deposit when ST impermanent loss exists
    error ST_DEPOSIT_DISABLED_IN_LOSS();

    /// @notice Thrown when an LP is attempting to deposit into or redeem from the market while it is in a fixed term state
    error DISABLED_IN_FIXED_TERM_STATE();

    /// @notice Thrown when the caller of a permissioned function isn't the market's senior or junior tranche
    error ONLY_TRANCHE();

    /// @notice Thrown when the specified account is the null address
    error NULL_DEPOSITOR();

    /// @notice Thrown when the specified account is already blacklisted
    error ACCOUNT_ALREADY_BLACKLISTED(address account);

    /// @notice Thrown when the specified account is not blacklisted
    error ACCOUNT_NOT_BLACKLISTED(address account);

    /// @notice Thrown when the specified account is blacklisted
    error ACCOUNT_BLACKLISTED(address account);

    /// @notice Thrown when the blacklist status is already set
    error BLACKLIST_STATUS_ALREADY_SET(bool isBlacklistEnabled);

    /// @notice Thrown when the to address is not whitelisted on the tranche
    error ACCOUNT_NOT_WHITELISTED_TRANCHE_LP(address to);

    /// @notice Thrown when the array of accounts is empty
    error EMPTY_ARRAY();

    /**
     * @notice Retrieves the senior tranche address
     * @return seniorTranche The address of the senior tranche for this Royco market
     */
    function SENIOR_TRANCHE() external view returns (address seniorTranche);

    /**
     * @notice Retrieves the ST asset address
     * @return stAsset The senior tranche's base asset address
     */
    function ST_ASSET() external view returns (address stAsset);

    /**
     * @notice Retrieves the junior tranche address
     * @return juniorTranche The address of the junior tranche for this Royco market
     */
    function JUNIOR_TRANCHE() external view returns (address juniorTranche);

    /**
     * @notice Retrieves the JT asset address
     * @return jtAsset The junior tranche's base asset address
     */
    function JT_ASSET() external view returns (address jtAsset);

    /**
     * @notice Retrieves the accountant address
     * @return accountant The accountant responsible for maintaining this Royco market's accounting state and marking tranche NAVs to market
     */
    function ACCOUNTANT() external view returns (address accountant);

    /**
     * @notice Sets the new protocol fee recipient
     * @dev Only callable by a designated admin
     * @param _protocolFeeRecipient The address of the new protocol fee recipient
     */
    function setProtocolFeeRecipient(address _protocolFeeRecipient) external;

    /**
     * @notice Sets the ST self-liquidation bonus remitted to redeeming ST LPs when liquidation utilization threshold has been breached
     * @dev Only callable by a designated admin
     * @param _stSelfLiquidationBonusWAD The ST self liquidation bonus, scaled to WAD precision
     */
    function setSeniorTrancheSelfLiquidationBonus(uint64 _stSelfLiquidationBonusWAD) external;

    /**
     * @notice Blacklists the assets of the specified addresses
     * @param _accounts The addresses of the accounts to blacklist
     */
    function blacklistAccounts(address[] calldata _accounts) external;

    /**
     * @notice Unblacklists the assets of the specified addresses
     * @param _accounts The addresses of the accounts to unblacklist
     */
    function unblacklistAccounts(address[] calldata _accounts) external;

    /**
     * @notice Checks if the specified account is blacklisted
     * @param _account The address of the account to check
     * @return isBlacklisted Whether the account is blacklisted
     */
    function isBlacklisted(address _account) external view returns (bool);

    /**
     * @notice Sets the blacklist enabled state
     * @param _blacklistEnabled The new blacklist enabled state
     */
    function setBlacklistStatus(bool _blacklistEnabled) external;

    /**
     * @notice Retrieves the state of the Royco kernel
     * @return state The Royco kernel's state, including the protocol fee recipient and the kernel's controlled tranche and base assets
     */
    function getState() external view returns (RoycoKernelStateView memory state);

    /**
     * @notice Converts the specified ST assets denominated in its tranche units to the kernel's NAV units
     * @param _stAssets The ST assets denominated in tranche units to convert to the kernel's NAV units
     * @return nav The specified ST assets denominated in its tranche units converted to the kernel's NAV units
     */
    function stConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _stAssets) external view returns (NAV_UNIT nav);

    /**
     * @notice Converts the specified JT assets denominated in its tranche units to the kernel's NAV units
     * @param _jtAssets The JT assets denominated in tranche units to convert to the kernel's NAV units
     * @return nav The specified JT assets denominated in its tranche units converted to the kernel's NAV units
     */
    function jtConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _jtAssets) external view returns (NAV_UNIT nav);

    /**
     * @notice Converts the specified assets denominated in the kernel's NAV units to assets denominated in ST's tranche units
     * @param _navAssets The NAV of the assets denominated in the kernel's NAV units to convert to assets denominated in ST's tranche units
     * @return stAssets The specified NAV of the assets denominated in the kernel's NAV units converted to assets denominated in ST's tranche units
     */
    function stConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) external view returns (TRANCHE_UNIT stAssets);

    /**
     * @notice Converts the specified assets denominated in the kernel's NAV units to assets denominated in JT's tranche units
     * @param _navAssets The NAV of the assets denominated in the kernel's NAV units to convert to assets denominated in JT's tranche units
     * @return jtAssets The specified NAV of the assets denominated in the kernel's NAV units converted to assets denominated in JT's tranche units
     */
    function jtConvertNAVUnitsToTrancheUnits(NAV_UNIT _navAssets) external view returns (TRANCHE_UNIT jtAssets);

    /**
     * @notice Synchronizes and persists the raw and effective NAVs of both tranches
     * @dev Only executes a pre-op sync because there is no operation being executed in the same call as this sync
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     */
    function syncTrancheAccounting() external returns (SyncedAccountingState memory state);

    /**
     * @notice Previews a synchronization of the raw and effective NAVs of both tranches
     * @dev Does not mutate any state
     * @param _trancheType An enumerator indicating which tranche to execute this preview for
     * @return state The synced NAV, impermanent loss, and fee accounting containing all mark-to-market accounting data
     * @return claims The claims on ST and JT assets that the specified tranche has denominated in tranche-native units
     * @return totalTrancheShares The total number of shares that exist in the specified tranche after minting any protocol fee shares post-sync
     */
    function previewSyncTrancheAccounting(TrancheType _trancheType)
        external
        view
        returns (SyncedAccountingState memory state, AssetClaims memory claims, uint256 totalTrancheShares);

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the senior tranche
     * @param _receiver The address that will receive the ST shares equating to the deposited assets
     * @return assets The maximum amount of assets that can be deposited into the senior tranche, denominated in the senior tranche's tranche units
     */
    function stMaxDeposit(address _receiver) external view returns (TRANCHE_UNIT assets);

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn from the senior tranche
     * @param _owner The address that is withdrawing the assets
     * @return claimOnStNAV The notional claims on ST assets that the senior tranche has denominated in kernel's NAV units
     * @return claimOnJtNAV The notional claims on JT assets that the senior tranche has denominated in kernel's NAV units
     * @return stMaxWithdrawableNAV The maximum amount of assets that can be withdrawn from the senior tranche, denominated in the kernel's NAV units
     * @return jtMaxWithdrawableNAV The maximum amount of assets that can be withdrawn from the junior tranche, denominated in the kernel's NAV units
     * @return totalTrancheSharesAfterMintingFees The total number of shares that exist in the senior tranche after minting any protocol fee shares post-sync
     */
    function stMaxWithdrawable(address _owner)
        external
        view
        returns (
            NAV_UNIT claimOnStNAV,
            NAV_UNIT claimOnJtNAV,
            NAV_UNIT stMaxWithdrawableNAV,
            NAV_UNIT jtMaxWithdrawableNAV,
            uint256 totalTrancheSharesAfterMintingFees
        );

    /**
     * @notice Previews the deposit of a specified amount of assets into the senior tranche
     * @dev The kernel may decide to simulate the deposit and revert internally with the result
     * @dev Should revert if deposits are asynchronous
     * @param _assets The amount of assets to deposit, denominated in the senior tranche's tranche units
     * @return stateBeforeDeposit The state of the senior tranche before the deposit, after applying the pre-op sync
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units
     */
    function stPreviewDeposit(TRANCHE_UNIT _assets) external view returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated);

    /**
     * @notice Previews the redemption of a specified number of shares from the senior tranche
     * @dev The kernel may decide to simulate the redemption and revert internally with the result
     * @dev Should revert if redemptions are asynchronous
     * @param _shares The number of shares to redeem
     * @return userClaim The distribution of assets that would be transferred to the receiver on redemption, denominated in the respective tranches' tranche units
     */
    function stPreviewRedeem(uint256 _shares) external view returns (AssetClaims memory userClaim);

    /**
     * @notice Processes the deposit of a specified amount of assets into the senior tranche
     * @dev Assumes that the funds are transferred to the kernel before the deposit call is made
     * @param _assets The amount of assets to deposit, denominated in the senior tranche's tranche units
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units
     * @return navToMintSharesAt The NAV at which the shares will be minted, exclusive of valueAllocated
     */
    function stDeposit(TRANCHE_UNIT _assets) external returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt);

    /**
     * @notice Processes the redemption of a specified number of shares from the senior tranche
     * @dev The function is expected to transfer the senior and junior assets directly to the receiver, based on the redemption claims
     * @param _shares The number of shares to redeem
     * @param _receiver The address that is receiving the assets
     * @param _bypassRedemptionRestrictions Whether to bypass the redemption restrictions (eg. for Transfer Agent Obligations on RWA)
     * @return userAssetClaims The distribution of assets that were transferred to the receiver on redemption
     */
    function stRedeem(uint256 _shares, address _receiver, bool _bypassRedemptionRestrictions) external returns (AssetClaims memory userAssetClaims);

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the junior tranche
     * @param _receiver The address that will receive the JT shares equating to the deposited assets
     * @return assets The maximum amount of assets that can be deposited into the junior tranche, denominated in the junior tranche's tranche units
     */
    function jtMaxDeposit(address _receiver) external view returns (TRANCHE_UNIT assets);

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn from the junior tranche
     * @param _owner The address that is withdrawing the assets
     * @return claimOnStNAV The notional claims on ST assets that the junior tranche has denominated in kernel's NAV units
     * @return claimOnJtNAV The notional claims on JT assets that the junior tranche has denominated in kernel's NAV units
     * @return stMaxWithdrawableNAV The maximum amount of assets that can be withdrawn from the senior tranche, denominated in the kernel's NAV units
     * @return jtMaxWithdrawableNAV The maximum amount of assets that can be withdrawn from the junior tranche, denominated in the kernel's NAV units
     * @return totalTrancheSharesAfterMintingFees The total number of shares that exist in the junior tranche after minting any protocol fee shares post-sync, including virtual shares
     */
    function jtMaxWithdrawable(address _owner)
        external
        view
        returns (
            NAV_UNIT claimOnStNAV,
            NAV_UNIT claimOnJtNAV,
            NAV_UNIT stMaxWithdrawableNAV,
            NAV_UNIT jtMaxWithdrawableNAV,
            uint256 totalTrancheSharesAfterMintingFees
        );

    /**
     * @notice Previews the deposit of a specified amount of assets into the junior tranche
     * @dev The kernel may decide to simulate the deposit and revert internally with the result
     * @dev Should revert if deposits are asynchronous
     * @param _assets The amount of assets to deposit, denominated in the junior tranche's tranche units
     * @return stateBeforeDeposit The state of the junior tranche before the deposit, after applying the pre-op sync
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units
     */
    function jtPreviewDeposit(TRANCHE_UNIT _assets) external view returns (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated);

    /**
     * @notice Previews the redemption of a specified number of shares from the junior tranche
     * @dev The kernel may decide to simulate the redemption and revert internally with the result
     * @dev Should revert if redemptions are asynchronous
     * @param _shares The number of shares to redeem
     * @return userClaim The distribution of assets that would be transferred to the receiver on redemption, denominated in the respective tranches' tranche units
     */
    function jtPreviewRedeem(uint256 _shares) external view returns (AssetClaims memory userClaim);

    /**
     * @notice Processes the deposit of a specified amount of assets into the junior tranche
     * @dev Assumes that the funds are transferred to the kernel before the deposit call is made
     * @param _assets The amount of assets to deposit, denominated in the junior tranche's tranche units
     * @return valueAllocated The value of the assets deposited, denominated in the kernel's NAV units
     * @return navToMintSharesAt The NAV at which the shares will be minted, exclusive of valueAllocated
     */
    function jtDeposit(TRANCHE_UNIT _assets) external returns (NAV_UNIT valueAllocated, NAV_UNIT navToMintSharesAt);

    /**
     * @notice Processes the redemption of a specified number of shares from the junior tranche
     * @dev The function is expected to transfer the senior and junior assets directly to the receiver, based on the redemption claims
     * @param _shares The number of shares to redeem
     * @param _receiver The address that is receiving the assets
     * @param _bypassRedemptionRestrictions Whether to bypass the redemption restrictions (eg. for Transfer Agent Obligations on RWA)
     * @return userAssetClaims The distribution of assets that were transferred to the receiver on redemption
     */
    function jtRedeem(uint256 _shares, address _receiver, bool _bypassRedemptionRestrictions) external returns (AssetClaims memory userAssetClaims);

    /**
     * @notice Pre-balance update hook for the tranche
     * @dev This function should revert if the balance update is invalid.
     * @dev Should be called before every tranche share balance update
     * @param _caller The address that is calling the balance update
     * @param _from The address from which the balance is being updated
     * @param _to The address to which the balance is being updated
     * @param _value The amount of the balance being updated
     */
    function preTrancheBalanceUpdateHook(address _caller, address _from, address _to, uint256 _value) external;
}
