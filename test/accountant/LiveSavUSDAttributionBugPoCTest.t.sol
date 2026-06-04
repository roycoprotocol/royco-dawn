// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { UUPSUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC4626 } from "../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { RoycoAccountant } from "../../src/accountant/RoycoAccountant.sol";
import { IRoycoKernel } from "../../src/interfaces/IRoycoKernel.sol";
import { IRoycoVaultTranche } from "../../src/interfaces/IRoycoVaultTranche.sol";
import { toUint256 } from "../../src/libraries/Units.sol";

/**
 * @title LiveSavUSDAttributionBugPoCTest
 * @notice Reproduces the `RoycoAccountant` attribution bug end-to-end against the LIVE
 *         savUSD market on Avalanche mainnet - no fresh deployment, no mocked accountant state,
 *         only on-chain contracts at their currently-deployed addresses.
 *
 *         The three addresses below are the majority ST holders (as reported on Avalanche
 *         snowtrace). The test impersonates them, has them redeem their full ST positions,
 *         then triggers a second yield event by mocking the savUSD ERC4626 share price upward.
 *         The accountant attributes the entire delta to `stEffectiveNAV` despite ST's total
 *         supply collapsing to (effectively) zero.
 *
 * @dev Auth is bypassed by mocking `IAccessManager.canCall(...)` on the factory to return
 *      `(true, 0)` - the factory IS the AccessManager (via `AccessManagerUpgradeable`), and the
 *      `restricted` modifier on every gated function routes through `_authority().canCall(...)`.
 *      We need the bypass to (a) impersonate the existing ST holders for redeems without
 *      relying on their `ST_LP_ROLE` membership, and (b) call `syncTrancheAccounting()`
 *      without a SYNC_ROLE holder. No state corruption is performed - only `convertToAssets`
 *      on savUSD itself is bumped, simulating the natural action of vault share-price growth.
 */
contract LiveSavUSDAttributionBugPoCTest is Test {
    // --- Royco savUSD market - live deployments on Avalanche -------------------
    address internal constant FACTORY = 0x7cC6fB28eC7b5e7afC3cB3986141797ffc27253C;
    address internal constant YDM = 0x00b01af1736C7d7646bd97fb6f0Dc96Bf57d0810;
    address internal constant ST = 0xDA7bf1788aecb94fE6D5D3f739358De94f43E5C9;
    address internal constant JT = 0x2dfde7811567562aaB39D0A292e43aa7195f6Cf6;
    address internal constant ACCOUNTANT = 0x1067405d143a3973Dc48fD0Ea14ed6c1AF20dbb1;
    address internal constant KERNEL = 0x7240FF91b471217FF93349184ABE9f102Ca1955C;

    // --- savUSD (ERC4626) on Avalanche -----------------------------------------
    address internal constant SAVUSD = 0x06d47F3fb376649c3A9Dafe069B3D6E35572219E;

    // --- Majority ST holders ---------------------------------------------------
    address internal constant ST_HOLDER_1 = 0x170ff06326eBb64BF609a848Fc143143994AF6c8;
    address internal constant ST_HOLDER_2 = 0x05ea95aE815809D77153Ed3500Ad6d936712b639;
    address internal constant ST_HOLDER_3 = 0x77777Cc68b333a2256B436D675E8D257699Aa667;

    /// @dev The IdenticalERC4626SharesOracleQuoter constructor pins this constant at deploy
    ///      time: `10 ** (WAD_DECIMALS + IERC4626(ST_ASSET).decimals() - IERC20Metadata(asset).decimals())`.
    ///      For savUSD (18 dec) over AVUSD (18 dec) this is `10**18 = 1e18`. The quoter calls
    ///      `convertToAssets(ERC4626_SHARES_TO_CONVERT_TO_ASSETS)` at every quote - mocking
    ///      this exact input bumps the kernel-perceived NAV.
    uint256 internal constant SHARES_QUOTED_BY_KERNEL = 1e18;

    /// @dev Pinned to a recent Avalanche head so the on-chain state (ST holder balances,
    ///      tranche NAV, etc.) is deterministic across runs.
    uint256 internal constant FORK_BLOCK = 86_023_000;

    function setUp() public {
        vm.createSelectFork(vm.envString("AVALANCHE_RPC_URL"), FORK_BLOCK);

        // Bypass auth across the board: any `restricted` call passes regardless of msg.sender.
        // No state corruption - only an access-control mock.
        vm.mockCall(FACTORY, abi.encodeWithSignature("canCall(address,address,bytes4)"), abi.encode(true, uint32(0)));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // POC
    // ═══════════════════════════════════════════════════════════════════════════

    function test_poc_liveSavUSDMarket_attributionBug() external {
        uint256 preDrainSharePriceWAD = toUint256(IRoycoVaultTranche(ST).convertToAssets(1e18).nav);

        // Yield arrives, risk premium gets distributed to JT.
        _bumpSavUSDSharePrice(1.1e18);
        IRoycoKernel(KERNEL).syncTrancheAccounting();

        // Majority ST holders drain.
        _redeemAll(ST_HOLDER_1);
        _redeemAll(ST_HOLDER_2);
        _redeemAll(ST_HOLDER_3);
        IRoycoKernel(KERNEL).syncTrancheAccounting();

        // Second yield event - the moment the bug surfaces.
        _bumpSavUSDSharePrice(1.1e18);
        IRoycoKernel(KERNEL).syncTrancheAccounting();

        uint256 postSharePriceWAD = toUint256(IRoycoVaultTranche(ST).convertToAssets(1e18).nav);
        assertGt(postSharePriceWAD, preDrainSharePriceWAD * 10, "BUG: per-share NAV jumped >10x after majority drain");
    }

    /// @notice Same scenario as the bug repro above, but with the on-chain accountant proxy
    ///         upgraded to a freshly-compiled impl built from the locally-patched source.
    ///         If the fix is correct, the second yield event should NOT inflate
    ///         `stEffectiveNAV` against the dust ST supply remaining after majority drain.
    /// @dev We deploy a fresh `RoycoAccountant` impl pointing at the live kernel address, then
    ///      call `upgradeToAndCall(newImpl, "")` on the proxy. Auth is already bypassed via the
    ///      `canCall` mock from `setUp` — any address can perform the upgrade.
    function test_fixValidation_liveSavUSDMarket_afterAccountantUpgrade() external {
        // Upgrade the on-chain accountant proxy to the locally-fixed impl.
        RoycoAccountant newImpl = new RoycoAccountant(KERNEL);
        UUPSUpgradeable(ACCOUNTANT).upgradeToAndCall(address(newImpl), "");

        _bumpSavUSDSharePrice(1.1e18);
        IRoycoKernel(KERNEL).syncTrancheAccounting();

        uint256 preDrainSharePriceWAD = toUint256(IRoycoVaultTranche(ST).convertToAssets(1e18).nav);

        _redeemAll(ST_HOLDER_1);
        _redeemAll(ST_HOLDER_2);
        _redeemAll(ST_HOLDER_3);
        IRoycoKernel(KERNEL).syncTrancheAccounting();

        _bumpSavUSDSharePrice(1.1e18);
        IRoycoKernel(KERNEL).syncTrancheAccounting();

        uint256 postSharePriceWAD = toUint256(IRoycoVaultTranche(ST).convertToAssets(1e18).nav);
        assertLt(postSharePriceWAD, preDrainSharePriceWAD * 11 / 10, "FIX FAILED: per-share NAV jumped >1.21x after majority drain");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Mocks savUSD's `convertToAssets(SHARES_QUOTED_BY_KERNEL)` to return the current
    ///      value scaled by `_factorWAD`. Only that exact selector + input is mocked; other
    ///      convertToAssets calls flow through normally.
    function _bumpSavUSDSharePrice(uint256 _factorWAD) internal {
        uint256 current = IERC4626(SAVUSD).convertToAssets(SHARES_QUOTED_BY_KERNEL);
        uint256 next = current * _factorWAD / 1e18;
        vm.mockCall(SAVUSD, abi.encodeWithSelector(IERC4626.convertToAssets.selector, SHARES_QUOTED_BY_KERNEL), abi.encode(next));
    }

    function _redeemAll(address _holder) internal {
        uint256 bal = IERC20(ST).balanceOf(_holder);
        if (bal == 0) return;
        vm.prank(_holder);
        IRoycoVaultTranche(ST).redeem(bal, _holder, _holder);
    }
}
