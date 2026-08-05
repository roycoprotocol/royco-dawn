// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Vm } from "../../../lib/forge-std/src/Vm.sol";
import { ERC20Mock } from "../../../lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import { ERC1967Proxy } from "../../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Math } from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

import { IRoycoEntryPoint } from "../../../src/interfaces/IRoycoEntryPoint.sol";
import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { MAX_NAV_UNITS, MAX_TRANCHE_UNITS, WAD, ZERO_NAV_UNITS, ZERO_TRANCHE_UNITS } from "../../../src/libraries/Constants.sol";
import { AssetClaims } from "../../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, UnitsMathLib, toTrancheUnits, toUint256 } from "../../../src/libraries/Units.sol";
import { RoycoEntryPoint } from "../../../src/periphery/RoycoEntryPoint.sol";

import { BaseTest } from "../../base/BaseTest.t.sol";
import { ERC4626Mock } from "../../mock/ERC4626Mock.sol";

/// @title RoycoEntryPointTestBase
/// @notice Base test contract for RoycoEntryPoint tests
/// @dev Sets up a complete market with entry point configured for both tranches
abstract contract RoycoEntryPointTestBase is BaseTest {
    using Math for uint256;
    using UnitsMathLib for NAV_UNIT;
    using UnitsMathLib for TRANCHE_UNIT;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    uint24 internal constant DEFAULT_DEPOSIT_DELAY = 1 days;
    uint24 internal constant DEFAULT_REDEMPTION_DELAY = 1 days;
    uint64 internal constant DEFAULT_EXECUTOR_BONUS = 0.01e18; // 1%
    uint256 internal constant INITIAL_FUNDING = 1_000_000e18;

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════

    RoycoEntryPoint internal entryPointImpl;
    IRoycoEntryPoint internal entryPoint;

    // Test users
    Vm.Wallet internal USER_A;
    Vm.Wallet internal USER_B;
    Vm.Wallet internal EXECUTOR;
    address internal USER_A_ADDRESS;
    address internal USER_B_ADDRESS;
    address internal EXECUTOR_ADDRESS;

    // ═══════════════════════════════════════════════════════════════════════════
    // SETUP
    // ═══════════════════════════════════════════════════════════════════════════

    function setUp() public virtual {
        // Setup base Royco infrastructure
        _setUpRoyco();

        // Deploy a market using the deploy script
        _deployMarket();

        // Setup test users with LP roles
        _setupTestUsers();

        // Deploy and configure entry point
        _deployEntryPoint();

        // Fund test users
        _fundTestUsers();
    }

    /// @notice Deploys a complete market (ST, JT, Kernel, Accountant)
    function _deployMarket() internal virtual;

    /// @notice Sets up test user wallets and grants them LP roles
    function _setupTestUsers() internal {
        USER_A = _initWallet("USER_A", 100 ether);
        USER_B = _initWallet("USER_B", 100 ether);
        EXECUTOR = _initWallet("EXECUTOR", 100 ether);

        USER_A_ADDRESS = USER_A.addr;
        USER_B_ADDRESS = USER_B.addr;
        EXECUTOR_ADDRESS = EXECUTOR.addr;

        // Grant LP roles to test users
        vm.startPrank(LP_ROLE_ADMIN_ADDRESS);
        FACTORY.grantRole(ST_LP_ROLE, USER_A_ADDRESS, 0);
        FACTORY.grantRole(JT_LP_ROLE, USER_A_ADDRESS, 0);
        FACTORY.grantRole(ST_LP_ROLE, USER_B_ADDRESS, 0);
        FACTORY.grantRole(JT_LP_ROLE, USER_B_ADDRESS, 0);
        FACTORY.grantRole(ST_LP_ROLE, EXECUTOR_ADDRESS, 0);
        FACTORY.grantRole(JT_LP_ROLE, EXECUTOR_ADDRESS, 0);
        vm.stopPrank();
    }

    /// @notice Deploys the entry point and configures it for both tranches
    function _deployEntryPoint() internal {
        entryPointImpl = new RoycoEntryPoint();

        // Prepare tranche configs
        address[] memory tranches = new address[](2);
        tranches[0] = address(ST);
        tranches[1] = address(JT);

        IRoycoEntryPoint.TrancheConfig[] memory configs = new IRoycoEntryPoint.TrancheConfig[](2);
        configs[0] = IRoycoEntryPoint.TrancheConfig({
            enabled: true,
            yieldRecipient: IRoycoEntryPoint.AccruedYieldRecipient.REMAINING_LPS,
            depositDelaySeconds: DEFAULT_DEPOSIT_DELAY,
            redemptionDelaySeconds: DEFAULT_REDEMPTION_DELAY
        });
        configs[1] = IRoycoEntryPoint.TrancheConfig({
            enabled: true,
            yieldRecipient: IRoycoEntryPoint.AccruedYieldRecipient.REMAINING_LPS,
            depositDelaySeconds: DEFAULT_DEPOSIT_DELAY,
            redemptionDelaySeconds: DEFAULT_REDEMPTION_DELAY
        });

        // Deploy proxy
        bytes memory initData = abi.encodeCall(RoycoEntryPoint.initialize, (address(FACTORY), tranches, configs));
        address proxy = address(new ERC1967Proxy(address(entryPointImpl), initData));
        entryPoint = IRoycoEntryPoint(proxy);

        // Grant entry point LP roles so it can deposit/redeem on tranches
        vm.startPrank(LP_ROLE_ADMIN_ADDRESS);
        FACTORY.grantRole(ST_LP_ROLE, address(entryPoint), 0);
        FACTORY.grantRole(JT_LP_ROLE, address(entryPoint), 0);
        vm.stopPrank();
    }

    /// @notice Funds test users with tranche assets
    function _fundTestUsers() internal virtual;

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS - DEPOSITS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Requests a deposit through the entry point
    function _requestDeposit(
        address _user,
        address _tranche,
        uint256 _assets,
        address _receiver,
        uint64 _executorBonusWAD
    )
        internal
        returns (uint256 nonce, uint32 executableAt)
    {
        address asset = IRoycoVaultTranche(_tranche).asset();

        vm.startPrank(_user);
        IERC20(asset).approve(address(entryPoint), _assets);
        (nonce, executableAt) = entryPoint.requestDeposit(_tranche, toTrancheUnits(_assets), _receiver, _executorBonusWAD);
        vm.stopPrank();
    }

    /// @notice Requests a deposit with default params
    function _requestDepositDefault(address _user, address _tranche, uint256 _assets) internal returns (uint256 nonce, uint32 executableAt) {
        return _requestDeposit(_user, _tranche, _assets, _user, DEFAULT_EXECUTOR_BONUS);
    }

    /// @notice Executes a deposit request
    function _executeDeposit(address _executor, address _user, uint256 _nonce, uint256 _assetsToDeposit) internal returns (uint256 sharesMinted) {
        vm.prank(_executor);
        sharesMinted = entryPoint.executeDeposit(_user, _nonce, _assetsToDeposit == type(uint256).max ? MAX_TRANCHE_UNITS : toTrancheUnits(_assetsToDeposit));
    }

    /// @notice Executes a deposit with MAX amount
    function _executeDepositMax(address _executor, address _user, uint256 _nonce) internal returns (uint256 sharesMinted) {
        return _executeDeposit(_executor, _user, _nonce, type(uint256).max);
    }

    /// @notice Cancels a deposit request
    function _cancelDeposit(address _user, uint256 _nonce, address _receiver) internal {
        vm.prank(_user);
        entryPoint.cancelDepositRequest(_nonce, _receiver);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS - REDEMPTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Requests a redemption through the entry point
    function _requestRedemption(
        address _user,
        address _tranche,
        uint256 _shares,
        address _receiver,
        uint64 _executorBonusWAD
    )
        internal
        returns (uint256 nonce, uint32 executableAt)
    {
        vm.startPrank(_user);
        IERC20(_tranche).approve(address(entryPoint), _shares);
        (nonce, executableAt) = entryPoint.requestRedemption(_tranche, _shares, _receiver, _executorBonusWAD);
        vm.stopPrank();
    }

    /// @notice Requests a redemption with default params
    function _requestRedemptionDefault(address _user, address _tranche, uint256 _shares) internal returns (uint256 nonce, uint32 executableAt) {
        return _requestRedemption(_user, _tranche, _shares, _user, DEFAULT_EXECUTOR_BONUS);
    }

    /// @notice Executes a redemption request
    function _executeRedemption(address _executor, address _user, uint256 _nonce, uint256 _sharesToRedeem) internal returns (AssetClaims memory claims) {
        vm.prank(_executor);
        claims = entryPoint.executeRedemption(_user, _nonce, _sharesToRedeem == type(uint256).max ? type(uint256).max : _sharesToRedeem);
    }

    /// @notice Executes a redemption with MAX amount
    function _executeRedemptionMax(address _executor, address _user, uint256 _nonce) internal returns (AssetClaims memory claims) {
        return _executeRedemption(_executor, _user, _nonce, type(uint256).max);
    }

    /// @notice Cancels a redemption request
    function _cancelRedemption(address _user, uint256 _nonce, address _receiver) internal {
        vm.prank(_user);
        entryPoint.cancelRedemptionRequest(_nonce, _receiver);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS - TIME
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Warps time past the deposit delay
    function _warpPastDepositDelay() internal {
        vm.warp(block.timestamp + DEFAULT_DEPOSIT_DELAY + 1);
    }

    /// @notice Warps time past the redemption delay
    function _warpPastRedemptionDelay() internal {
        vm.warp(block.timestamp + DEFAULT_REDEMPTION_DELAY + 1);
    }

    /// @notice Warps to a specific executable timestamp
    function _warpTo(uint32 _timestamp) internal {
        vm.warp(_timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS - YIELD SIMULATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Simulates yield on the tranche (to be overridden)
    function _simulateYield(address _tranche, uint256 _percentageWAD) internal virtual;

    /// @notice Simulates loss on the tranche (to be overridden)
    function _simulateLoss(address _tranche, uint256 _percentageWAD) internal virtual;

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS - DIRECT DEPOSITS (bypass entry point for setup)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deposits directly to tranche (bypassing entry point)
    function _directDeposit(address _user, address _tranche, uint256 _assets) internal returns (uint256 shares) {
        address asset = IRoycoVaultTranche(_tranche).asset();
        vm.startPrank(_user);
        IERC20(asset).approve(_tranche, _assets);
        shares = IRoycoVaultTranche(_tranche).deposit(toTrancheUnits(_assets), _user);
        vm.stopPrank();
    }
}
