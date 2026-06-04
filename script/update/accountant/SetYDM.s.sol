// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoAccountant } from "../../../src/interfaces/IRoycoAccountant.sol";
import { AdaptiveCurveYDM_V2 } from "../../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { ParameterUpdateBase } from "../base/ParameterUpdateBase.sol";

/**
 * @title SetYDM
 * @notice Generates Safe transaction batches for re-initializing the AdaptiveCurve_V2 YDM
 *         across multiple markets and chains
 * @dev Usage:
 *      1. Add/update config entries in `_initializeConfigs()` for target markets
 *      2. Run: forge script script/update/accountant/SetYDM.s.sol
 *      3. Import the generated JSON files from output/update/accountant/ into Safe Transaction Builder
 */
contract SetYDM is ParameterUpdateBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev AdaptiveCurveYDM_V2 singleton address (CREATE2, same on every chain we target)
    address internal constant ADAPTIVE_CURVE_YDM_V2 = 0x00b01af1736C7d7646bd97fb6f0Dc96Bf57d0810;

    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    struct SetYDMConfig {
        uint256 chainId;
        string marketName;
        address ydm;
        uint64 jtYieldShareAtZeroUtilWAD;
        uint64 jtYieldShareAtTargetUtilWAD;
        uint64 jtYieldShareAtFullUtilWAD;
        uint64 maxAdaptationSpeedWAD;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    SetYDMConfig[] internal _configs;

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
     * @notice Configure YDM re-initialization here
     * @dev Values mirror the AdaptiveCurveYDM_V2 params from script/config/MarketDeploymentConfig.sol,
     *      with `maxAdaptationSpeedWAD` forced to 0.
     */
    function _initializeConfigs() internal {
        // ── Mainnet ──────────────────────────────────────────────────────────
        // syrupUSDC : Y_0=7%, Y_target=7%, Y_100=11%, adaptation speed = 40 days
        _configs.push(
            SetYDMConfig({
                chainId: MAINNET,
                marketName: SYRUP_USDC,
                ydm: ADAPTIVE_CURVE_YDM_V2,
                jtYieldShareAtZeroUtilWAD: 0.07e18,
                jtYieldShareAtTargetUtilWAD: 0.07e18,
                jtYieldShareAtFullUtilWAD: 0.11e18,
                maxAdaptationSpeedWAD: uint64(40e18 / uint256(365 days))
            })
        );
        // stcUSD    : Y_0=6%, Y_target=6%, Y_100=18%, adaptation speed = 40 days
        _configs.push(
            SetYDMConfig({
                chainId: MAINNET,
                marketName: STCUSD,
                ydm: ADAPTIVE_CURVE_YDM_V2,
                jtYieldShareAtZeroUtilWAD: 0.06e18,
                jtYieldShareAtTargetUtilWAD: 0.06e18,
                jtYieldShareAtFullUtilWAD: 0.18e18,
                maxAdaptationSpeedWAD: uint64(40e18 / uint256(365 days))
            })
        );

        // ── Arbitrum ─────────────────────────────────────────────────────────
        // sUSDai    : Y_0=11%, Y_target=11%, Y_100=31%, adaptation speed = 40 days
        _configs.push(
            SetYDMConfig({
                chainId: ARBITRUM,
                marketName: SUSDAI,
                ydm: ADAPTIVE_CURVE_YDM_V2,
                jtYieldShareAtZeroUtilWAD: 0.11e18,
                jtYieldShareAtTargetUtilWAD: 0.11e18,
                jtYieldShareAtFullUtilWAD: 0.31e18,
                maxAdaptationSpeedWAD: uint64(40e18 / uint256(365 days))
            })
        );
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
                    SetYDMConfig storage cfg = _configs[i];
                    MarketAddresses memory addrs = getMarketAddresses(cfg.marketName);

                    bytes memory ydmInitData = abi.encodeCall(
                        AdaptiveCurveYDM_V2.initializeYDMForMarket,
                        (cfg.jtYieldShareAtZeroUtilWAD, cfg.jtYieldShareAtTargetUtilWAD, cfg.jtYieldShareAtFullUtilWAD, cfg.maxAdaptationSpeedWAD)
                    );

                    updates[idx] = UpdateParams({
                        marketName: cfg.marketName,
                        target: addrs.accountant,
                        callData: abi.encodeCall(IRoycoAccountant.setYDM, (cfg.ydm, ydmInitData)),
                        description: string.concat("Set YDM for ", cfg.marketName, " (maxAdaptationSpeedWAD=", vm.toString(cfg.maxAdaptationSpeedWAD), ")")
                    });
                    idx++;
                }
            }

            _processChain(chainId, updates, "accountant", "set_ydm", "Set YDM");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Verifies the accountant points at the expected YDM and the curve was
     *         re-initialized with the expected params on that YDM.
     */
    function _verify(UpdateParams memory _params) internal view override {
        // Decode `setYDM(address ydm, bytes initData)` from the outer calldata
        (address expectedYDM, bytes memory initData) = _decodeSetYDMCallData(_params.callData);

        // Decode `initializeYDMForMarket(uint64,uint64,uint64,uint64)` from initData
        (uint64 expectedZeroUtilWAD, uint64 expectedTargetUtilWAD, uint64 expectedFullUtilWAD, uint64 expectedMaxAdaptationSpeedWAD) =
            _decodeInitializeYDMForMarketCallData(initData);

        // Accountant must now point at the expected YDM
        IRoycoAccountant.RoycoAccountantState memory state = IRoycoAccountant(_params.target).getState();
        require(state.ydm == expectedYDM, VerificationFailed("YDM address mismatch after execution"));

        // The YDM must have stored the new curve params for this accountant.
        // Mirror the derivation from initializeYDMForMarket.
        uint64 expectedDiscount = expectedTargetUtilWAD - expectedZeroUtilWAD;
        uint64 expectedPremium = expectedFullUtilWAD - expectedTargetUtilWAD;

        (
            uint64 jtYieldShareAtTargetWAD,
            uint32 lastAdaptationTimestamp,
            uint64 maxAdaptationSpeedWAD,
            uint64 discountToTargetAtZeroUtilWAD,
            uint64 premiumToTargetAtFullUtilWAD
        ) = AdaptiveCurveYDM_V2(expectedYDM).accountantToCurve(_params.target);

        require(jtYieldShareAtTargetWAD == expectedTargetUtilWAD, VerificationFailed("jtYieldShareAtTargetWAD mismatch"));
        require(maxAdaptationSpeedWAD == expectedMaxAdaptationSpeedWAD, VerificationFailed("maxAdaptationSpeedWAD mismatch"));
        require(discountToTargetAtZeroUtilWAD == expectedDiscount, VerificationFailed("discountToTargetAtZeroUtilWAD mismatch"));
        require(premiumToTargetAtFullUtilWAD == expectedPremium, VerificationFailed("premiumToTargetAtFullUtilWAD mismatch"));
        // initializeYDMForMarket resets the last-adaptation timestamp to zero
        require(lastAdaptationTimestamp == 0, VerificationFailed("lastAdaptationTimestamp not reset"));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Strips the 4-byte selector and abi.decodes the `(address, bytes)` params of `setYDM`.
    function _decodeSetYDMCallData(bytes memory _cd) internal pure returns (address ydm, bytes memory initData) {
        bytes memory args = new bytes(_cd.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = _cd[i + 4];
        }
        (ydm, initData) = abi.decode(args, (address, bytes));
    }

    /// @dev Strips the 4-byte selector and abi.decodes the 4 uint64 params of `initializeYDMForMarket`.
    function _decodeInitializeYDMForMarketCallData(bytes memory _cd)
        internal
        pure
        returns (uint64 zeroUtilWAD, uint64 targetUtilWAD, uint64 fullUtilWAD, uint64 maxAdaptationSpeedWAD)
    {
        bytes memory args = new bytes(_cd.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = _cd[i + 4];
        }
        (zeroUtilWAD, targetUtilWAD, fullUtilWAD, maxAdaptationSpeedWAD) = abi.decode(args, (uint64, uint64, uint64, uint64));
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
