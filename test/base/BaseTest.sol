// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { Vm } from "../../lib/forge-std/src/Vm.sol";
import { ERC20Mock } from "../../lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { RoycoFactory } from "../../src/RoycoFactory.sol";
import { RoycoAccountant } from "../../src/accountant/RoycoAccountant.sol";
import { RoycoRoles } from "../../src/auth/RoycoRoles.sol";
import { RoycoKernel } from "../../src/kernels/base/RoycoKernel.sol";
import { TrancheAssetClaims, TrancheType } from "../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toUint256 } from "../../src/libraries/Units.sol";
import { StaticCurveRDM } from "../../src/rdm/StaticCurveRDM.sol";
import { RoycoJT } from "../../src/tranches/RoycoJT.sol";
import { RoycoST } from "../../src/tranches/RoycoST.sol";
import { RoycoVaultTranche } from "../../src/tranches/RoycoVaultTranche.sol";
import { USDC_ERC4626_AaveV3JT_Kernel } from "../mock/USDC_ERC4626_AaveV3JT_Kernel.sol";
import { Assertions } from "./Assertions.sol";

contract BaseTest is Test, RoycoRoles, Assertions {
    struct TrancheState {
        NAV_UNIT rawNAV;
        NAV_UNIT effectiveNAV;
        TRANCHE_UNIT stAssetsClaim;
        TRANCHE_UNIT jtAssetsClaim;
        NAV_UNIT protocolFeeValue;
        uint256 totalShares;
    }

    // -----------------------------------------
    // Test Wallets
    // -----------------------------------------
    Vm.Wallet internal OWNER;
    address internal OWNER_ADDRESS;

    Vm.Wallet internal PAUSER;
    address internal PAUSER_ADDRESS;

    Vm.Wallet internal UPGRADER;
    address internal UPGRADER_ADDRESS;

    Vm.Wallet internal PROTOCOL_FEE_RECIPIENT;
    address internal PROTOCOL_FEE_RECIPIENT_ADDRESS;

    Vm.Wallet internal ALICE;
    Vm.Wallet internal BOB;
    Vm.Wallet internal CHARLIE;
    Vm.Wallet internal DAN;

    address internal ALICE_ADDRESS;
    address internal BOB_ADDRESS;
    address internal CHARLIE_ADDRESS;
    address internal DAN_ADDRESS;

    address[] internal providers;

    // -----------------------------------------
    // Assets
    // -----------------------------------------

    ERC20Mock internal MOCK_USDC;
    ERC20Mock internal MOCK_USDT;
    ERC20Mock internal MOCK_DAI;
    address[] internal ASSETS;

    // -----------------------------------------
    // Royco Deployments
    // -----------------------------------------

    // Initial Deployments
    RoycoFactory public FACTORY;
    StaticCurveRDM public RDM;
    RoycoST public ST_IMPL;
    RoycoJT public JT_IMPL;
    USDC_ERC4626_AaveV3JT_Kernel public USDC_ERC4626_AaveV3JT_KERNEL_IMPL;
    RoycoAccountant public ACCOUNTANT_IMPL;

    // Deployed Later in the concrete tests
    RoycoVaultTranche internal ST;
    RoycoVaultTranche internal JT;
    RoycoKernel internal KERNEL;
    RoycoAccountant internal ACCOUNTANT;
    bytes32 internal MARKET_ID;

    // -----------------------------------------
    // Royco Deployments Parameters
    // -----------------------------------------

    uint256 internal SEED_AMOUNT;
    string internal SENIOR_TRANCH_NAME = "Royco Senior Tranche";
    string internal SENIOR_TRANCH_SYMBOL = "RST";
    string internal JUNIOR_TRANCH_NAME = "Royco Junior Tranche";
    string internal JUNIOR_TRANCH_SYMBOL = "RJT";
    uint64 internal COVERAGE_WAD = 0.2e18; // 20% coverage
    uint96 internal BETA_WAD = 0; // Different opportunities
    uint64 internal PROTOCOL_FEE_WAD = 0.01e18; // 1% protocol fee

    /// -----------------------------------------
    /// Mainnet Fork Addresses
    /// -----------------------------------------
    uint256 internal forkId;
    address internal constant ETHEREUM_MAINNET_USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant ETHEREUM_MAINNET_AAVE_V3_POOL_ADDRESS = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    mapping(uint256 chainId => mapping(address asset => address aTokenAddress)) internal aTokenAddresses;

    constructor() {
        aTokenAddresses[1][ETHEREUM_MAINNET_USDC_ADDRESS] = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    }

    modifier prankModifier(address _pranker) {
        vm.startPrank(_pranker);
        _;
        vm.stopPrank();
    }

    function _setUpRoyco() internal virtual {
        _setupFork();
        _setupWallets();
        _setupAssets(10_000_000_000);

        // Deploy RDM
        RDM = new StaticCurveRDM();
        vm.label(address(RDM), "RDM");

        // Deploy tranche implementations
        ST_IMPL = new RoycoST();
        JT_IMPL = new RoycoJT();
        vm.label(address(ST_IMPL), "STImpl");
        vm.label(address(JT_IMPL), "JTImpl");

        // Deploy accountant implementation
        ACCOUNTANT_IMPL = new RoycoAccountant();
        vm.label(address(ACCOUNTANT_IMPL), "AccountantImpl");

        // Deploy KERNEL implementation
        USDC_ERC4626_AaveV3JT_KERNEL_IMPL = new USDC_ERC4626_AaveV3JT_Kernel();
        vm.label(address(USDC_ERC4626_AaveV3JT_KERNEL_IMPL), "KernelImpl");

        // Deploy FACTORY
        FACTORY = new RoycoFactory(OWNER_ADDRESS);
        vm.label(address(FACTORY), "Factory");

        _setupFactoryAuth();
    }

    function _setupFork() internal {
        (uint256 forkBlock, string memory forkRpcUrl) = _forkConfiguration();
        if (bytes(forkRpcUrl).length > 0) {
            require(forkBlock != 0, "Fork block is required");
            vm.createSelectFork(forkRpcUrl, forkBlock);
        }
    }

    function _setupAssets(uint256 _seedAmount) internal {
        MOCK_USDC = new ERC20Mock();
        MOCK_USDC.mint(OWNER_ADDRESS, _seedAmount * (10 ** 18));
        MOCK_USDC.mint(ALICE_ADDRESS, _seedAmount * (10 ** 18));
        MOCK_USDC.mint(BOB_ADDRESS, _seedAmount * (10 ** 18));
        ASSETS.push(address(MOCK_USDC));

        MOCK_USDT = new ERC20Mock();
        MOCK_USDT.mint(OWNER_ADDRESS, _seedAmount * (10 ** 18));
        MOCK_USDT.mint(ALICE_ADDRESS, _seedAmount * (10 ** 18));
        MOCK_USDT.mint(BOB_ADDRESS, _seedAmount * (10 ** 18));
        ASSETS.push(address(MOCK_USDT));

        MOCK_DAI = new ERC20Mock();
        MOCK_DAI.mint(OWNER_ADDRESS, _seedAmount * (10 ** 18));
        MOCK_DAI.mint(ALICE_ADDRESS, _seedAmount * (10 ** 18));
        MOCK_DAI.mint(BOB_ADDRESS, _seedAmount * (10 ** 18));
        ASSETS.push(address(MOCK_DAI));
    }

    function _setupWallets() internal {
        // Init wallets with 1000 ETH each
        OWNER = _initWallet("OWNER", 1000 ether);
        PAUSER = _initWallet("PAUSER", 1000 ether);
        UPGRADER = _initWallet("UPGRADER", 1000 ether);
        ALICE = _initWallet("ALICE", 1000 ether);
        BOB = _initWallet("BOB", 1000 ether);
        CHARLIE = _initWallet("CHARLIE", 1000 ether);
        DAN = _initWallet("DAN", 1000 ether);
        PROTOCOL_FEE_RECIPIENT = _initWallet("PROTOCOL_FEE_RECIPIENT", 1000 ether);

        // Set addresses
        OWNER_ADDRESS = OWNER.addr;
        PAUSER_ADDRESS = PAUSER.addr;
        UPGRADER_ADDRESS = UPGRADER.addr;
        ALICE_ADDRESS = ALICE.addr;
        BOB_ADDRESS = BOB.addr;
        CHARLIE_ADDRESS = CHARLIE.addr;
        DAN_ADDRESS = DAN.addr;
        PROTOCOL_FEE_RECIPIENT_ADDRESS = PROTOCOL_FEE_RECIPIENT.addr;

        providers.push(ALICE_ADDRESS);
        providers.push(BOB_ADDRESS);
        providers.push(CHARLIE_ADDRESS);
        providers.push(DAN_ADDRESS);
    }

    function _setDeployedMarket(RoycoVaultTranche _st, RoycoVaultTranche _jt, RoycoKernel _kernel, RoycoAccountant _accountant, bytes32 _marketId) internal {
        ST = _st;
        JT = _jt;
        KERNEL = _kernel;
        ACCOUNTANT = _accountant;
        MARKET_ID = _marketId;

        vm.label(address(ST), "ST");
        vm.label(address(JT), "JT");
        vm.label(address(KERNEL), "Kernel");
        vm.label(address(ACCOUNTANT), "Accountant");
    }

    function _initWallet(string memory _name, uint256 _amount) internal returns (Vm.Wallet memory) {
        Vm.Wallet memory wallet = vm.createWallet(_name);
        vm.label(wallet.addr, _name);
        vm.deal(wallet.addr, _amount);
        return wallet;
    }

    /// @notice Sets up roles for a tranche
    /// @param _providers The providers addresses
    /// @param _pauser The pauser address
    /// @param _upgrader The upgrader address
    function _setUpTrancheRoles(address[] memory _providers, address _pauser, address _upgrader) internal prankModifier(OWNER_ADDRESS) {
        FACTORY.grantRole(RoycoRoles.PAUSER_ROLE, _pauser, 0);
        FACTORY.grantRole(RoycoRoles.UPGRADER_ROLE, _upgrader, 0);
        for (uint256 i = 0; i < _providers.length; i++) {
            FACTORY.grantRole(RoycoRoles.DEPOSIT_ROLE, _providers[i], 0);
            FACTORY.grantRole(RoycoRoles.REDEEM_ROLE, _providers[i], 0);
        }
    }

    /// @notice Sets up roles for a kernel
    /// @param _kernelAdmin The kernel admin address
    function _setUpKernelRoles(address _kernelAdmin) internal prankModifier(OWNER_ADDRESS) {
        FACTORY.grantRole(RoycoRoles.KERNEL_ADMIN_ROLE, _kernelAdmin, 0);
    }

    /// @notice Sets up roles for the factory
    function _setupFactoryAuth() internal prankModifier(OWNER_ADDRESS) {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = RoycoFactory.deployMarket.selector;
        FACTORY.setTargetFunctionRole(address(FACTORY), selectors, type(uint64).max);
    }

    /// @notice Generates a provider address
    /// @param index The index of the provider
    /// @return provider The provider address
    function _generateProvider(RoycoVaultTranche _tranche, uint256 index) internal virtual prankModifier(OWNER_ADDRESS) returns (Vm.Wallet memory provider) {
        // Generate a unique wallet
        string memory providerName = string(abi.encodePacked("PROVIDER", vm.toString(index)));
        provider = _initWallet(providerName, 10_000_000e6);

        // Grant Permissions
        FACTORY.grantRole(RoycoRoles.DEPOSIT_ROLE, provider.addr, 0);
        FACTORY.grantRole(RoycoRoles.REDEEM_ROLE, provider.addr, 0);

        return provider;
    }

    /// @notice Verifies the preview NAVs of the senior and junior tranches
    /// @param _stState The state of the senior tranche
    /// @param _jtState The state of the junior tranche
    function _verifyPreviewNAVs(
        TrancheState memory _stState,
        TrancheState memory _jtState,
        TRANCHE_UNIT _maxAbsDeltaTrancheUnits,
        NAV_UNIT _maxAbsDeltaNAV
    )
        internal
    {
        assertTrue(address(ST) != address(0), "Senior tranche is not deployed");
        assertTrue(address(JT) != address(0), "Junior tranche is not deployed");

        assertApproxEqAbs(ST.getRawNAV(), _stState.rawNAV, toUint256(_maxAbsDeltaNAV), "ST raw NAV mismatch");
        TrancheAssetClaims memory stClaims = ST.totalAssets();
        assertApproxEqAbs(stClaims.effectiveNAV, _stState.effectiveNAV, toUint256(_maxAbsDeltaNAV), "ST effective NAV mismatch");
        assertApproxEqAbs(stClaims.stAssets, _stState.stAssetsClaim, toUint256(_maxAbsDeltaTrancheUnits), "ST st assets claim mismatch");
        assertApproxEqAbs(stClaims.jtAssets, _stState.jtAssetsClaim, toUint256(_maxAbsDeltaTrancheUnits), "ST jt assets claim mismatch");

        assertApproxEqAbs(JT.getRawNAV(), _jtState.rawNAV, toUint256(_maxAbsDeltaNAV), "JT raw NAV mismatch");
        TrancheAssetClaims memory jtClaims = JT.totalAssets();
        assertApproxEqAbs(jtClaims.effectiveNAV, _jtState.effectiveNAV, toUint256(_maxAbsDeltaNAV), "JT effective NAV mismatch");
        assertApproxEqAbs(jtClaims.stAssets, _jtState.stAssetsClaim, toUint256(_maxAbsDeltaTrancheUnits), "JT st assets claim mismatch");
        assertApproxEqAbs(jtClaims.jtAssets, _jtState.jtAssetsClaim, toUint256(_maxAbsDeltaTrancheUnits), "JT jt assets claim mismatch");
    }

    /// @notice Verifies the fee taken by the senior and junior tranches
    /// @param _stState The state of the senior tranche
    /// @param _jtState The state of the junior tranche
    /// @param _feeRecipient The address of the fee recipient
    function _verifyFeeTaken(TrancheState storage _stState, TrancheState storage _jtState, address _feeRecipient) internal {
        uint256 seniorFeeShares = ST.balanceOf(_feeRecipient);
        NAV_UNIT seniorFeeSharesValue = ST.convertToAssets(seniorFeeShares).effectiveNAV;
        assertEq(seniorFeeSharesValue, _stState.protocolFeeValue, "ST protocol fee value mismatch");

        uint256 juniorFeeShares = JT.balanceOf(_feeRecipient);
        NAV_UNIT juniorFeeSharesValue = JT.convertToAssets(juniorFeeShares).effectiveNAV;
        assertEq(juniorFeeSharesValue, _jtState.protocolFeeValue, "JT protocol fee value mismatch");
    }

    /// @notice Updates the state of the senior and junior tranches on a deposit
    /// @param _trancheState The state of the tranche
    /// @param _assets The amount of ASSETS deposited
    /// @param _assetsValue The value of the ASSETS deposited
    /// @param _shares The amount of shares deposited
    /// @param _trancheType The type of tranche
    function _updateOnDeposit(
        TrancheState storage _trancheState,
        TRANCHE_UNIT _assets,
        NAV_UNIT _assetsValue,
        uint256 _shares,
        TrancheType _trancheType
    )
        internal
    {
        _trancheState.rawNAV = _trancheState.rawNAV + _assetsValue;
        _trancheState.effectiveNAV = _trancheState.effectiveNAV + _assetsValue;
        if (_trancheType == TrancheType.SENIOR) {
            _trancheState.stAssetsClaim = _trancheState.stAssetsClaim + _assets;
        } else {
            _trancheState.jtAssetsClaim = _trancheState.jtAssetsClaim + _assets;
        }
        _trancheState.totalShares += _shares;
    }

    /// @notice Updates the state of the senior and junior tranches on a withdrawal
    /// @param _trancheState The state of the tranche
    /// @param _stAssetsWithdrawn The amount of ST assets withdrawn
    /// @param _jtAssetsWithdrawn The amount of JT assets withdrawn
    /// @param _totalAssetsValueWithdrawn The value of the ASSETS withdrawn
    /// @param _shares The amount of shares withdrawn
    function _updateOnWithdraw(
        TrancheState storage _trancheState,
        TRANCHE_UNIT _stAssetsWithdrawn,
        TRANCHE_UNIT _jtAssetsWithdrawn,
        NAV_UNIT _totalAssetsValueWithdrawn,
        uint256 _shares
    )
        internal
    {
        _trancheState.rawNAV = _trancheState.rawNAV - _totalAssetsValueWithdrawn;
        _trancheState.effectiveNAV = _trancheState.effectiveNAV - _totalAssetsValueWithdrawn;
        _trancheState.stAssetsClaim = _trancheState.stAssetsClaim - _stAssetsWithdrawn;
        _trancheState.jtAssetsClaim = _trancheState.jtAssetsClaim - _jtAssetsWithdrawn;
        _trancheState.totalShares = _trancheState.totalShares - _shares;
    }

    /// @notice Converts the specified assets denominated in JT's tranche units to the kernel's NAV units
    /// @param _assets The assets denominated in JT's tranche units to convert to the kernel's NAV units
    /// @return value The specified assets denominated in JT's tranche units converted to the kernel's NAV units
    function _toJTValue(TRANCHE_UNIT _assets) internal view returns (NAV_UNIT) {
        return KERNEL.jtConvertTrancheUnitsToNAVUnits(_assets);
    }

    /// @notice Converts the specified assets denominated in ST's tranche units to the kernel's NAV units
    /// @param _assets The assets denominated in ST's tranche units to convert to the kernel's NAV units
    /// @return value The specified assets denominated in ST's tranche units converted to the kernel's NAV units
    function _toSTValue(TRANCHE_UNIT _assets) internal view returns (NAV_UNIT) {
        return KERNEL.stConvertTrancheUnitsToNAVUnits(_assets);
    }

    /// @notice Deploys a KERNEL using ERC1967 proxy
    /// @param _kernelImplementation The implementation address
    /// @param _kernelInitData The initialization data
    /// @return KERNELProxy The deployed proxy address
    function _deployKernel(address _kernelImplementation, bytes memory _kernelInitData) internal returns (address KERNELProxy) {
        KERNELProxy = address(new ERC1967Proxy(_kernelImplementation, _kernelInitData));
    }

    /// @notice Returns the fork configuration
    /// @return forkBlock The fork block
    /// @return forkRpcUrl The fork RPC URL
    function _forkConfiguration() internal virtual returns (uint256 forkBlock, string memory forkRpcUrl) {
        return (0, "");
    }
}
