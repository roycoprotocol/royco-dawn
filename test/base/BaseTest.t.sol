// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { Vm } from "../../lib/forge-std/src/Vm.sol";
import { ERC20Mock } from "../../lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { DeployScript } from "../../script/Deploy.s.sol";
import { ExtraRoles } from "../../script/config/ExtraRoles.sol";
import { RoycoAccountant } from "../../src/accountant/RoycoAccountant.sol";
import { RolesConfiguration, RoycoFactory } from "../../src/factory/RoycoFactory.sol";
import { IRoycoAccountant } from "../../src/interfaces/IRoycoAccountant.sol";
import { IRoycoFactory } from "../../src/interfaces/IRoycoFactory.sol";
import { IRoycoKernel } from "../../src/interfaces/IRoycoKernel.sol";
import { IRoycoVaultTranche } from "../../src/interfaces/IRoycoVaultTranche.sol";
import { IYDM } from "../../src/interfaces/IYDM.sol";
import { AssetClaims, TrancheType } from "../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toUint256 } from "../../src/libraries/Units.sol";
import { RoycoJuniorTranche } from "../../src/tranches/RoycoJuniorTranche.sol";
import { RoycoSeniorTranche } from "../../src/tranches/RoycoSeniorTranche.sol";
import { Assertions } from "./Assertions.t.sol";

abstract contract BaseTest is Test, RolesConfiguration, Assertions, ExtraRoles {
    uint256 internal constant BPS = 0.0001e18;

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

    // Role-specific wallets
    Vm.Wallet internal PAUSER;
    address internal PAUSER_ADDRESS;

    Vm.Wallet internal UNPAUSER;
    address internal UNPAUSER_ADDRESS;

    Vm.Wallet internal UPGRADER;
    address internal UPGRADER_ADDRESS;

    Vm.Wallet internal SYNC_ROLE_HOLDER;
    address internal SYNC_ROLE_ADDRESS;

    Vm.Wallet internal KERNEL_ADMIN;
    address internal KERNEL_ADMIN_ADDRESS;

    Vm.Wallet internal ACCOUNTANT_ADMIN;
    address internal ACCOUNTANT_ADMIN_ADDRESS;

    Vm.Wallet internal PROTOCOL_FEE_SETTER;
    address internal PROTOCOL_FEE_SETTER_ADDRESS;

    Vm.Wallet internal ORACLE_QUOTER_ADMIN;
    address internal ORACLE_QUOTER_ADMIN_ADDRESS;

    Vm.Wallet internal LP_ROLE_ADMIN;
    address internal LP_ROLE_ADMIN_ADDRESS;

    Vm.Wallet internal ROLE_GUARDIAN;
    address internal ROLE_GUARDIAN_ADDRESS;

    Vm.Wallet internal PROTOCOL_FEE_RECIPIENT;
    address internal PROTOCOL_FEE_RECIPIENT_ADDRESS;

    Vm.Wallet internal DEPLOYER;
    address internal DEPLOYER_ADDRESS;

    Vm.Wallet internal DEPLOYER_ADMIN;
    address internal DEPLOYER_ADMIN_ADDRESS;

    Vm.Wallet internal TRANSFER_AGENT;
    address internal TRANSFER_AGENT_ADDRESS;

    // ST-only providers
    Vm.Wallet internal ST_ALICE;
    Vm.Wallet internal ST_BOB;
    Vm.Wallet internal ST_CHARLIE;
    Vm.Wallet internal ST_DAN;
    address internal ST_ALICE_ADDRESS;
    address internal ST_BOB_ADDRESS;
    address internal ST_CHARLIE_ADDRESS;
    address internal ST_DAN_ADDRESS;

    // JT-only providers
    Vm.Wallet internal JT_ALICE;
    Vm.Wallet internal JT_BOB;
    Vm.Wallet internal JT_CHARLIE;
    Vm.Wallet internal JT_DAN;
    address internal JT_ALICE_ADDRESS;
    address internal JT_BOB_ADDRESS;
    address internal JT_CHARLIE_ADDRESS;
    address internal JT_DAN_ADDRESS;

    // Backward-compat aliases (ALICE=JT, BOB=ST)
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

    // Deploy Script
    DeployScript internal DEPLOY_SCRIPT;

    // Deployments
    RoycoFactory internal FACTORY;
    IYDM internal YDM;
    RoycoSeniorTranche public ST_IMPL;
    RoycoJuniorTranche internal JT_IMPL;
    RoycoAccountant internal ACCOUNTANT_IMPL;
    address internal KERNEL_IMPL;
    IRoycoVaultTranche internal ST;
    IRoycoVaultTranche internal JT;
    IRoycoKernel internal KERNEL;
    IRoycoAccountant internal ACCOUNTANT;

    // -----------------------------------------
    // Royco Deployments Parameters
    // -----------------------------------------

    uint256 internal SEED_AMOUNT;
    string internal SENIOR_TRANCHE_NAME = "Royco Senior Tranche";
    string internal SENIOR_TRANCHE_SYMBOL = "RST";
    string internal JUNIOR_TRANCHE_NAME = "Royco Junior Tranche";
    string internal JUNIOR_TRANCHE_SYMBOL = "RJT";
    uint64 internal COVERAGE_WAD = 0.2e18; // 20% coverage
    uint96 internal BETA_WAD = 0; // Different opportunities
    uint64 internal ST_PROTOCOL_FEE_WAD = 0.1e18; // 10% protocol fee
    uint64 internal JT_PROTOCOL_FEE_WAD = 0.1e18; // 10% protocol fee
    uint256 internal LIQUIDATION_UTILIZATION_WAD = 6.4667e18; // Liquidation utilization threshold
    uint24 internal FIXED_TERM_DURATION_SECONDS = 2 weeks; // 2 weeks in seconds
    NAV_UNIT internal DUST_TOLERANCE = toNAVUnits(uint256(1));

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

        // Deploy the deploy script
        DEPLOY_SCRIPT = new DeployScript();
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
        MOCK_USDC.mint(ST_ALICE_ADDRESS, _seedAmount * (10 ** 18));
        MOCK_USDC.mint(JT_ALICE_ADDRESS, _seedAmount * (10 ** 18));
        MOCK_USDC.mint(ST_BOB_ADDRESS, _seedAmount * (10 ** 18));
        MOCK_USDC.mint(JT_BOB_ADDRESS, _seedAmount * (10 ** 18));
        ASSETS.push(address(MOCK_USDC));

        MOCK_USDT = new ERC20Mock();
        MOCK_USDT.mint(OWNER_ADDRESS, _seedAmount * (10 ** 18));
        MOCK_USDT.mint(ST_ALICE_ADDRESS, _seedAmount * (10 ** 18));
        MOCK_USDT.mint(JT_ALICE_ADDRESS, _seedAmount * (10 ** 18));
        MOCK_USDT.mint(ST_BOB_ADDRESS, _seedAmount * (10 ** 18));
        MOCK_USDT.mint(JT_BOB_ADDRESS, _seedAmount * (10 ** 18));
        ASSETS.push(address(MOCK_USDT));

        MOCK_DAI = new ERC20Mock();
        MOCK_DAI.mint(OWNER_ADDRESS, _seedAmount * (10 ** 18));
        MOCK_DAI.mint(ST_ALICE_ADDRESS, _seedAmount * (10 ** 18));
        MOCK_DAI.mint(JT_ALICE_ADDRESS, _seedAmount * (10 ** 18));
        MOCK_DAI.mint(ST_BOB_ADDRESS, _seedAmount * (10 ** 18));
        MOCK_DAI.mint(JT_BOB_ADDRESS, _seedAmount * (10 ** 18));
        ASSETS.push(address(MOCK_DAI));
    }

    function _setupWallets() internal {
        // Admin wallet
        OWNER = _initWallet("OWNER", 1000 ether);
        OWNER_ADDRESS = OWNER.addr;

        // Role-specific wallets
        PAUSER = _initWallet("PAUSER", 1000 ether);
        PAUSER_ADDRESS = PAUSER.addr;

        UNPAUSER = _initWallet("UNPAUSER", 1000 ether);
        UNPAUSER_ADDRESS = UNPAUSER.addr;

        UPGRADER = _initWallet("UPGRADER", 1000 ether);
        UPGRADER_ADDRESS = UPGRADER.addr;

        SYNC_ROLE_HOLDER = _initWallet("SYNC_ROLE_HOLDER", 1000 ether);
        SYNC_ROLE_ADDRESS = SYNC_ROLE_HOLDER.addr;

        KERNEL_ADMIN = _initWallet("KERNEL_ADMIN", 1000 ether);
        KERNEL_ADMIN_ADDRESS = KERNEL_ADMIN.addr;

        ACCOUNTANT_ADMIN = _initWallet("ACCOUNTANT_ADMIN", 1000 ether);
        ACCOUNTANT_ADMIN_ADDRESS = ACCOUNTANT_ADMIN.addr;

        PROTOCOL_FEE_SETTER = _initWallet("PROTOCOL_FEE_SETTER", 1000 ether);
        PROTOCOL_FEE_SETTER_ADDRESS = PROTOCOL_FEE_SETTER.addr;

        ORACLE_QUOTER_ADMIN = _initWallet("ORACLE_QUOTER_ADMIN", 1000 ether);
        ORACLE_QUOTER_ADMIN_ADDRESS = ORACLE_QUOTER_ADMIN.addr;

        LP_ROLE_ADMIN = _initWallet("LP_ROLE_ADMIN", 1000 ether);
        LP_ROLE_ADMIN_ADDRESS = LP_ROLE_ADMIN.addr;

        ROLE_GUARDIAN = _initWallet("ROLE_GUARDIAN", 1000 ether);
        ROLE_GUARDIAN_ADDRESS = ROLE_GUARDIAN.addr;

        PROTOCOL_FEE_RECIPIENT = _initWallet("PROTOCOL_FEE_RECIPIENT", 1000 ether);
        PROTOCOL_FEE_RECIPIENT_ADDRESS = PROTOCOL_FEE_RECIPIENT.addr;

        // Deployer wallets (for factory deployment)
        DEPLOYER = _initWallet("DEPLOYER", 1000 ether);
        DEPLOYER_ADDRESS = DEPLOYER.addr;

        DEPLOYER_ADMIN = _initWallet("DEPLOYER_ADMIN", 1000 ether);
        DEPLOYER_ADMIN_ADDRESS = DEPLOYER_ADMIN.addr;

        // Transfer agent wallet (for compliance operations)
        TRANSFER_AGENT = _initWallet("TRANSFER_AGENT", 1000 ether);
        TRANSFER_AGENT_ADDRESS = TRANSFER_AGENT.addr;
    }

    function _setupProviders() internal {
        // ST-only providers
        ST_ALICE = _generateProvider("ST_ALICE", ST_LP_ROLE);
        ST_BOB = _generateProvider("ST_BOB", ST_LP_ROLE);
        ST_CHARLIE = _generateProvider("ST_CHARLIE", ST_LP_ROLE);
        ST_DAN = _generateProvider("ST_DAN", ST_LP_ROLE);

        ST_ALICE_ADDRESS = ST_ALICE.addr;
        ST_BOB_ADDRESS = ST_BOB.addr;
        ST_CHARLIE_ADDRESS = ST_CHARLIE.addr;
        ST_DAN_ADDRESS = ST_DAN.addr;

        // JT-only providers
        JT_ALICE = _generateProvider("JT_ALICE", JT_LP_ROLE);
        JT_BOB = _generateProvider("JT_BOB", JT_LP_ROLE);
        JT_CHARLIE = _generateProvider("JT_CHARLIE", JT_LP_ROLE);
        JT_DAN = _generateProvider("JT_DAN", JT_LP_ROLE);

        JT_ALICE_ADDRESS = JT_ALICE.addr;
        JT_BOB_ADDRESS = JT_BOB.addr;
        JT_CHARLIE_ADDRESS = JT_CHARLIE.addr;
        JT_DAN_ADDRESS = JT_DAN.addr;

        // Backward-compat aliases (ALICE=JT, BOB=ST)
        ALICE = JT_ALICE;
        ALICE_ADDRESS = JT_ALICE_ADDRESS;
        BOB = ST_BOB;
        BOB_ADDRESS = ST_BOB_ADDRESS;
        CHARLIE = JT_CHARLIE;
        CHARLIE_ADDRESS = JT_CHARLIE_ADDRESS;
        DAN = JT_DAN;
        DAN_ADDRESS = JT_DAN_ADDRESS;

        // All unique provider addresses
        providers.push(ST_ALICE_ADDRESS);
        providers.push(JT_ALICE_ADDRESS);
        providers.push(ST_BOB_ADDRESS);
        providers.push(JT_BOB_ADDRESS);
        providers.push(ST_CHARLIE_ADDRESS);
        providers.push(JT_CHARLIE_ADDRESS);
        providers.push(ST_DAN_ADDRESS);
        providers.push(JT_DAN_ADDRESS);
    }

    function _setDeployedMarket(DeployScript.DeploymentResult memory _deploymentResult) internal {
        ST_IMPL = _deploymentResult.stTrancheImplementation;
        vm.label(address(ST_IMPL), "STImpl");

        JT_IMPL = _deploymentResult.jtTrancheImplementation;
        vm.label(address(JT_IMPL), "JTImpl");

        ACCOUNTANT_IMPL = _deploymentResult.accountantImplementation;
        vm.label(address(ACCOUNTANT_IMPL), "AccountantImpl");

        KERNEL_IMPL = _deploymentResult.kernelImplementation;
        vm.label(address(KERNEL_IMPL), "KernelImpl");

        YDM = _deploymentResult.ydm;
        vm.label(address(YDM), "YDM");

        ST = _deploymentResult.seniorTranche;
        vm.label(address(ST), "ST");

        JT = _deploymentResult.juniorTranche;
        vm.label(address(JT), "JT");

        ACCOUNTANT = _deploymentResult.accountant;
        vm.label(address(ACCOUNTANT), "Accountant");

        KERNEL = _deploymentResult.kernel;
        vm.label(address(KERNEL), "Kernel");

        FACTORY = _deploymentResult.factory;
        vm.label(address(FACTORY), "Factory");

        _wireExtraRoles();
    }

    /// @dev Wires roles that live in `ExtraRoles` and are intentionally NOT passed through
    ///      `factory.initialize` (canonical `RolesConfiguration.getRoleConfig` doesn't know
    ///      them, so including them in the init array would revert). Pranks FNDN (the
    ///      admin-role holder): `OWNER_ADDRESS` for a fresh in-memory deploy, `ROOT_MULTISIG`
    ///      when the test forks a chain where the factory is already on-chain.
    function _wireExtraRoles() internal {
        // Live-chain factory admin (matches MarketDeploymentConfig.ROOT_MULTISIG).
        address fndn;
        (bool ownerIsAdmin,) = FACTORY.hasRole(0, OWNER_ADDRESS);
        if (ownerIsAdmin) {
            fndn = OWNER_ADDRESS;
        } else {
            fndn = 0x7c405bbD131e42af506d14e752f2e59B19D49997; // ROOT_MULTISIG
        }

        // Standard 24h delay matches the canonical UNPAUSER config (and what `ApplySecurityMigration`
        // applies in production). The `_scheduleAndExecuteUnpause` test helper relies on a non-zero
        // delay — OZ AccessManager.schedule reverts when the caller's `setback == 0`.
        (bool unpauserHasRole,) = FACTORY.hasRole(ADMIN_UNPAUSER_ROLE, UNPAUSER_ADDRESS);
        if (!unpauserHasRole) {
            vm.prank(fndn);
            FACTORY.grantRole(ADMIN_UNPAUSER_ROLE, UNPAUSER_ADDRESS, 1 days);
        }
    }

    function _initWallet(string memory _name, uint256 _amount) internal returns (Vm.Wallet memory) {
        Vm.Wallet memory wallet = vm.createWallet(_name);
        vm.label(wallet.addr, _name);
        vm.deal(wallet.addr, _amount);
        return wallet;
    }

    /// @notice Generates a provider address
    /// @param _name The name of the provider
    /// @return provider The provider address
    function _generateProvider(string memory _name, uint64 _role) internal virtual returns (Vm.Wallet memory provider) {
        provider = _initWallet(_name, 10_000_000e6);

        vm.prank(LP_ROLE_ADMIN_ADDRESS);
        FACTORY.grantRole(_role, provider.addr, 0);

        return provider;
    }

    /// @notice Generates a provider address with both ST and JT LP roles
    /// @param index The index of the provider
    /// @return provider The provider address
    function _generateProvider(uint256 index) internal virtual returns (Vm.Wallet memory provider) {
        string memory providerName = string(abi.encodePacked("PROVIDER", vm.toString(index)));
        provider = _initWallet(providerName, 10_000_000e6);

        vm.startPrank(LP_ROLE_ADMIN_ADDRESS);
        FACTORY.grantRole(ST_LP_ROLE, provider.addr, 0);
        FACTORY.grantRole(JT_LP_ROLE, provider.addr, 0);
        vm.stopPrank();

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
        view
    {
        assertTrue(address(ST) != address(0), "Senior tranche is not deployed");
        assertTrue(address(JT) != address(0), "Junior tranche is not deployed");

        assertApproxEqAbs(ST.getRawNAV(), _stState.rawNAV, toUint256(_maxAbsDeltaNAV), "ST raw NAV mismatch");
        AssetClaims memory stClaims = ST.totalAssets();
        assertApproxEqAbs(stClaims.nav, _stState.effectiveNAV, toUint256(_maxAbsDeltaNAV), "ST effective NAV mismatch");
        assertApproxEqAbs(stClaims.stAssets, _stState.stAssetsClaim, toUint256(_maxAbsDeltaTrancheUnits), "ST st assets claim mismatch");
        assertApproxEqAbs(stClaims.jtAssets, _stState.jtAssetsClaim, toUint256(_maxAbsDeltaTrancheUnits), "ST jt assets claim mismatch");

        assertApproxEqAbs(JT.getRawNAV(), _jtState.rawNAV, toUint256(_maxAbsDeltaNAV), "JT raw NAV mismatch");
        AssetClaims memory jtClaims = JT.totalAssets();
        assertApproxEqAbs(jtClaims.nav, _jtState.effectiveNAV, toUint256(_maxAbsDeltaNAV), "JT effective NAV mismatch");
        assertApproxEqAbs(jtClaims.stAssets, _jtState.stAssetsClaim, toUint256(_maxAbsDeltaTrancheUnits), "JT st assets claim mismatch");
        assertApproxEqAbs(jtClaims.jtAssets, _jtState.jtAssetsClaim, toUint256(_maxAbsDeltaTrancheUnits), "JT jt assets claim mismatch");
    }

    /// @notice Verifies the fee taken by the senior and junior tranches
    /// @param _stState The state of the senior tranche
    /// @param _jtState The state of the junior tranche
    /// @param _feeRecipient The address of the fee recipient
    function _verifyFeeTaken(TrancheState storage _stState, TrancheState storage _jtState, address _feeRecipient) internal view {
        uint256 seniorFeeShares = ST.balanceOf(_feeRecipient);
        NAV_UNIT seniorFeeSharesValue = ST.convertToAssets(seniorFeeShares).nav;
        assertEq(seniorFeeSharesValue, _stState.protocolFeeValue, "ST protocol fee value mismatch");

        uint256 juniorFeeShares = JT.balanceOf(_feeRecipient);
        NAV_UNIT juniorFeeSharesValue = JT.convertToAssets(juniorFeeShares).nav;
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

    /// @notice Generates role assignments using the role-specific addresses
    /// @return roleAssignments Array of role assignment configurations
    function _generateRoleAssignments() internal view returns (IRoycoFactory.RoleAssignmentConfiguration[] memory roleAssignments) {
        return DEPLOY_SCRIPT.generateRolesAssignments(
            DeployScript.RoleAssignmentAddresses({
                pauserAddress: PAUSER_ADDRESS,
                unpauserAddress: UNPAUSER_ADDRESS,
                upgraderAddress: UPGRADER_ADDRESS,
                syncRoleAddress: SYNC_ROLE_ADDRESS,
                adminKernelAddress: KERNEL_ADMIN_ADDRESS,
                adminAccountantAddress: ACCOUNTANT_ADMIN_ADDRESS,
                adminProtocolFeeSetterAddress: PROTOCOL_FEE_SETTER_ADDRESS,
                adminOracleQuoterAddress: ORACLE_QUOTER_ADMIN_ADDRESS,
                lpRoleAdminAddress: LP_ROLE_ADMIN_ADDRESS,
                guardianAddress: ROLE_GUARDIAN_ADDRESS,
                deployerAddress: DEPLOYER_ADDRESS,
                deployerAdminAddress: DEPLOYER_ADMIN_ADDRESS,
                protocolFeeRecipientAddress: PROTOCOL_FEE_RECIPIENT_ADDRESS,
                transferAgentAddress: TRANSFER_AGENT_ADDRESS
            })
        );
    }

    /// @notice Grants all roles to their respective addresses
    /// @dev This should be called after the factory is deployed
    function _grantAllRoles() internal prankModifier(OWNER_ADDRESS) {
        // Grant ADMIN_PAUSER_ROLE
        FACTORY.grantRole(ADMIN_PAUSER_ROLE, PAUSER_ADDRESS, 0);

        // Grant ADMIN_UNPAUSER_ROLE
        FACTORY.grantRole(ADMIN_UNPAUSER_ROLE, UNPAUSER_ADDRESS, 0);

        // Grant ADMIN_UPGRADER_ROLE
        FACTORY.grantRole(ADMIN_UPGRADER_ROLE, UPGRADER_ADDRESS, 0);

        // Grant SYNC_ROLE
        FACTORY.grantRole(SYNC_ROLE, SYNC_ROLE_ADDRESS, 0);

        // Grant ADMIN_KERNEL_ROLE
        FACTORY.grantRole(ADMIN_KERNEL_ROLE, KERNEL_ADMIN_ADDRESS, 0);

        // Grant ADMIN_ACCOUNTANT_ROLE
        FACTORY.grantRole(ADMIN_ACCOUNTANT_ROLE, ACCOUNTANT_ADMIN_ADDRESS, 0);

        // Grant ADMIN_PROTOCOL_FEE_SETTER_ROLE
        FACTORY.grantRole(ADMIN_PROTOCOL_FEE_SETTER_ROLE, PROTOCOL_FEE_SETTER_ADDRESS, 0);

        // Grant ADMIN_ORACLE_QUOTER_ROLE
        FACTORY.grantRole(ADMIN_ORACLE_QUOTER_ROLE, ORACLE_QUOTER_ADMIN_ADDRESS, 0);

        // Grant LP_ROLE_ADMIN_ROLE
        FACTORY.grantRole(LP_ROLE_ADMIN_ROLE, LP_ROLE_ADMIN_ADDRESS, 0);

        // Grant TRANSFER_AGENT_ROLE
        FACTORY.grantRole(TRANSFER_AGENT_ROLE, TRANSFER_AGENT_ADDRESS, 0);

        // Set ST_LP_ROLE and JT_LP_ROLE admin to LP_ROLE_ADMIN_ROLE
        FACTORY.setRoleAdmin(ST_LP_ROLE, LP_ROLE_ADMIN_ROLE);
        FACTORY.setRoleAdmin(JT_LP_ROLE, LP_ROLE_ADMIN_ROLE);
    }

    // -----------------------------------------
    // Role-Specific Helper Functions
    // -----------------------------------------

    /// @notice Calls sync on the kernel with SYNC_ROLE
    function _sync() internal prankModifier(SYNC_ROLE_ADDRESS) {
        KERNEL.syncTrancheAccounting();
    }

    /// @notice Schedules and executes a kernel admin operation (handles delay)
    /// @param _target The target contract address
    /// @param _data The calldata for the operation
    function _executeKernelAdminOperation(address _target, bytes memory _data) internal {
        // Schedule the operation
        vm.prank(KERNEL_ADMIN_ADDRESS);
        FACTORY.schedule(_target, _data, 0);

        // Warp past the delay (2 days for ADMIN_KERNEL_ROLE)
        vm.warp(block.timestamp + 2 days + 1);

        // Execute the operation
        vm.prank(KERNEL_ADMIN_ADDRESS);
        FACTORY.execute(_target, _data);
    }

    /// @notice Schedules and executes an accountant admin operation (handles delay)
    /// @param _target The target contract address
    /// @param _data The calldata for the operation
    function _executeAccountantAdminOperation(address _target, bytes memory _data) internal {
        // Schedule the operation
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        FACTORY.schedule(_target, _data, 0);

        // Warp past the delay (2 days for ADMIN_ACCOUNTANT_ROLE)
        vm.warp(block.timestamp + 2 days + 1);

        // Execute the operation
        vm.prank(ACCOUNTANT_ADMIN_ADDRESS);
        FACTORY.execute(_target, _data);
    }

    /// @notice Schedules and executes a protocol fee setter operation (handles delay)
    /// @param _target The target contract address
    /// @param _data The calldata for the operation
    function _executeProtocolFeeSetterOperation(address _target, bytes memory _data) internal {
        // Schedule the operation
        vm.prank(PROTOCOL_FEE_SETTER_ADDRESS);
        FACTORY.schedule(_target, _data, 0);

        // Warp past the delay (2 days for ADMIN_PROTOCOL_FEE_SETTER_ROLE)
        vm.warp(block.timestamp + 2 days + 1);

        // Execute the operation
        vm.prank(PROTOCOL_FEE_SETTER_ADDRESS);
        FACTORY.execute(_target, _data);
    }

    /// @notice Sets the protocol fee recipient via kernel admin (with scheduling)
    /// @param _newRecipient The new protocol fee recipient address
    function _setProtocolFeeRecipient(address _newRecipient) internal {
        bytes memory data = abi.encodeCall(KERNEL.setProtocolFeeRecipient, (_newRecipient));
        _executeKernelAdminOperation(address(KERNEL), data);
    }

    /// @notice Sets the coverage via accountant admin (with scheduling)
    /// @param _newCoverageWAD The new coverage in WAD
    function _setCoverage(uint64 _newCoverageWAD) internal {
        bytes memory data = abi.encodeCall(ACCOUNTANT.setCoverage, (_newCoverageWAD));
        _executeAccountantAdminOperation(address(ACCOUNTANT), data);
    }

    /// @notice Sets the beta via accountant admin (with scheduling)
    /// @param _newBetaWAD The new beta in WAD
    function _setBeta(uint96 _newBetaWAD) internal {
        bytes memory data = abi.encodeCall(ACCOUNTANT.setBeta, (_newBetaWAD));
        _executeAccountantAdminOperation(address(ACCOUNTANT), data);
    }

    /// @notice Sets the ST protocol fee via protocol fee setter (with scheduling)
    /// @param _newFeeWAD The new fee in WAD
    function _setSeniorTrancheProtocolFee(uint64 _newFeeWAD) internal {
        bytes memory data = abi.encodeCall(ACCOUNTANT.setSeniorTrancheProtocolFee, (_newFeeWAD));
        _executeProtocolFeeSetterOperation(address(ACCOUNTANT), data);
    }

    /// @notice Sets the JT protocol fee via protocol fee setter (with scheduling)
    /// @param _newFeeWAD The new fee in WAD
    function _setJuniorTrancheProtocolFee(uint64 _newFeeWAD) internal {
        bytes memory data = abi.encodeCall(ACCOUNTANT.setJuniorTrancheProtocolFee, (_newFeeWAD));
        _executeProtocolFeeSetterOperation(address(ACCOUNTANT), data);
    }
}
