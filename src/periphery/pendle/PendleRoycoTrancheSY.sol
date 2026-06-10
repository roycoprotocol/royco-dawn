// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import { ArrayLib, PMath, PendleERC20SYUpgV2 } from "../../../lib/Pendle-SY-Public/contracts/core/StandardizedYield/implementations/PendleERC20SYUpgV2.sol";
import { MerklRewardAbstract__NoStorage } from "../../../lib/Pendle-SY-Public/contracts/core/misc/MerklRewardAbstract__NoStorage.sol";
import { IAccessManaged } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { toTrancheUnits, toUint256 } from "../../libraries/Units.sol";

/**
 * @title PendleRoycoTrancheSY
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Pendle Standardized Yield (SY) implementation for Royco tranche shares (Senior or Junior)
 */
contract PendleRoycoTrancheSY is PendleERC20SYUpgV2, MerklRewardAbstract__NoStorage {
    /// @dev The authority of the Royco tranche for this SY
    address private immutable ROYCO_AUTHORITY;

    /// @dev The base asset of the Royco tranche for this SY
    address private immutable TRANCHE_BASE_ASSET;

    /**
     * @notice Constructs the Pendle SY for the Royco senior or junior tranche
     * @param _roycoTranche The address of the Royco tranche which constitutes the yield bearing token of this SY
     * @param _offchainRewardManager The address of the offchain reward manager (null address if none exists for this SY)
     */
    constructor(address _roycoTranche, address _offchainRewardManager)
        PendleERC20SYUpgV2(_roycoTranche)
        MerklRewardAbstract__NoStorage(_offchainRewardManager)
    {
        // Query and immutably set the tranche's authority and base asset
        ROYCO_AUTHORITY = IAccessManaged(_roycoTranche).authority();
        TRANCHE_BASE_ASSET = IRoycoVaultTranche(_roycoTranche).asset();
    }

    /**
     * @notice Initializes the SY's ERC20 metadata and owner
     * @param _name The name of the SY token
     * @param _symbol The symbol of the SY token
     * @param _owner The owner of the SY
     */
    function initialize(string memory _name, string memory _symbol, address _owner) external override(PendleERC20SYUpgV2) initializer {
        // Initialize the SY base state
        __SYBaseUpgV2_init(_name, _symbol, _owner);
        // Extend a maximum approval to the tranche for the tranche's base asset
        _safeApproveInf(TRANCHE_BASE_ASSET, yieldToken);
    }

    /**
     * @notice Computes the SY shares to mint for the deposited token
     * @dev Tranche shares wrap 1:1; the tranche's base asset is deposited into the tranche and the minted shares are wrapped
     * @param _tokenIn The deposited token (the tranche share or the tranche's base asset)
     * @param _amountDeposited The amount of the token deposited
     * @return amountSharesOut The amount of SY shares to mint to the depositor
     */
    function _deposit(address _tokenIn, uint256 _amountDeposited) internal override(PendleERC20SYUpgV2) returns (uint256 amountSharesOut) {
        if (_tokenIn == yieldToken) return _amountDeposited;
        return IRoycoVaultTranche(yieldToken).deposit(toTrancheUnits(_amountDeposited), address(this));
    }

    /**
     * @notice Previews the SY shares that would be minted for a deposit
     * @dev Tranche shares preview 1:1. For the base asset, returns the tranche's own deposit preview
     * @param _tokenIn The token to deposit (the tranche share or the tranche's base asset)
     * @param _amountTokenToDeposit The amount of the token to deposit
     * @return amountSharesOut The amount of SY shares that would be minted to the depositor
     */
    function _previewDeposit(address _tokenIn, uint256 _amountTokenToDeposit) internal view override(PendleERC20SYUpgV2) returns (uint256 amountSharesOut) {
        if (_tokenIn == yieldToken) return _amountTokenToDeposit;
        return IRoycoVaultTranche(yieldToken).previewDeposit(toTrancheUnits(_amountTokenToDeposit));
    }

    /**
     * @notice Returns the exchange rate of one tranche share in terms of the market's NAV units (USD, BTC, ETH, etc.)
     * @return The exchange rate such that: exchangeRate * syBalance / 1e18 = asset value
     */
    function exchangeRate() public view override(PendleERC20SYUpgV2) returns (uint256) {
        // Pendle's exchangeRate is NAV per 1e18 SY wei
        // For this 1:1 SY over an 18 decimal Royco tranche, PMath.ONE == 1 whole tranche share == 1 whole tranche SY
        // Return the exchange rate of 1 whole tranche SY in NAV units (always has 18 decimals of precision)
        return toUint256(IRoycoVaultTranche(yieldToken).convertToAssets(PMath.ONE).nav);
    }

    /// @notice Returns the tokens that can be deposited into this SY
    /// @return res The tranche share, plus the tranche's base asset if the tranche currently accepts direct deposits from this SY
    function getTokensIn() public view override(PendleERC20SYUpgV2) returns (address[] memory res) {
        if (_canDepositTrancheBaseAsset()) return ArrayLib.create(TRANCHE_BASE_ASSET, yieldToken);
        return ArrayLib.create(yieldToken);
    }

    /**
     * @notice Returns whether the specified token can be deposited into this SY
     * @param _token The ostensibly depositable token
     * @return Whether the specified token can be deposited into this SY
     */
    function isValidTokenIn(address _token) public view override(PendleERC20SYUpgV2) returns (bool) {
        return _token == yieldToken || (_token == TRANCHE_BASE_ASSET && _canDepositTrancheBaseAsset());
    }

    /**
     * @notice Returns metadata about the asset that the exchange rate is denominated in
     * @return assetType Always LIQUIDITY, as the exchange rate is denominated in the market's NAV units
     * @return assetAddress The Royco tranche address
     * @return assetDecimals Decimals of the asset (matches exchange rate denomination)
     */
    function assetInfo() external view override(PendleERC20SYUpgV2) returns (AssetType assetType, address assetAddress, uint8 assetDecimals) {
        return (AssetType.LIQUIDITY, yieldToken, decimals);
    }

    /**
     * @notice Returns whether this SY can deposit the tranche's base asset directly into the tranche
     * @dev Holds when the tranche's authority lets this SY call deposit on the tranche with no execution delay,
     *      either because direct deposits are permissionless or because this SY was whitelisted as an LP
     * @dev Markets that only accept deposits through the Royco entrypoint do not support base asset deposits
     * @return Whether this SY can deposit the tranche's base asset directly into the tranche
     */
    function _canDepositTrancheBaseAsset() internal view returns (bool) {
        (bool allowed, uint32 delay) = IAccessManager(ROYCO_AUTHORITY).canCall(address(this), yieldToken, IRoycoVaultTranche.deposit.selector);
        return (allowed && delay == 0);
    }
}
