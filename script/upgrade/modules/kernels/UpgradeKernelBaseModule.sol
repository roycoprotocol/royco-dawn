// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoKernel } from "../../../../src/interfaces/IRoycoKernel.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../../../../src/libraries/Units.sol";

import { UpgradeModuleBase } from "../UpgradeModuleBase.sol";

/// @notice Minimal interface to read the immutable bool that's exposed on the concrete `RoycoKernel`
///         but not on `IRoycoKernel`. Avoids importing the full `RoycoKernel` here.
interface IKernelExtra {
    function ENFORCE_TRANCHE_SHARES_TRANSFER_WHITELIST() external view returns (bool);
}

/**
 * @title UpgradeKernelBaseModule
 * @notice Abstract base for `RoycoKernel`-family upgrades. Concrete subclasses (one per kernel
 *         contract type) supply the kernel contract name (used in the salt), the creation code,
 *         and any kernel-type-specific snapshot/verify logic.
 *
 * @dev Payload schema (ABI-encoded by the orchestrator):
 *        abi.encode(string marketName)
 *
 *      The base module:
 *        1. Resolves the kernel proxy via `getMarketAddresses(chainId, marketName).kernel`
 *        2. Validates the proxy is a kernel (immutables non-zero, getState() succeeds)
 *        3. Reads the `RoycoKernelConstructionParams` off the existing impl
 *        4. Lets the subclass build the new impl creation code from those params
 *        5. Predicts the new impl's CREATE2 address using the subclass-supplied kernel contract name
 *
 *      `snapshotState` records the common kernel surface (immutables + `getState()` + the live
 *      tranche↔NAV conversion rate) and concatenates the subclass-specific snapshot.
 *      `verify` decodes both halves and asserts continuity.
 */
abstract contract UpgradeKernelBaseModule is UpgradeModuleBase {
    error UpgradeKernelBaseModule__NotAKernelProxy(address proxy);
    error UpgradeKernelBaseModule__NewImplIdenticalToOld(address impl);
    error UpgradeKernelBaseModule__ImmutableChanged(string field);
    error UpgradeKernelBaseModule__StateChanged(string field);
    error UpgradeKernelBaseModule__ConversionRateChanged(string side, uint256 expected, uint256 actual);

    // ═══════════════════════════════════════════════════════════════════════════
    // ABSTRACT — implemented by concrete kernel modules
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Contract name embedded in the CREATE2 salt prefix; must match the live kernel impl class.
    function _kernelContractName() internal pure virtual returns (string memory);

    /// @notice Creation code for the new kernel impl, given the construction params read off the proxy.
    function _kernelCreationCodeWith(IRoycoKernel.RoycoKernelConstructionParams memory cp) internal pure virtual returns (bytes memory);

    /// @notice Module-specific snapshot bytes (e.g. quoter config, kernel-type immutables).
    function _snapshotKernelSpecific(address proxy) internal view virtual returns (bytes memory);

    /// @notice Module-specific verification given the snapshot returned by `_snapshotKernelSpecific`.
    function _verifyKernelSpecific(address proxy, bytes memory specificSnapshot) internal view virtual;

    // ═══════════════════════════════════════════════════════════════════════════
    // PREPARE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc UpgradeModuleBase
    function prepare(uint256 _chainId, string memory _saltVersion, bytes memory _payload) external view override returns (PreparedUpgrade memory prepared) {
        string memory marketName = abi.decode(_payload, (string));

        MarketAddresses memory addrs = getMarketAddresses(_chainId, marketName);
        address proxy = addrs.kernel;

        IRoycoKernel.RoycoKernelConstructionParams memory cp = _readConstructionParams(proxy);
        require(
            cp.seniorTranche != address(0) && cp.juniorTranche != address(0) && cp.accountant != address(0), UpgradeKernelBaseModule__NotAKernelProxy(proxy)
        );
        // Sanity-check: the kernel must report state (proves the proxy is initialized + is a kernel)
        IRoycoKernel(proxy).getState();

        address oldImpl = _readImplementation(proxy);
        bytes memory creationCode = _kernelCreationCodeWith(cp);
        bytes32 salt = keccak256(abi.encodePacked("ROYCO_KERNEL_", _kernelContractName(), "_IMPLEMENTATION_", _saltVersion));

        address newImpl = _predictImpl(salt, creationCode);
        require(newImpl != oldImpl, UpgradeKernelBaseModule__NewImplIdenticalToOld(newImpl));

        string memory label = string.concat("Kernel/", marketName);

        prepared = PreparedUpgrade({
            proxy: proxy,
            oldImpl: oldImpl,
            newImpl: newImpl,
            implSalt: salt,
            implCreationCode: creationCode,
            call: UpgradeCall({
                marketName: marketName,
                target: proxy,
                callData: _buildUpgradeCallData(newImpl),
                description: string.concat("Upgrade ", label, " (", _kernelContractName(), ") implementation to ", vm.toString(newImpl))
            }),
            label: label
        });
    }

    function _readConstructionParams(address _proxy) internal view returns (IRoycoKernel.RoycoKernelConstructionParams memory cp) {
        IRoycoKernel k = IRoycoKernel(_proxy);
        cp.seniorTranche = k.SENIOR_TRANCHE();
        cp.stAsset = k.ST_ASSET();
        cp.juniorTranche = k.JUNIOR_TRANCHE();
        cp.jtAsset = k.JT_ASSET();
        cp.accountant = k.ACCOUNTANT();
        cp.enforceVaultSharesTransferWhitelist = IKernelExtra(_proxy).ENFORCE_TRANCHE_SHARES_TRANSFER_WHITELIST();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SNAPSHOT / VERIFY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc UpgradeModuleBase
    function snapshotState(address _proxy) external view override returns (bytes memory) {
        return abi.encode(_snapshotCommon(_proxy), _snapshotKernelSpecific(_proxy));
    }

    /// @inheritdoc UpgradeModuleBase
    function verify(address _proxy, bytes memory _preStateSnapshot) external view override {
        (bytes memory common, bytes memory specific) = abi.decode(_preStateSnapshot, (bytes, bytes));
        _verifyCommon(_proxy, common);
        _verifyKernelSpecific(_proxy, specific);
    }

    /// @dev Common kernel state shared by every kernel type. Conversion rates are evaluated at
    ///      `1e18` tranche units; `block.timestamp` is the same for snapshot and verify (orchestrator
    ///      calls them back-to-back), so any oracle-driven math is reproducible.
    function _snapshotCommon(address _proxy) internal view returns (bytes memory) {
        IRoycoKernel k = IRoycoKernel(_proxy);
        IRoycoKernel.RoycoKernelStateView memory state = k.getState();
        uint256 stConv = NAV_UNIT.unwrap(k.stConvertTrancheUnitsToNAVUnits(_oneTrancheUnit()));
        uint256 jtConv = NAV_UNIT.unwrap(k.jtConvertTrancheUnitsToNAVUnits(_oneTrancheUnit()));
        return abi.encode(
            k.SENIOR_TRANCHE(),
            k.ST_ASSET(),
            k.JUNIOR_TRANCHE(),
            k.JT_ASSET(),
            k.ACCOUNTANT(),
            IKernelExtra(_proxy).ENFORCE_TRANCHE_SHARES_TRANSFER_WHITELIST(),
            state,
            stConv,
            jtConv
        );
    }

    function _verifyCommon(address _proxy, bytes memory _snap) internal view {
        (
            address senior,
            address stAsset,
            address junior,
            address jtAsset,
            address accountant,
            bool enforceWhitelist,
            IRoycoKernel.RoycoKernelStateView memory state,
            uint256 stConvRate,
            uint256 jtConvRate
        ) = abi.decode(_snap, (address, address, address, address, address, bool, IRoycoKernel.RoycoKernelStateView, uint256, uint256));

        IRoycoKernel k = IRoycoKernel(_proxy);
        require(k.SENIOR_TRANCHE() == senior, UpgradeKernelBaseModule__ImmutableChanged("SENIOR_TRANCHE"));
        require(k.ST_ASSET() == stAsset, UpgradeKernelBaseModule__ImmutableChanged("ST_ASSET"));
        require(k.JUNIOR_TRANCHE() == junior, UpgradeKernelBaseModule__ImmutableChanged("JUNIOR_TRANCHE"));
        require(k.JT_ASSET() == jtAsset, UpgradeKernelBaseModule__ImmutableChanged("JT_ASSET"));
        require(k.ACCOUNTANT() == accountant, UpgradeKernelBaseModule__ImmutableChanged("ACCOUNTANT"));
        require(
            IKernelExtra(_proxy).ENFORCE_TRANCHE_SHARES_TRANSFER_WHITELIST() == enforceWhitelist,
            UpgradeKernelBaseModule__ImmutableChanged("ENFORCE_TRANCHE_SHARES_TRANSFER_WHITELIST")
        );

        IRoycoKernel.RoycoKernelStateView memory post = k.getState();
        require(post.isBlacklistEnabled == state.isBlacklistEnabled, UpgradeKernelBaseModule__StateChanged("isBlacklistEnabled"));
        require(post.protocolFeeRecipient == state.protocolFeeRecipient, UpgradeKernelBaseModule__StateChanged("protocolFeeRecipient"));
        require(post.stSelfLiquidationBonusWAD == state.stSelfLiquidationBonusWAD, UpgradeKernelBaseModule__StateChanged("stSelfLiquidationBonusWAD"));
        require(
            TRANCHE_UNIT.unwrap(post.stOwnedYieldBearingAssets) == TRANCHE_UNIT.unwrap(state.stOwnedYieldBearingAssets),
            UpgradeKernelBaseModule__StateChanged("stOwnedYieldBearingAssets")
        );
        require(
            TRANCHE_UNIT.unwrap(post.jtOwnedYieldBearingAssets) == TRANCHE_UNIT.unwrap(state.jtOwnedYieldBearingAssets),
            UpgradeKernelBaseModule__StateChanged("jtOwnedYieldBearingAssets")
        );

        uint256 postStConv = NAV_UNIT.unwrap(k.stConvertTrancheUnitsToNAVUnits(_oneTrancheUnit()));
        uint256 postJtConv = NAV_UNIT.unwrap(k.jtConvertTrancheUnitsToNAVUnits(_oneTrancheUnit()));
        require(postStConv == stConvRate, UpgradeKernelBaseModule__ConversionRateChanged("ST", stConvRate, postStConv));
        require(postJtConv == jtConvRate, UpgradeKernelBaseModule__ConversionRateChanged("JT", jtConvRate, postJtConv));
    }

    function _oneTrancheUnit() private pure returns (TRANCHE_UNIT) {
        return TRANCHE_UNIT.wrap(1e18);
    }
}
