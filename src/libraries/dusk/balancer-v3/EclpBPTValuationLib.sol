// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IGyroECLPPool } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/pool-gyro/IGyroECLPPool.sol";
import { IVault } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { Rounding } from "../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { GyroECLPMath } from "../../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/lib/GyroECLPMath.sol";
import { SignedFixedPoint } from "../../../../lib/balancer-v3-monorepo/pkg/pool-gyro/contracts/lib/SignedFixedPoint.sol";
import { FixedPoint } from "../../../../lib/balancer-v3-monorepo/pkg/solidity-utils/contracts/math/FixedPoint.sol";
import { Math } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { SafeCast } from "../../../../lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { WAD } from "../../Constants.sol";
import { NAV_UNIT, UnitsMathLib, toInt256, toNAVUnits, toUint256 } from "../../Units.sol";

/**
 * @title EclpBPTValuationLib
 * @author Waymont, Balancer Labs
 * @notice Conservatively values a Dusk junior tranche's Balancer pool token (BPT) at a candidate senior tranche rate
 * @dev The junior collateral is a Gyro E-CLP position pairing the senior tranche share against a quote asset. Valuing it needs the senior rate, which is itself the unknown the sync resolves: the senior tranche's claim depends on the junior collateral's value, which in turn depends on the senior rate. The sync resolves it by trying candidate senior NAVs and re-valuing the collateral at each, and this library supplies that per-candidate value
 * @dev The pool inputs are read from the Vault once per solve and frozen into a params struct; each candidate is then valued from that struct alone, with no further reads. Reading once makes the valuation a fixed function across the solve and immune to pool manipulation mid-sync. Either token ordering is handled, since the caller supplies the senior share's pool index
 * @dev The raw pool value is Balancer's `EclpLPOracle` valuation, ported verbatim with its `GyroECLPMath` primitives (see the porting note below), so it inherits the oracle's audited arithmetic and rounding. A demand cap and senior-favoring rounding keep the mark conservative, never overstating the junior collateral. NAV quantities are typed as `NAV_UNIT` and unwrapped to integers only at the Balancer call boundary
 */
library EclpBPTValuationLib {
    using FixedPoint for uint256;
    using Math for uint256;
    using SignedFixedPoint for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using UnitsMathLib for NAV_UNIT;

    /// @notice Thrown when a frozen input the valuation divides by is zero, or the senior index is out of range
    error INVALID_VALUATION_INPUT();

    /**
     * @notice The pool inputs read once at the start of a solve and held fixed while the senior tranche rate is resolved
     * @dev The `params`, `derivedParams`, and `invariant` fields keep Balancer's naming, since they are passed verbatim into the ported valuation
     * @param params The E-CLP curve parameters (alpha, beta, c, s, lambda)
     * @param derivedParams The off-chain derived E-CLP parameters (tauAlpha, tauBeta, u, v, w, z, dSq)
     * @param invariant The pool's liquidity invariant, rounded down. The valuation derives the pool composition from this frozen invariant rather than the live balances, so trades during the sync cannot move the mark
     * @param stSharePoolIndex The senior tranche share's index in the pool's token registration order (0 or 1)
     * @param quoteAssetRate The quote asset's NAV value per pool scaled-18 unit, held constant across the solve. Net of the pool's own rate scaling, which the frozen invariant already applies, so the rate is not double counted; yield-bearing quotes carry their own rate
     * @param stShareSupply The senior tranche share total supply (18 decimals)
     * @param stShareRate The senior share rate the pool's live senior balance was scaled by at solve start (its NAV per share). The frozen invariant is denominated in these units, so candidate rates are expressed relative to it
     * @param jtOwnedBPT The BPT amount the junior tranche owns
     * @param bptTotalSupply The pool's total BPT supply; the junior claim is the fraction `jtOwnedBPT / bptTotalSupply` of the pool value
     * @param isSupplyCapped True when the pool's curve would imply holding more senior shares than the supply at some price, so the value is capped at low senior NAVs; false means the value equals the raw pool value everywhere
     * @param maxCappedSTEffectiveNAV The largest candidate senior NAV still in the capped region; at or below it the value is capped, above it it is the raw pool value
     * @param capContinuityOffset The gap between the raw pool value and the capped value at the threshold, subtracted from the raw pool value above the threshold so the capped and raw pieces meet with no jump
     */
    struct FixedEclpBPTValuationParams {
        IGyroECLPPool.EclpParams params;
        IGyroECLPPool.DerivedEclpParams derivedParams;
        uint256 invariant;
        uint256 stSharePoolIndex;
        NAV_UNIT quoteAssetRate;
        uint256 stShareSupply;
        NAV_UNIT stShareRate;
        uint256 jtOwnedBPT;
        uint256 bptTotalSupply;
        bool isSupplyCapped;
        NAV_UNIT maxCappedSTEffectiveNAV;
        NAV_UNIT capContinuityOffset;
    }

    // =============================
    // Valuation Input Retrieval
    // =============================

    /**
     * @notice Reads and freezes every input for one solve from the Balancer Vault and pool
     * @dev Reads the pool parameters, live balances, and invariant, then precomputes the demand cap. After this returns, valuing a candidate touches no storage and makes no external calls
     * @param _vault The Balancer V3 Vault custodying the pool
     * @param _pool The Gyro E-CLP pool backing the junior tranche; its two tokens are the senior tranche share and the quote asset
     * @param _stSharePoolIndex The senior tranche share's index in the pool's token registration order (0 or 1), resolved and validated by the caller at deployment
     * @param _quoteAssetRate The quote asset's NAV value per pool scaled-18 unit (net of the pool's own rate scaling)
     * @param _stShareSupply The senior tranche share total supply
     * @param _stShareRate The senior share rate currently scaling the pool's live senior balance (its NAV per share)
     * @param _jtOwnedBPT The BPT amount the junior tranche owns
     * @return state The frozen valuation params
     */
    function getFixedEclpBPTValuationParams(
        IVault _vault,
        address _pool,
        uint256 _stSharePoolIndex,
        NAV_UNIT _quoteAssetRate,
        uint256 _stShareSupply,
        NAV_UNIT _stShareRate,
        uint256 _jtOwnedBPT
    )
        internal
        view
        returns (FixedEclpBPTValuationParams memory state)
    {
        IGyroECLPPool pool = IGyroECLPPool(_pool);
        state.stSharePoolIndex = _stSharePoolIndex;

        // The total BPT supply backing the junior's pro-rata claim, read from the Vault (its internal accounting is the source of truth, and cheaper than the pool's ERC20 facade, which just forwards to the Vault)
        uint256 bptTotalSupply = _vault.totalSupply(_pool);

        // Fail fast at solve start on the fixed inputs that the valuation depends on
        require(
            _stSharePoolIndex <= 1 && toUint256(_quoteAssetRate) >= uint256(_MIN_PRICE_ECLP) && toUint256(_quoteAssetRate) <= uint256(type(int256).max)
                && _stShareSupply != 0 && toUint256(_stShareRate) != 0 && _jtOwnedBPT <= bptTotalSupply,
            INVALID_VALUATION_INPUT()
        );

        // The E-CLP parameters: a single staticcall returning the pool's immutables
        (state.params, state.derivedParams) = pool.getECLPParams();

        // The frozen invariant, computed exactly as the oracle does: from live rate-scaled balances, rounded DOWN so the mark never overstates the pool (senior-favoring)
        uint256[] memory balancesLiveScaled18 = _vault.getCurrentLiveBalances(_pool);
        state.invariant = pool.computeInvariant(balancesLiveScaled18, Rounding.ROUND_DOWN);

        state.quoteAssetRate = _quoteAssetRate;
        state.stShareSupply = _stShareSupply;
        state.stShareRate = _stShareRate;
        state.jtOwnedBPT = _jtOwnedBPT;
        state.bptTotalSupply = bptTotalSupply;

        // Precompute the demand cap so the valuation never counts senior shares beyond the supply that actually exists
        _precomputeDemandCap(state);
    }

    // =============================
    // Conservative Valuation
    // =============================

    /**
     * @notice The junior tranche's conservative raw NAV at a candidate senior NAV: its pro-rata share of the conservative pool value
     * @dev The value the kernel feeds into the accountant settlement each solve step. The pro-rata share `jtOwnedBPT / bptTotalSupply` is applied in a single floored division, rounding the junior claim down (senior-favoring)
     * @param _state The frozen valuation params
     * @param _ostensibleSTEffectiveNAV The candidate senior tranche effective NAV being tested
     * @return The junior tranche's conservative raw NAV
     */
    function computeOstensibleJTRawNAV(FixedEclpBPTValuationParams memory _state, NAV_UNIT _ostensibleSTEffectiveNAV) internal pure returns (NAV_UNIT) {
        return _computeOstensibleConservativePoolNAV(_state, _ostensibleSTEffectiveNAV).mulDiv(_state.jtOwnedBPT, _state.bptTotalSupply, Math.Rounding.Floor);
    }

    /**
     * @notice The conservative value of the whole pool at a candidate senior NAV
     * @dev The raw pool value from the ported oracle math, with the demand cap applied. Returns a value for every candidate without reverting, so the solve can value any candidate without aborting the surrounding operation
     * @param _state The frozen valuation params
     * @param _ostensibleSTEffectiveNAV The candidate senior tranche effective NAV being tested
     * @return The conservative pool value
     */
    function _computeOstensibleConservativePoolNAV(
        FixedEclpBPTValuationParams memory _state,
        NAV_UNIT _ostensibleSTEffectiveNAV
    )
        private
        pure
        returns (NAV_UNIT)
    {
        // Capped region: the curve implies holding at least the real senior supply, so the position is marked as the full supply at the candidate rate, which equals the candidate senior NAV itself
        if (_state.isSupplyCapped && _ostensibleSTEffectiveNAV <= _state.maxCappedSTEffectiveNAV) {
            return _ostensibleSTEffectiveNAV;
        }

        // The raw (uncapped) pool value from the ported oracle math, evaluated at the candidate senior price
        NAV_UNIT rawPoolNAV = toNAVUnits(
            _computeEclpTvl(
                _state.params,
                _state.derivedParams,
                _state.invariant,
                _computeOrderedPriceVector(_state, _computeSTShareScaledPrice(_state, _ostensibleSTEffectiveNAV))
            )
        );

        // Uncapped region: the implied holding is below the supply, so the value is not capped to that NAV. Lower the raw value by the continuity offset that stitches it onto the capped region; the offset never exceeds the raw value, so the result stays in [0, raw]
        return _state.isSupplyCapped ? rawPoolNAV - _state.capContinuityOffset : rawPoolNAV;
    }

    // =============================
    // Internal Utility Functions
    // =============================

    /**
     * @notice Builds the price array the ported valuation consumes: the senior price at the senior token index, the quote rate at the other
     * @dev The ported valuation rejects prices below `_MIN_PRICE_ECLP` (where it loses precision), so the senior price is floored to that bound. The only candidates affected are senior losses beyond ~99.99999%, which the kernel rejects as outside the pool's expressible range, so the floor never raises a published mark while keeping the valuation total
     * @param _state The frozen valuation params
     * @param _stShareScaledPrice The senior leg's pool-scaled price
     * @return prices The senior price at the senior token index and the quote rate at the other
     */
    function _computeOrderedPriceVector(FixedEclpBPTValuationParams memory _state, uint256 _stShareScaledPrice) private pure returns (int256[] memory prices) {
        prices = new int256[](2);
        prices[_state.stSharePoolIndex] = (_stShareScaledPrice < uint256(_MIN_PRICE_ECLP) ? uint256(_MIN_PRICE_ECLP) : _stShareScaledPrice).toInt256();
        prices[1 - _state.stSharePoolIndex] = toInt256(_state.quoteAssetRate);
    }

    /**
     * @notice The pool-scaled senior price for a senior NAV: its implied per-share rate relative to the frozen rate
     * @dev The pool's senior balance is already scaled by the senior rate, so the frozen invariant is in rate-scaled units. To re-price at a senior NAV, the curve is fed that NAV's per-share rate divided by the frozen rate (1.0 at the frozen rate), which avoids double counting the rate: concretely NAV * WAD^2 / (supply * frozen rate). Computed straight from the NAV at full precision and rounded down (senior-favoring); forming the per-share rate first would quantize it and make the mark jump in coarse steps the solve cannot follow
     * @param _state The frozen valuation params
     * @param _stEffectiveNAV The senior tranche effective NAV to price
     * @return The pool-scaled senior price (WAD)
     */
    function _computeSTShareScaledPrice(FixedEclpBPTValuationParams memory _state, NAV_UNIT _stEffectiveNAV) private pure returns (uint256) {
        return toUint256(_stEffectiveNAV).mulDiv((WAD ** 2), (_state.stShareSupply * toUint256(_state.stShareRate)));
    }

    /**
     * @notice Precomputes the demand cap so the mark never counts senior shares that do not exist
     * @dev At each senior price the curve implies a senior-share holding. At low prices that holding can exceed the supply: the pool could only hold that many if more senior shares existed, and counting holdings beyond the supply would credit the senior tranche coverage the junior cannot deliver, so the counted holding is capped at the supply. The implied holding falls as the senior price rises, so it crosses the supply at a single price, found here by a one-off bisection. At or below the corresponding candidate NAV the value is capped to that NAV; above it the value is the raw pool value minus a fixed offset chosen so the two regions meet with no jump. If the implied holding never reaches the supply anywhere, the value is the raw pool value directly
     * @param _state The frozen valuation params, mutated in place to set the cap fields
     */
    function _precomputeDemandCap(FixedEclpBPTValuationParams memory _state) private pure {
        bool seniorIsToken0 = _state.stSharePoolIndex == 0;

        // Hoist the senior leg's corner reserve coefficient once: the x leg (from tauBeta) for senior token0, the y leg (from tauAlpha) for senior token1
        int256 seniorCorner = seniorIsToken0
            ? _removePrecision(GyroECLPMath.mulAinv(_state.params, _state.derivedParams.tauBeta).x)
            : _removePrecision(GyroECLPMath.mulAinv(_state.params, _state.derivedParams.tauAlpha).y);

        // The cap threshold in the pool's scaled-18 senior units: the senior supply valued at the frozen rate
        uint256 stSupplyScaled = _state.stShareSupply.mulDown(toUint256(_state.stShareRate));

        // Demand peaks at the senior-rich corner: the all-token0 extent for senior token0, the all-token1 extent for senior token1
        int256 peakCoeff = seniorIsToken0
            ? _removePrecision(
                GyroECLPMath.mulAinv(_state.params, _state.derivedParams.tauBeta).x - GyroECLPMath.mulAinv(_state.params, _state.derivedParams.tauAlpha).x
            )
            : _removePrecision(
                GyroECLPMath.mulAinv(_state.params, _state.derivedParams.tauAlpha).y - GyroECLPMath.mulAinv(_state.params, _state.derivedParams.tauBeta).y
            );
        uint256 peakReserveScaled = peakCoeff <= 0 ? 0 : uint256(peakCoeff).mulDown(_state.invariant);

        // Fast path: even the peak implied holding stays within the supply, so the value is never capped and the raw pool value is used everywhere
        if (peakReserveScaled <= stSupplyScaled) {
            _state.isSupplyCapped = false;
            return;
        }
        _state.isSupplyCapped = true;

        // Find the price ratio in [alpha, beta] where the senior reserve crosses the supply. The reserve decreases in the ratio when
        // the senior is token0 (peak at alpha) and increases when it is token1 (peak at beta), so orient the bisection by the index
        int256 ratioLow = _state.params.alpha;
        int256 ratioHigh = _state.params.beta;
        while (ratioHigh - ratioLow > 1) {
            int256 midRatio = (ratioLow + ratioHigh) / 2;
            // A reserve at or above the supply sits on the high-reserve side of the crossing; keep the half-interval still straddling it
            if ((_computeSeniorReserveScaledAtRatio(_state, midRatio, seniorCorner) >= stSupplyScaled) == seniorIsToken0) {
                ratioLow = midRatio;
            } else {
                ratioHigh = midRatio;
            }
        }
        int256 thresholdRatio = (ratioLow + ratioHigh) / 2;

        // Map the crossing ratio back to a senior scaled price, then to the candidate senior NAV the per-candidate path compares against.
        // The ratio is senior/quote for senior token0 (invert by multiplying) and quote/senior for senior token1 (invert by dividing)
        int256 quoteRate = toInt256(_state.quoteAssetRate);
        uint256 thresholdPrice = seniorIsToken0 ? uint256(thresholdRatio.mulDownMag(quoteRate)) : uint256(quoteRate.divDownMag(thresholdRatio));
        NAV_UNIT thresholdNAV = toNAVUnits(thresholdPrice.mulDiv(_state.stShareSupply * toUint256(_state.stShareRate), (WAD ** 2)));
        _state.maxCappedSTEffectiveNAV = thresholdNAV;

        // The continuity offset that stitches the two regions: raw pool value at the threshold minus the threshold NAV. Evaluating the raw value
        // at the same price the per-candidate path uses for the threshold guarantees the value never dips downward across the seam
        uint256 rawAtThreshold = _computeEclpTvl(
            _state.params, _state.derivedParams, _state.invariant, _computeOrderedPriceVector(_state, _computeSTShareScaledPrice(_state, thresholdNAV))
        );
        _state.capContinuityOffset = rawAtThreshold > toUint256(thresholdNAV) ? toNAVUnits(rawAtThreshold - toUint256(thresholdNAV)) : toNAVUnits(uint256(0));
    }

    /**
     * @notice The senior-share holding the curve implies at a price ratio, in scaled-18 senior units
     * @dev Used only while locating the cap threshold. Reconstructs the senior leg's fair-point reserve (the x leg for senior token0, the y leg for senior token1) the same way the ported in-band branch does
     * @param _state The frozen valuation params
     * @param _pxIny The price ratio (token0 price over token1 price) inside the band
     * @param _seniorCorner The senior leg's corner reserve coefficient, hoisted by the caller
     * @return The implied senior holding at the fair point
     */
    function _computeSeniorReserveScaledAtRatio(FixedEclpBPTValuationParams memory _state, int256 _pxIny, int256 _seniorCorner) private pure returns (uint256) {
        IGyroECLPPool.Vector2 memory vec = GyroECLPMath.mulAinv(_state.params, GyroECLPMath.tau(_state.params, _pxIny));
        int256 reserveAtRatio = _state.stSharePoolIndex == 0 ? vec.x : vec.y;
        int256 coeff = _seniorCorner - reserveAtRatio;
        return coeff <= 0 ? 0 : uint256(coeff).mulDown(_state.invariant);
    }

    // =====================================================================================
    // Balancer E-CLP Valuation: ported verbatim from EclpLPOracle, DO NOT MODIFY
    // -------------------------------------------------------------------------------------
    // The functions and constants below are copied unmodified from
    // lib/balancer-v3-monorepo/pkg/oracles/contracts/EclpLPOracle.sol, pinned at the
    // balancer-v3-monorepo submodule commit 0a5890a8c5d79865498d75cdc6ecdc75cf8d297d:
    //   https://github.com/balancer/balancer-v3-monorepo/blob/0a5890a8c5d79865498d75cdc6ecdc75cf8d297d/pkg/oracles/contracts/EclpLPOracle.sol
    // so that the pool valuation inherits the audited oracle's exact arithmetic, rounding,
    // and precision. They call the unmodified GyroECLPMath primitives. The only difference
    // from the oracle is the call site: the invariant is the frozen `L` loaded once, and the
    // prices are the candidate senior rate and the frozen quote rate, rather than live
    // Chainlink feeds. Naming and comments are preserved exactly as in the source.
    // =====================================================================================

    int256 private constant _MIN_PRICE_ECLP = 1e11; // 1e-7 scaled

    /// @notice One of the token prices is too small.
    error TokenPriceTooSmall();

    /**
     * @notice Computes the total value locked for constant ellipse (ECLP) pools of two assets.
     * @dev This computation is resistant to price manipulation within the Balancer pool. Bounds on underlying prices
     * are enforced to make this safe across a range of typical pool parameter combinations. These include typical
     * stable pair configs and the following parameter combinations: alpha in [0.05, 0.999], beta in [1.001, 1.1],
     * relative price range width (beta/alpha-1) >= 10bp, min-curvature price q = 1.0, lambda in [1, 1e8]. This yields
     * a relative error of at most 0.1bp, assuming `invariant / totalSupply >= 2` or total redemption amount at least
     * 1 USD. Please refer to Section 5.4 Consolidated Price Feed, in the Gyro technical documentation, for further
     * details: (https://docs.gyro.finance/gyd/technical-documents.html).
     *
     * @param params ECLP pool parameters
     * @param derivedParams (tau(alpha), tau(beta)) in 18 decimals. The other elements are not used.
     * @param invariant Value of the pool invariant / supply of BPT
     * @param prices Prices of the two assets according to a market oracle
     * @return tvl Total value of the pool, in the same unit as the price oracles
     */
    function _computeEclpTvl(
        IGyroECLPPool.EclpParams memory params,
        IGyroECLPPool.DerivedEclpParams memory derivedParams,
        uint256 invariant,
        int256[] memory prices
    )
        internal
        pure
        returns (uint256 tvl)
    {
        if (prices[0] < _MIN_PRICE_ECLP || prices[1] < _MIN_PRICE_ECLP) {
            revert TokenPriceTooSmall();
        }
        (int256 px, int256 py) = (prices[0], prices[1]);

        int256 pxIny = px.divDownMag(py);
        if (pxIny < params.alpha) {
            int256 bP = _removePrecision(GyroECLPMath.mulAinv(params, derivedParams.tauBeta).x - GyroECLPMath.mulAinv(params, derivedParams.tauAlpha).x);
            tvl = (bP.mulDownMag(px)).toUint256().mulDown(invariant);
        } else if (pxIny > params.beta) {
            int256 bP = _removePrecision(GyroECLPMath.mulAinv(params, derivedParams.tauAlpha).y - GyroECLPMath.mulAinv(params, derivedParams.tauBeta).y);
            tvl = (bP.mulDownMag(py)).toUint256().mulDown(invariant);
        } else {
            IGyroECLPPool.Vector2 memory vec = GyroECLPMath.mulAinv(params, GyroECLPMath.tau(params, pxIny));
            vec.x = _removePrecision(GyroECLPMath.mulAinv(params, derivedParams.tauBeta).x) - vec.x;
            vec.y = _removePrecision(GyroECLPMath.mulAinv(params, derivedParams.tauAlpha).y) - vec.y;
            tvl = GyroECLPMath.scalarProd(IGyroECLPPool.Vector2(px, py), vec).toUint256().mulDown(invariant);
        }
    }

    /**
     * @dev E-CLP derived parameters are stored with 38 decimals precision. We remove 20 decimals to get 18-decimal
     * precision.
     */
    function _removePrecision(int256 value) private pure returns (int256) {
        return value / 1e20;
    }
}
