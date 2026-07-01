// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IdenticalAssetsChainlinkOracleQuoter } from "../../../src/kernels/base/quoter/base/IdenticalAssetsChainlinkOracleQuoter.sol";
import { ParameterUpdateBase } from "../base/ParameterUpdateBase.sol";

/**
 * @title SetSequencerUptimeFeed
 * @notice Generates a Safe transaction batch for updating a kernel's L2 sequencer uptime feed
 *         address + grace period across multiple markets and chains.
 *
 * @dev `setSequencerUptimeFeed` on the kernel is gated by `ADMIN_ORACLE_QUOTER_ROLE`, which has an
 *      execution delay of 0 (Immediate per `RolesConfiguration`). So this uses the harness's
 *      direct-call flow (`_processChainDirect`) — one Safe JSON per chain, no schedule/execute
 *      split. `ROOT_MULTISIG` holds the role on production factories.
 *
 *      A null sequencer uptime feed disables the L2 sequencer check (for markets not deployed on an L2).
 *      When a feed is set, the grace period must be a positive duration.
 *
 *      Usage:
 *      1. Add/update config entries in `_initializeConfigs()`.
 *      2. Run: forge script script/update/kernel/SetSequencerUptimeFeed.s.sol
 *      3. Import the JSON from output/update/kernel/{chainId}_set_sequencer_uptime_feed.json
 *         into the ROOT Safe (same multisig that holds ADMIN_ORACLE_QUOTER_ROLE).
 */
contract SetSequencerUptimeFeed is ParameterUpdateBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    string internal constant OUTPUT_SUBDIR = "kernel";
    string internal constant OUTPUT_PREFIX = "set_sequencer_uptime_feed";
    string internal constant BATCH_DESCRIPTION = "Royco Kernel: update L2 sequencer uptime feed + grace period";

    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    struct SetSequencerUptimeFeedConfig {
        uint256 chainId;
        string marketName;
        address newSequencerUptimeFeed;
        uint48 newGracePeriodSeconds;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    SetSequencerUptimeFeedConfig[] internal _configs;

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
     * @notice Configure L2 sequencer uptime feed updates here.
     * @dev Example:
     *      ```
     *      _configs.push(SetSequencerUptimeFeedConfig({
     *          chainId: BASE,
     *          marketName: YO_USD,
     *          newSequencerUptimeFeed: getSequencerUptimeFeed(BASE),
     *          newGracePeriodSeconds: 1 hours
     *      }));
     *      ```
     */
    function _initializeConfigs() internal { }

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
                SetSequencerUptimeFeedConfig storage cfg = _configs[i];
                MarketAddresses memory addrs = getMarketAddresses(cfg.marketName);

                updates[idx] = UpdateParams({
                    marketName: cfg.marketName,
                    target: addrs.kernel,
                    callData: abi.encodeCall(
                        IdenticalAssetsChainlinkOracleQuoter.setSequencerUptimeFeed, (cfg.newSequencerUptimeFeed, cfg.newGracePeriodSeconds)
                    ),
                    description: string.concat(
                        "Set L2 sequencer uptime feed for ",
                        cfg.marketName,
                        " to ",
                        vm.toString(cfg.newSequencerUptimeFeed),
                        " (gracePeriod=",
                        vm.toString(uint256(cfg.newGracePeriodSeconds)),
                        "s)"
                    )
                });
                idx++;
            }

            _processChainDirect(chainId, ROOT_MULTISIG, updates, OUTPUT_SUBDIR, OUTPUT_PREFIX, BATCH_DESCRIPTION);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Decodes the calldata and asserts the kernel now returns the expected sequencer uptime feed + grace period.
    function _verify(UpdateParams memory _params) internal pure override {
        (address expectedFeed, uint48 expectedGracePeriod) = _decodeCallData(_params.callData);

        IdenticalAssetsChainlinkOracleQuoter.IdenticalAssetsChainlinkOracleQuoterState memory state =
            IdenticalAssetsChainlinkOracleQuoter(_params.target).getChainlinkOracleConfiguration();

        require(state.sequencerUptimeFeed == expectedFeed, VerificationFailed("Sequencer uptime feed address mismatch after execution"));
        require(state.gracePeriodSeconds == expectedGracePeriod, VerificationFailed("Grace period mismatch after execution"));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Strips the 4-byte selector and abi.decodes `(address, uint48)` from the call.
    function _decodeCallData(bytes memory _cd) internal pure returns (address sequencerUptimeFeed, uint48 gracePeriodSeconds) {
        bytes memory args = new bytes(_cd.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = _cd[i + 4];
        }
        (sequencerUptimeFeed, gracePeriodSeconds) = abi.decode(args, (address, uint48));
    }

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
