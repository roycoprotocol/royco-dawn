// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IAccessManaged } from "../../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "../../../../lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { IERC20Metadata } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import { IERC4626 } from "../../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { IMapleGlobals } from "../../../../src/interfaces/external/maple/IMapleGlobals.sol";
import { IMaplePool } from "../../../../src/interfaces/external/maple/IMaplePool.sol";
import { IMaplePoolManager } from "../../../../src/interfaces/external/maple/IMaplePoolManager.sol";
import { IMaplePoolPermissionManager } from "../../../../src/interfaces/external/maple/IMaplePoolPermissionManager.sol";
import { MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel } from "../../../../src/kernels/MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel.sol";
import { WAD, WAD_DECIMALS } from "../../../../src/libraries/Constants.sol";
import { AssetClaims } from "../../../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../../src/libraries/Units.sol";

import { DisabledChainlinkOracle_ERC4626_TestBase } from "../base/DisabledChainlinkOracle_ERC4626_TestBase.t.sol";

import { COMPONENT_ID_KERNEL_MAPLE_V2 } from "../../../../src/factory/templates/Components.sol";
import { MapleV2DeploymentTemplate } from "../../../../src/factory/templates/dawn/MapleV2DeploymentTemplate.sol";

/// @title Maple_syrupUSDC_Test
/// @notice Tests MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel with Maple's syrupUSDC
/// @dev Both ST and JT use syrupUSDC as the tranche asset on Ethereum mainnet
///
/// syrupUSDC is Maple Finance's yield-bearing USDC vault where:
///   - Tranche Unit: syrupUSDC shares (6 decimals)
///   - Underlying Asset: USDC (6 decimals)
///   - NAV Unit: USD
///
/// Key differences from standard ERC4626:
///   - Uses convertToExitAssets() which accounts for unrealizedLosses
///   - Transfer restrictions enforced via PoolManager.canCall()
///
/// The Chainlink oracle is disabled (address(1)) with stored rate = 1e18 (USDC = $1).
contract Maple_syrupUSDC_Test is DisabledChainlinkOracle_ERC4626_TestBase {
    // ═══════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice syrupUSDC on Ethereum mainnet
    address internal constant SYRUP_USDC = 0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b;

    // ═══════════════════════════════════════════════════════════════════════════
    // PROTOCOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns the test configuration for syrupUSDC
    function getTestConfig() public pure override returns (TestConfig memory) {
        return
            TestConfig({
                forkBlock: 21_000_000, forkRpcUrlEnvVar: "MAINNET_RPC_URL", stAsset: SYRUP_USDC, jtAsset: SYRUP_USDC, initialFunding: 1_000_000_000e6
            });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT (uses MarketDeploymentConfig)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys the syrupUSDC kernel and market using parameters from MarketDeploymentConfig
    function _deployKernelAndMarket() internal override returns (MarketDeployment memory) {
        MapleV2DeploymentTemplate template = new MapleV2DeploymentTemplate(FACTORY);
        DawnDeploymentParams memory p;
        p.marketId = keccak256("MAPLE_SYRUP_USDC_TEST");
        p.template = address(template);
        p.kernelComponentId = COMPONENT_ID_KERNEL_MAPLE_V2;
        p.kernelCreationCode = type(MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel).creationCode;
        p.stAsset = config.stAsset;
        p.jtAsset = config.jtAsset;
        p.kernelSpecificParams = abi.encode(
            MapleV2DeploymentTemplate.KernelParams({ initialConversionRateWAD: WAD, baseAssetToNavAssetOracle: address(1), stalenessThresholdSeconds: 86_400 })
        );
        p.stProtocolFeeWAD = ST_PROTOCOL_FEE_WAD;
        p.jtProtocolFeeWAD = JT_PROTOCOL_FEE_WAD;
        p.yieldShareProtocolFeeWAD = 0;
        p.coverageWAD = COVERAGE_WAD;
        p.betaWAD = BETA_WAD;
        p.liquidationUtilizationWAD = LIQUIDATION_UTILIZATION_WAD;
        p.fixedTermDurationSeconds = FIXED_TERM_DURATION_SECONDS;
        p.stNAVDustTolerance = DUST_TOLERANCE;
        p.jtNAVDustTolerance = DUST_TOLERANCE;
        p.enforceVaultSharesTransferWhitelist = false;
        p.stSelfLiquidationBonusWAD = 0;
        return _deployDawnMarket(p);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOLERANCE OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Returns max tranche unit delta for syrupUSDC (6 decimals)
    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e3));
    }

    /// @notice Returns max NAV delta for syrupUSDC
    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MAPLE-SPECIFIC: OVERRIDE convertToAssets TO USE convertToExitAssets
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Gets the current share price using Maple's convertToExitAssets (accounts for unrealizedLosses)
    function _getCurrentSharePriceWAD() internal view override returns (uint256) {
        if (mockedSharePriceWAD != 0) {
            return mockedSharePriceWAD;
        }
        return IMaplePool(config.stAsset).convertToExitAssets(_getSharesToConvertToAssets());
    }

    /// @notice Mocks Maple's convertToExitAssets instead of standard convertToAssets
    function _mockConvertToAssets(uint256 _newSharePriceWAD) internal override {
        mockedSharePriceWAD = _newSharePriceWAD;
        uint256 sharesToConvert = _getSharesToConvertToAssets();
        vm.mockCall(config.stAsset, abi.encodeWithSelector(IMaplePool.convertToExitAssets.selector, sharesToConvert), abi.encode(_newSharePriceWAD));
    }

    /// @notice Computes the share amount matching the kernel's ERC4626_SHARES_TO_CONVERT_TO_ASSETS
    function _getSharesToConvertToAssets() internal view override returns (uint256) {
        return 10 ** (WAD_DECIMALS + IERC4626(config.stAsset).decimals() - IERC20Metadata(IERC4626(config.stAsset).asset()).decimals());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MAPLE-SPECIFIC: _preTrancheBalanceUpdate TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Selector for hasPermission(address,address[],bytes32) - the array overload
    bytes4 internal constant HAS_PERMISSION_ARRAY_SELECTOR = bytes4(keccak256("hasPermission(address,address[],bytes32)"));

    /// @dev Selector for isFunctionPaused(bytes4) - Maple's internal 1-param version used by pool manager
    bytes4 internal constant MAPLE_IS_FUNCTION_PAUSED_BYTES4_SELECTOR = bytes4(keccak256("isFunctionPaused(bytes4)"));

    /// @notice Helper to get the Maple kernel cast
    function _mapleKernel() internal view returns (MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel) {
        return MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel(address(KERNEL));
    }

    /// @notice Helper to get the Maple pool permission manager
    function _permissionManager() internal view returns (address) {
        return IMaplePoolManager(_mapleKernel().MAPLE_POOL_MANAGER()).poolPermissionManager();
    }

    /// @notice Helper to get the Maple globals address
    function _globals() internal view returns (address) {
        return IMaplePoolManager(_mapleKernel().MAPLE_POOL_MANAGER()).globals();
    }

    /// @notice Verifies JT.transfer calls hasPermission with correct lenders [sender, recipient]
    function test_preTrancheBalanceUpdate_JT_transfer_callsHasPermissionCorrectly() external {
        _depositJT(ALICE_ADDRESS, 10_000e6);

        uint256 shares = JT.balanceOf(ALICE_ADDRESS);
        uint256 transferAmount = shares / 2;

        // Build expected lenders array: [sender, recipient]
        address[] memory expectedLenders = new address[](2);
        expectedLenders[0] = ALICE_ADDRESS;
        expectedLenders[1] = BOB_ADDRESS;

        vm.expectCall(
            _permissionManager(),
            abi.encodeWithSelector(HAS_PERMISSION_ARRAY_SELECTOR, _mapleKernel().MAPLE_POOL_MANAGER(), expectedLenders, bytes32("P:transfer"))
        );

        vm.prank(ALICE_ADDRESS);
        JT.transfer(BOB_ADDRESS, transferAmount);
    }

    /// @notice Verifies JT.transferFrom calls hasPermission with correct lenders [from, to]
    function test_preTrancheBalanceUpdate_JT_transferFrom_callsHasPermissionCorrectly() external {
        _depositJT(ALICE_ADDRESS, 10_000e6);

        uint256 shares = JT.balanceOf(ALICE_ADDRESS);
        uint256 transferAmount = shares / 2;

        vm.prank(ALICE_ADDRESS);
        JT.approve(BOB_ADDRESS, shares);

        // Build expected lenders array: [from, to]
        address[] memory expectedLenders = new address[](2);
        expectedLenders[0] = ALICE_ADDRESS;
        expectedLenders[1] = BOB_ADDRESS;

        vm.expectCall(
            _permissionManager(),
            abi.encodeWithSelector(HAS_PERMISSION_ARRAY_SELECTOR, _mapleKernel().MAPLE_POOL_MANAGER(), expectedLenders, bytes32("P:transferFrom"))
        );

        vm.prank(BOB_ADDRESS);
        JT.transferFrom(ALICE_ADDRESS, BOB_ADDRESS, transferAmount);
    }

    /// @notice Verifies ST.transfer calls hasPermission with correct lenders [sender, recipient]
    function test_preTrancheBalanceUpdate_ST_transfer_callsHasPermissionCorrectly() external {
        _depositJT(ALICE_ADDRESS, 100_000e6);
        _depositST(BOB_ADDRESS, 10_000e6);

        uint256 shares = ST.balanceOf(BOB_ADDRESS);
        uint256 transferAmount = shares / 2;

        // Build expected lenders array: [sender, recipient]
        address[] memory expectedLenders = new address[](2);
        expectedLenders[0] = BOB_ADDRESS;
        expectedLenders[1] = CHARLIE_ADDRESS;

        vm.expectCall(
            _permissionManager(),
            abi.encodeWithSelector(HAS_PERMISSION_ARRAY_SELECTOR, _mapleKernel().MAPLE_POOL_MANAGER(), expectedLenders, bytes32("P:transfer"))
        );

        vm.prank(BOB_ADDRESS);
        ST.transfer(CHARLIE_ADDRESS, transferAmount);
    }

    /// @notice Verifies ST.transferFrom calls hasPermission with correct lenders [from, to]
    function test_preTrancheBalanceUpdate_ST_transferFrom_callsHasPermissionCorrectly() external {
        _depositJT(ALICE_ADDRESS, 100_000e6);
        _depositST(BOB_ADDRESS, 10_000e6);

        uint256 shares = ST.balanceOf(BOB_ADDRESS);
        uint256 transferAmount = shares / 2;

        vm.prank(BOB_ADDRESS);
        ST.approve(CHARLIE_ADDRESS, shares);

        // Build expected lenders array: [from, to]
        address[] memory expectedLenders = new address[](2);
        expectedLenders[0] = BOB_ADDRESS;
        expectedLenders[1] = CHARLIE_ADDRESS;

        vm.expectCall(
            _permissionManager(),
            abi.encodeWithSelector(HAS_PERMISSION_ARRAY_SELECTOR, _mapleKernel().MAPLE_POOL_MANAGER(), expectedLenders, bytes32("P:transferFrom"))
        );

        vm.prank(CHARLIE_ADDRESS);
        ST.transferFrom(BOB_ADDRESS, CHARLIE_ADDRESS, transferAmount);
    }

    /// @notice Verifies deposit to SELF skips kernel's permission check (depositor already validated by underlying pool)
    /// @dev Gas optimization: when _caller == _to, the depositor is validated by Maple's transferFrom
    function test_preTrancheBalanceUpdate_deposit_toSelf_bypassesKernelCheck() external {
        // Deposit to self bypasses kernel's permission check since:
        // 1. Depositor is validated by Maple when pool tokens are transferred to kernel
        // 2. Receiver == depositor, so no additional validation needed
        _depositJT(ALICE_ADDRESS, 10_000e6);

        assertTrue(JT.balanceOf(ALICE_ADDRESS) > 0, "Deposit to self should succeed");
    }

    /// @notice Verifies deposit to different receiver validates both sender and receiver
    function test_preTrancheBalanceUpdate_deposit_toDifferentReceiver_validatesReceiver() external {
        deal(config.jtAsset, ALICE_ADDRESS, 10_000e6);

        vm.startPrank(ALICE_ADDRESS);
        IERC20(config.jtAsset).approve(address(JT), 10_000e6);

        // Kernel should call hasPermission to verify [ALICE, BOB] have permission
        address[] memory expectedLenders = new address[](2);
        expectedLenders[0] = ALICE_ADDRESS;
        expectedLenders[1] = BOB_ADDRESS;

        vm.expectCall(
            _permissionManager(),
            abi.encodeWithSelector(HAS_PERMISSION_ARRAY_SELECTOR, _mapleKernel().MAPLE_POOL_MANAGER(), expectedLenders, bytes32("P:transfer"))
        );

        JT.deposit(toTrancheUnits(10_000e6), BOB_ADDRESS);
        vm.stopPrank();

        assertTrue(JT.balanceOf(BOB_ADDRESS) > 0, "Deposit to Bob should succeed");
    }

    /// @notice Verifies deposit reverts if sender/receiver pair is blocked by Maple
    /// @dev Note: Mock affects both Maple's underlying check and kernel's check; Maple's error surfaces first
    function test_preTrancheBalanceUpdate_deposit_revertsIfReceiverBlocked() external {
        deal(config.jtAsset, ALICE_ADDRESS, 10_000e6);

        // Mock hasPermission to return false - this affects both Maple's pool check and kernel's check
        // Maple's pool check happens first during the transferFrom, so we see Maple's error
        vm.mockCall(_permissionManager(), abi.encodeWithSelector(HAS_PERMISSION_ARRAY_SELECTOR), abi.encode(false));

        vm.startPrank(ALICE_ADDRESS);
        IERC20(config.jtAsset).approve(address(JT), 10_000e6);

        // The revert comes from Maple's pool during the transferFrom (before kernel's check)
        vm.expectRevert("PM:CC:NOT_ALLOWED");
        JT.deposit(toTrancheUnits(10_000e6), BOB_ADDRESS);
        vm.stopPrank();
    }

    /// @notice Verifies owner redeem validates owner is on Maple's allowlist
    /// @dev Calls hasPermission with [owner] (single element) using P:transfer
    function test_preTrancheBalanceUpdate_redeem_ownerRedeem_callsHasPermissionCorrectly() external {
        _depositJT(ALICE_ADDRESS, 10_000e6);
        uint256 shares = JT.balanceOf(ALICE_ADDRESS);

        // Kernel should call hasPermission with [owner] for owner redeems (optimized to single element)
        address[] memory expectedLenders = new address[](1);
        expectedLenders[0] = ALICE_ADDRESS; // owner

        vm.expectCall(
            _permissionManager(),
            abi.encodeWithSelector(HAS_PERMISSION_ARRAY_SELECTOR, _mapleKernel().MAPLE_POOL_MANAGER(), expectedLenders, bytes32("P:transfer"))
        );

        vm.prank(ALICE_ADDRESS);
        AssetClaims memory claims = JT.redeem(shares, ALICE_ADDRESS, ALICE_ADDRESS);

        assertTrue(toUint256(claims.stAssets) + toUint256(claims.jtAssets) > 0, "Redeem should succeed for allowed owner");
    }

    /// @notice Verifies operator redeem validates owner (not operator) on Maple's allowlist
    /// @dev Calls hasPermission with [owner] using P:transfer (same as owner redemption)
    /// @dev Receiver of pool tokens is validated by Maple on the actual transfer
    function test_preTrancheBalanceUpdate_redeem_operatorRedeem_callsHasPermissionCorrectly() external {
        _depositJT(ALICE_ADDRESS, 10_000e6);
        uint256 shares = JT.balanceOf(ALICE_ADDRESS);

        // Approve BOB as operator
        vm.prank(ALICE_ADDRESS);
        JT.approve(BOB_ADDRESS, shares);

        // Mock factory's canCall to allow BOB to call redeem on JT
        address factory = IAccessManaged(address(JT)).authority();
        vm.mockCall(factory, abi.encodeWithSelector(IAccessManager.canCall.selector, BOB_ADDRESS, address(JT)), abi.encode(true, uint32(0)));

        // Kernel should call hasPermission with [owner] for ALL redeems (owner's shares being transferred out)
        address[] memory expectedLenders = new address[](1);
        expectedLenders[0] = ALICE_ADDRESS; // owner

        vm.expectCall(
            _permissionManager(),
            abi.encodeWithSelector(HAS_PERMISSION_ARRAY_SELECTOR, _mapleKernel().MAPLE_POOL_MANAGER(), expectedLenders, bytes32("P:transfer"))
        );

        // BOB (operator) redeems ALICE's shares to CHARLIE
        vm.prank(BOB_ADDRESS);
        AssetClaims memory claims = JT.redeem(shares, CHARLIE_ADDRESS, ALICE_ADDRESS);

        assertTrue(toUint256(claims.stAssets) + toUint256(claims.jtAssets) > 0, "Operator redeem should succeed");
    }

    /// @notice Verifies operator can redeem on behalf of owner even if operator is blacklisted
    /// @dev Only the owner is checked for redemptions; receiver is validated by Maple on pool token transfer
    function test_preTrancheBalanceUpdate_redeem_operatorBlacklistedStillWorks() external {
        _depositJT(ALICE_ADDRESS, 10_000e6);
        uint256 shares = JT.balanceOf(ALICE_ADDRESS);

        // Approve BOB as operator
        vm.prank(ALICE_ADDRESS);
        JT.approve(BOB_ADDRESS, shares);

        // Mock factory's canCall to allow BOB to call redeem on JT
        address factory = IAccessManaged(address(JT)).authority();
        vm.mockCall(factory, abi.encodeWithSelector(IAccessManager.canCall.selector, BOB_ADDRESS, address(JT)), abi.encode(true, uint32(0)));

        // BOB (operator) redeems ALICE's shares - succeeds because only owner is checked
        vm.prank(BOB_ADDRESS);
        AssetClaims memory claims = JT.redeem(shares, CHARLIE_ADDRESS, ALICE_ADDRESS);

        assertTrue(toUint256(claims.stAssets) + toUint256(claims.jtAssets) > 0, "Operator redeem should succeed even if operator would be blacklisted");
    }

    /// @notice Verifies blacklisted owner cannot redeem even to a fresh address
    /// @dev This prevents circumventing Maple's blacklist via redemption to a new address
    function test_preTrancheBalanceUpdate_redeem_revertsIfOwnerBlacklisted() external {
        _depositJT(ALICE_ADDRESS, 10_000e6);
        uint256 shares = JT.balanceOf(ALICE_ADDRESS);

        // Build the specific lenders array that kernel will check for owner redeem: [owner] (single element)
        address[] memory redeemLenders = new address[](1);
        redeemLenders[0] = ALICE_ADDRESS;

        // Mock hasPermission for the specific redeem check to return false
        vm.mockCall(
            _permissionManager(),
            abi.encodeWithSelector(HAS_PERMISSION_ARRAY_SELECTOR, _mapleKernel().MAPLE_POOL_MANAGER(), redeemLenders, bytes32("P:transfer")),
            abi.encode(false)
        );

        // ALICE tries to redeem to BOB (fresh address) - should fail because ALICE is blacklisted
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel.OPERATION_REJECTED_BY_MAPLE_PERMISSION_MANAGER.selector);
        JT.redeem(shares, BOB_ADDRESS, ALICE_ADDRESS);
    }

    /// @notice Verifies allowed owner can redeem to any receiver
    /// @dev Receiver is validated by Maple during kernel→receiver pool token transfer
    function test_preTrancheBalanceUpdate_redeem_allowedOwnerCanRedeemToOther() external {
        _depositJT(ALICE_ADDRESS, 10_000e6);
        uint256 shares = JT.balanceOf(ALICE_ADDRESS);

        // ALICE (allowed) redeems to BOB - owner check passes, receiver validated by Maple directly
        vm.prank(ALICE_ADDRESS);
        AssetClaims memory claims = JT.redeem(shares, BOB_ADDRESS, ALICE_ADDRESS);

        assertTrue(toUint256(claims.stAssets) + toUint256(claims.jtAssets) > 0, "Allowed owner can redeem to other");
    }

    /// @notice Verifies transfer reverts when hasPermission returns false
    function test_preTrancheBalanceUpdate_revertsWhenHasPermissionReturnsFalse() external {
        _depositJT(ALICE_ADDRESS, 10_000e6);
        uint256 shares = JT.balanceOf(ALICE_ADDRESS);

        // Mock hasPermission to return false
        vm.mockCall(_permissionManager(), abi.encodeWithSelector(HAS_PERMISSION_ARRAY_SELECTOR), abi.encode(false));

        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel.OPERATION_REJECTED_BY_MAPLE_PERMISSION_MANAGER.selector);
        JT.transfer(BOB_ADDRESS, shares / 2);
    }

    /// @notice Verifies transferFrom reverts when hasPermission returns false
    function test_preTrancheBalanceUpdate_transferFrom_revertsWhenHasPermissionReturnsFalse() external {
        _depositJT(ALICE_ADDRESS, 10_000e6);
        uint256 shares = JT.balanceOf(ALICE_ADDRESS);

        vm.prank(ALICE_ADDRESS);
        JT.approve(BOB_ADDRESS, shares);

        // Mock hasPermission to return false
        vm.mockCall(_permissionManager(), abi.encodeWithSelector(HAS_PERMISSION_ARRAY_SELECTOR), abi.encode(false));

        vm.prank(BOB_ADDRESS);
        vm.expectRevert(MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel.OPERATION_REJECTED_BY_MAPLE_PERMISSION_MANAGER.selector);
        JT.transferFrom(ALICE_ADDRESS, BOB_ADDRESS, shares / 2);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MAPLE-SPECIFIC: PAUSE CHECK TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies transfer reverts when Maple's canCall function is paused
    function test_preTrancheBalanceUpdate_transfer_revertsWhenCanCallPaused() external {
        _depositJT(ALICE_ADDRESS, 10_000e6);
        uint256 shares = JT.balanceOf(ALICE_ADDRESS);

        // Mock globals to return true for isFunctionPaused(poolManager, canCall.selector)
        vm.mockCall(
            _globals(),
            abi.encodeWithSelector(IMapleGlobals.isFunctionPaused.selector, _mapleKernel().MAPLE_POOL_MANAGER(), IMaplePoolManager.canCall.selector),
            abi.encode(true)
        );

        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel.MAPLE_POOL_TOKEN_TRANSFERS_PAUSED.selector);
        JT.transfer(BOB_ADDRESS, shares / 2);
    }

    /// @notice Verifies transferFrom reverts when Maple's canCall function is paused
    function test_preTrancheBalanceUpdate_transferFrom_revertsWhenCanCallPaused() external {
        _depositJT(ALICE_ADDRESS, 10_000e6);
        uint256 shares = JT.balanceOf(ALICE_ADDRESS);

        vm.prank(ALICE_ADDRESS);
        JT.approve(BOB_ADDRESS, shares);

        // Mock globals to return true for isFunctionPaused(poolManager, canCall.selector)
        vm.mockCall(
            _globals(),
            abi.encodeWithSelector(IMapleGlobals.isFunctionPaused.selector, _mapleKernel().MAPLE_POOL_MANAGER(), IMaplePoolManager.canCall.selector),
            abi.encode(true)
        );

        vm.prank(BOB_ADDRESS);
        vm.expectRevert(MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel.MAPLE_POOL_TOKEN_TRANSFERS_PAUSED.selector);
        JT.transferFrom(ALICE_ADDRESS, BOB_ADDRESS, shares / 2);
    }

    /// @notice Verifies deposit to different receiver reverts when Maple's canCall is paused
    /// @dev Maple's underlying pool transfer check catches the pause before our kernel check
    function test_preTrancheBalanceUpdate_deposit_toDifferentReceiver_revertsWhenCanCallPaused() external {
        deal(config.jtAsset, ALICE_ADDRESS, 10_000e6);

        vm.startPrank(ALICE_ADDRESS);
        IERC20(config.jtAsset).approve(address(JT), 10_000e6);

        // Mock Maple's internal isFunctionPaused(bytes4) call - pool manager uses this 1-param version
        vm.mockCall(_globals(), abi.encodeWithSelector(MAPLE_IS_FUNCTION_PAUSED_BYTES4_SELECTOR, IMaplePoolManager.canCall.selector), abi.encode(true));

        // Maple's pool check happens first during transferFrom (user → kernel), so we see Maple's error
        vm.expectRevert("PM:CC:PAUSED");
        JT.deposit(toTrancheUnits(10_000e6), BOB_ADDRESS);
        vm.stopPrank();
    }

    /// @notice Verifies redeem reverts when Maple's canCall function is paused
    /// @dev Kernel transfers pool tokens before burning tranche shares, so Maple's check catches pause first
    function test_preTrancheBalanceUpdate_redeem_revertsWhenCanCallPaused() external {
        _depositJT(ALICE_ADDRESS, 10_000e6);
        uint256 shares = JT.balanceOf(ALICE_ADDRESS);

        // Mock Maple's internal isFunctionPaused(bytes4) call - pool manager uses this 1-param version
        vm.mockCall(_globals(), abi.encodeWithSelector(MAPLE_IS_FUNCTION_PAUSED_BYTES4_SELECTOR, IMaplePoolManager.canCall.selector), abi.encode(true));

        // Maple's pool check happens first during pool token transfer (kernel → receiver)
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert("PM:CC:PAUSED");
        JT.redeem(shares, ALICE_ADDRESS, ALICE_ADDRESS);
    }

    /// @notice Verifies deposit to self still hits Maple's pause check on pool token transfer
    /// @dev Our kernel early-returns for deposit to self, but Maple's pool check catches pause first anyway
    function test_preTrancheBalanceUpdate_deposit_toSelf_stillHitsMaplePauseCheck() external {
        deal(config.jtAsset, ALICE_ADDRESS, 10_000e6);

        vm.startPrank(ALICE_ADDRESS);
        IERC20(config.jtAsset).approve(address(JT), 10_000e6);

        // Mock Maple's internal isFunctionPaused(bytes4) call - pool manager uses this 1-param version
        vm.mockCall(_globals(), abi.encodeWithSelector(MAPLE_IS_FUNCTION_PAUSED_BYTES4_SELECTOR, IMaplePoolManager.canCall.selector), abi.encode(true));

        // Even deposit to self fails because Maple's pool token transfer check runs first
        // (before our kernel's early return can be reached)
        vm.expectRevert("PM:CC:PAUSED");
        JT.deposit(toTrancheUnits(10_000e6), ALICE_ADDRESS);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MAPLE-SPECIFIC: getTrancheUnitToNAVUnitConversionRateWAD TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies kernel calls convertToExitAssets (not convertToAssets) for NAV calculation
    function test_getTrancheUnitToNAVUnitConversionRateWAD_usesConvertToExitAssets() external {
        uint256 sharesToConvert = _getSharesToConvertToAssets();

        // Expect convertToExitAssets to be called with the correct share amount
        vm.expectCall(config.stAsset, abi.encodeWithSelector(IMaplePool.convertToExitAssets.selector, sharesToConvert));

        // Call the kernel's conversion rate function
        _mapleKernel().getTrancheUnitToNAVUnitConversionRateWAD();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Verifies zero amount transfer still calls hasPermission
    function test_preTrancheBalanceUpdate_zeroAmount_callsHasPermission() external {
        _depositJT(ALICE_ADDRESS, 10_000e6);

        // Build expected lenders array: [sender, recipient]
        address[] memory expectedLenders = new address[](2);
        expectedLenders[0] = ALICE_ADDRESS;
        expectedLenders[1] = BOB_ADDRESS;

        // Zero amount transfer should still call hasPermission
        vm.expectCall(
            _permissionManager(),
            abi.encodeWithSelector(HAS_PERMISSION_ARRAY_SELECTOR, _mapleKernel().MAPLE_POOL_MANAGER(), expectedLenders, bytes32("P:transfer"))
        );

        vm.prank(ALICE_ADDRESS);
        JT.transfer(BOB_ADDRESS, 0);
    }

    /// @notice Verifies self-transfer (from == to) still calls hasPermission
    function test_preTrancheBalanceUpdate_selfTransfer_callsHasPermission() external {
        _depositJT(ALICE_ADDRESS, 10_000e6);

        uint256 shares = JT.balanceOf(ALICE_ADDRESS);
        uint256 transferAmount = shares / 2;

        // Build expected lenders array: [sender, recipient] where both are ALICE
        address[] memory expectedLenders = new address[](2);
        expectedLenders[0] = ALICE_ADDRESS;
        expectedLenders[1] = ALICE_ADDRESS;

        // Self-transfer should call hasPermission with [ALICE, ALICE]
        vm.expectCall(
            _permissionManager(),
            abi.encodeWithSelector(HAS_PERMISSION_ARRAY_SELECTOR, _mapleKernel().MAPLE_POOL_MANAGER(), expectedLenders, bytes32("P:transfer"))
        );

        vm.prank(ALICE_ADDRESS);
        JT.transfer(ALICE_ADDRESS, transferAmount);
    }
}
