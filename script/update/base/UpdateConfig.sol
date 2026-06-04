// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoKernel } from "../../../src/interfaces/IRoycoKernel.sol";

/**
 * @title UpdateConfig
 * @notice Registry mapping market names to deployed kernel addresses per chain
 * @dev All other addresses (accountant, tranches) are derived from the kernel at runtime.
 *      Add new markets by extending `_initializeDeployedMarkets()`.
 */
abstract contract UpdateConfig {
    // ═══════════════════════════════════════════════════════════════════════════
    // CHAIN IDs
    // ═══════════════════════════════════════════════════════════════════════════

    uint256 internal constant MAINNET = 1;
    uint256 internal constant AVALANCHE = 43_114;
    uint256 internal constant ARBITRUM = 42_161;
    uint256 internal constant BASE = 8453;

    // ═══════════════════════════════════════════════════════════════════════════
    // FACTORY ADDRESS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Deployed using CREATE2 — same address on every chain
    address internal constant ROYCO_FACTORY = 0x7cC6fB28eC7b5e7afC3cB3986141797ffc27253C;

    // ═══════════════════════════════════════════════════════════════════════════
    // MULTISIG ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Root multisig — holds the timelocked admin roles (ADMIN_ACCOUNTANT_ROLE, ADMIN_KERNEL_ROLE, etc.)
    address internal constant ROOT_MULTISIG = 0x7c405bbD131e42af506d14e752f2e59B19D49997;

    /// @dev Executor multisig — holds the GUARDIAN_ROLE (can cancel pending operations)
    address internal constant EXECUTOR_MULTISIG = 0x84d37A25e46029CE161111420E07cEb78880119e;

    /// @dev WCE multisig — operations multisig holding immediate-delay admin roles
    ///      (e.g. ADMIN_ENTRY_POINT_ROLE with 0 delay).
    address internal constant WCE_MULTISIG = 0x84d37A25e46029CE161111420E07cEb78880119e;

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET NAMES
    // ═══════════════════════════════════════════════════════════════════════════

    string internal constant STCUSD = "stcUSD";
    string internal constant SNUSD = "sNUSD";
    string internal constant SAVUSD = "savUSD";
    string internal constant AUTOUSD = "autoUSD";
    string internal constant SMOKEHOUSE_USDC = "SmokehouseUSDC";
    string internal constant SYRUP_USDC = "syrupUSDC";
    string internal constant SUSDAI = "sUSDai";
    string internal constant PARETO_FALCONX = "ParetoFalconX";
    string internal constant APYUSD = "apyUSD";
    string internal constant eEARN = "eEARN";

    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Resolved market addresses (derived from kernel at runtime)
    struct MarketAddresses {
        address kernel;
        address accountant;
        address seniorTranche;
        address juniorTranche;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev chainId → marketName → kernel address
    mapping(uint256 chainId => mapping(string marketName => address kernel)) internal _deployedKernels;

    /// @dev Chainlink-style aggregators (`latestRoundData()`) that need to stay "fresh" through the
    ///      2-day simulation warp. The harness captures `latestRoundData` for each entry pre-warp,
    ///      then `vm.mockCall`s the oracle post-warp to keep the same `answer` but report
    ///      `updatedAt = block.timestamp`, defeating downstream staleness checks.
    mapping(uint256 chainId => address[] oracles) internal _chainlinkOracles;

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error MarketNotFound(string marketName, uint256 chainId);

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor() {
        _initializeDeployedMarkets();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GETTERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the Chainlink-style oracles to keep fresh during simulation for `_chainId`.
    function getChainlinkOracles(uint256 _chainId) public view returns (address[] memory oracles) {
        oracles = _chainlinkOracles[_chainId];
    }

    /**
     * @notice Resolves all market addresses from the kernel for the current chain
     * @param _marketName The market name (must match a configured entry)
     * @return addrs The resolved kernel, accountant, and tranche addresses
     */
    function getMarketAddresses(string memory _marketName) public view returns (MarketAddresses memory addrs) {
        addrs.kernel = _deployedKernels[block.chainid][_marketName];
        require(addrs.kernel != address(0), MarketNotFound(_marketName, block.chainid));

        IRoycoKernel kernel = IRoycoKernel(addrs.kernel);
        addrs.accountant = kernel.ACCOUNTANT();
        addrs.seniorTranche = kernel.SENIOR_TRANCHE();
        addrs.juniorTranche = kernel.JUNIOR_TRANCHE();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _initializeDeployedMarkets() internal {
        // ── Mainnet ──────────────────────────────────────────────────────────
        _deployedKernels[MAINNET][STCUSD] = 0x9911F227E9428964D8A35B852513919C8DF92038;
        _deployedKernels[MAINNET][SNUSD] = 0x0aE0978B868804929fd4C06B3B22D9197B8cd3c6;
        _deployedKernels[MAINNET][AUTOUSD] = 0x8748D1c21CC550B435487F473d9Aaf6C84dA46A6;
        _deployedKernels[MAINNET][SMOKEHOUSE_USDC] = 0x6dBdf6EBdF02F50ec6a7d6F782850996928176F9;
        _deployedKernels[MAINNET][SYRUP_USDC] = 0xde1Ce2cF64808e50d000F93058784270E412B3A4;
        _deployedKernels[MAINNET][PARETO_FALCONX] = 0x15bb63C07740ff972F76716cAcC5766f0C641791;
        _deployedKernels[MAINNET][APYUSD] = 0xcFbdEA0990F21b103c8D123d0D5273B4ea269cb4;
        _deployedKernels[MAINNET][eEARN] = 0x36c1d7CaFa9A220fc1450fA070277aED69F8c9B2;

        // ── Avalanche ────────────────────────────────────────────────────────
        _deployedKernels[AVALANCHE][SAVUSD] = 0x7240FF91b471217FF93349184ABE9f102Ca1955C;

        // ── Arbitrum ─────────────────────────────────────────────────────────
        _deployedKernels[ARBITRUM][SUSDAI] = 0xFdb17E53eA5d342124b8473188BCB9F05F1949CA;

        // ── Chainlink oracles to keep fresh through the 2-day simulation warp ─
        // Add any aggregator address whose staleness check would otherwise revert mid-simulation.
        // Mocking `latestRoundData()` on the cap oracle short-circuits any RedStone push-feed
        // adapter staleness checks reached transitively, so RedStone-backed feeds belong here too.
        _chainlinkOracles[MAINNET].push(0x5e7281f74e74D76347f0b8f4a36Fd3cb29c19d95); // sNUSD: RedStone nusd_fundamental
        _chainlinkOracles[MAINNET].push(0x9A5a3c3Ed0361505cC1D4e824B3854De5724434A); // stcUSD: RedStone cUSD_FUNDAMENTAL
        _chainlinkOracles[MAINNET].push(0x651b101f72F82630cf59c68E6EE4305aFBd3B1F5); // apyUSD: Chainlink apxusd-usd
    }
}
