// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IPool } from "../../src/interfaces/aave/IPool.sol";
import { RoycoAccountantState } from "../../src/libraries/RoycoAccountantStorageLib.sol";
import { RoycoKernelState } from "../../src/libraries/RoycoKernelStorageLib.sol";
import { MainnetForkWithAaveTestBase } from "./base/MainnetForkWithAaveBaseTest.sol";

contract DeploymentsTest is MainnetForkWithAaveTestBase {
    constructor() {
        BETA_WAD = 1e18; // Same opportunities
    }

    function setUp() public {
        _setUpRoyco();
    }

    /// @notice Verifies senior tranche deployment parameters
    function test_SeniorTrancheDeployment() public {
        // Basic wiring
        assertTrue(address(ST) != address(0), "Senior tranche not deployed");
        // Kernel wiring
        assertEq(ST.kernel(), address(KERNEL), "ST KERNEL address mismatch");
        assertEq(ST.marketId(), MARKET_ID, "ST MARKET_ID mismatch");

        // Asset and metadata
        assertEq(address(ST.asset()), ETHEREUM_MAINNET_USDC_ADDRESS, "ST asset should be USDC");
        assertEq(ST.name(), SENIOR_TRANCH_NAME, "ST name mismatch");
        assertEq(ST.symbol(), SENIOR_TRANCH_SYMBOL, "ST symbol mismatch");

        // Initial NAV and totals
        assertEq(ST.totalSupply(), 0, "ST initial totalSupply should be 0");
        assertEq(ST.getRawNAV(), 0, "ST initial raw NAV should be 0");
        assertEq(ST.getEffectiveNAV(), 0, "ST initial effective NAV should be 0");
        assertEq(ST.totalAssets(), 0, "ST initial total ASSETS should be 0");
    }

    /// @notice Verifies junior tranche deployment parameters
    function test_JuniorTrancheDeployment() public {
        // Basic wiring
        assertTrue(address(JT) != address(0), "Junior tranche not deployed");
        // Kernel wiring
        assertEq(JT.kernel(), address(KERNEL), "JT KERNEL address mismatch");
        assertEq(JT.marketId(), MARKET_ID, "JT MARKET_ID mismatch");

        // Asset and metadata
        assertEq(address(JT.asset()), ETHEREUM_MAINNET_USDC_ADDRESS, "JT asset should be USDC");
        assertEq(JT.name(), JUNIOR_TRANCH_NAME, "JT name mismatch");
        assertEq(JT.symbol(), JUNIOR_TRANCH_SYMBOL, "JT symbol mismatch");

        // Initial NAV and totals
        assertEq(JT.totalSupply(), 0, "JT initial totalSupply should be 0");
        assertEq(JT.getRawNAV(), 0, "JT initial raw NAV should be 0");
        assertEq(JT.getEffectiveNAV(), 0, "JT initial effective NAV should be 0");
        assertEq(JT.totalAssets(), 0, "JT initial total ASSETS should be 0");
    }

    /// @notice Verifies KERNEL deployment parameters and wiring
    function test_KernelAndAccountantDeployment() public {
        // Basic wiring
        assertTrue(address(KERNEL) != address(0), "Kernel not deployed");

        RoycoKernelState memory kernelState = KERNEL.getState();
        RoycoAccountantState memory accountantState = ACCOUNTANT.getState();

        // Tranche wiring
        assertEq(kernelState.seniorTranche, address(ST), "Kernel ST mismatch");
        assertEq(kernelState.juniorTranche, address(JT), "Kernel JT mismatch");
        assertEq(kernelState.accountant, address(ACCOUNTANT), "Kernel accountant mismatch");
        assertEq(kernelState.protocolFeeRecipient, PROTOCOL_FEE_RECIPIENT_ADDRESS, "Kernel protocolFeeRecipient mismatch");

        // Coverage, beta, protocol fee configuration
        assertEq(accountantState.coverageWAD, COVERAGE_WAD, "Kernel coverageWAD mismatch");
        assertEq(accountantState.betaWAD, BETA_WAD, "BETA_WAD mismatch");
        assertEq(accountantState.protocolFeeWAD, PROTOCOL_FEE_WAD, "Kernel protocolFeeWAD mismatch");

        // RDM wiring
        assertEq(accountantState.rdm, address(RDM), "Kernel RDM mismatch");

        // Initial NAV / ASSETS via KERNEL view functions
        assertEq(KERNEL.getSTTotalEffectiveAssets(), 0, "Kernel ST total effective ASSETS should be 0");
        assertEq(KERNEL.getJTTotalEffectiveAssets(), 0, "Kernel JT total effective ASSETS should be 0");
        assertEq(KERNEL.getSTRawNAV(), 0, "Kernel ST raw NAV should be 0");
        assertEq(KERNEL.getJTRawNAV(), 0, "Kernel JT raw NAV should be 0");

        // Aave wiring: pool and AUSDC mapping must be consistent
        address expectedAToken = IPool(ETHEREUM_MAINNET_AAVE_V3_POOL_ADDRESS).getReserveAToken(ETHEREUM_MAINNET_USDC_ADDRESS);
        assertEq(expectedAToken, address(AUSDC), "AUSDC address should match Aave pool data");
    }
}
