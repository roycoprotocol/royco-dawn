// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoAccountant } from "../../../src/interfaces/IRoycoAccountant.sol";
import { ParameterUpdateBase } from "../base/ParameterUpdateBase.sol";

/**
 * @title SetLiquidationUtilization
 * @notice Generates Safe transaction batches for updating `liquidationUtilizationWAD` on each
 *         market's accountant across multiple markets and chains.
 *
 * @dev `setLiquidationUtilization` is `restricted` to `ADMIN_ACCOUNTANT_ROLE` (timelocked). The
 *      harness emits one batched Safe JSON per chain per phase (schedule, execute, cancel).
 *
 *      Usage:
 *      1. Add/update config entries in `_initializeConfigs()` for target markets
 *      2. Run: forge script script/update/accountant/SetLiquidationUtilization.s.sol
 *      3. Import the generated JSON files from output/update/accountant/ into Safe Transaction Builder
 *
 *      Values are WAD precision: 1e18 = 100% utilization. The setter accepts values strictly above
 *      WAD (i.e. above 100% utilization) per the accountant's coverage-config validation.
 */
contract SetLiquidationUtilization is ParameterUpdateBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    struct SetLiquidationUtilizationConfig {
        uint256 chainId;
        string marketName;
        uint256 newLiquidationUtilizationWAD;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    SetLiquidationUtilizationConfig[] internal _configs;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor() {
        _initializeConfigs();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIG
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Configure liquidation-utilization updates here.
    /// @dev Values are WAD-scaled fractional percentages (1e18 = 100%).
    function _initializeConfigs() internal {
        // ── Mainnet ──────────────────────────────────────────────────────────
        // sNUSD                : 100.14306%
        _configs.push(SetLiquidationUtilizationConfig({ chainId: MAINNET, marketName: SNUSD, newLiquidationUtilizationWAD: 1.0014306e18 }));
        // autoUSD              : 125.00000%
        _configs.push(SetLiquidationUtilizationConfig({ chainId: MAINNET, marketName: AUTOUSD, newLiquidationUtilizationWAD: 1.25e18 }));
        // syrupUSDC            : 133.33333%
        _configs.push(SetLiquidationUtilizationConfig({ chainId: MAINNET, marketName: SYRUP_USDC, newLiquidationUtilizationWAD: 1.3333333e18 }));
        // stcUSD               : 100.33445%
        _configs.push(SetLiquidationUtilizationConfig({ chainId: MAINNET, marketName: STCUSD, newLiquidationUtilizationWAD: 1.0033445e18 }));
        // ParetoFalconX        : 300.00000%
        _configs.push(SetLiquidationUtilizationConfig({ chainId: MAINNET, marketName: PARETO_FALCONX, newLiquidationUtilizationWAD: 3.0e18 }));
        // apyUSD               : 200.00000%
        _configs.push(SetLiquidationUtilizationConfig({ chainId: MAINNET, marketName: APYUSD, newLiquidationUtilizationWAD: 2.0e18 }));
        // eEARN                : 101.01010%
        _configs.push(SetLiquidationUtilizationConfig({ chainId: MAINNET, marketName: eEARN, newLiquidationUtilizationWAD: 1.010101e18 }));

        // ── Avalanche ────────────────────────────────────────────────────────
        // savUSD               : 100.05003%
        // _configs.push(SetLiquidationUtilizationConfig({ chainId: AVALANCHE, marketName: SAVUSD, newLiquidationUtilizationWAD: 1.0005003e18 }));

        // ── Arbitrum ─────────────────────────────────────────────────────────
        // sUSDai               : 116.66667%
        _configs.push(SetLiquidationUtilizationConfig({ chainId: ARBITRUM, marketName: SUSDAI, newLiquidationUtilizationWAD: 1.1666667e18 }));
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
                if (_configs[i].chainId != chainId) continue;
                SetLiquidationUtilizationConfig storage cfg = _configs[i];
                MarketAddresses memory addrs = getMarketAddresses(cfg.marketName);
                updates[idx] = UpdateParams({
                    marketName: cfg.marketName,
                    target: addrs.accountant,
                    callData: abi.encodeCall(IRoycoAccountant.setLiquidationUtilization, (cfg.newLiquidationUtilizationWAD)),
                    description: string.concat("Set liquidationUtilizationWAD for ", cfg.marketName, " to ", vm.toString(cfg.newLiquidationUtilizationWAD))
                });
                idx++;
            }

            _processChain(chainId, updates, "accountant", "set_liquidation_utilization", "Set liquidation utilization");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _verify(UpdateParams memory _params) internal pure override {
        IRoycoAccountant.RoycoAccountantState memory state = IRoycoAccountant(_params.target).getState();

        // Extract expected value from the calldata (skip 4-byte selector; uint256 is at offset 4)
        uint256 expected;
        bytes memory cd = _params.callData;
        assembly {
            expected := mload(add(cd, 36))
        }

        require(state.liquidationUtilizationWAD == expected, VerificationFailed("liquidationUtilizationWAD mismatch after execution"));
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
