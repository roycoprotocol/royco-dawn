// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoAccountant } from "../../../src/interfaces/IRoycoAccountant.sol";
import { ParameterUpdateBase } from "../base/ParameterUpdateBase.sol";

/**
 * @title SetCoverage
 * @notice Generates Safe transaction batches for updating coverage across multiple markets and chains
 * @dev Usage:
 *      1. Add/update config entries in `_initializeConfigs()` for target markets
 *      2. Run: forge script script/update/accountant/SetCoverage.s.sol
 *      3. Import the generated JSON files from output/update/accountant/ into Safe Transaction Builder
 *
 *      The script automatically forks each chain, simulates all updates for that chain,
 *      and generates one batched JSON per chain per phase (schedule, execute, cancel).
 */
contract SetCoverage is ParameterUpdateBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    struct SetCoverageConfig {
        uint256 chainId;
        string marketName;
        uint64 newCoverageWAD;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    SetCoverageConfig[] internal _configs;

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
     * @notice Configure coverage updates here
     * @dev Add entries for each market that needs a coverage update.
     *      Markets can span multiple chains — the script handles grouping and forking.
     *      Coverage values use WAD precision (1e18 = 100%).
     *      Valid range: 0.05e18 (5%) to 1e18 (100%).
     */
    function _initializeConfigs() internal {
        // sUSDai → 7%
        _configs.push(SetCoverageConfig({ chainId: ARBITRUM, marketName: SUSDAI, newCoverageWAD: 0.07e18 }));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ENTRY POINT
    // ═══════════════════════════════════════════════════════════════════════════

    function run() external {
        require(_configs.length > 0, "No configs defined");

        // Collect unique chain IDs
        uint256[] memory chainIds = _getUniqueChainIds();

        // Process each chain
        for (uint256 c = 0; c < chainIds.length; c++) {
            uint256 chainId = chainIds[c];

            // Collect configs for this chain
            uint256 count = 0;
            for (uint256 i = 0; i < _configs.length; i++) {
                if (_configs[i].chainId == chainId) count++;
            }

            // Build UpdateParams for this chain (requires fork to resolve addresses)
            string memory rpcUrl = _getRpcUrl(chainId);
            vm.createSelectFork(rpcUrl);

            UpdateParams[] memory updates = new UpdateParams[](count);
            uint256 idx = 0;
            for (uint256 i = 0; i < _configs.length; i++) {
                if (_configs[i].chainId == chainId) {
                    SetCoverageConfig storage cfg = _configs[i];
                    MarketAddresses memory addrs = getMarketAddresses(cfg.marketName);
                    updates[idx] = UpdateParams({
                        marketName: cfg.marketName,
                        target: addrs.accountant,
                        callData: abi.encodeCall(IRoycoAccountant.setCoverage, (cfg.newCoverageWAD)),
                        description: string.concat("Set coverage for ", cfg.marketName, " to ", vm.toString(cfg.newCoverageWAD))
                    });
                    idx++;
                }
            }

            _processChain(chainId, updates, "accountant", "set_coverage", "Set coverage");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _verify(UpdateParams memory _params) internal view override {
        IRoycoAccountant.RoycoAccountantState memory state = IRoycoAccountant(_params.target).getState();

        // Extract expected coverage from the calldata (skip 4-byte selector)
        uint64 expected;
        bytes memory cd = _params.callData;
        assembly {
            expected := mload(add(cd, 36))
        }

        require(state.coverageWAD == expected, VerificationFailed("Coverage mismatch after execution"));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _getUniqueChainIds() internal view returns (uint256[] memory) {
        // First pass: count unique chain IDs
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

        // Trim to size
        uint256[] memory result = new uint256[](uniqueCount);
        for (uint256 i = 0; i < uniqueCount; i++) {
            result[i] = temp[i];
        }
        return result;
    }
}
