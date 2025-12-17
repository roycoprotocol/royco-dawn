// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC165 } from "../../../lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import { TrancheAssetClaims } from "../../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../../libraries/Units.sol";
import { IRoycoAsyncCancellableVault } from "./IRoycoAsyncCancellableVault.sol";
import { IRoycoAsyncVault } from "./IRoycoAsyncVault.sol";

interface IRoycoVaultTranche is IERC165, IRoycoAsyncVault, IRoycoAsyncCancellableVault {
    /**
     * @notice Emitted when a deposit is made
     * @param sender The address that made the deposit
     * @param owner The address that owns the shares
     * @param assets The amount of assets deposited
     * @param shares The amount of shares minted
     */
    event Deposit(address indexed sender, address indexed owner, TRANCHE_UNIT assets, uint256 shares);

    /**
     * @notice Emitted when a protocol fee is minted to the protocol fee recipient
     * @param protocolFeeRecipient The address that received the protocol fee shares
     * @param mintedProtocolFeeShares The number of protocol fee shares that were minted
     * @param totalTrancheShares The total number of shares that exist in the tranche after minting any protocol fee shares post-sync
     */
    event MintProtocolFeeShares(address indexed protocolFeeRecipient, uint256 mintedProtocolFeeShares, uint256 totalTrancheShares);

    /**
     * @notice Returns the raw net asset value of the tranche's invested assets
     * @dev Excludes yield splits, coverage applications, etc.
     * @dev The NAV is expressed in the tranche's base asset
     * @return nav The raw net asset value of the tranche's invested assets
     */
    function getRawNAV() external view returns (NAV_UNIT nav);

    /**
     * @notice Returns the address of the kernel contract handling strategy logic
     */
    function kernel() external view returns (address);

    /**
     * @notice Returns the identifier of the Royco market this tranche is linked to
     */
    function marketId() external view returns (bytes32);

    /**
     * @notice Returns the total effective assets in the tranche's NAV units
     * @dev Includes yield splits, coverage applications, etc.
     * @dev The NAV is expressed in the tranche's base asset
     * @return claims The breakdown of assets that represent the value of the tranche's shares
     */
    function totalAssets() external view returns (TrancheAssetClaims memory claims);

    /**
     * @notice Returns the maximum amount of assets that can be deposited into the tranche
     * @dev The assets are expressed in the tranche's base asset
     * @param _receiver The address to receive the deposited assets
     * @return assets The maximum amount of assets that can be deposited into the tranche
     */
    function maxDeposit(address _receiver) external view returns (TRANCHE_UNIT assets);

    /**
     * @notice Returns the maximum amount of shares that can be redeemed from the tranche
     * @dev The shares are expressed in the tranche's base asset
     * @param _owner The address to redeem the shares from
     * @return shares The maximum amount of shares that can be redeemed from the tranche
     */
    function maxRedeem(address _owner) external view returns (uint256 shares);

    /**
     * @notice Returns the number of shares that would be minted for a given amount of assets
     * @dev The assets are expressed in the tranche's base asset
     * @dev Disabled if deposit execution is asynchronous
     * @param _assets The amount of assets to preview the deposit for
     * @return shares The number of shares that would be minted for a given amount of assets
     */
    function previewDeposit(TRANCHE_UNIT _assets) external view returns (uint256 shares);

    /**
     * @notice Returns the number of shares that would be minted for a given amount of assets
     * @dev The assets are expressed in the tranche's base asset
     * @param _assets The amount of assets to convert to shares
     * @return shares The number of shares that would be minted for a given amount of assets
     */
    function convertToShares(TRANCHE_UNIT _assets) external view returns (uint256 shares);

    /**
     * @notice Returns the breakdown of assets that the shares have a claim on
     * @dev The shares are expressed in the tranche's base asset
     * @dev Disabled if redemption execution is asynchronous
     * @param _shares The number of shares to convert to claims
     * @return claims The breakdown of assets that the shares have a claim on
     */
    function previewRedeem(uint256 _shares) external view returns (TrancheAssetClaims memory claims);

    /**
     * @notice Returns the breakdown of assets that the shares have a claim on
     * @dev The shares are expressed in the tranche's base asset
     * @param _shares The number of shares to convert to assets
     * @return claims The breakdown of assets that the shares have a claim on
     */
    function convertToAssets(uint256 _shares) external view returns (TrancheAssetClaims memory claims);

    /**
     * @notice Mints tranche shares to the receiver
     * @dev The assets are expressed in the tranche's base asset
     * @param _assets The amount of assets to mint
     * @param _receiver The address to mint the shares to
     * @param _controller The controller of the request
     * @return shares The number of shares that were minted
     */
    function deposit(TRANCHE_UNIT _assets, address _receiver, address _controller) external returns (uint256 shares);

    /**
     * @notice Redeems tranche shares from the owner
     * @dev The shares are expressed in the tranche's base asset
     * @param _shares The number of shares to redeem
     * @param _receiver The address to redeem the shares to
     * @param _controller The controller of the request
     * @return claims The breakdown of assets that the redeemed shares have a claim on
     */
    function redeem(uint256 _shares, address _receiver, address _controller) external returns (TrancheAssetClaims memory claims);

    /**
     * @notice Previews the number of shares that would be minted to the protocol fee recipient to satisfy the ratio of total assets that the fee represents
     * @dev The fee assets are expressed in the tranche's base asset
     * @param _protocolFeeAssets The fee accrued for this tranche as a result of the pre-op sync
     * @param _trancheTotalAssets The total effective assets controlled by this tranche as a result of the pre-op sync
     * @return mintedProtocolFeeShares The number of protocol fee shares that would be minted to the protocol fee recipient
     * @return totalTrancheShares The total number of shares that exist in the tranche after minting any protocol fee shares post-sync
     */
    function previewMintProtocolFeeShares(
        NAV_UNIT _protocolFeeAssets,
        NAV_UNIT _trancheTotalAssets
    )
        external
        view
        returns (uint256 mintedProtocolFeeShares, uint256 totalTrancheShares);

    /**
     * @notice Mints tranche shares to the protocol fee recipient, representing ownership over the fee assets of the tranche
     * @dev Must be called by the tranche's kernel everytime protocol fees are accrued in its pre-op synchronization
     * @param _protocolFeeAssets The fee accrued for this tranche as a result of the pre-op sync
     * @param _protocolFeeRecipient The address to receive the freshly minted protocol fee shares
     * @param _trancheTotalAssets The total effective assets controlled by this tranche as a result of the pre-op sync
     * @return mintedProtocolFeeShares The number of protocol fee shares that were minted to the protocol fee recipient
     * @return totalTrancheShares The total number of shares that exist in the tranche after minting any protocol fee shares post-sync
     */
    function mintProtocolFeeShares(
        NAV_UNIT _protocolFeeAssets,
        NAV_UNIT _trancheTotalAssets,
        address _protocolFeeRecipient
    )
        external
        returns (uint256 mintedProtocolFeeShares, uint256 totalTrancheShares);

    /**
     * @notice Returns the address of the tranche's deposit asset
     * @return asset The address of the tranche's deposit asset
     */
    function asset() external view returns (address asset);
}
