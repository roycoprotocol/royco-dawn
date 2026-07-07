// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC20Upgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import { EIP712Upgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/utils/cryptography/EIP712Upgradeable.sol";
import { IERC5267 } from "../../lib/openzeppelin-contracts/contracts/interfaces/IERC5267.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

import { Create2DeployUtils } from "../utils/Create2DeployUtils.sol";

/**
 * @title TrancheNameFix
 * @notice One-time throwaway UUPS implementation used to correct a tranche's ERC20 name/symbol
 *         (and the matching ERC20Permit EIP-712 domain name) that were set wrong at deployment.
 *
 * @dev Intended flow (must be executed ATOMICALLY in a single batch — see the warning below):
 *        1. `proxy.upgradeToAndCall(nameFixImpl, abi.encodeCall(TrancheNameFix.setName, (correctName)))`
 *           (goes through the AccessManager since the live impl's `_authorizeUpgrade` is `restricted`)
 *        2. `proxy.setSymbol(correctSymbol)` (only if the symbol is wrong too)
 *        3. `proxy.upgradeToAndCall(originalImpl, "")` — open on this impl, no AccessManager needed
 *
 *      It is NOT derived from RoycoVaultTranche on purpose: it has no constructor args / immutables,
 *      so a single deployment serves both the senior and junior tranche proxies. Deriving from
 *      `ERC20Upgradeable` keeps all token reads (balances, name, symbol) intact while this impl is live.
 *
 *      WARNING: `_authorizeUpgrade` is intentionally OPEN so the original implementation can be
 *      restored without a second trip through the AccessManager timelock. While this implementation
 *      is live, ANYONE can upgrade the proxy. Steps 1-3 must therefore execute atomically (same
 *      Safe batch / same transaction) so the proxy never rests on this implementation.
 */
contract TrancheNameFix is ERC20Upgradeable, EIP712Upgradeable, UUPSUpgradeable {
    /// @notice Emitted when the ERC20 + EIP-712 domain name is corrected
    event NameSet(string newName, string eip712Name);

    /// @notice Emitted when the ERC20 symbol is corrected
    event SymbolSet(string newSymbol);

    /// @dev Mirror of OZ v5 `ERC20Upgradeable.ERC20Storage` (ERC-7201: openzeppelin.storage.ERC20)
    struct OZERC20Storage {
        mapping(address account => uint256) balances;
        mapping(address account => mapping(address spender => uint256)) allowances;
        uint256 totalSupply;
        string name;
        string symbol;
    }

    /// @dev Mirror of OZ v5 `EIP712Upgradeable.EIP712Storage` (ERC-7201: openzeppelin.storage.EIP712)
    struct OZEIP712Storage {
        bytes32 hashedName;
        bytes32 hashedVersion;
        string name;
        string version;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC20")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC20_STORAGE_LOCATION = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;

    /// @dev keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.EIP712")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EIP712_STORAGE_LOCATION = 0xa16a46d94261c7517cc8ff89f61c0ce93598e3c849801011dee649a6a557d100;

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Sets the ERC20 name and the ERC20Permit EIP-712 domain name (both were initialized
     *         from the same wrong string in `__RoycoTranche_init`)
     * @dev Meant to be passed as the `data` of `upgradeToAndCall` so the fix applies in the same
     *      transaction as the upgrade
     */
    function setName(string calldata _newName) external onlyProxy {
        _erc20Storage().name = _newName;
        _eip712Storage().name = _newName;
        emit NameSet(name(), _EIP712Name());
    }

    /// @notice Sets the ERC20 symbol
    function setSymbol(string calldata _newSymbol) external onlyProxy {
        _erc20Storage().symbol = _newSymbol;
        emit SymbolSet(symbol());
    }

    /// @dev Intentionally open — see the contract-level warning. This implementation must only be
    ///      live within a single atomic batch that ends by restoring the original implementation.
    function _authorizeUpgrade(address _newImplementation) internal override(UUPSUpgradeable) { }

    function _erc20Storage() private pure returns (OZERC20Storage storage $) {
        assembly {
            $.slot := ERC20_STORAGE_LOCATION
        }
    }

    function _eip712Storage() private pure returns (OZEIP712Storage storage $) {
        assembly {
            $.slot := EIP712_STORAGE_LOCATION
        }
    }

    fallback() external { }
}

/**
 * @title DeployTrancheNameFix
 * @notice Standalone CREATE2 deployment of the `TrancheNameFix` implementation
 *
 * @dev Usage:
 *        source .env && forge script script/independent/DeployTrancheNameFix.s.sol \
 *          --rpc-url $BASE_RPC_URL --broadcast --verify
 *
 *      The contract has no constructor args, so the same deployment serves every tranche proxy on
 *      the chain. When run against Base, the script also fork-simulates the full fix + restore
 *      round-trip on the mis-named sNUSN market tranches as a sanity check before broadcasting.
 */
contract DeployTrancheNameFix is Create2DeployUtils {
    bytes32 internal constant SALT = keccak256("ROYCO_TRANCHE_NAME_FIX_IMPLEMENTATION_V1");
    bytes32 internal constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // Base sNUSN market tranche proxies (name/symbol deployed as "sNUSN")
    uint256 internal constant BASE_CHAIN_ID = 8453;
    address internal constant SNUSN_ST_PROXY = 0x98d55707B60793AC8cadAB3C456dA156671F138a;
    address internal constant SNUSN_JT_PROXY = 0xeEEd721C62e8b2d2d5AdA18FE82014C6c08D18A5;

    error SimulationNameMismatch(address proxy);
    error SimulationSymbolMismatch(address proxy);
    error SimulationDomainNameMismatch(address proxy);
    error SimulationImplNotRestored(address proxy);
    error SimulationTotalSupplyChanged(address proxy);

    function run() external {
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        (address impl, bool alreadyDeployed) = deployWithSanityChecks(SALT, type(TrancheNameFix).creationCode, false);
        vm.stopBroadcast();

        console2.log("TrancheNameFix implementation:", impl, alreadyDeployed ? "(already deployed)" : "(deployed)");

        if (block.chainid == BASE_CHAIN_ID) {
            _simulateFixRoundTrip(SNUSN_ST_PROXY, impl, "Royco Senior Tranche sNUSD-SIM", "ROY-ST-sNUSD-SIM");
            _simulateFixRoundTrip(SNUSN_JT_PROXY, impl, "Royco Junior Tranche sNUSD-SIM", "ROY-JT-sNUSD-SIM");
        }
    }

    /// @dev Fork-only simulation: swaps the impl slot in, applies the fix, restores the original
    ///      impl through the open `upgradeToAndCall`, and asserts nothing else moved. All state is
    ///      reverted afterwards; nothing here is broadcast.
    function _simulateFixRoundTrip(address _proxy, address _fixImpl, string memory _newName, string memory _newSymbol) internal {
        uint256 snapshotId = vm.snapshotState();

        ERC20Upgradeable tranche = ERC20Upgradeable(_proxy);
        address originalImpl = _readImpl(_proxy);
        uint256 totalSupplyBefore = tranche.totalSupply();

        // Stand in for the AccessManager-gated upgrade to the fix impl + setName setup call
        vm.store(_proxy, ERC1967_IMPL_SLOT, bytes32(uint256(uint160(_fixImpl))));
        TrancheNameFix(_proxy).setName(_newName);
        TrancheNameFix(_proxy).setSymbol(_newSymbol);

        // Restore the original implementation through the (open) UUPS upgrade path
        UUPSUpgradeable(_proxy).upgradeToAndCall(originalImpl, "");

        require(keccak256(bytes(tranche.name())) == keccak256(bytes(_newName)), SimulationNameMismatch(_proxy));
        require(keccak256(bytes(tranche.symbol())) == keccak256(bytes(_newSymbol)), SimulationSymbolMismatch(_proxy));
        (, string memory domainName,,,,,) = IERC5267(_proxy).eip712Domain();
        require(keccak256(bytes(domainName)) == keccak256(bytes(_newName)), SimulationDomainNameMismatch(_proxy));
        require(_readImpl(_proxy) == originalImpl, SimulationImplNotRestored(_proxy));
        require(tranche.totalSupply() == totalSupplyBefore, SimulationTotalSupplyChanged(_proxy));

        console2.log("  [OK] Simulated fix + restore round-trip on", _proxy);

        vm.revertToState(snapshotId);
    }

    function _readImpl(address _proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(_proxy, ERC1967_IMPL_SLOT))));
    }
}
