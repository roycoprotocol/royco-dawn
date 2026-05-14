// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoAccountant } from "../../../src/interfaces/IRoycoAccountant.sol";
import { ParameterUpdateBase } from "../base/ParameterUpdateBase.sol";

/**
 * @title SetFixedTermDuration
 * @notice Generates Safe transaction batches for updating the fixed-term duration on a market's
 *         accountant across multiple markets and chains.
 * @dev Usage:
 *      1. Add/update config entries in `_initializeConfigs()` for target markets
 *      2. Run: forge script script/update/accountant/SetFixedTermDuration.s.sol
 *      3. Import the generated JSON files from output/update/accountant/ into Safe Transaction Builder
 *
 *      Setting `0` puts the market in perpetual mode (no fixed term). Otherwise the value is the
 *      term length in seconds; the next sync after this update commences a new fixed term iff the
 *      market was perpetual or the previous term has already ended.
 */
contract SetFixedTermDuration is ParameterUpdateBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    struct SetFixedTermDurationConfig {
        uint256 chainId;
        string marketName;
        uint24 newFixedTermDurationSeconds;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    SetFixedTermDurationConfig[] internal _configs;

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
     * @notice Configure fixed-term-duration updates here.
     * @dev `newFixedTermDurationSeconds` is a `uint24` (max ~194 days). Use `0` for perpetual.
     */
    function _initializeConfigs() internal {
        // autoUSD → 5 days
        _configs.push(SetFixedTermDurationConfig({ chainId: MAINNET, marketName: AUTOUSD, newFixedTermDurationSeconds: uint24(5 days) }));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ENTRY POINT
    // ═══════════════════════════════════════════════════════════════════════════

    function run() external {
        require(_configs.length > 0, "No configs defined");

        uint256[] memory chainIds = _getUniqueChainIds();

        for (uint256 c = 0; c < chainIds.length; c++) {
            uint256 chainId = chainIds[c];

            uint256 count = 0;
            for (uint256 i = 0; i < _configs.length; i++) {
                if (_configs[i].chainId == chainId) count++;
            }

            string memory rpcUrl = _getRpcUrl(chainId);
            vm.createSelectFork(rpcUrl);

            UpdateParams[] memory updates = new UpdateParams[](count);
            uint256 idx = 0;
            for (uint256 i = 0; i < _configs.length; i++) {
                if (_configs[i].chainId == chainId) {
                    SetFixedTermDurationConfig storage cfg = _configs[i];
                    MarketAddresses memory addrs = getMarketAddresses(cfg.marketName);
                    updates[idx] = UpdateParams({
                        marketName: cfg.marketName,
                        target: addrs.accountant,
                        callData: abi.encodeCall(IRoycoAccountant.setFixedTermDuration, (cfg.newFixedTermDurationSeconds)),
                        description: string.concat(
                            "Set fixed term duration for ", cfg.marketName, " to ", vm.toString(uint256(cfg.newFixedTermDurationSeconds)), " seconds"
                        )
                    });
                    idx++;
                }
            }

            _processChain(chainId, updates, "accountant", "set_fixed_term_duration", "Set fixed term duration");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _verify(UpdateParams memory _params) internal view override {
        IRoycoAccountant.RoycoAccountantState memory state = IRoycoAccountant(_params.target).getState();

        // Extract expected duration from the calldata (skip 4-byte selector). uint24 lives in the
        // low-order bytes of the 32-byte word at offset 4, so a full mload + cast pulls it out.
        uint24 expected;
        bytes memory cd = _params.callData;
        assembly {
            expected := mload(add(cd, 36))
        }

        require(state.fixedTermDurationSeconds == expected, VerificationFailed("fixedTermDurationSeconds mismatch after execution"));
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
