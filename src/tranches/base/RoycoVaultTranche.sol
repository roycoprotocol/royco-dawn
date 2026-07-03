// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { ERC20Upgradeable, IERC20, IERC20Metadata } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import { ERC20BurnableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import { ERC20PausableUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import { ERC20PermitUpgradeable } from "../../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { SafeERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { RoycoBase } from "../../base/RoycoBase.sol";
import { IRoycoKernel } from "../../interfaces/IRoycoKernel.sol";
import { IRoycoVaultTranche } from "../../interfaces/IRoycoVaultTranche.sol";
import { WAD_DECIMALS, ZERO_NAV_UNITS } from "../../libraries/Constants.sol";
import { AssetClaims, SyncedAccountingState, TrancheType } from "../../libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, UnitsMathLib, toNAVUnits, toTrancheUnits, toUint256 } from "../../libraries/Units.sol";
import { UtilsLib } from "../../libraries/UtilsLib.sol";

/**
 * @title RoycoVaultTranche
 * @author Ankur Dubey, Shivaansh Kapoor
 * @notice Abstract base contract implementing core vault functionality for Royco tranches (ST and JT)
 * @dev Tranches interact with the kernel for asset operations and the accountant for NAV synchronizations
 */
abstract contract RoycoVaultTranche is IRoycoVaultTranche, RoycoBase, ERC20PausableUpgradeable, ERC20BurnableUpgradeable, ERC20PermitUpgradeable {
    using Math for uint256;
    using UnitsMathLib for uint256;
    using SafeERC20 for IERC20;

    /// @dev The address of the yield bearing asset of the tranche
    address private immutable ASSET;

    /// @inheritdoc IRoycoVaultTranche
    address public immutable override(IRoycoVaultTranche) KERNEL;

    /**
     * @notice Constructs the Royco vault tranche
     * @param _asset The underlying asset for the tranche
     * @param _kernel The kernel that handles strategy logic
     */
    constructor(address _asset, address _kernel) {
        // Ensure that the asset and kernel are not null
        require(_asset != address(0) && _kernel != address(0), NULL_ADDRESS());

        // Set the immutable state
        ASSET = _asset;
        KERNEL = _kernel;
    }

    /**
     * @notice Initializes the Royco tranche
     * @dev This function initializes parent contracts and the tranche-specific state
     * @param _params Deployment parameters including name, symbol, and initial authority
     */
    function __RoycoTranche_init(RoycoTrancheInitParams calldata _params) internal onlyInitializing {
        // Initialize the parent contracts
        __ERC20_init_unchained(_params.name, _params.symbol);
        __ERC20Pausable_init();
        __ERC20Burnable_init();
        __ERC20Permit_init(_params.name);
        __RoycoBase_init(_params.initialAuthority);
    }

    /// =============================
    /// Tranche Deposit and Redeem Functions
    /// =============================

    /// @inheritdoc IRoycoVaultTranche
    function deposit(TRANCHE_UNIT _assets, address _receiver) public virtual override(IRoycoVaultTranche) whenNotPaused restricted returns (uint256 shares) {
        require(_receiver != address(0), ERC20InvalidReceiver(address(0)));

        // Transfer the assets to the kernel
        IERC20(ASSET).safeTransferFrom(msg.sender, KERNEL, toUint256(_assets));

        // Deposit the assets into the Royco market and get the fraction of total assets allocated
        (NAV_UNIT valueAllocated, NAV_UNIT effectiveNAVToMintAt) =
            (TRANCHE_TYPE() == TrancheType.SENIOR ? IRoycoKernel(KERNEL).stDeposit(_assets) : IRoycoKernel(KERNEL).jtDeposit(_assets));

        // effectiveNAVToMint at can be zero initially when the tranche is deployed
        require(valueAllocated != ZERO_NAV_UNITS, INVALID_VALUE_ALLOCATED());

        // valueAllocated represents the value of the assets deposited in the asset that the tranche's NAV is denominated in
        // shares are minted to the user at the effective NAV of the tranche
        // effectiveNAVToMintAt is the effective NAV of the tranche before the deposit is made, ie. the NAV at which the shares will be minted
        shares = _convertToShares(valueAllocated, totalSupply(), effectiveNAVToMintAt, Math.Rounding.Floor);
        require(shares != 0, MUST_MINT_NON_ZERO_SHARES());

        // Mint the shares to the receiver
        _mint(_receiver, shares);

        emit Deposit(msg.sender, _receiver, _assets, shares);
    }

    /// @inheritdoc IRoycoVaultTranche
    function redeem(
        uint256 _shares,
        address _receiver,
        address _owner
    )
        public
        virtual
        override(IRoycoVaultTranche)
        whenNotPaused
        restricted
        returns (AssetClaims memory claims)
    {
        require(_receiver != address(0), ERC20InvalidReceiver(address(0)));
        require(_shares != 0, MUST_REQUEST_NON_ZERO_SHARES());

        // Spend allowance if msg.sender is not the owner
        if (msg.sender != _owner) {
            _spendAllowance(_owner, msg.sender, _shares);
        }

        // Process the withdrawal from the Royco market
        // It is expected that the kernel transfers the assets directly to the receiver
        claims =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IRoycoKernel(KERNEL).stRedeem(_shares, _receiver, false)
                : IRoycoKernel(KERNEL).jtRedeem(_shares, _receiver, false));

        // Burn shares after kernel processes redemption (kernel depends on pre-burn total supply)
        _burn(_owner, _shares);

        emit Redeem(msg.sender, _receiver, claims, _shares);
    }

    /// @inheritdoc IRoycoVaultTranche
    function mintProtocolFeeShares(
        NAV_UNIT _protocolFeeNAV,
        NAV_UNIT _totalTrancheNAV,
        address _protocolFeeRecipient
    )
        external
        virtual
        override(IRoycoVaultTranche)
        returns (uint256 protocolFeeSharesMinted, uint256 totalTrancheShares)
    {
        // Only the kernel can mint protocol fee shares based on sync
        require(msg.sender == KERNEL, ONLY_KERNEL());

        // Mint any protocol fee shares accrued to the specified recipient
        (protocolFeeSharesMinted, totalTrancheShares) = previewMintProtocolFeeShares(_protocolFeeNAV, _totalTrancheNAV);
        if (protocolFeeSharesMinted != 0) _mint(_protocolFeeRecipient, protocolFeeSharesMinted);

        emit ProtocolFeeSharesMinted(_protocolFeeRecipient, protocolFeeSharesMinted, totalTrancheShares);
    }

    // =============================
    // Tranche Compliance Functions
    // =============================

    /// @inheritdoc IRoycoVaultTranche
    function seizeShares(address _from, address _receiver, uint256 _shares) external virtual override(IRoycoVaultTranche) restricted {
        // Basic sanity checks on the seizure
        require(_from != address(0), NULL_ADDRESS());
        require(_receiver != address(0), ERC20InvalidReceiver(address(0)));
        require(_shares != 0, MUST_REQUEST_NON_ZERO_SHARES());

        // Transfer the shares to the receiver
        // Bypass the balance update hook
        super._update(_from, _receiver, _shares);

        emit SharesSeized(msg.sender, _from, _receiver, _shares);
    }

    /// @inheritdoc IRoycoVaultTranche
    function seizeAndRedeemShares(
        address _from,
        address _receiver,
        uint256 _shares
    )
        external
        virtual
        override(IRoycoVaultTranche)
        restricted
        returns (AssetClaims memory claims)
    {
        // Basic sanity checks on the seizure
        require(_from != address(0), NULL_ADDRESS());
        require(_receiver != address(0), ERC20InvalidReceiver(address(0)));
        require(_shares != 0, MUST_REQUEST_NON_ZERO_SHARES());

        // Force process the withdrawal from the Royco market
        // It is expected that the kernel transfers the assets directly to the receiver
        claims =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IRoycoKernel(KERNEL).stRedeem(_shares, _receiver, true)
                : IRoycoKernel(KERNEL).jtRedeem(_shares, _receiver, true));

        // Burn shares after kernel processes redemption
        // Bypass the balance update hook
        super._update(_from, address(0), _shares);

        emit SharesSeizedAndRedeemed(msg.sender, _from, _receiver, claims, _shares);
    }

    /// @inheritdoc ERC20BurnableUpgradeable
    function burn(uint256 _shares) public override(ERC20BurnableUpgradeable, IRoycoVaultTranche) whenNotPaused restricted {
        super.burn(_shares);
    }

    /// @inheritdoc ERC20BurnableUpgradeable
    function burnFrom(address _account, uint256 _shares) public override(ERC20BurnableUpgradeable, IRoycoVaultTranche) whenNotPaused restricted {
        super.burnFrom(_account, _shares);
    }

    /// =============================
    /// Tranche Preview and Conversion Functions
    /// =============================

    /// @inheritdoc IRoycoVaultTranche
    function previewDeposit(TRANCHE_UNIT _assets) external view virtual override(IRoycoVaultTranche) returns (uint256 shares) {
        // Get the state of the tranche before the deposit and the value allocated to the tranche
        (SyncedAccountingState memory stateBeforeDeposit, NAV_UNIT valueAllocated) =
            (TRANCHE_TYPE() == TrancheType.SENIOR ? IRoycoKernel(KERNEL).stPreviewDeposit(_assets) : IRoycoKernel(KERNEL).jtPreviewDeposit(_assets));

        // Preview the total tranche shares after minting any protocol fee shares post-sync
        NAV_UNIT feeAccrued = TRANCHE_TYPE() == TrancheType.SENIOR ? stateBeforeDeposit.stProtocolFeeAccrued : stateBeforeDeposit.jtProtocolFeeAccrued;
        NAV_UNIT effectiveNAV = TRANCHE_TYPE() == TrancheType.SENIOR ? stateBeforeDeposit.stEffectiveNAV : stateBeforeDeposit.jtEffectiveNAV;
        (uint256 feeSharesMinted,) = previewMintProtocolFeeShares(feeAccrued, effectiveNAV);

        // Calculate the shares to be minted to the receiver, considering the protocol fee shares
        shares = _convertToShares(valueAllocated, feeSharesMinted + totalSupply(), effectiveNAV, Math.Rounding.Floor);
    }

    /// @inheritdoc IRoycoVaultTranche
    function previewRedeem(uint256 _shares) external view virtual override(IRoycoVaultTranche) returns (AssetClaims memory claims) {
        claims = (TRANCHE_TYPE() == TrancheType.SENIOR ? IRoycoKernel(KERNEL).stPreviewRedeem(_shares) : IRoycoKernel(KERNEL).jtPreviewRedeem(_shares));
    }

    /// @inheritdoc IRoycoVaultTranche
    function convertToAssets(uint256 _shares) public view virtual override(IRoycoVaultTranche) returns (AssetClaims memory claims) {
        // Get the post-sync tranche state: applying NAV reconciliation.
        (AssetClaims memory trancheClaims, uint256 trancheTotalShares) = _previewPostSyncTrancheState();
        return UtilsLib.scaleAssetClaims(trancheClaims, _shares, trancheTotalShares);
    }

    /// @inheritdoc IRoycoVaultTranche
    function convertToShares(TRANCHE_UNIT _assets) public view virtual override(IRoycoVaultTranche) returns (uint256 shares) {
        // Get the post-sync tranche state: applying NAV reconciliation.
        NAV_UNIT navAssets =
        (TRANCHE_TYPE() == TrancheType.SENIOR
                ? IRoycoKernel(KERNEL).stConvertTrancheUnitsToNAVUnits(_assets)
                : IRoycoKernel(KERNEL).jtConvertTrancheUnitsToNAVUnits(_assets));
        (AssetClaims memory trancheClaims, uint256 trancheTotalShares) = _previewPostSyncTrancheState();
        shares = _convertToShares(navAssets, trancheTotalShares, trancheClaims.nav, Math.Rounding.Floor);
    }

    /// @inheritdoc IRoycoVaultTranche
    function previewMintProtocolFeeShares(
        NAV_UNIT _protocolFeeNAV,
        NAV_UNIT _totalTrancheNAV
    )
        public
        view
        virtual
        override(IRoycoVaultTranche)
        returns (uint256 protocolFeeSharesMinted, uint256 totalTrancheShares)
    {
        // Compute the shares to be minted to the protocol fee recipient to satisfy the ratio of total assets that the fee represents
        // Subtract fee assets from total tranche assets because fees are included in total tranche assets
        // Round in favor of the tranche
        totalTrancheShares = totalSupply();

        // If the protocol fee NAV is zero, return zero shares
        if (_protocolFeeNAV == ZERO_NAV_UNITS) return (0, totalTrancheShares);

        // Calculate the shares to be minted to the protocol fee recipient and add it to the total tranche shares
        totalTrancheShares += protocolFeeSharesMinted = _convertToShares(
            _protocolFeeNAV, totalTrancheShares, (_totalTrancheNAV - _protocolFeeNAV), Math.Rounding.Floor
        );
    }

    /// =============================
    /// Tranche Max Deposit and Redeem Functions
    /// =============================

    /// @inheritdoc IRoycoVaultTranche
    function maxDeposit(address _receiver) external view virtual override(IRoycoVaultTranche) returns (TRANCHE_UNIT assets) {
        assets = (TRANCHE_TYPE() == TrancheType.SENIOR ? IRoycoKernel(KERNEL).stMaxDeposit(_receiver) : IRoycoKernel(KERNEL).jtMaxDeposit(_receiver));
    }

    /// @inheritdoc IRoycoVaultTranche
    function maxRedeem(address _owner) public view virtual override(IRoycoVaultTranche) returns (uint256 shares) {
        //  We query the kernel for (a) N_s and N_j - the notional claim of the tranche on the ST and JT assets respectively in NAV units, and
        //                          (b) L_s and L_j - the amount that can be withdrawn from the senior and junior tranches globally in NAV units, respectively
        //  When shares are redeemed, assets from the senior and junior tranches are withdrawn proportionally to the notional claims of the tranche on the respective assets.
        //  But, the global max withdrawable assets for each tranche are also considered. These are inclusive of any coverage requirements, as well as liquidity constraints.
        //  If T respresents the total shares in the tranche, s the total shares owned by the owner, then the maximum amount of shares that can be redeemed s' is subject to:
        //      (a) s' * N_s / T  <= min(s * N_s / T, L_s) => s' <= min(s, T * L_s / N_s)
        //      (b) s' * N_j / T  <= min(s * N_j / T, L_j) => s' <= min(s, T * L_j / N_j)
        //  Therefore, the maximum amount of shares that can be redeemed is:
        //      s' = min(s, T * L_s / N_s, T * L_j / N_j)
        uint256 sharesOwned = balanceOf(_owner);
        // Get the notional claims and the max withdrawable assets for the tranche
        (NAV_UNIT claimOnStNAV, NAV_UNIT claimOnJtNAV, NAV_UNIT stMaxWithdrawableNAV, NAV_UNIT jtMaxWithdrawableNAV, uint256 totalSharesAfterMintingFees) =
            (TRANCHE_TYPE() == TrancheType.SENIOR ? IRoycoKernel(KERNEL).stMaxWithdrawable(_owner) : IRoycoKernel(KERNEL).jtMaxWithdrawable(_owner));

        // We do not allow redemptions if the tranche has no claims on the assets
        if (claimOnStNAV + claimOnJtNAV == ZERO_NAV_UNITS) return 0;

        // Calculate the maximum amount of shares that can be redeemed based on the senior and junior constraints
        // If the notional claim of the tranche on the ST or JT assets is zero, ignore the constraints since the tranche has no claims on the assets
        uint256 sharesWithdrawableBasedOnSeniorConstraints =
            claimOnStNAV == ZERO_NAV_UNITS ? sharesOwned : totalSharesAfterMintingFees.mulDiv(stMaxWithdrawableNAV, claimOnStNAV, Math.Rounding.Floor);
        uint256 sharesWithdrawableBasedOnJuniorConstraints =
            claimOnJtNAV == ZERO_NAV_UNITS ? sharesOwned : totalSharesAfterMintingFees.mulDiv(jtMaxWithdrawableNAV, claimOnJtNAV, Math.Rounding.Floor);
        shares = Math.min(sharesOwned, Math.min(sharesWithdrawableBasedOnSeniorConstraints, sharesWithdrawableBasedOnJuniorConstraints));
    }

    /// =============================
    /// General Tranche View Functions
    /// =============================

    /// @inheritdoc IRoycoVaultTranche
    function totalAssets() external view virtual override(IRoycoVaultTranche) returns (AssetClaims memory claims) {
        (, claims,) = IRoycoKernel(KERNEL).previewSyncTrancheAccounting(TRANCHE_TYPE());
    }

    /// @inheritdoc IRoycoVaultTranche
    function getRawNAV() external view virtual override(IRoycoVaultTranche) returns (NAV_UNIT nav) {
        (SyncedAccountingState memory state,,) = IRoycoKernel(KERNEL).previewSyncTrancheAccounting(TRANCHE_TYPE());
        nav = TRANCHE_TYPE() == TrancheType.SENIOR ? state.stRawNAV : state.jtRawNAV;
    }

    /// @inheritdoc IERC20Metadata
    function decimals() public view virtual override(ERC20Upgradeable, IERC20Metadata) returns (uint8) {
        // The Kernel always uses WAD precision for NAV units
        // Shares are minted using NAV values, instead of asset values, so they have identical precision to NAV units (WAD precision)
        return uint8(WAD_DECIMALS);
    }

    /// @inheritdoc IRoycoVaultTranche
    function asset() external view virtual override(IRoycoVaultTranche) returns (address) {
        return ASSET;
    }

    /// @dev Returns the type of the tranche (Senior or Junior)
    function TRANCHE_TYPE() public pure virtual returns (TrancheType);

    // =============================
    // Internal Utility Functions
    // =============================

    /**
     * @notice Returns the total tranche assets and shares after previewing a NAV synchronization in the kernel
     * @return trancheClaims The breakdown of total tranche's total controlled assets
     * @return trancheTotalShares The total supply of tranche shares (including marginally minted fee shares)
     */
    function _previewPostSyncTrancheState() internal view returns (AssetClaims memory trancheClaims, uint256 trancheTotalShares) {
        (, trancheClaims, trancheTotalShares) = IRoycoKernel(KERNEL).previewSyncTrancheAccounting(TRANCHE_TYPE());
    }

    /**
     * @dev Returns the amount of shares that have a claim on the specified amount of tranche controlled assets
     * @param _assets The amount of assets to convert in NAV units
     * @param _totalSupply The total supply of tranche shares (including marginally minted fee shares)
     * @param _totalAssets The total tranche controlled assets in NAV units
     * @param _rounding The rounding mode to use
     * @return shares The number of shares that have a claim on the specified amount of tranche controlled assets
     */
    function _convertToShares(NAV_UNIT _assets, uint256 _totalSupply, NAV_UNIT _totalAssets, Math.Rounding _rounding) internal pure returns (uint256 shares) {
        if (_totalSupply == 0) return toUint256(_assets);

        // When total assets are zero, we want new depositors to dilute the existing unbacked share holders
        // At this boundary condition, we assume all existing shares are backed by a single NAV unit
        // This gives majority ownership of the deposited assets to the new depositor, diluting all existing share holders
        if (_totalAssets == ZERO_NAV_UNITS) _totalAssets = toNAVUnits(uint256(1));

        return _totalSupply.mulDiv(_assets, _totalAssets, _rounding);
    }

    /// @inheritdoc ERC20PausableUpgradeable
    function _update(address _from, address _to, uint256 _value) internal override(ERC20PausableUpgradeable, ERC20Upgradeable) whenNotPaused {
        // Call the kernel pre-balance update hook to assert that the balance update is valid
        IRoycoKernel(KERNEL).preTrancheBalanceUpdateHook(msg.sender, _from, _to, _value);

        // Call the parent contract update function to update the balance
        // NOTE: This will execute even if the tranche is in a paused state
        ERC20Upgradeable._update(_from, _to, _value);
    }
}
