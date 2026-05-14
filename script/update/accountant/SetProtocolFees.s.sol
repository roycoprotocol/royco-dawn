// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoAccountant } from "../../../src/interfaces/IRoycoAccountant.sol";
import { ParameterUpdateBase } from "../base/ParameterUpdateBase.sol";

/**
 * @title SetProtocolFees
 * @notice Generates Safe transaction batches for updating any combination of the three protocol
 *         fees on a market's accountant — `stProtocolFeeWAD`, `jtProtocolFeeWAD`,
 *         `yieldShareProtocolFeeWAD` — across multiple markets and chains.
 *
 * @dev Each config carries one value per fee. Use `SKIP` (`type(uint64).max`) to leave a fee
 *      unchanged; only fields with concrete values produce transactions in the Safe batch.
 *
 *      Usage:
 *      1. Add/update config entries in `_initializeConfigs()` for target markets
 *      2. Run: forge script script/update/accountant/SetProtocolFees.s.sol
 *      3. Import the generated JSON files from output/update/accountant/ into Safe Transaction Builder
 *
 *      Fee values use WAD precision (1e18 = 100%).
 */
contract SetProtocolFees is ParameterUpdateBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Sentinel meaning "leave this fee unchanged". Picked so a real WAD value (≤ 1e18)
    ///      can never collide with it.
    uint64 internal constant SKIP = type(uint64).max;

    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    struct SetProtocolFeesConfig {
        uint256 chainId;
        string marketName;
        uint64 stProtocolFeeWAD;
        uint64 jtProtocolFeeWAD;
        uint64 yieldShareProtocolFeeWAD;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    SetProtocolFeesConfig[] internal _configs;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor() {
        _initializeConfigs();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIG
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Configure protocol fee updates here.
     * @dev Set each field to a WAD value or to `SKIP` to leave it unchanged.
     *
     *      Example:
     *      ```
     *      _configs.push(SetProtocolFeesConfig({
     *          chainId: MAINNET,
     *          marketName: APYUSD,
     *          stProtocolFeeWAD: 0.1e18,
     *          jtProtocolFeeWAD: SKIP,
     *          yieldShareProtocolFeeWAD: 0.45e18
     *      }));
     *      ```
     */
    function _initializeConfigs() internal {
        _configs.push(
            SetProtocolFeesConfig({ chainId: MAINNET, marketName: APYUSD, stProtocolFeeWAD: 0.1e18, jtProtocolFeeWAD: 0, yieldShareProtocolFeeWAD: 0.1e18 })
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ENTRY POINT
    // ═══════════════════════════════════════════════════════════════════════════

    function run() external {
        require(_configs.length > 0, "No configs defined");

        uint256[] memory chainIds = _getUniqueChainIds();

        for (uint256 c = 0; c < chainIds.length; c++) {
            uint256 chainId = chainIds[c];

            string memory rpcUrl = _getRpcUrl(chainId);
            vm.createSelectFork(rpcUrl);

            UpdateParams[] memory updates = _buildUpdatesForChain(chainId);
            require(updates.length > 0, "No fee updates for chain after applying SKIP");

            _processChain(chainId, updates, "accountant", "set_protocol_fees", "Set protocol fees");
        }
    }

    /// @dev Walks the configs for `_chainId` and emits one `UpdateParams` per non-skipped fee.
    function _buildUpdatesForChain(uint256 _chainId) internal view returns (UpdateParams[] memory updates) {
        // First pass — count concrete fee updates so we can size the array.
        uint256 count = 0;
        for (uint256 i = 0; i < _configs.length; i++) {
            if (_configs[i].chainId != _chainId) continue;
            if (_configs[i].stProtocolFeeWAD != SKIP) count++;
            if (_configs[i].jtProtocolFeeWAD != SKIP) count++;
            if (_configs[i].yieldShareProtocolFeeWAD != SKIP) count++;
        }

        updates = new UpdateParams[](count);
        uint256 idx = 0;

        for (uint256 i = 0; i < _configs.length; i++) {
            if (_configs[i].chainId != _chainId) continue;
            SetProtocolFeesConfig storage cfg = _configs[i];
            MarketAddresses memory addrs = getMarketAddresses(cfg.marketName);

            if (cfg.stProtocolFeeWAD != SKIP) {
                updates[idx++] = UpdateParams({
                    marketName: cfg.marketName,
                    target: addrs.accountant,
                    callData: abi.encodeCall(IRoycoAccountant.setSeniorTrancheProtocolFee, (cfg.stProtocolFeeWAD)),
                    description: string.concat("Set ST protocol fee for ", cfg.marketName, " to ", vm.toString(cfg.stProtocolFeeWAD))
                });
            }
            if (cfg.jtProtocolFeeWAD != SKIP) {
                updates[idx++] = UpdateParams({
                    marketName: cfg.marketName,
                    target: addrs.accountant,
                    callData: abi.encodeCall(IRoycoAccountant.setJuniorTrancheProtocolFee, (cfg.jtProtocolFeeWAD)),
                    description: string.concat("Set JT protocol fee for ", cfg.marketName, " to ", vm.toString(cfg.jtProtocolFeeWAD))
                });
            }
            if (cfg.yieldShareProtocolFeeWAD != SKIP) {
                updates[idx++] = UpdateParams({
                    marketName: cfg.marketName,
                    target: addrs.accountant,
                    callData: abi.encodeCall(IRoycoAccountant.setYieldShareProtocolFee, (cfg.yieldShareProtocolFeeWAD)),
                    description: string.concat("Set yield-share protocol fee for ", cfg.marketName, " to ", vm.toString(cfg.yieldShareProtocolFeeWAD))
                });
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _verify(UpdateParams memory _params) internal view override {
        IRoycoAccountant.RoycoAccountantState memory state = IRoycoAccountant(_params.target).getState();

        bytes4 selector = bytes4(_params.callData);
        uint64 expected;
        bytes memory cd = _params.callData;
        assembly {
            expected := mload(add(cd, 36))
        }

        if (selector == IRoycoAccountant.setSeniorTrancheProtocolFee.selector) {
            require(state.stProtocolFeeWAD == expected, VerificationFailed("stProtocolFeeWAD mismatch after execution"));
        } else if (selector == IRoycoAccountant.setJuniorTrancheProtocolFee.selector) {
            require(state.jtProtocolFeeWAD == expected, VerificationFailed("jtProtocolFeeWAD mismatch after execution"));
        } else if (selector == IRoycoAccountant.setYieldShareProtocolFee.selector) {
            require(state.yieldShareProtocolFeeWAD == expected, VerificationFailed("yieldShareProtocolFeeWAD mismatch after execution"));
        } else {
            revert VerificationFailed("Unexpected selector in calldata");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _getUniqueChainIds() internal view returns (uint256[] memory) {
        uint256[] memory temp = new uint256[](_configs.length);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < _configs.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (temp[j] == _configs[i].chainId) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                temp[uniqueCount] = _configs[i].chainId;
                uniqueCount++;
            }
        }

        uint256[] memory result = new uint256[](uniqueCount);
        for (uint256 i = 0; i < uniqueCount; i++) {
            result[i] = temp[i];
        }
        return result;
    }
}
