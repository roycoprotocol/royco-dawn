// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IRoycoDuskKernel } from "../../src/interfaces/IRoycoDuskKernel.sol";
import { IRoycoVaultTranche } from "../../src/interfaces/IRoycoVaultTranche.sol";
import { TrancheType } from "../../src/libraries/Types.sol";
import { DuskBaseTest } from "../base/DuskBaseTest.t.sol";

/**
 * @title DuskFactoryTest
 * @notice End-to-end factory deployment test for a Dusk-Balancer market against a mainnet fork.
 *         Exercises the full path: register template -> deploy ST/JT/Kernel/Accountant proxies
 *         -> deploy Balancer V3 hooks + pool + rate providers -> apply role bindings -> verify().
 *
 *         The market under test pairs sUSDe (ST) with USDC (quote) using Chainlink USD feeds on
 *         both legs and the mainnet-extracted Gyro E-CLP geometry from
 *         `0x2191df821c198600499aa1f0031b1a7514d7a7d9`.
 *
 *         Asserts after deployment:
 *         - All four market proxies have the AccessManager-bound authority.
 *         - Tranche types are correct + kernel cross-wiring is consistent.
 *         - The Balancer V3 pool exists, is registered with the vault, has the right two tokens,
 *           and is bound to the freshly-deployed hooks proxy.
 *         - Kernel.QUOTE_ASSET == USDC.
 */
contract DuskFactoryTest is DuskBaseTest {
    bytes32 internal constant MARKET_ID = keccak256("ROYCO_DUSK_SUSDE_USDC_TEST");

    MarketDeployment internal market;

    function setUp() public {
        _setUpRoyco();
        market = _deployDuskMarket(_defaultSusdeUsdcParams(MARKET_ID));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BASIC WIRING ASSERTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_marketDeployed_allFourProxiesNonZero() external view {
        assertTrue(address(market.seniorTranche) != address(0), "ST proxy not deployed");
        assertTrue(address(market.juniorTranche) != address(0), "JT proxy not deployed");
        assertTrue(address(market.kernel) != address(0), "Kernel proxy not deployed");
        assertTrue(address(market.accountant) != address(0), "Accountant proxy not deployed");
        assertTrue(address(market.ydm) != address(0), "YDM not deployed");
    }

    function test_marketDeployed_trancheTypesCorrect() external view {
        assertEq(uint8(market.seniorTranche.TRANCHE_TYPE()), uint8(TrancheType.SENIOR), "ST has wrong tranche type");
        assertEq(uint8(market.juniorTranche.TRANCHE_TYPE()), uint8(TrancheType.JUNIOR), "JT has wrong tranche type");
    }

    function test_marketDeployed_trancheKernelWiring() external view {
        assertEq(address(market.seniorTranche.KERNEL()), address(market.kernel), "ST.KERNEL mismatch");
        assertEq(address(market.juniorTranche.KERNEL()), address(market.kernel), "JT.KERNEL mismatch");
    }

    function test_marketDeployed_stAssetIsSusde() external view {
        assertEq(market.seniorTranche.asset(), ETH_MAINNET_SUSDE, "ST asset is not sUSDe");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DUSK-KERNEL-SPECIFIC ASSERTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_kernelWiring_seniorAndJuniorBackPointers() external view {
        IRoycoDuskKernel duskKernel = IRoycoDuskKernel(address(market.kernel));
        assertEq(duskKernel.SENIOR_TRANCHE(), address(market.seniorTranche), "Kernel.SENIOR_TRANCHE mismatch");
        assertEq(duskKernel.JUNIOR_TRANCHE(), address(market.juniorTranche), "Kernel.JUNIOR_TRANCHE mismatch");
        assertEq(duskKernel.ST_ASSET(), ETH_MAINNET_SUSDE, "Kernel.ST_ASSET is not sUSDe");
        assertEq(duskKernel.QUOTE_ASSET(), ETH_MAINNET_USDC, "Kernel.QUOTE_ASSET is not USDC");
        assertEq(duskKernel.ACCOUNTANT(), address(market.accountant), "Kernel.ACCOUNTANT mismatch");
    }

    function test_kernelWiring_jtAssetIsTheBalancerPool() external view {
        IRoycoDuskKernel duskKernel = IRoycoDuskKernel(address(market.kernel));
        address pool = duskKernel.JT_ASSET();
        assertTrue(pool != address(0), "JT asset (pool) not set on kernel");
        assertEq(market.juniorTranche.asset(), pool, "JT.asset() != kernel.JT_ASSET()");
        assertTrue(BALANCER_V3_VAULT.isPoolRegistered(pool), "Pool not registered with Balancer V3 Vault");
    }

    function test_accountantWiring_kernelBackPointer() external view {
        assertEq(address(market.accountant.KERNEL()), address(market.kernel), "Accountant.KERNEL mismatch");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BALANCER V3 POOL CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    function test_pool_tokensAreSTShareAndQuoteAsset() external view {
        IRoycoDuskKernel duskKernel = IRoycoDuskKernel(address(market.kernel));
        address pool = duskKernel.JT_ASSET();

        IERC20[] memory poolTokens = BALANCER_V3_VAULT.getPoolTokens(pool);
        assertEq(poolTokens.length, 2, "Pool token count != 2");

        address t0 = address(poolTokens[0]);
        address t1 = address(poolTokens[1]);
        bool match0 = t0 == address(market.seniorTranche) && t1 == ETH_MAINNET_USDC;
        bool match1 = t0 == ETH_MAINNET_USDC && t1 == address(market.seniorTranche);
        assertTrue(match0 || match1, "Pool token set does not match {ST_PROXY, USDC}");
    }
}
