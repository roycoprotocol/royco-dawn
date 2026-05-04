// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

import { IRoycoFactory } from "../../../../src/interfaces/IRoycoFactory.sol";
import { IRoycoVaultTranche } from "../../../../src/interfaces/IRoycoVaultTranche.sol";
import { MAX_NAV_UNITS, ZERO_NAV_UNITS } from "../../../../src/libraries/Constants.sol";
import { AssetClaims, TrancheType } from "../../../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toTrancheUnits, toUint256 } from "../../../../src/libraries/Units.sol";

/// @title MockTranche
/// @notice A simplified mock implementation of IRoycoVaultTranche for testing the entry point
/// @dev Uses a simple 1:1 asset-to-share ratio for simplicity, with configurable share price
contract MockTranche is IRoycoVaultTranche, ERC20 {
    using SafeERC20 for IERC20;
    using Math for uint256;

    address public immutable UNDERLYING_ASSET;
    address public immutable FACTORY;
    TrancheType public immutable TRANCHE_TYPE_VALUE;

    // Configurable share price (in WAD, 1e18 = 1:1)
    uint256 public sharePriceWAD = 1e18;

    // Mock kernel address (not used in tests but needed for interface)
    address public kernelAddress;

    // Max deposit/redeem limits (defaults to max)
    uint256 public maxDepositLimit = type(uint256).max;
    uint256 public maxRedeemLimit = type(uint256).max;

    // Track total deposited assets for NAV calculation
    uint256 public totalDepositedAssets;

    constructor(
        address _asset,
        address _factory,
        TrancheType _trancheType
    )
        ERC20(_trancheType == TrancheType.SENIOR ? "Mock Senior Tranche" : "Mock Junior Tranche", _trancheType == TrancheType.SENIOR ? "MST" : "MJT")
    {
        UNDERLYING_ASSET = _asset;
        FACTORY = _factory;
        TRANCHE_TYPE_VALUE = _trancheType;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MOCK CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Sets the share price for testing yield scenarios
    /// @param _sharePriceWAD New share price in WAD (1e18 = 1:1)
    function setSharePrice(uint256 _sharePriceWAD) external {
        sharePriceWAD = _sharePriceWAD;
    }

    /// @notice Sets the kernel address
    function setKernel(address _kernel) external {
        kernelAddress = _kernel;
    }

    /// @notice Sets max deposit limit
    function setMaxDeposit(uint256 _limit) external {
        maxDepositLimit = _limit;
    }

    /// @notice Sets max redeem limit
    function setMaxRedeem(uint256 _limit) external {
        maxRedeemLimit = _limit;
    }

    /// @notice Simulates yield by increasing share price
    /// @param _yieldPercentWAD Yield percentage in WAD (e.g., 0.1e18 for 10%)
    function simulateYield(uint256 _yieldPercentWAD) external {
        sharePriceWAD = sharePriceWAD.mulDiv(1e18 + _yieldPercentWAD, 1e18);
    }

    /// @notice Simulates loss by decreasing share price
    /// @param _lossPercentWAD Loss percentage in WAD (e.g., 0.1e18 for 10%)
    function simulateLoss(uint256 _lossPercentWAD) external {
        sharePriceWAD = sharePriceWAD.mulDiv(1e18 - _lossPercentWAD, 1e18);
    }

    /// @notice Burns shares from the caller (used by entry point for yield forfeiture)
    /// @param _amount Amount of shares to burn
    function burn(uint256 _amount) external override {
        _burn(msg.sender, _amount);
    }

    function burnFrom(address _account, uint256 _amount) external override {
        _burn(_account, _amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // IRoycoVaultTranche IMPLEMENTATION
    // ═══════════════════════════════════════════════════════════════════════════

    function KERNEL() external view override returns (address) {
        return kernelAddress;
    }

    function TRANCHE_TYPE() external view override returns (TrancheType) {
        return TRANCHE_TYPE_VALUE;
    }

    function asset() external view override returns (address) {
        return UNDERLYING_ASSET;
    }

    function getRawNAV() external view override returns (NAV_UNIT) {
        // NAV based on deposited assets adjusted by share price
        uint256 nav = totalDepositedAssets.mulDiv(sharePriceWAD, 1e18);
        return toNAVUnits(nav);
    }

    function totalAssets() external view override returns (AssetClaims memory claims) {
        uint256 assets = totalSupply().mulDiv(sharePriceWAD, 1e18);
        claims = AssetClaims({
            stAssets: TRANCHE_TYPE_VALUE == TrancheType.SENIOR ? toTrancheUnits(assets) : toTrancheUnits(0),
            jtAssets: TRANCHE_TYPE_VALUE == TrancheType.JUNIOR ? toTrancheUnits(assets) : toTrancheUnits(0),
            nav: toNAVUnits(assets)
        });
    }

    function maxDeposit(address) external view override returns (TRANCHE_UNIT) {
        return toTrancheUnits(maxDepositLimit);
    }

    function maxRedeem(address _owner) external view override returns (uint256) {
        uint256 balance = balanceOf(_owner);
        return balance < maxRedeemLimit ? balance : maxRedeemLimit;
    }

    function previewDeposit(TRANCHE_UNIT _assets) external view override returns (uint256 shares) {
        shares = _convertToShares(toUint256(_assets));
    }

    function previewRedeem(uint256 _shares) external view override returns (AssetClaims memory claims) {
        uint256 assets = _convertToAssets(_shares);
        claims = AssetClaims({
            stAssets: TRANCHE_TYPE_VALUE == TrancheType.SENIOR ? toTrancheUnits(assets) : toTrancheUnits(0),
            jtAssets: TRANCHE_TYPE_VALUE == TrancheType.JUNIOR ? toTrancheUnits(assets) : toTrancheUnits(0),
            nav: toNAVUnits(assets)
        });
    }

    function convertToShares(TRANCHE_UNIT _assets) external view override returns (uint256 shares) {
        shares = _convertToShares(toUint256(_assets));
    }

    function convertToAssets(uint256 _shares) external view override returns (AssetClaims memory claims) {
        uint256 assets = _convertToAssets(_shares);
        claims = AssetClaims({
            stAssets: TRANCHE_TYPE_VALUE == TrancheType.SENIOR ? toTrancheUnits(assets) : toTrancheUnits(0),
            jtAssets: TRANCHE_TYPE_VALUE == TrancheType.JUNIOR ? toTrancheUnits(assets) : toTrancheUnits(0),
            nav: toNAVUnits(assets)
        });
    }

    function deposit(TRANCHE_UNIT _assets, address _receiver) external override returns (uint256 shares) {
        uint256 assetAmount = toUint256(_assets);
        require(assetAmount > 0, "MUST_MINT_NON_ZERO_SHARES");

        shares = _convertToShares(assetAmount);

        // Transfer assets from caller
        IERC20(UNDERLYING_ASSET).safeTransferFrom(msg.sender, address(this), assetAmount);

        // Track deposited assets
        totalDepositedAssets += assetAmount;

        // Mint shares
        _mint(_receiver, shares);

        emit Deposit(msg.sender, _receiver, _assets, shares);
    }

    function redeem(uint256 _shares, address _receiver, address _owner) external override returns (AssetClaims memory claims) {
        require(_shares > 0, "MUST_REQUEST_NON_ZERO_SHARES");

        // Handle allowance if caller is not owner
        if (msg.sender != _owner) {
            _spendAllowance(_owner, msg.sender, _shares);
        }

        uint256 assets = _convertToAssets(_shares);

        // Burn shares
        _burn(_owner, _shares);

        // Update tracked assets
        if (totalDepositedAssets >= assets) {
            totalDepositedAssets -= assets;
        } else {
            totalDepositedAssets = 0;
        }

        // Transfer assets
        IERC20(UNDERLYING_ASSET).safeTransfer(_receiver, assets);

        claims = AssetClaims({
            stAssets: TRANCHE_TYPE_VALUE == TrancheType.SENIOR ? toTrancheUnits(assets) : toTrancheUnits(0),
            jtAssets: TRANCHE_TYPE_VALUE == TrancheType.JUNIOR ? toTrancheUnits(assets) : toTrancheUnits(0),
            nav: toNAVUnits(assets)
        });

        emit Redeem(msg.sender, _receiver, claims, _shares);
    }

    function seizeShares(address _from, address _receiver, uint256 _shares) external override {
        _transfer(_from, _receiver, _shares);
        emit SharesSeized(msg.sender, _from, _receiver, _shares);
    }

    function seizeAndRedeemShares(address _from, address _receiver, uint256 _shares) external override returns (AssetClaims memory claims) {
        uint256 assets = _convertToAssets(_shares);

        _burn(_from, _shares);

        if (totalDepositedAssets >= assets) {
            totalDepositedAssets -= assets;
        } else {
            totalDepositedAssets = 0;
        }

        IERC20(UNDERLYING_ASSET).safeTransfer(_receiver, assets);

        claims = AssetClaims({
            stAssets: TRANCHE_TYPE_VALUE == TrancheType.SENIOR ? toTrancheUnits(assets) : toTrancheUnits(0),
            jtAssets: TRANCHE_TYPE_VALUE == TrancheType.JUNIOR ? toTrancheUnits(assets) : toTrancheUnits(0),
            nav: toNAVUnits(assets)
        });

        emit SharesSeizedAndRedeemed(msg.sender, _from, _receiver, claims, _shares);
    }

    function previewMintProtocolFeeShares(
        NAV_UNIT _protocolFeeNAV,
        NAV_UNIT _totalTrancheNAV
    )
        external
        view
        override
        returns (uint256 protocolFeeSharesMinted, uint256 totalTrancheShares)
    {
        // Simplified implementation for testing
        uint256 feeNAV = toUint256(_protocolFeeNAV);
        uint256 totalNAV = toUint256(_totalTrancheNAV);

        if (totalNAV == 0) {
            protocolFeeSharesMinted = feeNAV;
        } else {
            protocolFeeSharesMinted = totalSupply().mulDiv(feeNAV, totalNAV);
        }
        totalTrancheShares = totalSupply() + protocolFeeSharesMinted;
    }

    function mintProtocolFeeShares(
        NAV_UNIT _protocolFeeNAV,
        NAV_UNIT _totalTrancheNAV,
        address _protocolFeeRecipient
    )
        external
        override
        returns (uint256 protocolFeeSharesMinted, uint256 totalTrancheShares)
    {
        (protocolFeeSharesMinted, totalTrancheShares) = this.previewMintProtocolFeeShares(_protocolFeeNAV, _totalTrancheNAV);

        if (protocolFeeSharesMinted > 0) {
            _mint(_protocolFeeRecipient, protocolFeeSharesMinted);
        }

        emit ProtocolFeeSharesMinted(_protocolFeeRecipient, protocolFeeSharesMinted, totalTrancheShares);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _convertToShares(uint256 _assets) internal view returns (uint256) {
        // shares = assets * 1e18 / sharePriceWAD
        return _assets.mulDiv(1e18, sharePriceWAD, Math.Rounding.Floor);
    }

    function _convertToAssets(uint256 _shares) internal view returns (uint256) {
        // assets = shares * sharePriceWAD / 1e18
        return _shares.mulDiv(sharePriceWAD, 1e18, Math.Rounding.Floor);
    }
}
