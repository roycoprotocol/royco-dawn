// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IVault } from "../../../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { RemoveLiquidityKind, RemoveLiquidityParams } from "../../../../../../../../lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import { LPOracleBase } from "../../../../../../../../lib/balancer-v3-monorepo/pkg/oracles/contracts/LPOracleBase.sol";
import { VaultGuard } from "../../../../../../../../lib/balancer-v3-monorepo/pkg/vault/contracts/VaultGuard.sol";
import { IERC20 } from "../../../../../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../../../../../../../libraries/Constants.sol";
import { Math, NAV_UNIT, QUOTE_UNIT, TRANCHE_UNIT, UnitsMathLib, toNAVUnits, toUint256 } from "../../../../../../../libraries/Units.sol";
import { IRoycoDawnKernel, RoycoDawnKernel, RoycoDuskKernel, SyncedAccountingState } from "../../../../../RoycoDuskKernel.sol";

/**
 * @title JuniorAssetsBalancerV3PoolTokensQuoter
 * @notice A quoter for Dusk Kernels using Balancer V3 pools (ST share <> Quote asset) as their secondary liquidity venue
 * @notice The junior tranche asset is a Balancer Pool Token (BPT) between this kernel's senior tranche share and quote asset
 * @dev The Junior Tranche's BPT (Balancer Pool Token) represents its liquidity position in the pool
 *      This quoter reads the pool's current raw token balances from the Balancer V3 Vault and derives JT's pro-rata claim from the ratio of JT's BPT holdings to total BPT supply
 */
abstract contract JuniorAssetsBalancerV3PoolTokensQuoter is RoycoDuskKernel, VaultGuard {
    using UnitsMathLib for NAV_UNIT;

    /// @dev Storage slot for JuniorAssetsBalancerV3PoolTokensQuoterState using ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.JuniorAssetsBalancerV3PoolTokensQuoterState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant JUNIOR_ASSETS_BALANCER_V3_POOL_TOKENS_QUOTER_STORAGE_SLOT = 0xcb864d5a84df475b0a3b2c58a883c323a7153e386508eff47aa48ffccf304100;

    /// @dev Storage state for the Royco junior assets Balancer V3 pool tokens quoter
    /// @custom:storage-location erc7201:Royco.storage.JuniorAssetsBalancerV3PoolTokensQuoterState
    struct JuniorAssetsBalancerV3PoolTokensQuoterState {
        address juniorTrancheBPTOracle;
    }

    /// @notice Emitted when the junior tranche BPT oracle is updated
    event JuniorTrancheBPTOracleUpdated(address indexed juniorTrancheBPTOracle);

    /// @dev Thrown when the pool invoking a hook isn't this market's junior tranche pool
    error ONLY_JUNIOR_TRANCHE_BALANCER_POOL();

    /// @notice Thrown when the Balancer pool is not registered with the Balancer V3 Vault
    error POOL_NOT_REGISTERED();

    /// @notice Thrown when the pool's tokens don't match the ST tranche share (index 0) and quote asset (index 1)
    error INVALID_POOL_TOKEN_CONFIGURATION();

    /// @notice Thrown when the BPT oracle does not price this market's junior tranche pool (the JT asset)
    error JUNIOR_TRANCHE_BPT_ORACLE_POOL_MISMATCH();

    /**
     * @notice Constructs the Junior Assets Balancer V3 pool tokens quoter
     * @param _balancerV3Vault The canonical Balancer V3 Vault
     */
    constructor(address _balancerV3Vault) VaultGuard(IVault(_balancerV3Vault)) {
        // Ensure that the Balancer V3 Pool is registered with the vault
        require(_vault.isPoolRegistered(JT_ASSET), POOL_NOT_REGISTERED());

        // Retrieve the constituent tokens of this kernel's Balancer V3 pool and ensure that their are exactly 2 with ST share at index 0 and the kernel's quote asset at index 1
        IERC20[] memory tokens = _vault.getPoolTokens(JT_ASSET);
        require(tokens.length == 2 && address(tokens[0]) == SENIOR_TRANCHE && address(tokens[1]) == QUOTE_ASSET, INVALID_POOL_TOKEN_CONFIGURATION());
    }

    /**
     * @notice Initializes the junior assets Balancer V3 pool tokens quoter
     * @param _bptOracle The Balancer V3 LP oracle pricing 1 BPT of the junior tranche pool conservatively (as if at balance) in NAV units
     */
    function __JuniorAssetsBalancerV3PoolTokensQuoter_init_unchained(address _bptOracle) internal onlyInitializing {
        _setJuniorTrancheBPTOracle(_bptOracle);
    }

    // =============================
    // JT Deposit Helper Functions
    // =============================
    function jtBuildPositionFromSTUnderlyingAndQuoteAsset(
        TRANCHE_UNIT _stUnderlying,
        QUOTE_UNIT _quoteAsset
    )
        external
        restricted
        whenNotPaused
        nonReentrant
        withQuoterCache
        returns (uint256 jtShares)
    {
        // Execute an accounting sync to reconcile underlying PNL
        SyncedAccountingState memory state = _preOpSyncTrancheAccounting();
    }

    // =============================
    // Junior Tranche Quoter Functions
    // =============================

    /// @inheritdoc IRoycoDawnKernel
    function jtConvertTrancheUnitsToNAVUnits(TRANCHE_UNIT _jtAssets) public view virtual override(IRoycoDawnKernel, RoycoDawnKernel) returns (NAV_UNIT nav) {
        // Preemptively return zero NAV for zero BPTs
        if (_jtAssets == ZERO_TRANCHE_UNITS) return ZERO_NAV_UNITS;

        // Get the conservative TVL of the JT Balancer pool in NAV units
        // The rate providers of the pool are configured to price both constituent assets in this kernel's NAV units
        // NOTE: No need to check for price staleness since the pool's rate providers use this kernel's quoter which employ their own staleness enforcement
        NAV_UNIT poolNAV = toNAVUnits(LPOracleBase(_getJuniorAssetsBalancerV3PoolTokensQuoterStorage().juniorTrancheBPTOracle).computeTVL());

        // Compute the proportional value of the specified JT assets (BPTs)
        return poolNAV.mulDiv(toUint256(_jtAssets), _vault.totalSupply(JT_ASSET), Math.Rounding.Floor);
    }

    // =============================
    // Balancer V3 Liquidity Position Callback Function
    // =============================

    /**
     * @notice Callback that performs the proportional BPT unwrap inside the unlocked Balancer V3 Vault's context
     * @dev Only callable by the Balancer V3 Vault
     * @dev This callback must settle all credit and debt created in the vault's accounting by the end of its execution
     * @param _jtAssets The exact BPT amount (JT assets) to burn from this contract's balance
     * @param _receiver The recipient of the claims on the internal ST shares and quote assets withdrawn
     */
    function jtUnwrapBalancerV3LiquidityPosition(TRANCHE_UNIT _jtAssets, address _receiver) external onlyVault returns (uint256 internalSTSharesWithdrawn) {
        // Debit this kernel with the proportional constituent claims tied to the specified amount of JT assets
        (, uint256[] memory amountsOut,) = _vault.removeLiquidity(
            RemoveLiquidityParams({
                pool: JT_ASSET, // The Balancer pool to remove liquidity from is the junior tranche's asset (BPT)
                from: address(this), // The kernel custodies the BPT balance of the entire junior tranche, so the BPT constituents are debited from its claims
                maxBptAmountIn: toUint256(_jtAssets), // For PROPORTIONAL removals the Vault treats this as the exact BPT amount to burn (not an upper bound)
                minAmountsOut: new uint256[](2), // No slippage floors needed: PROPORTIONAL removals preserve the pool's invariant under any composition, so the unwrap is sandwich-resistant by construction
                kind: RemoveLiquidityKind.PROPORTIONAL, // Mirrors the pro-rata math used by `jtConvertTrancheUnitsToLPClaims` so the unwrap matches the quote
                userData: "" // PROPORTIONAL removals skip the pool's compute callback and this kernel's hooks do not consume userData
            })
        );
        // Credit the internal ST shares withdrawn to this kernel: these will be burnt and their claim on ST assets will be remitted to the receiver upstream
        _vault.sendTo(IERC20(SENIOR_TRANCHE), address(this), (internalSTSharesWithdrawn = amountsOut[0]));
        // Credit the quote assets withdrawn directly to the specified receiver
        _vault.sendTo(IERC20(QUOTE_ASSET), _receiver, amountsOut[1]);
        /// @dev All credit and debt created during this callback has been settled
    }

    // =============================
    // BPT Oracle Administration Functions
    // =============================

    /**
     * @notice Sets the Balancer V3 LP oracle used to price the junior tranche BPT in NAV units
     * @dev Executes an accounting sync after, and optionally before, updating the oracle
     * @dev Only callable by a designated admin
     * @param _bptOracle The new Balancer V3 LP oracle pricing 1 BPT of the junior tranche pool in NAV units
     * @param _syncBeforeUpdate Whether to sync the tranche accounting before updating the oracle
     */
    function setJuniorTrancheBPTOracle(address _bptOracle, bool _syncBeforeUpdate) external restricted {
        if (_syncBeforeUpdate) _preOpSyncTrancheAccounting();
        _setJuniorTrancheBPTOracle(_bptOracle);
        _preOpSyncTrancheAccounting();
    }

    /// @notice Returns the Balancer V3 LP oracle pricing the junior tranche BPT in NAV units
    function getJuniorTrancheBPTOracle() external view returns (address juniorTrancheBPTOracle) {
        return _getJuniorAssetsBalancerV3PoolTokensQuoterStorage().juniorTrancheBPTOracle;
    }

    // =============================
    // Internal Utility Functions
    // =============================

    /// @inheritdoc RoycoDuskKernel
    /// @dev Unlocks the Balancer V3 Vault and dispatches into the unwrap liquidity position callback
    /// @dev The vault is required to be unlocked with a callback in order to transition into a transient accounting state, expecting the callback to settle all credit and debt before returning
    function _jtUnwrapLiquidityPosition(
        TRANCHE_UNIT _jtAssets,
        address _receiver
    )
        internal
        override(RoycoDuskKernel)
        returns (uint256 internalSTSharesWithdrawn)
    {
        // Unlock the Balancer vault, execute the callback to unwrap the specified units of the liquidity position, and return the internal ST shares withdrawn in the process
        bytes memory callbackReturnData = _vault.unlock(abi.encodeCall(this.jtUnwrapBalancerV3LiquidityPosition, (_jtAssets, _receiver)));
        assembly ("memory-safe") {
            internalSTSharesWithdrawn := mload(add(callbackReturnData, 0x20))
        }
    }

    // =============================
    // Internal BPT Oracle Functions
    // =============================

    /**
     * @notice Validates and sets the junior tranche BPT oracle
     * @dev Reverts if the oracle is null or does not price this market's junior tranche pool (the JT asset)
     * @param _bptOracle The new Balancer V3 LP oracle pricing 1 BPT of the junior tranche pool in NAV units
     */
    function _setJuniorTrancheBPTOracle(address _bptOracle) internal {
        require(_bptOracle != address(0), NULL_ADDRESS());
        // Ensure that the BPT oracle prices this market's junior tranche pool (the JT asset)
        require(address(LPOracleBase(_bptOracle).pool()) == JT_ASSET, JUNIOR_TRANCHE_BPT_ORACLE_POOL_MISMATCH());

        _getJuniorAssetsBalancerV3PoolTokensQuoterStorage().juniorTrancheBPTOracle = _bptOracle;
        emit JuniorTrancheBPTOracleUpdated(_bptOracle);
    }

    // =============================
    // Quoter State Accessor Functions
    // =============================

    /// @dev Returns a storage pointer to the JuniorAssetsBalancerV3PoolTokensQuoterState storage
    function _getJuniorAssetsBalancerV3PoolTokensQuoterStorage() private pure returns (JuniorAssetsBalancerV3PoolTokensQuoterState storage $) {
        assembly ("memory-safe") {
            $.slot := JUNIOR_ASSETS_BALANCER_V3_POOL_TOKENS_QUOTER_STORAGE_SLOT
        }
    }
}
