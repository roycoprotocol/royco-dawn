// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";

import { AccessManager } from "../../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { ERC20Mock } from "../../../lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

import { Errors } from "../../../lib/Pendle-SY-Public/contracts/core/libraries/Errors.sol";

import { IRoycoVaultTranche } from "../../../src/interfaces/IRoycoVaultTranche.sol";
import { TrancheType } from "../../../src/libraries/Types.sol";
import { toTrancheUnits } from "../../../src/libraries/Units.sol";
import { PendleRoycoTrancheSY } from "../../../src/periphery/pendle/PendleRoycoTrancheSY.sol";
import { PendleRoycoTrancheSYFactory } from "../../../src/periphery/pendle/PendleRoycoTrancheSYFactory.sol";

import { MockTranche } from "../entrypoint/mocks/MockTranche.sol";

import { MockRoycoFactory } from "./PendleRoycoTrancheSYFactoryTest.t.sol";

/// @title PendleRoycoTrancheSYBaseAssetDepositTest
/// @notice Audit-grade end-to-end tests for the SY's direct base asset deposit path
/// @dev The tranche's authority is a REAL OZ AccessManager so the SY's deposit gate is exercised against genuine
///      canCall semantics (PUBLIC_ROLE, per-account whitelisting, execution delays, closed targets) rather than a stub.
///      MockTranche does not itself enforce the authority on deposit; gate enforcement inside the tranche is covered
///      by the kernel/tranche suites. This suite covers the SY's view of the gate and the wrap/unwrap value flows.
contract PendleRoycoTrancheSYBaseAssetDepositTest is Test {
    /// =====================================================================
    /// CONSTANTS
    /// =====================================================================
    address internal constant PENDLE_PAUSE_CONTROLLER = 0x2aD631F72fB16d91c4953A7f4260A97C2fE2f31e;
    uint64 internal constant LP_ROLE = 42;
    uint256 internal constant WAD = 1e18;

    /// =====================================================================
    /// STATE
    /// =====================================================================
    ERC20Mock internal asset;
    MockRoycoFactory internal mockRoycoFactory;
    AccessManager internal accessManager;
    MockTranche internal seniorTranche;
    MockTranche internal juniorTranche;
    PendleRoycoTrancheSYFactory internal syFactory;
    PendleRoycoTrancheSY internal sy;

    address internal authorityAdmin = makeAddr("authorityAdmin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    /// =====================================================================
    /// SETUP
    /// =====================================================================

    function setUp() public {
        asset = new ERC20Mock();
        mockRoycoFactory = new MockRoycoFactory();
        accessManager = new AccessManager(authorityAdmin);

        seniorTranche = new MockTranche(address(asset), address(mockRoycoFactory), TrancheType.SENIOR);
        juniorTranche = new MockTranche(address(asset), address(mockRoycoFactory), TrancheType.JUNIOR);
        mockRoycoFactory.registerPair(address(seniorTranche), address(juniorTranche));

        // Wire the real AccessManager as the tranche's authority BEFORE SY deployment (the SY caches it at construction)
        seniorTranche.setAuthority(address(accessManager));

        syFactory = new PendleRoycoTrancheSYFactory(address(mockRoycoFactory));
        sy = PendleRoycoTrancheSY(payable(syFactory.deploySY(address(seniorTranche), address(0))));
    }

    /// =====================================================================
    /// HELPERS
    /// =====================================================================

    /// @dev Points the tranche's deposit selector at the specified role on the real AccessManager
    function _setDepositRole(uint64 _roleId) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IRoycoVaultTranche.deposit.selector;
        vm.prank(authorityAdmin);
        accessManager.setTargetFunctionRole(address(seniorTranche), selectors, _roleId);
    }

    /// @dev Opens the gate for everyone: direct tranche deposits become permissionless
    function _openGateToPublic() internal {
        _setDepositRole(accessManager.PUBLIC_ROLE());
    }

    /// @dev Opens the gate for the SY only, with the specified execution delay
    function _whitelistSY(uint32 _executionDelay) internal {
        _setDepositRole(LP_ROLE);
        vm.prank(authorityAdmin);
        accessManager.grantRole(LP_ROLE, address(sy), _executionDelay);
    }

    /// @dev Mints base assets to a user and approves the SY to pull them
    function _mintAndApprove(address _user, uint256 _amount) internal {
        asset.mint(_user, _amount);
        vm.prank(_user);
        asset.approve(address(sy), _amount);
    }

    /// @dev Deposits base assets into the SY as the specified user
    function _depositBaseAsset(address _user, uint256 _amount) internal returns (uint256 sharesOut) {
        _mintAndApprove(_user, _amount);
        vm.prank(_user);
        sharesOut = sy.deposit(_user, address(asset), _amount, 0);
    }

    /// @dev Mints tranche shares to a user and deposits them into the SY
    function _depositTrancheShares(address _user, uint256 _shares) internal returns (uint256 sharesOut) {
        seniorTranche.mint(_user, _shares);
        vm.startPrank(_user);
        seniorTranche.approve(address(sy), _shares);
        sharesOut = sy.deposit(_user, address(seniorTranche), _shares, 0);
        vm.stopPrank();
    }

    /// @dev Core solvency invariant: every SY wei is backed by exactly one tranche share wei held by the SY
    function _assertSYSolvent() internal view {
        assertEq(sy.totalSupply(), seniorTranche.balanceOf(address(sy)), "SY supply must equal its tranche share backing");
    }

    /// =====================================================================
    /// GATE: tokens in reflect real AccessManager state
    /// =====================================================================

    function test_gate_defaultClosed_shareIsOnlyTokenIn() public {
        // Fresh AccessManager: deposit's target function role defaults to ADMIN_ROLE, which the SY does not hold.
        address[] memory tokensIn = sy.getTokensIn();
        assertEq(tokensIn.length, 1);
        assertEq(tokensIn[0], address(seniorTranche));

        assertTrue(sy.isValidTokenIn(address(seniorTranche)));
        assertFalse(sy.isValidTokenIn(address(asset)));
        assertFalse(sy.isValidTokenIn(makeAddr("randomToken")));
    }

    function test_gate_publicRole_opensBaseAsset() public {
        _openGateToPublic();

        address[] memory tokensIn = sy.getTokensIn();
        assertEq(tokensIn.length, 2);
        assertEq(tokensIn[0], address(asset));
        assertEq(tokensIn[1], address(seniorTranche));

        assertTrue(sy.isValidTokenIn(address(asset)));
        assertTrue(sy.isValidTokenIn(address(seniorTranche)));
    }

    function test_gate_syWhitelistedWithZeroDelay_opensBaseAsset() public {
        _whitelistSY(0);
        assertTrue(sy.isValidTokenIn(address(asset)));
        assertEq(sy.getTokensIn().length, 2);
    }

    function test_gate_syWhitelistedWithExecutionDelay_staysClosed() public {
        // canCall returns (false, delay) for a member with an execution delay: the SY cannot deposit atomically.
        _whitelistSY(1 hours);
        assertFalse(sy.isValidTokenIn(address(asset)));
        assertEq(sy.getTokensIn().length, 1);
    }

    function test_gate_otherAccountWhitelisted_staysClosed() public {
        // Whitelisting some other LP must not open the SY's gate.
        _setDepositRole(LP_ROLE);
        vm.prank(authorityAdmin);
        accessManager.grantRole(LP_ROLE, bob, 0);

        assertFalse(sy.isValidTokenIn(address(asset)));
    }

    function test_gate_revocationClosesGate() public {
        _whitelistSY(0);
        assertTrue(sy.isValidTokenIn(address(asset)));

        vm.prank(authorityAdmin);
        accessManager.revokeRole(LP_ROLE, address(sy));

        // The gate is consulted live: no storage staleness in the SY.
        assertFalse(sy.isValidTokenIn(address(asset)));
        assertEq(sy.getTokensIn().length, 1);
    }

    function test_gate_closedTarget_overridesPublicRole() public {
        _openGateToPublic();
        assertTrue(sy.isValidTokenIn(address(asset)));

        vm.prank(authorityAdmin);
        accessManager.setTargetClosed(address(seniorTranche), true);

        assertFalse(sy.isValidTokenIn(address(asset)));
    }

    function test_gate_authorityIsCachedAtConstruction() public {
        // Migrating the tranche to a new wide-open authority does NOT open the SY's gate: the SY consults the
        // authority cached at construction (a conscious design trade-off; the SY is upgradeable if this ever changes).
        AccessManager openManager = new AccessManager(authorityAdmin);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IRoycoVaultTranche.deposit.selector;
        uint64 publicRole = openManager.PUBLIC_ROLE();
        vm.prank(authorityAdmin);
        openManager.setTargetFunctionRole(address(seniorTranche), selectors, publicRole);

        seniorTranche.setAuthority(address(openManager));
        assertFalse(sy.isValidTokenIn(address(asset)));

        // Conversely, the cached authority keeps governing the gate after the tranche migrates away from it.
        _openGateToPublic();
        assertTrue(sy.isValidTokenIn(address(asset)));
    }

    function test_gate_closed_previewDepositBaseAssetReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.SYInvalidTokenIn.selector, address(asset)));
        sy.previewDeposit(address(asset), 1e18);
    }

    function test_gate_closed_depositBaseAssetReverts() public {
        _mintAndApprove(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.SYInvalidTokenIn.selector, address(asset)));
        sy.deposit(alice, address(asset), 1e18, 0);
    }

    function test_gate_closesMidFlow_depositReverts() public {
        // Adversarial: the gate closes between a user's preview and their deposit. The deposit must revert
        // rather than fall back to some stale validity.
        _whitelistSY(0);
        uint256 previewed = sy.previewDeposit(address(asset), 1e18);
        assertEq(previewed, 1e18);

        vm.prank(authorityAdmin);
        accessManager.revokeRole(LP_ROLE, address(sy));

        _mintAndApprove(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.SYInvalidTokenIn.selector, address(asset)));
        sy.deposit(alice, address(asset), 1e18, 0);
    }

    /// =====================================================================
    /// TOKENS OUT: redemptions are share-only regardless of the gate
    /// =====================================================================

    function test_tokensOut_shareOnly_evenWhenGateOpen() public {
        _openGateToPublic();

        address[] memory tokensOut = sy.getTokensOut();
        assertEq(tokensOut.length, 1);
        assertEq(tokensOut[0], address(seniorTranche));

        assertTrue(sy.isValidTokenOut(address(seniorTranche)));
        assertFalse(sy.isValidTokenOut(address(asset)));
    }

    function test_redeem_toBaseAsset_reverts() public {
        _openGateToPublic();
        uint256 sharesOut = _depositBaseAsset(alice, 10e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.SYInvalidTokenOut.selector, address(asset)));
        sy.redeem(alice, sharesOut, address(asset), 0, false);
    }

    /// =====================================================================
    /// DEPOSIT: tranche share path is 1:1 and unaffected by the gate
    /// =====================================================================

    function test_deposit_trancheShares_oneToOne_gateClosed() public {
        uint256 sharesOut = _depositTrancheShares(alice, 5e18);
        assertEq(sharesOut, 5e18);
        assertEq(sy.balanceOf(alice), 5e18);
        _assertSYSolvent();
    }

    function test_deposit_trancheShares_oneToOne_unaffectedByGateAndPrice() public {
        _openGateToPublic();
        seniorTranche.setSharePrice(3e18); // share price is irrelevant to the 1:1 wrap
        uint256 sharesOut = _depositTrancheShares(alice, 5e18);
        assertEq(sharesOut, 5e18);
        _assertSYSolvent();
    }

    function test_deposit_zeroAmount_reverts() public {
        _openGateToPublic();
        vm.expectRevert(abi.encodeWithSelector(Errors.SYZeroDeposit.selector));
        sy.deposit(alice, address(asset), 0, 0);

        vm.expectRevert(abi.encodeWithSelector(Errors.SYZeroDeposit.selector));
        sy.deposit(alice, address(seniorTranche), 0, 0);
    }

    /// =====================================================================
    /// DEPOSIT: base asset path
    /// =====================================================================

    function test_deposit_baseAsset_atParity() public {
        _openGateToPublic();
        uint256 amount = 100e18;

        uint256 sharesOut = _depositBaseAsset(alice, amount);

        // At a 1:1 share price, assets convert to tranche shares 1:1 and tranche shares wrap into SY 1:1.
        assertEq(sharesOut, amount);
        assertEq(sy.balanceOf(alice), amount);
        // The assets flowed user -> SY -> tranche; nothing is stranded in the SY.
        assertEq(asset.balanceOf(alice), 0);
        assertEq(asset.balanceOf(address(sy)), 0);
        assertEq(asset.balanceOf(address(seniorTranche)), amount);
        _assertSYSolvent();
    }

    function test_deposit_baseAsset_atPremiumSharePrice() public {
        _openGateToPublic();
        seniorTranche.setSharePrice(1.25e18);
        uint256 amount = 100e18;

        uint256 sharesOut = _depositBaseAsset(alice, amount);

        // shares = floor(assets * WAD / sharePrice)
        assertEq(sharesOut, amount * WAD / 1.25e18);
        _assertSYSolvent();
    }

    function test_deposit_baseAsset_atDiscountSharePrice() public {
        _openGateToPublic();
        seniorTranche.setSharePrice(0.8e18);
        uint256 amount = 100e18;

        uint256 sharesOut = _depositBaseAsset(alice, amount);

        assertEq(sharesOut, amount * WAD / 0.8e18);
        _assertSYSolvent();
    }

    function test_deposit_baseAsset_previewMatchesActual() public {
        _openGateToPublic();
        seniorTranche.setSharePrice(1.337e18);
        uint256 amount = 123_456_789_012_345_678;

        uint256 previewed = sy.previewDeposit(address(asset), amount);
        uint256 actual = _depositBaseAsset(alice, amount);

        assertEq(actual, previewed);
        // The SY's preview must also agree with the tranche's own preview.
        assertEq(previewed, seniorTranche.previewDeposit(toTrancheUnits(amount)));
    }

    function test_deposit_baseAsset_minSharesOutBoundary() public {
        _openGateToPublic();
        seniorTranche.setSharePrice(1.25e18);
        uint256 amount = 100e18;
        uint256 expectedOut = sy.previewDeposit(address(asset), amount);

        // minSharesOut == expected passes exactly at the boundary.
        _mintAndApprove(alice, amount);
        vm.prank(alice);
        uint256 sharesOut = sy.deposit(alice, address(asset), amount, expectedOut);
        assertEq(sharesOut, expectedOut);

        // minSharesOut == expected + 1 must revert.
        _mintAndApprove(bob, amount);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.SYInsufficientSharesOut.selector, expectedOut, expectedOut + 1));
        sy.deposit(bob, address(asset), amount, expectedOut + 1);
    }

    function test_deposit_baseAsset_mintsToReceiver() public {
        _openGateToPublic();
        _mintAndApprove(alice, 10e18);

        vm.prank(alice);
        uint256 sharesOut = sy.deposit(bob, address(asset), 10e18, 0);

        assertEq(sy.balanceOf(bob), sharesOut);
        assertEq(sy.balanceOf(alice), 0);
    }

    function test_deposit_baseAsset_infiniteApprovalNotConsumed() public {
        _openGateToPublic();
        assertEq(asset.allowance(address(sy), address(seniorTranche)), type(uint256).max);

        _depositBaseAsset(alice, 100e18);

        // OZ ERC20 does not decrement infinite allowances: the initialize-time approval lasts forever.
        assertEq(asset.allowance(address(sy), address(seniorTranche)), type(uint256).max);
    }

    function test_deposit_mixedPaths_solvencyHolds() public {
        _openGateToPublic();
        seniorTranche.setSharePrice(1.1e18);

        _depositTrancheShares(alice, 7e18);
        _depositBaseAsset(alice, 13e18);
        _depositTrancheShares(bob, 3e18);
        _depositBaseAsset(bob, 29e18);

        _assertSYSolvent();
    }

    function test_deposit_baseAsset_equivalentToDirectTrancheDeposit() public {
        _openGateToPublic();
        seniorTranche.setSharePrice(1.25e18);
        uint256 amount = 100e18;

        // Alice deposits base assets through the SY.
        uint256 syRouteShares = _depositBaseAsset(alice, amount);

        // Bob deposits the same amount directly at the tranche, then wraps the shares.
        asset.mint(bob, amount);
        vm.startPrank(bob);
        asset.approve(address(seniorTranche), amount);
        uint256 trancheShares = seniorTranche.deposit(toTrancheUnits(amount), bob);
        seniorTranche.approve(address(sy), trancheShares);
        uint256 directRouteShares = sy.deposit(bob, address(seniorTranche), trancheShares, 0);
        vm.stopPrank();

        // Both routes must mint identical SY shares: the SY adds no spread in either direction.
        assertEq(syRouteShares, directRouteShares);
        _assertSYSolvent();
    }

    /// =====================================================================
    /// ADVERSARIAL
    /// =====================================================================

    function test_deposit_randomToken_revertsEvenWhenGateOpen() public {
        _openGateToPublic();
        ERC20Mock randomToken = new ERC20Mock();
        randomToken.mint(alice, 1e18);

        vm.startPrank(alice);
        randomToken.approve(address(sy), 1e18);
        vm.expectRevert(abi.encodeWithSelector(Errors.SYInvalidTokenIn.selector, address(randomToken)));
        sy.deposit(alice, address(randomToken), 1e18, 0);
        vm.stopPrank();
    }

    function test_deposit_baseAsset_revertsWithoutUserApproval() public {
        _openGateToPublic();
        asset.mint(alice, 1e18);

        vm.prank(alice);
        vm.expectRevert();
        sy.deposit(alice, address(asset), 1e18, 0);
    }

    function test_deposit_baseAsset_revertsWithInsufficientBalance() public {
        _openGateToPublic();
        vm.prank(alice);
        asset.approve(address(sy), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert();
        sy.deposit(alice, address(asset), 1e18, 0);
    }

    function test_deposit_revertsWhenPaused_bothPaths() public {
        _openGateToPublic();

        vm.prank(PENDLE_PAUSE_CONTROLLER);
        sy.pause();

        _mintAndApprove(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert();
        sy.deposit(alice, address(asset), 1e18, 0);

        seniorTranche.mint(alice, 1e18);
        vm.startPrank(alice);
        seniorTranche.approve(address(sy), 1e18);
        vm.expectRevert();
        sy.deposit(alice, address(seniorTranche), 1e18, 0);
        vm.stopPrank();

        // Unpausing restores both paths.
        vm.prank(PENDLE_PAUSE_CONTROLLER);
        sy.unpause();
        _depositBaseAsset(alice, 1e18);
        _assertSYSolvent();
    }

    function test_redeem_revertsWhenPaused() public {
        _openGateToPublic();
        uint256 sharesOut = _depositBaseAsset(alice, 10e18);

        vm.prank(PENDLE_PAUSE_CONTROLLER);
        sy.pause();

        vm.prank(alice);
        vm.expectRevert();
        sy.redeem(alice, sharesOut, address(seniorTranche), 0, false);
    }

    function test_deposit_baseAsset_dustGuardedByMinSharesOut() public {
        // 1 wei of assets at a 2x share price floors to 0 tranche shares. The live tranche reverts with
        // MUST_MINT_NON_ZERO_SHARES; depositors through any tranche must protect themselves with minSharesOut.
        _openGateToPublic();
        seniorTranche.setSharePrice(2e18);
        assertEq(sy.previewDeposit(address(asset), 1), 0);

        _mintAndApprove(alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.SYInsufficientSharesOut.selector, 0, 1));
        sy.deposit(alice, address(asset), 1, 1);
    }

    /// =====================================================================
    /// END-TO-END ROUND TRIPS
    /// =====================================================================

    function test_e2e_baseAssetDeposit_fullRoundTripAtParity() public {
        _openGateToPublic();
        uint256 amount = 100e18;

        // Deposit base assets -> SY shares.
        uint256 syShares = _depositBaseAsset(alice, amount);

        // Redeem SY shares -> tranche shares.
        vm.prank(alice);
        uint256 trancheSharesOut = sy.redeem(alice, syShares, address(seniorTranche), 0, false);
        assertEq(trancheSharesOut, syShares);
        assertEq(seniorTranche.balanceOf(alice), syShares);
        assertEq(sy.totalSupply(), 0);
        _assertSYSolvent();

        // Unwrap tranche shares -> base assets at the tranche. Full circle with no value leakage at parity.
        vm.prank(alice);
        seniorTranche.redeem(trancheSharesOut, alice, alice);
        assertEq(asset.balanceOf(alice), amount);
    }

    function test_e2e_yieldAccruesThroughWrap() public {
        _openGateToPublic();
        uint256 amount = 100e18;
        uint256 syShares = _depositBaseAsset(alice, amount);

        // 10% yield accrues on the tranche. Fund the mock so it can pay out the appreciation.
        seniorTranche.simulateYield(0.1e18);
        asset.mint(address(seniorTranche), amount / 10);

        // The SY's exchange rate tracks the tranche's NAV per share.
        assertEq(sy.exchangeRate(), 1.1e18);

        // Unwind: alice realizes the yield through the wrap.
        vm.prank(alice);
        uint256 trancheSharesOut = sy.redeem(alice, syShares, address(seniorTranche), 0, false);
        vm.prank(alice);
        seniorTranche.redeem(trancheSharesOut, alice, alice);
        assertEq(asset.balanceOf(alice), amount * 11 / 10);
    }

    function test_e2e_lossFlowsThroughWrap() public {
        _openGateToPublic();
        uint256 amount = 100e18;
        uint256 syShares = _depositBaseAsset(alice, amount);

        // 10% loss on the tranche.
        seniorTranche.simulateLoss(0.1e18);
        assertEq(sy.exchangeRate(), 0.9e18);

        vm.prank(alice);
        uint256 trancheSharesOut = sy.redeem(alice, syShares, address(seniorTranche), 0, false);
        vm.prank(alice);
        seniorTranche.redeem(trancheSharesOut, alice, alice);
        assertEq(asset.balanceOf(alice), amount * 9 / 10);
    }

    function test_e2e_twoDepositors_noValueTransferBetweenLPs() public {
        _openGateToPublic();
        uint256 amount = 100e18;

        // Alice deposits at parity; the share price then doubles before bob deposits the same asset amount.
        uint256 aliceShares = _depositBaseAsset(alice, amount);
        seniorTranche.simulateYield(1e18); // 2x
        asset.mint(address(seniorTranche), amount); // back the appreciation
        uint256 bobShares = _depositBaseAsset(bob, amount);

        // Bob's identical asset amount buys exactly half the shares: alice's appreciation is not diluted.
        assertEq(bobShares, aliceShares / 2);
        _assertSYSolvent();

        // Each unwinds and receives exactly their entitlement: alice 2x, bob his principal.
        vm.startPrank(alice);
        uint256 aliceTrancheShares = sy.redeem(alice, aliceShares, address(seniorTranche), 0, false);
        seniorTranche.redeem(aliceTrancheShares, alice, alice);
        vm.stopPrank();
        assertEq(asset.balanceOf(alice), 2 * amount);

        vm.startPrank(bob);
        uint256 bobTrancheShares = sy.redeem(bob, bobShares, address(seniorTranche), 0, false);
        seniorTranche.redeem(bobTrancheShares, bob, bob);
        vm.stopPrank();
        assertEq(asset.balanceOf(bob), amount);
    }

    /// =====================================================================
    /// FUZZ
    /// =====================================================================

    function testFuzz_gateReflectsExecutionDelayExactly(uint32 _executionDelay) public {
        _whitelistSY(_executionDelay);
        // The gate is open iff the SY can deposit with NO execution delay.
        assertEq(sy.isValidTokenIn(address(asset)), _executionDelay == 0);
        assertEq(sy.getTokensIn().length, _executionDelay == 0 ? 2 : 1);
    }

    function testFuzz_previewParityAndSolvency_baseAsset(uint256 _amount, uint256 _sharePriceWAD) public {
        _amount = bound(_amount, 1, 1e36);
        _sharePriceWAD = bound(_sharePriceWAD, 1, 1e24);

        _openGateToPublic();
        seniorTranche.setSharePrice(_sharePriceWAD);

        uint256 previewed = sy.previewDeposit(address(asset), _amount);
        uint256 actual = _depositBaseAsset(alice, _amount);

        // Preview must equal execution exactly for every (amount, price) pair, and the SY stays fully backed.
        assertEq(actual, previewed);
        _assertSYSolvent();
    }

    function testFuzz_e2e_roundTripConservesValuePerMockMath(uint256 _amount, uint256 _entryPriceWAD, uint256 _exitPriceWAD) public {
        _amount = bound(_amount, 1, 1e30);
        _entryPriceWAD = bound(_entryPriceWAD, 1e12, 1e24);
        _exitPriceWAD = bound(_exitPriceWAD, 1e12, 1e24);

        _openGateToPublic();
        seniorTranche.setSharePrice(_entryPriceWAD);
        uint256 syShares = _depositBaseAsset(alice, _amount);

        // Dust amounts at high share prices floor to zero shares. The live tranche reverts such deposits with
        // MUST_MINT_NON_ZERO_SHARES; the mock mints zero, leaving nothing to round trip.
        if (syShares == 0) return;

        // Move the share price and ensure the tranche can pay out the implied assets.
        seniorTranche.setSharePrice(_exitPriceWAD);
        uint256 expectedAssetsOut = syShares * _exitPriceWAD / WAD;
        if (expectedAssetsOut > _amount) asset.mint(address(seniorTranche), expectedAssetsOut - _amount);

        // Unwind through the SY and the tranche.
        vm.startPrank(alice);
        uint256 trancheSharesOut = sy.redeem(alice, syShares, address(seniorTranche), 0, false);
        if (trancheSharesOut != 0) seniorTranche.redeem(trancheSharesOut, alice, alice);
        vm.stopPrank();

        // The wrap adds zero spread: assets out match the tranche's own floor math exactly.
        assertEq(trancheSharesOut, syShares);
        assertEq(asset.balanceOf(alice), expectedAssetsOut);
        assertEq(sy.totalSupply(), 0);
        _assertSYSolvent();
    }
}
