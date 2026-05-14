// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { AssetClaims, TrancheType } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT } from "../../../src/libraries/Units.sol";
import { RoycoJuniorTranche } from "../../../src/tranches/RoycoJuniorTranche.sol";
import { RoycoSeniorTranche } from "../../../src/tranches/RoycoSeniorTranche.sol";

import { UpgradeModuleBase } from "./UpgradeModuleBase.sol";

/**
 * @title UpgradeTrancheModule
 * @notice Module for upgrading `RoycoSeniorTranche` and `RoycoJuniorTranche` proxies.
 *
 * @dev Payload schema (ABI-encoded by the orchestrator):
 *        abi.encode(string marketName, TrancheType trancheType)
 *
 *      The module:
 *        1. Resolves the proxy via `getMarketAddresses(chainId, marketName).{seniorTranche|juniorTranche}`
 *        2. Validates `proxy.TRANCHE_TYPE()` matches the requested `trancheType`
 *        3. Reads constructor immutables off the existing impl: `asset()`, `KERNEL()`
 *        4. Predicts the new impl address via CREATE2 using the SAME constructor args
 *
 *      `snapshotState()` (post-warp) and `verify()` together assert continuity of:
 *        name, symbol, totalSupply, asset, KERNEL, TRANCHE_TYPE, and `totalAssets()` (all three
 *        claim fields: stAssets, jtAssets, nav).
 */
contract UpgradeTrancheModule is UpgradeModuleBase {
    error UpgradeTrancheModule__TrancheTypeMismatch(TrancheType requested, TrancheType actual);
    error UpgradeTrancheModule__NotATrancheProxy(address proxy);
    error UpgradeTrancheModule__NewImplIdenticalToOld(address impl);
    error UpgradeTrancheModule__NameChanged();
    error UpgradeTrancheModule__SymbolChanged();
    error UpgradeTrancheModule__TotalSupplyChanged(uint256 expected, uint256 actual);
    error UpgradeTrancheModule__AssetImmutableChanged(address expected, address actual);
    error UpgradeTrancheModule__KernelImmutableChanged(address expected, address actual);
    error UpgradeTrancheModule__TrancheTypeChanged(TrancheType expected, TrancheType actual);
    error UpgradeTrancheModule__TotalAssetsStChanged(TRANCHE_UNIT expected, TRANCHE_UNIT actual);
    error UpgradeTrancheModule__TotalAssetsJtChanged(TRANCHE_UNIT expected, TRANCHE_UNIT actual);
    error UpgradeTrancheModule__TotalAssetsNavChanged(NAV_UNIT expected, NAV_UNIT actual);

    /// @inheritdoc UpgradeModuleBase
    function prepare(uint256 _chainId, string memory _saltVersion, bytes memory _payload) external view override returns (PreparedUpgrade memory prepared) {
        (string memory marketName, TrancheType trancheType) = abi.decode(_payload, (string, TrancheType));

        MarketAddresses memory addrs = getMarketAddresses(_chainId, marketName);
        address proxy = trancheType == TrancheType.SENIOR ? addrs.seniorTranche : addrs.juniorTranche;

        // Type validation — reverts if the proxy is not the requested tranche variant
        IRoycoVaultTranche t = IRoycoVaultTranche(proxy);
        TrancheType actual = t.TRANCHE_TYPE();
        require(actual == trancheType, UpgradeTrancheModule__TrancheTypeMismatch(trancheType, actual));

        // Read constructor immutables off the proxy (delegatecalled into existing impl)
        address asset = t.asset();
        address kernel = t.KERNEL();
        require(asset != address(0) && kernel != address(0), UpgradeTrancheModule__NotATrancheProxy(proxy));

        address oldImpl = _readImplementation(proxy);

        // Build creation code with the SAME constructor args
        bytes memory creationCode = trancheType == TrancheType.SENIOR
            ? abi.encodePacked(type(RoycoSeniorTranche).creationCode, abi.encode(asset, kernel))
            : abi.encodePacked(type(RoycoJuniorTranche).creationCode, abi.encode(asset, kernel));

        // Salt — user owns the version suffix; bump it per upgrade
        bytes32 salt = trancheType == TrancheType.SENIOR
            ? keccak256(abi.encodePacked("ROYCO_ST_TRANCHE_IMPLEMENTATION_", _saltVersion))
            : keccak256(abi.encodePacked("ROYCO_JT_TRANCHE_IMPLEMENTATION_", _saltVersion));

        address newImpl = _predictImpl(salt, creationCode);
        require(newImpl != oldImpl, UpgradeTrancheModule__NewImplIdenticalToOld(newImpl));

        string memory label = string.concat(trancheType == TrancheType.SENIOR ? "ST/" : "JT/", marketName);

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
                description: string.concat("Upgrade ", label, " tranche implementation to ", vm.toString(newImpl))
            }),
            label: label
        });
    }

    /// @inheritdoc UpgradeModuleBase
    function snapshotState(address _proxy) external view override returns (bytes memory) {
        IRoycoVaultTranche t = IRoycoVaultTranche(_proxy);
        AssetClaims memory claims = t.totalAssets();
        return abi.encode(t.name(), t.symbol(), t.totalSupply(), t.asset(), t.KERNEL(), t.TRANCHE_TYPE(), claims.stAssets, claims.jtAssets, claims.nav);
    }

    /// @inheritdoc UpgradeModuleBase
    function verify(address _proxy, bytes memory _preStateSnapshot) external view override {
        (
            string memory name,
            string memory symbol,
            uint256 totalSupply,
            address asset,
            address kernel,
            TrancheType trancheType,
            TRANCHE_UNIT stAssets,
            TRANCHE_UNIT jtAssets,
            NAV_UNIT nav
        ) = abi.decode(_preStateSnapshot, (string, string, uint256, address, address, TrancheType, TRANCHE_UNIT, TRANCHE_UNIT, NAV_UNIT));

        IRoycoVaultTranche t = IRoycoVaultTranche(_proxy);
        require(keccak256(bytes(t.name())) == keccak256(bytes(name)), UpgradeTrancheModule__NameChanged());
        require(keccak256(bytes(t.symbol())) == keccak256(bytes(symbol)), UpgradeTrancheModule__SymbolChanged());
        require(t.totalSupply() == totalSupply, UpgradeTrancheModule__TotalSupplyChanged(totalSupply, t.totalSupply()));
        require(t.asset() == asset, UpgradeTrancheModule__AssetImmutableChanged(asset, t.asset()));
        require(t.KERNEL() == kernel, UpgradeTrancheModule__KernelImmutableChanged(kernel, t.KERNEL()));
        require(t.TRANCHE_TYPE() == trancheType, UpgradeTrancheModule__TrancheTypeChanged(trancheType, t.TRANCHE_TYPE()));

        AssetClaims memory claims = t.totalAssets();
        require(TRANCHE_UNIT.unwrap(claims.stAssets) == TRANCHE_UNIT.unwrap(stAssets), UpgradeTrancheModule__TotalAssetsStChanged(stAssets, claims.stAssets));
        require(TRANCHE_UNIT.unwrap(claims.jtAssets) == TRANCHE_UNIT.unwrap(jtAssets), UpgradeTrancheModule__TotalAssetsJtChanged(jtAssets, claims.jtAssets));
        require(NAV_UNIT.unwrap(claims.nav) == NAV_UNIT.unwrap(nav), UpgradeTrancheModule__TotalAssetsNavChanged(nav, claims.nav));
    }
}
