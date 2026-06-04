// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title UpgradeConfig
 * @notice Self-contained registry of deployed Royco addresses for the upgrade system.
 * @dev Holds every address the upgrade scripts need — factory, multisigs, and per-market
 *      (ST / JT / accountant / kernel). Unlike the parameter-update config, this does not
 *      derive ST/JT/accountant from the kernel via on-chain calls; everything is hardcoded so
 *      upgrades never depend on the current live contracts being intact (e.g. when the kernel
 *      itself is the thing being upgraded). YDM is omitted — it is non-upgradeable.
 *
 *      Add new markets or chains by extending `_initializeConfig()` — strictly additive; never
 *      mutate existing entries without a code review.
 */
abstract contract UpgradeConfig {
    // ═══════════════════════════════════════════════════════════════════════════
    // CHAIN IDs
    // ═══════════════════════════════════════════════════════════════════════════

    uint256 internal constant MAINNET = 1;
    uint256 internal constant AVALANCHE = 43_114;
    uint256 internal constant ARBITRUM = 42_161;
    uint256 internal constant BASE = 8453;

    // ═══════════════════════════════════════════════════════════════════════════
    // MULTISIGS  (same across every chain)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Holds the timelocked admin roles including `ADMIN_UPGRADER_ROLE`
    address internal constant ROOT_MULTISIG = 0x7c405bbD131e42af506d14e752f2e59B19D49997;

    /// @dev Holds `GUARDIAN_ROLE` (can cancel pending operations)
    address internal constant EXECUTOR_MULTISIG = 0x84d37A25e46029CE161111420E07cEb78880119e;

    // ═══════════════════════════════════════════════════════════════════════════
    // MARKET NAMES
    // ═══════════════════════════════════════════════════════════════════════════

    string internal constant SNUSD = "sNUSD";
    string internal constant AUTOUSD = "autoUSD";
    string internal constant SAVUSD = "savUSD";
    string internal constant SUSDAI = "sUSDai";
    string internal constant SMOKEHOUSE_USDC = "SmokehouseUSDC";
    string internal constant SYRUP_USDC = "syrupUSDC";
    string internal constant STCUSD = "stcUSD";
    string internal constant PARETO_FALCONX = "ParetoFalconX";
    string internal constant APYUSD = "apyUSD";
    string internal constant EEARN = "eEARN";

    // ═══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    struct MarketAddresses {
        address seniorTranche;
        address juniorTranche;
        address accountant;
        address kernel;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error UpgradeConfig__FactoryNotRegistered(uint256 chainId);
    error UpgradeConfig__MarketNotFound(string marketName, uint256 chainId);

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Factory (AccessManager) per chain. A singleton — one factory deployment per chain,
    ///      not keyed per market. Every market on a given chain shares this factory.
    mapping(uint256 chainId => address factory) internal _factories;

    /// @dev (chainId, marketName) → addresses for the market's ST, JT, accountant, and kernel
    mapping(uint256 chainId => mapping(string marketName => MarketAddresses addrs)) internal _markets;

    /// @dev Chainlink-style aggregators (anything implementing `latestRoundData()`) that need to
    ///      stay "fresh" through the 2-day simulation warp. Before the warp the orchestrator
    ///      captures `latestRoundData` for each entry and after the warp it `vm.mockCall`s the
    ///      oracle so the response keeps its `answer` but reports `updatedAt = block.timestamp`,
    ///      avoiding staleness reverts in downstream sync/quoter math.
    mapping(uint256 chainId => address[] oracles) internal _chainlinkOracles;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor() {
        _initializeConfig();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // GETTERS
    // ═══════════════════════════════════════════════════════════════════════════

    function getFactory(uint256 _chainId) public view returns (address factory) {
        factory = _factories[_chainId];
        require(factory != address(0), UpgradeConfig__FactoryNotRegistered(_chainId));
    }

    function getMarketAddresses(uint256 _chainId, string memory _marketName) public view returns (MarketAddresses memory addrs) {
        addrs = _markets[_chainId][_marketName];
        require(addrs.kernel != address(0), UpgradeConfig__MarketNotFound(_marketName, _chainId));
    }

    function getChainlinkOracles(uint256 _chainId) public view returns (address[] memory oracles) {
        oracles = _chainlinkOracles[_chainId];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _initializeConfig() internal virtual {
        // Factory — singleton, CREATE2-deterministic; currently the same address on every chain.
        address royco_factory = 0x7cC6fB28eC7b5e7afC3cB3986141797ffc27253C;
        _factories[MAINNET] = royco_factory;
        _factories[AVALANCHE] = royco_factory;
        _factories[ARBITRUM] = royco_factory;
        _factories[BASE] = royco_factory;

        // ── Mainnet ──────────────────────────────────────────────────────────
        _markets[MAINNET][SNUSD] = MarketAddresses({
            seniorTranche: 0x2070Af1C865f5d764F673Baf5654822947e71243,
            juniorTranche: 0x3821eBea3BBbE23F3dea74f24082BD0f0b67f6c5,
            accountant: 0xCaa3F221fCf3c2EC7b6a49B73BB810cca35e1085,
            kernel: 0x0aE0978B868804929fd4C06B3B22D9197B8cd3c6
        });
        _markets[MAINNET][AUTOUSD] = MarketAddresses({
            seniorTranche: 0x73C641fe41EB0270C7f473f3c3E4A40eb97fd8dE,
            juniorTranche: 0x6f0D6567099621deE3850C673d73c532071A888d,
            accountant: 0xB0166629D78E3876F570f18B154A60b99024b6f4,
            kernel: 0x8748D1c21CC550B435487F473d9Aaf6C84dA46A6
        });
        _markets[MAINNET][SMOKEHOUSE_USDC] = MarketAddresses({
            seniorTranche: 0xa225F24654b8995036606D5Cd0634133a4BE169c,
            juniorTranche: 0xC8fab124292cB792d15041292C2399910bD086d1,
            accountant: 0x955f8f7691a8908fA5a2798935Bda557A03aFb75,
            kernel: 0x6dBdf6EBdF02F50ec6a7d6F782850996928176F9
        });
        _markets[MAINNET][SYRUP_USDC] = MarketAddresses({
            seniorTranche: 0x66182442522D3049A941035190C315379c959250,
            juniorTranche: 0x5f340B400F892bBFDed2e5c316369Dcbf05C282A,
            accountant: 0x2995f615D0ec527eD43eBb22DE0DcB66084c98FE,
            kernel: 0xde1Ce2cF64808e50d000F93058784270E412B3A4
        });
        _markets[MAINNET][STCUSD] = MarketAddresses({
            seniorTranche: 0xa7Da92685ea436276B2e87aE12E5eE6DABaD5bB5,
            juniorTranche: 0xe4060E83ad26618c7Ed56A02ce099beBA4f73b29,
            accountant: 0x59609E6f6faD8b90C025E03a98ef44f7435B122d,
            kernel: 0x9911F227E9428964D8A35B852513919C8DF92038
        });
        _markets[MAINNET][PARETO_FALCONX] = MarketAddresses({
            seniorTranche: 0x694ADB3077BBecE31882B6d6A74fc4A4fA6a754b,
            juniorTranche: 0x8E0ec43E51B88AA2324102e1A3D667822be51A6d,
            accountant: 0x37543D7C1e0e5C4467398681180af00efB68D0Dd,
            kernel: 0x15bb63C07740ff972F76716cAcC5766f0C641791
        });
        _markets[MAINNET][APYUSD] = MarketAddresses({
            seniorTranche: 0xBd373c9D3D8976a4FECC504a93c768BBE8C3227C,
            juniorTranche: 0xAB2ab53E1e2E2c5D7202918EC8c873712bcc4a2D,
            accountant: 0x5A42DD2e3C30b20663BB86D40DB0ea28689BbD0f,
            kernel: 0xcFbdEA0990F21b103c8D123d0D5273B4ea269cb4
        });
        _markets[MAINNET][EEARN] = MarketAddresses({
            seniorTranche: 0x1BA515a409DD702105415cDAAe439059aA0B402A,
            juniorTranche: 0x059bC7AA5000A26AAE2601CfbF060653Adf8Fd91,
            accountant: 0x0684a043e7b19f3325556A3cB5d074cfc601905D,
            kernel: 0x36c1d7CaFa9A220fc1450fA070277aED69F8c9B2
        });

        // ── Avalanche ────────────────────────────────────────────────────────
        _markets[AVALANCHE][SAVUSD] = MarketAddresses({
            seniorTranche: 0xDA7bf1788aecb94fE6D5D3f739358De94f43E5C9,
            juniorTranche: 0x2dfde7811567562aaB39D0A292e43aa7195f6Cf6,
            accountant: 0x1067405d143a3973Dc48fD0Ea14ed6c1AF20dbb1,
            kernel: 0x7240FF91b471217FF93349184ABE9f102Ca1955C
        });

        // ── Arbitrum ─────────────────────────────────────────────────────────
        _markets[ARBITRUM][SUSDAI] = MarketAddresses({
            seniorTranche: 0x90465aad4e426948A4ea342AC49A1A38200B7017,
            juniorTranche: 0xeB60a64039289a4c07879147073A1Ec5AEA91553,
            accountant: 0x1b282c9CDB63378788Bbfd059a7cd44bc9Cba738,
            kernel: 0xFdb17E53eA5d342124b8473188BCB9F05F1949CA
        });

        // ── Chainlink oracles to keep fresh through the 2-day simulation warp ─
        // Add any aggregator address whose staleness check would otherwise revert mid-simulation.
        // Mocking `latestRoundData()` on the cap oracle short-circuits any RedStone push-feed
        // adapter staleness checks reached transitively, so RedStone-backed feeds belong here too.
        _chainlinkOracles[MAINNET].push(0x5e7281f74e74D76347f0b8f4a36Fd3cb29c19d95); // sNUSD: RedStone nusd_fundamental
        _chainlinkOracles[MAINNET].push(0x9A5a3c3Ed0361505cC1D4e824B3854De5724434A); // stcUSD: RedStone cUSD_FUNDAMENTAL
        _chainlinkOracles[MAINNET].push(0x651b101f72F82630cf59c68E6EE4305aFBd3B1F5); // apyUSD: Chainlink apxusd-usd
    }
}
