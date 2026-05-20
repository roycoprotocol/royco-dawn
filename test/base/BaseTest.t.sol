// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../lib/forge-std/src/Test.sol";
import { Vm } from "../../lib/forge-std/src/Vm.sol";
import { AccessManager } from "../../lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol";
import { ERC20Mock } from "../../lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { RoycoAccountant } from "../../src/accountant/RoycoAccountant.sol";
import {
    ADMIN_ACCOUNTANT_ROLE,
    ADMIN_FACTORY_ROLE,
    ADMIN_KERNEL_ROLE,
    ADMIN_ORACLE_QUOTER_ROLE,
    ADMIN_PAUSER_ROLE,
    ADMIN_PROTOCOL_FEE_SETTER_ROLE,
    ADMIN_ROLE,
    ADMIN_UNPAUSER_ROLE,
    ADMIN_UPGRADER_ROLE,
    DEPLOYER_ROLE,
    GUARDIAN_ROLE,
    JT_LP_ROLE,
    LP_ROLE_ADMIN_ROLE,
    ST_LP_ROLE,
    SYNC_ROLE,
    TRANSFER_AGENT_ROLE
} from "../../src/factory/RolesConfiguration.sol";
import { RoycoFactory } from "../../src/factory/RoycoFactory.sol";
import { BaseDeploymentTemplate } from "../../src/factory/templates/BaseDeploymentTemplate.sol";
import {
    COMPONENT_ID_ACCOUNTANT_IMPL,
    COMPONENT_ID_JUNIOR_TRANCHE_IMPL,
    COMPONENT_ID_SENIOR_TRANCHE_IMPL,
    COMPONENT_ID_YDM
} from "../../src/factory/templates/Components.sol";
import { DawnDeploymentTemplate } from "../../src/factory/templates/dawn/base/DawnDeploymentTemplate.sol";
import { IRoycoAccountant } from "../../src/interfaces/IRoycoAccountant.sol";
import { IRoycoDawnKernel } from "../../src/interfaces/IRoycoDawnKernel.sol";
import { IRoycoEntryPoint } from "../../src/interfaces/IRoycoEntryPoint.sol";
import { IRoycoVaultTranche } from "../../src/interfaces/IRoycoVaultTranche.sol";
import { IYDM } from "../../src/interfaces/IYDM.sol";
import { IRoycoProtocolTemplate } from "../../src/interfaces/factory/IRoycoProtocolTemplate.sol";
import { AssetClaims, TrancheType } from "../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toNAVUnits, toUint256 } from "../../src/libraries/Units.sol";
import { RoycoJuniorTranche } from "../../src/tranches/RoycoJuniorTranche.sol";
import { RoycoSeniorTranche } from "../../src/tranches/RoycoSeniorTranche.sol";
import { AdaptiveCurveYDM_V2 } from "../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { Assertions } from "./Assertions.t.sol";

/**
 * @title BaseTest
 * @notice Base test infrastructure for the template-driven factory. Replaces the legacy BaseTest
 *         that targeted `RoycoDawnFactory`.
 *
 * @dev `_bootstrapFactory()` stands up a fresh AccessManager + RoycoFactory proxy, grants all the
 *      standard roles to test wallets, and leaves the factory ready to register templates against.
 *      Concrete kernel test suites override `_deployKernelAndMarket()` to deploy a template
 *      against this factory and call `executeMarketDeployment(...)`.
 */
abstract contract BaseTest is Test, Assertions {
    uint256 internal constant BPS = 0.0001e18;

    struct TrancheState {
        NAV_UNIT rawNAV;
        NAV_UNIT effectiveNAV;
        TRANCHE_UNIT stAssetsClaim;
        TRANCHE_UNIT jtAssetsClaim;
        NAV_UNIT protocolFeeValue;
        uint256 totalShares;
    }

    /// @notice Shape returned by `_deployKernelAndMarket()` — the new factory's
    ///         `executeMarketDeployment` result enriched with the impl pointers we surface for
    ///         tests that want to assert against them.
    struct MarketDeployment {
        IRoycoVaultTranche seniorTranche;
        IRoycoVaultTranche juniorTranche;
        IRoycoDawnKernel kernel;
        IRoycoAccountant accountant;
        IYDM ydm;
    }

    // -----------------------------------------
    // Test Wallets
    // -----------------------------------------
    Vm.Wallet internal OWNER;
    address internal OWNER_ADDRESS;

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

    // Backward-compat aliases
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

    /// @notice The AccessManager. Every Royco market contract is managed by this AM; the factory
    ///         is just one admin on it.
    AccessManager internal AM;

    /// @notice The new template-driven factory.
    RoycoFactory internal FACTORY;

    IYDM internal YDM;
    IRoycoVaultTranche internal ST;
    IRoycoVaultTranche internal JT;
    IRoycoDawnKernel internal KERNEL;
    IRoycoAccountant internal ACCOUNTANT;

    // -----------------------------------------
    // Royco Deployments Parameters
    // -----------------------------------------

    uint256 internal SEED_AMOUNT;
    string internal SENIOR_TRANCHE_NAME = "Royco Senior Tranche";
    string internal SENIOR_TRANCHE_SYMBOL = "RST";
    string internal JUNIOR_TRANCHE_NAME = "Royco Junior Tranche";
    string internal JUNIOR_TRANCHE_SYMBOL = "RJT";
    uint64 internal COVERAGE_WAD = 0.2e18;
    uint96 internal BETA_WAD = 0;
    uint64 internal ST_PROTOCOL_FEE_WAD = 0.1e18;
    uint64 internal JT_PROTOCOL_FEE_WAD = 0.1e18;
    uint256 internal LIQUIDATION_UTILIZATION_WAD = 6.4667e18;
    uint24 internal FIXED_TERM_DURATION_SECONDS = 2 weeks;
    NAV_UNIT internal DUST_TOLERANCE = toNAVUnits(uint256(1));

    /// @notice Common YDM tag used across markets in tests.
    bytes32 internal constant YDM_COMPONENT_TAG = bytes32("YDM_ADAPTIVE_CURVE_V2");
    bytes32 internal constant YDM_VERSION = bytes32("V1");

    // -----------------------------------------
    // Mainnet Fork Addresses
    // -----------------------------------------
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

    // ═══════════════════════════════════════════════════════════════════════════
    // BOOTSTRAP — fresh AM + factory + standard role grants.
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deploys + initializes a fresh AccessManager and RoycoFactory and wires the
    ///         standard role grants every test relies on.
    /// @dev `OWNER_ADDRESS` becomes the AM's `ADMIN_ROLE` holder. The factory's `initialize`
    ///      asserts that the factory itself holds `ADMIN_ROLE` on the AM, so we must grant the
    ///      role BEFORE the proxy's constructor fires the initializer. The factory proxy address
    ///      is predicted via the test-contract's next CREATE nonce.
    function _bootstrapFactory() internal {
        AM = new AccessManager(OWNER_ADDRESS);

        RoycoFactory factoryImpl = new RoycoFactory();

        // Predict the proxy's address — it's the next CREATE-deployed contract from this address.
        address predictedProxy = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        vm.prank(OWNER_ADDRESS);
        AM.grantRole(ADMIN_ROLE, predictedProxy, 0);

        // Deploy the proxy + initialize atomically.
        FACTORY = RoycoFactory(address(new ERC1967Proxy(address(factoryImpl), abi.encodeCall(RoycoFactory.initialize, (address(AM))))));
        require(address(FACTORY) == predictedProxy, "predicted-vs-actual proxy mismatch");

        vm.startPrank(OWNER_ADDRESS);

        AM.grantRole(ADMIN_FACTORY_ROLE, OWNER_ADDRESS, 0);
        AM.grantRole(DEPLOYER_ROLE, DEPLOYER_ADDRESS, 0);
        AM.grantRole(ADMIN_PAUSER_ROLE, PAUSER_ADDRESS, 0);
        AM.grantRole(ADMIN_UNPAUSER_ROLE, UNPAUSER_ADDRESS, 1 days);
        AM.grantRole(ADMIN_UPGRADER_ROLE, UPGRADER_ADDRESS, 0);
        AM.grantRole(SYNC_ROLE, SYNC_ROLE_ADDRESS, 0);
        AM.grantRole(ADMIN_KERNEL_ROLE, KERNEL_ADMIN_ADDRESS, 0);
        AM.grantRole(ADMIN_ACCOUNTANT_ROLE, ACCOUNTANT_ADMIN_ADDRESS, 0);
        AM.grantRole(ADMIN_PROTOCOL_FEE_SETTER_ROLE, PROTOCOL_FEE_SETTER_ADDRESS, 0);
        AM.grantRole(ADMIN_ORACLE_QUOTER_ROLE, ORACLE_QUOTER_ADMIN_ADDRESS, 0);
        AM.grantRole(LP_ROLE_ADMIN_ROLE, LP_ROLE_ADMIN_ADDRESS, 0);
        AM.grantRole(GUARDIAN_ROLE, ROLE_GUARDIAN_ADDRESS, 0);
        AM.grantRole(TRANSFER_AGENT_ROLE, TRANSFER_AGENT_ADDRESS, 0);

        // LP roles are admined by LP_ROLE_ADMIN — set the admin on the role, not a member.
        AM.setRoleAdmin(ST_LP_ROLE, LP_ROLE_ADMIN_ROLE);
        AM.setRoleAdmin(JT_LP_ROLE, LP_ROLE_ADMIN_ROLE);

        vm.stopPrank();
    }

    /// @notice Configuration knobs for the standard Dawn market deployment helper.
    /// @dev Subclasses populate this and call `_deployDawnMarket(...)` to register a template +
    ///      execute the deployment in one shot. Mirrors the canonical pattern used by
    ///      `test/kernels/dawn/ReUSD_ST_JT.t.sol`.
    struct DawnDeploymentParams {
        bytes32 marketId;
        address template;
        bytes32 kernelComponentId;
        bytes kernelCreationCode;
        address stAsset;
        address jtAsset;
        bytes kernelSpecificParams;
        // Accountant params (optional overrides). Defaults are pulled from `BaseTest` storage.
        uint64 stProtocolFeeWAD;
        uint64 jtProtocolFeeWAD;
        uint64 yieldShareProtocolFeeWAD;
        uint64 coverageWAD;
        uint96 betaWAD;
        uint256 liquidationUtilizationWAD;
        uint24 fixedTermDurationSeconds;
        NAV_UNIT stNAVDustTolerance;
        NAV_UNIT jtNAVDustTolerance;
        bool enforceVaultSharesTransferWhitelist;
        uint64 stSelfLiquidationBonusWAD;
    }

    /// @notice Standard Dawn market deployment: register the template, build `DawnParams`, execute.
    /// @dev `_p.template` must already be `new <Template>(FACTORY)`-deployed by the caller.
    function _deployDawnMarket(DawnDeploymentParams memory _p) internal returns (MarketDeployment memory) {
        _registerDawnTemplate(_p.template, _p.kernelComponentId, _p.kernelCreationCode);
        bytes memory encodedParams = _encodeDawnParams(_p);
        vm.prank(DEPLOYER_ADDRESS);
        IRoycoProtocolTemplate.DeploymentResult memory r = FACTORY.executeMarketDeployment(_p.template, encodedParams);
        return MarketDeployment({
            seniorTranche: IRoycoVaultTranche(r.seniorTranche),
            juniorTranche: IRoycoVaultTranche(r.juniorTranche),
            kernel: IRoycoDawnKernel(r.kernel),
            accountant: IRoycoAccountant(r.accountant),
            ydm: IYDM(r.ydm)
        });
    }

    function _registerDawnTemplate(address _template, bytes32 _kernelComponentId, bytes memory _kernelCreationCode) internal {
        bytes32[] memory ids = new bytes32[](5);
        bytes[] memory codes = new bytes[](5);
        ids[0] = COMPONENT_ID_SENIOR_TRANCHE_IMPL;
        codes[0] = type(RoycoSeniorTranche).creationCode;
        ids[1] = COMPONENT_ID_JUNIOR_TRANCHE_IMPL;
        codes[1] = type(RoycoJuniorTranche).creationCode;
        ids[2] = COMPONENT_ID_ACCOUNTANT_IMPL;
        codes[2] = type(RoycoAccountant).creationCode;
        ids[3] = COMPONENT_ID_YDM;
        codes[3] = type(AdaptiveCurveYDM_V2).creationCode;
        ids[4] = _kernelComponentId;
        codes[4] = _kernelCreationCode;
        vm.prank(OWNER_ADDRESS);
        FACTORY.registerTemplate(_template, ids, codes);
    }

    function _encodeDawnParams(DawnDeploymentParams memory _p) internal view returns (bytes memory) {
        return abi.encode(
            DawnDeploymentTemplate.DawnParams({
                marketId: _p.marketId,
                st: BaseDeploymentTemplate.SeniorTrancheParams({ name: SENIOR_TRANCHE_NAME, symbol: SENIOR_TRANCHE_SYMBOL, asset: _p.stAsset }),
                jt: BaseDeploymentTemplate.JuniorTrancheParams({ name: JUNIOR_TRANCHE_NAME, symbol: JUNIOR_TRANCHE_SYMBOL, asset: _p.jtAsset }),
                accountant: _buildAccountantParams(_p),
                ydm: BaseDeploymentTemplate.YDMParams({ componentTag: YDM_COMPONENT_TAG, version: YDM_VERSION }),
                kernelSpecificParams: _p.kernelSpecificParams,
                enforceVaultSharesTransferWhitelist: _p.enforceVaultSharesTransferWhitelist,
                protocolFeeRecipient: PROTOCOL_FEE_RECIPIENT_ADDRESS,
                stSelfLiquidationBonusWAD: _p.stSelfLiquidationBonusWAD,
                entryPoint: address(0),
                stEntryPointConfig: _emptyEntryPointConfig(),
                jtEntryPointConfig: _emptyEntryPointConfig()
            })
        );
    }

    function _buildAccountantParams(DawnDeploymentParams memory _p) internal pure returns (BaseDeploymentTemplate.AccountantParams memory) {
        return BaseDeploymentTemplate.AccountantParams({
            stProtocolFeeWAD: _p.stProtocolFeeWAD,
            jtProtocolFeeWAD: _p.jtProtocolFeeWAD,
            yieldShareProtocolFeeWAD: _p.yieldShareProtocolFeeWAD,
            coverageWAD: _p.coverageWAD,
            betaWAD: _p.betaWAD,
            liquidationUtilizationWAD: _p.liquidationUtilizationWAD,
            fixedTermDurationSeconds: _p.fixedTermDurationSeconds,
            stNAVDustTolerance: _p.stNAVDustTolerance,
            jtNAVDustTolerance: _p.jtNAVDustTolerance,
            ydmInitializationData: abi.encodeCall(AdaptiveCurveYDM_V2.initializeYDMForMarket, (uint64(0.06e18), uint64(0.06e18), uint64(0.18e18), uint64(0)))
        });
    }

    function _emptyEntryPointConfig() internal pure returns (IRoycoEntryPoint.TrancheConfig memory) {
        return IRoycoEntryPoint.TrancheConfig({
            enabled: false, yieldRecipient: IRoycoEntryPoint.AccruedYieldRecipient.PROTOCOL, depositDelaySeconds: 0, redemptionDelaySeconds: 0
        });
    }

    /// @notice Predicts the 4 market proxy addresses for a `marketId` — useful when the caller
    ///         needs to build role bindings BEFORE running `executeMarketDeployment`.
    function _predictMarketAddresses(bytes32 _marketId) internal view returns (address st, address jt, address kernel, address accountant) {
        st = FACTORY.predictDeterministicAddress(keccak256(abi.encodePacked("ROYCO_MARKET", _marketId, bytes32("ST"))));
        jt = FACTORY.predictDeterministicAddress(keccak256(abi.encodePacked("ROYCO_MARKET", _marketId, bytes32("JT"))));
        kernel = FACTORY.predictDeterministicAddress(keccak256(abi.encodePacked("ROYCO_MARKET", _marketId, bytes32("KERNEL"))));
        accountant = FACTORY.predictDeterministicAddress(keccak256(abi.encodePacked("ROYCO_MARKET", _marketId, bytes32("ACCOUNTANT"))));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SETUP HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Convenience wrapper for tests that don't deploy a full market: sets up wallets,
    ///         opens the optional fork (`_forkConfiguration()` override) and stands up a fresh
    ///         AM + factory. Subclasses doing their own market deployment (e.g.
    ///         `AbstractKernelTestSuite`) don't need to call this — they wire the same steps
    ///         individually.
    function _setUpRoyco() internal virtual {
        (uint256 forkBlock, string memory forkRpcUrl) = _forkConfiguration();
        if (bytes(forkRpcUrl).length > 0) {
            require(forkBlock != 0, "Fork block required");
            vm.createSelectFork(forkRpcUrl, forkBlock);
        }
        _setupWallets();
        _bootstrapFactory();
    }

    function _setupFork(uint256 _forkBlock, string memory _forkRpcUrlEnvVar) internal {
        if (bytes(_forkRpcUrlEnvVar).length > 0) {
            string memory rpcUrl = vm.envString(_forkRpcUrlEnvVar);
            require(bytes(rpcUrl).length > 0, "Fork RPC URL is not set");
            require(_forkBlock != 0, "Fork block is required");
            vm.createSelectFork(rpcUrl, _forkBlock);
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
        OWNER = _initWallet("OWNER", 1000 ether);
        OWNER_ADDRESS = OWNER.addr;

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
        DEPLOYER = _initWallet("DEPLOYER", 1000 ether);
        DEPLOYER_ADDRESS = DEPLOYER.addr;
        DEPLOYER_ADMIN = _initWallet("DEPLOYER_ADMIN", 1000 ether);
        DEPLOYER_ADMIN_ADDRESS = DEPLOYER_ADMIN.addr;
        TRANSFER_AGENT = _initWallet("TRANSFER_AGENT", 1000 ether);
        TRANSFER_AGENT_ADDRESS = TRANSFER_AGENT.addr;
    }

    function _setupProviders() internal {
        ST_ALICE = _generateProvider("ST_ALICE", ST_LP_ROLE);
        ST_BOB = _generateProvider("ST_BOB", ST_LP_ROLE);
        ST_CHARLIE = _generateProvider("ST_CHARLIE", ST_LP_ROLE);
        ST_DAN = _generateProvider("ST_DAN", ST_LP_ROLE);

        ST_ALICE_ADDRESS = ST_ALICE.addr;
        ST_BOB_ADDRESS = ST_BOB.addr;
        ST_CHARLIE_ADDRESS = ST_CHARLIE.addr;
        ST_DAN_ADDRESS = ST_DAN.addr;

        JT_ALICE = _generateProvider("JT_ALICE", JT_LP_ROLE);
        JT_BOB = _generateProvider("JT_BOB", JT_LP_ROLE);
        JT_CHARLIE = _generateProvider("JT_CHARLIE", JT_LP_ROLE);
        JT_DAN = _generateProvider("JT_DAN", JT_LP_ROLE);

        JT_ALICE_ADDRESS = JT_ALICE.addr;
        JT_BOB_ADDRESS = JT_BOB.addr;
        JT_CHARLIE_ADDRESS = JT_CHARLIE.addr;
        JT_DAN_ADDRESS = JT_DAN.addr;

        ALICE = JT_ALICE;
        ALICE_ADDRESS = JT_ALICE_ADDRESS;
        BOB = ST_BOB;
        BOB_ADDRESS = ST_BOB_ADDRESS;
        CHARLIE = JT_CHARLIE;
        CHARLIE_ADDRESS = JT_CHARLIE_ADDRESS;
        DAN = JT_DAN;
        DAN_ADDRESS = JT_DAN_ADDRESS;

        providers.push(ST_ALICE_ADDRESS);
        providers.push(JT_ALICE_ADDRESS);
        providers.push(ST_BOB_ADDRESS);
        providers.push(JT_BOB_ADDRESS);
        providers.push(ST_CHARLIE_ADDRESS);
        providers.push(JT_CHARLIE_ADDRESS);
        providers.push(ST_DAN_ADDRESS);
        providers.push(JT_DAN_ADDRESS);
    }

    function _setDeployedMarket(MarketDeployment memory _d) internal {
        YDM = _d.ydm;
        vm.label(address(YDM), "YDM");
        ST = _d.seniorTranche;
        vm.label(address(ST), "ST");
        JT = _d.juniorTranche;
        vm.label(address(JT), "JT");
        ACCOUNTANT = _d.accountant;
        vm.label(address(ACCOUNTANT), "Accountant");
        KERNEL = _d.kernel;
        vm.label(address(KERNEL), "Kernel");
    }

    function _initWallet(string memory _name, uint256 _amount) internal returns (Vm.Wallet memory) {
        Vm.Wallet memory wallet = vm.createWallet(_name);
        vm.label(wallet.addr, _name);
        vm.deal(wallet.addr, _amount);
        return wallet;
    }

    /// @notice Generates a provider address and grants `_role` to it (via the LP_ROLE_ADMIN).
    function _generateProvider(string memory _name, uint64 _role) internal virtual returns (Vm.Wallet memory provider) {
        provider = _initWallet(_name, 10_000_000e6);
        vm.prank(LP_ROLE_ADMIN_ADDRESS);
        AM.grantRole(_role, provider.addr, 0);
        return provider;
    }

    /// @notice Generates a provider address and grants BOTH ST and JT LP roles.
    function _generateProvider(uint256 index) internal virtual returns (Vm.Wallet memory provider) {
        string memory providerName = string(abi.encodePacked("PROVIDER", vm.toString(index)));
        provider = _initWallet(providerName, 10_000_000e6);
        vm.startPrank(LP_ROLE_ADMIN_ADDRESS);
        AM.grantRole(ST_LP_ROLE, provider.addr, 0);
        AM.grantRole(JT_LP_ROLE, provider.addr, 0);
        vm.stopPrank();
        return provider;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ASSERTIONS (carried over from the legacy BaseTest)
    // ═══════════════════════════════════════════════════════════════════════════

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

    function _verifyFeeTaken(TrancheState storage _stState, TrancheState storage _jtState, address _feeRecipient) internal view {
        uint256 seniorFeeShares = ST.balanceOf(_feeRecipient);
        NAV_UNIT seniorFeeSharesValue = ST.convertToAssets(seniorFeeShares).nav;
        assertEq(seniorFeeSharesValue, _stState.protocolFeeValue, "ST protocol fee value mismatch");

        uint256 juniorFeeShares = JT.balanceOf(_feeRecipient);
        NAV_UNIT juniorFeeSharesValue = JT.convertToAssets(juniorFeeShares).nav;
        assertEq(juniorFeeSharesValue, _jtState.protocolFeeValue, "JT protocol fee value mismatch");
    }

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

    /// @notice Converts JT tranche units to NAV units via the kernel's quoter.
    function _toJTValue(TRANCHE_UNIT _assets) internal view returns (NAV_UNIT) {
        return KERNEL.jtConvertTrancheUnitsToNAVUnits(_assets);
    }

    /// @notice Converts ST tranche units to NAV units via the kernel's quoter.
    function _toSTValue(TRANCHE_UNIT _assets) internal view returns (NAV_UNIT) {
        return KERNEL.stConvertTrancheUnitsToNAVUnits(_assets);
    }

    /// @notice Override in subclasses to return `(forkBlock, forkRpcUrl)` for fork-based tests.
    function _forkConfiguration() internal virtual returns (uint256 forkBlock, string memory forkRpcUrl) {
        return (0, "");
    }
}
