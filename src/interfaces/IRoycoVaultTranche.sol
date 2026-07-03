// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20Metadata } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { AssetClaims, TrancheType } from "../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../libraries/Units.sol";

/**
 * @title IRoycoVaultTranche
 * @notice Interface for the Royco vault tranche contract that manages LP deposits and redemptions for a given tranche
 * @dev Extends ERC20 with vault-like deposit/redeem functionality and protocol fee share minting
 */
interface IRoycoVaultTranche is IERC20Metadata {
    /**
     * @custom:field name - The name of the tranche share token (should be prefixed with "Royco-ST" or "Royco-JT")
     * @custom:field symbol - The symbol of the tranche share token (should be prefixed with "ST" or "JT")
     * @custom:field initialAuthority - The initial authority for the tranche
     */
    struct RoycoTrancheInitParams {
        string name;
        string symbol;
        address initialAuthority;
    }

    /**
     * @notice Emitted when a deposit is made into the tranche
     * @param sender The address that initiated the deposit
     * @param receiver The address that received the minted shares
     * @param assets The amount of assets deposited, denominated in the tranche's base asset units
     * @param shares The amount of shares minted to the receiver
     */
    event Deposit(address indexed sender, address indexed receiver, TRANCHE_UNIT assets, uint256 shares);

    /**
     * @notice Emitted when a redemption is made from the tranche
     * @param sender The address that initiated the redemption
     * @param receiver The address that received the redeemed assets
     * @param claims The asset claims received by the receiver, including claims on ST assets, JT assets, and their total NAV value
     * @param shares The amount of shares redeemed
     */
    event Redeem(address indexed sender, address indexed receiver, AssetClaims claims, uint256 shares);

    /**
     * @notice Emitted when protocol fee shares are minted to the fee recipient
     * @param protocolFeeRecipient The address that received the minted protocol fee shares
     * @param mintedProtocolFeeShares The number of protocol fee shares minted
     * @param totalTrancheShares The total shares in the tranche after minting the protocol fee shares
     */
    event ProtocolFeeSharesMinted(address indexed protocolFeeRecipient, uint256 mintedProtocolFeeShares, uint256 totalTrancheShares);

    /**
     * @notice Emitted when shares are seized from the tranche
     * @param caller The designated admin that initiated the seizure
     * @param from The address to seize shares from
     * @param to The address that received the seized shares
     * @param shares The amount of shares seized
     */
    event SharesSeized(address indexed caller, address indexed from, address indexed to, uint256 shares);

    /**
     * @notice Emitted when shares are seized and redeemed from the tranche
     * @param caller The designated admin that initiated the seizure and redemption
     * @param from The address to seize shares from
     * @param to The address that received the assets from redeeming the shares
     * @param claims The asset claims remitted to the receiver, including claims on ST assets, JT assets, and their total NAV value
     * @param shares The number of shares seized and redeemed
     */
    event SharesSeizedAndRedeemed(address indexed caller, address indexed from, address indexed to, AssetClaims claims, uint256 shares);

    /// @notice Thrown when a deposit would mint zero tranche shares (either zero assets or dust amount that rounds to zero shares)
    error MUST_MINT_NON_ZERO_SHARES();

    /// @notice Thrown when a redemption is requested with zero shares
    error MUST_REQUEST_NON_ZERO_SHARES();

    /// @notice Thrown when the caller of a permissioned function is not the tranche's configured kernel
    error ONLY_KERNEL();

    /// @notice Thrown when the value allocated from a deposit does not match the expected value
    error INVALID_VALUE_ALLOCATED();

    /**
     * @notice Returns the address of the kernel that this tranche is associated with
     * @return kernel The address of the kernel responsible for executing deposits and redemptions for this tranche
     */
    function KERNEL() external view returns (address kernel);

    /**
     * @notice Returns the raw NAV of the tranche's invested assets
     * @dev The raw NAV represents the pure value of the tranche's assets before any coverage adjustments or yield sharing
     * @return nav The raw NAV of the tranche's invested assets, denominated in the kernel's NAV units
     */
    function getRawNAV() external view returns (NAV_UNIT nav);

    /**
     * @notice Returns the total effective assets held by this tranche
     * @dev The effective assets include claims on both ST and JT assets after accounting for coverage and yield sharing
     * @return claims The total asset claims held by this tranche, including claims on ST assets, JT assets, and their total NAV value
     */
    function totalAssets() external view returns (AssetClaims memory claims);

    /**
     * @notice Returns the address of the underlying base asset for this tranche
     * @return asset The address of the ERC20 token used as the base asset for deposits into this tranche
     */
    function asset() external view returns (address asset);

    /**
     * @notice Returns the tranche type indicating whether this is a senior or junior tranche
     * @return trancheType An enumerator indicating SENIOR or JUNIOR tranche type
     */
    function TRANCHE_TYPE() external view returns (TrancheType trancheType);

    /**
     * @notice Returns the maximum amount of assets that can be deposited by the specified receiver
     * @dev May return zero if deposits are disabled due to market conditions (e.g., ST impermanent loss exists or coverage violated)
     * @param _receiver The address that would receive the minted shares
     * @return assets The maximum amount of assets that can be deposited, denominated in the tranche's base asset units
     */
    function maxDeposit(address _receiver) external view returns (TRANCHE_UNIT assets);

    /**
     * @notice Returns the maximum number of shares that can be redeemed by the specified owner
     * @dev May return zero if redemptions are disabled due to market conditions (e.g., fixed-term state for ST)
     * @param _owner The address that owns the shares to be redeemed
     * @return shares The maximum number of shares that can be redeemed
     */
    function maxRedeem(address _owner) external view returns (uint256 shares);

    /**
     * @notice Previews the number of shares that would be minted for a given deposit amount
     * @dev Does not mutate any state
     * @param _assets The amount of assets to deposit, denominated in the tranche's base asset units
     * @return shares The number of shares that would be minted for the specified deposit amount
     */
    function previewDeposit(TRANCHE_UNIT _assets) external view returns (uint256 shares);

    /**
     * @notice Previews the asset claims that would be received for a given redemption amount
     * @dev Does not mutate any state
     * @param _shares The number of shares to redeem
     * @return claims The asset claims that would be received, including claims on ST assets, JT assets, and their total NAV value
     */
    function previewRedeem(uint256 _shares) external view returns (AssetClaims memory claims);

    /**
     * @notice Converts a specified amount of assets to shares using the current exchange rate
     * @dev Does not mutate any state
     * @param _assets The amount of assets to convert, denominated in the tranche's base asset units
     * @return shares The equivalent number of shares for the specified asset amount
     */
    function convertToShares(TRANCHE_UNIT _assets) external view returns (uint256 shares);

    /**
     * @notice Converts a specified number of shares to asset claims using the current exchange rate
     * @dev Does not mutate any state
     * @param _shares The number of shares to convert
     * @return claims The equivalent asset claims for the specified share amount, including claims on ST assets, JT assets, and their total NAV value
     */
    function convertToAssets(uint256 _shares) external view returns (AssetClaims memory claims);

    /**
     * @notice Deposits assets into the tranche and mints shares to the receiver
     * @dev Transfers assets from the caller and mints shares to the receiver
     * @param _assets The amount of assets to deposit, denominated in the tranche's base asset units
     * @param _receiver The address that will receive the minted shares
     * @return shares The number of shares minted to the receiver
     */
    function deposit(TRANCHE_UNIT _assets, address _receiver) external returns (uint256 shares);

    /**
     * @notice Redeems shares from the tranche and transfers assets to the receiver
     * @dev Burns shares from the owner and transfers the corresponding asset claims to the receiver
     * @param _shares The number of shares to redeem
     * @param _receiver The address that will receive the redeemed assets
     * @param _owner The address that owns the shares being redeemed
     * @return claims The asset claims transferred to the receiver, including claims on ST assets, JT assets, and their total NAV value
     */
    function redeem(uint256 _shares, address _receiver, address _owner) external returns (AssetClaims memory claims);

    /**
     * @notice Burns shares from the caller
     * @dev Only callable by the kernel during accounting synchronization
     * @param _shares The number of shares to burn
     */
    function burn(uint256 _shares) external;

    /**
     * @notice Burns shares from the specified account
     * @dev Only callable by the kernel during accounting synchronization
     * @param _account The address to burn shares from
     * @param _shares The number of shares to burn
     */
    function burnFrom(address _account, uint256 _shares) external;

    /**
     * @notice Seizes shares from a user and transfers them to the receiver
     * @dev Only callable by a designated admin for compliance reasons
     * @dev Bypasses the balance update hook
     * @param _from The address to seize shares from
     * @param _receiver The address that will receive the seized shares
     * @param _shares The number of shares to seize
     */
    function seizeShares(address _from, address _receiver, uint256 _shares) external;

    /**
     * @notice Seizes shares from a user, redeems the shares, and transfers them to the receiver
     * @dev Only callable by a designated admin for compliance reasons
     * @param _from The address to seize and redeem shares from
     * @param _receiver The address that received the assets for the redeemed shares
     * @param _shares The number of shares to seize and redeem
     */
    function seizeAndRedeemShares(address _from, address _receiver, uint256 _shares) external returns (AssetClaims memory claims);

    /**
     * @notice Previews the protocol fee shares that would be minted for a given fee amount
     * @dev Does not mutate any state
     * @param _protocolFeeNAV The protocol fee amount to be minted as shares, denominated in the kernel's NAV units
     * @param _totalTrancheNAV The total effective NAV of the tranche before minting fee shares
     * @return protocolFeeSharesMinted The number of protocol fee shares that would be minted
     * @return totalTrancheShares The total shares in the tranche after minting the protocol fee shares
     */
    function previewMintProtocolFeeShares(
        NAV_UNIT _protocolFeeNAV,
        NAV_UNIT _totalTrancheNAV
    )
        external
        view
        returns (uint256 protocolFeeSharesMinted, uint256 totalTrancheShares);

    /**
     * @notice Mints protocol fee shares to the specified fee recipient
     * @dev Only callable by the kernel during accounting synchronization
     * @param _protocolFeeNAV The protocol fee amount to be minted as shares, denominated in the kernel's NAV units
     * @param _totalTrancheNAV The total effective NAV of the tranche before minting fee shares
     * @param _protocolFeeRecipient The address that will receive the minted protocol fee shares
     * @return protocolFeeSharesMinted The number of protocol fee shares minted
     * @return totalTrancheShares The total shares in the tranche after minting the protocol fee shares
     */
    function mintProtocolFeeShares(
        NAV_UNIT _protocolFeeNAV,
        NAV_UNIT _totalTrancheNAV,
        address _protocolFeeRecipient
    )
        external
        returns (uint256 protocolFeeSharesMinted, uint256 totalTrancheShares);
}
