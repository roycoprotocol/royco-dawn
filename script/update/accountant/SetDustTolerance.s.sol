// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoAccountant } from "../../../src/interfaces/IRoycoAccountant.sol";
import { NAV_UNIT, toNAVUnits } from "../../../src/libraries/Units.sol";
import { ParameterUpdateBase } from "../base/ParameterUpdateBase.sol";

/**
 * @title SetDustTolerance
 * @notice Generates Safe transaction batches for updating ST and JT NAV dust tolerances across markets and chains
 * @dev Each config entry produces up to TWO transactions inside the chain's batch:
 *      one `setSeniorTrancheDustTolerance(...)` and one `setJuniorTrancheDustTolerance(...)`.
 *      Both ST and JT updates are emitted unconditionally — pass equal values if you only want
 *      to "refresh" one side, or split into separate config entries for finer control.
 *
 *      Usage:
 *      1. Add/update config entries in `_initializeConfigs()` for target markets
 *      2. Run: forge script script/update/accountant/SetDustTolerance.s.sol
 *      3. Import the generated JSON files from output/update/accountant/ into Safe Transaction Builder
 *
 *      The script forks each chain, simulates each individual setter call in isolation,
 *      and writes one batched JSON per chain per phase (schedule, execute, cancel).
 */
contract SetDustTolerance is ParameterUpdateBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    struct SetDustToleranceConfig {
        uint256 chainId;
        string marketName;
        /// @dev New ST dust tolerance, denominated in NAV units (i.e. WAD-precision USD)
        uint256 newSTDustTolerance;
        /// @dev New JT dust tolerance, denominated in NAV units (i.e. WAD-precision USD)
        uint256 newJTDustTolerance;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    SetDustToleranceConfig[] internal _configs;

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
     * @notice Configure dust-tolerance updates here
     * @dev NAV units are 18-decimal USD. For a USDC-backed market (6-decimal asset),
     *      "5 USDC of dust" is `5 * 10 ** (18 - 6) = 5e12`. For an 18-decimal asset
     *      that represents ~$1, use the raw integer (e.g. `5` for 5 wei of dust).
     */
    function _initializeConfigs() internal {
        // stcUSD on Ethereum — set ST/JT dust to 5 (raw NAV units; cUSD is 18-decimal)
        _configs.push(SetDustToleranceConfig({ chainId: MAINNET, marketName: STCUSD, newSTDustTolerance: 1e16, newJTDustTolerance: 1e16 }));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ENTRY POINT
    // ═══════════════════════════════════════════════════════════════════════════

    function run() external {
        require(_configs.length > 0, "No configs defined");

        uint256[] memory chainIds = _getUniqueChainIds();

        for (uint256 c = 0; c < chainIds.length; c++) {
            uint256 chainId = chainIds[c];

            // Two updates per config entry on this chain (one ST, one JT)
            uint256 count = 0;
            for (uint256 i = 0; i < _configs.length; i++) {
                if (_configs[i].chainId == chainId) count += 2;
            }

            // Fork the chain to resolve addresses from the kernel
            string memory rpcUrl = _getRpcUrl(chainId);
            vm.createSelectFork(rpcUrl);

            UpdateParams[] memory updates = new UpdateParams[](count);
            uint256 idx = 0;
            for (uint256 i = 0; i < _configs.length; i++) {
                if (_configs[i].chainId != chainId) continue;
                SetDustToleranceConfig storage cfg = _configs[i];
                MarketAddresses memory addrs = getMarketAddresses(cfg.marketName);

                NAV_UNIT stTol = toNAVUnits(cfg.newSTDustTolerance);
                NAV_UNIT jtTol = toNAVUnits(cfg.newJTDustTolerance);

                updates[idx++] = UpdateParams({
                    marketName: cfg.marketName,
                    target: addrs.accountant,
                    callData: abi.encodeCall(IRoycoAccountant.setSeniorTrancheDustTolerance, (stTol)),
                    description: string.concat("Set ST dust tolerance for ", cfg.marketName, " to ", vm.toString(cfg.newSTDustTolerance))
                });
                updates[idx++] = UpdateParams({
                    marketName: cfg.marketName,
                    target: addrs.accountant,
                    callData: abi.encodeCall(IRoycoAccountant.setJuniorTrancheDustTolerance, (jtTol)),
                    description: string.concat("Set JT dust tolerance for ", cfg.marketName, " to ", vm.toString(cfg.newJTDustTolerance))
                });
            }

            _processChain(chainId, updates, "accountant", "set_dust_tolerance", "Set ST/JT dust tolerance");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _verify(UpdateParams memory _params) internal view override {
        IRoycoAccountant.RoycoAccountantState memory state = IRoycoAccountant(_params.target).getState();

        // Decode the expected NAV_UNIT from the calldata (skip 4-byte selector)
        uint256 expected;
        bytes memory cd = _params.callData;
        assembly {
            expected := mload(add(cd, 36))
        }

        // Dispatch on selector to assert against the right field
        bytes4 selector = bytes4(cd);
        if (selector == IRoycoAccountant.setSeniorTrancheDustTolerance.selector) {
            require(NAV_UNIT.unwrap(state.stNAVDustTolerance) == expected, VerificationFailed("ST dust tolerance mismatch"));
        } else if (selector == IRoycoAccountant.setJuniorTrancheDustTolerance.selector) {
            require(NAV_UNIT.unwrap(state.jtNAVDustTolerance) == expected, VerificationFailed("JT dust tolerance mismatch"));
        } else {
            revert VerificationFailed("Unknown selector in dust tolerance update");
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
