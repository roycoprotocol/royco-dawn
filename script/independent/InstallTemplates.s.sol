// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoAccountant } from "../../src/accountant/RoycoAccountant.sol";
import {
    COMPONENT_ID_ACCOUNTANT_IMPL,
    COMPONENT_ID_JUNIOR_TRANCHE_IMPL,
    COMPONENT_ID_KERNEL_APYUSD,
    COMPONENT_ID_KERNEL_IDENTICAL_ERC20_CHAINLINK,
    COMPONENT_ID_KERNEL_IDENTICAL_ERC20_CHAINLINK_SBT,
    COMPONENT_ID_KERNEL_IDENTICAL_ERC4626_ADMIN_ORACLE,
    COMPONENT_ID_KERNEL_IDENTICAL_ERC4626_CHAINLINK_ORACLE,
    COMPONENT_ID_KERNEL_IDENTICAL_MAKINA,
    COMPONENT_ID_KERNEL_IDLECDOAA,
    COMPONENT_ID_KERNEL_LOCKED_IUSD,
    COMPONENT_ID_KERNEL_MAPLE_V2,
    COMPONENT_ID_KERNEL_REUSD,
    COMPONENT_ID_KERNEL_SUSDAI,
    COMPONENT_ID_KERNEL_SUSDAT,
    COMPONENT_ID_SENIOR_TRANCHE_IMPL,
    COMPONENT_ID_YDM
} from "../../src/factory/templates/Components.sol";
import { COMPONENT_ID_DUSK_KERNEL_CHAINLINK_ST_BPT_CHAINLINK_QUOTE } from "../../src/factory/templates/Components.sol";
import { IdenticalERC20ChainlinkDeploymentTemplate } from "../../src/factory/templates/dawn/IdenticalERC20ChainlinkDeploymentTemplate.sol";
import { IdenticalERC20ChainlinkSBTDeploymentTemplate } from "../../src/factory/templates/dawn/IdenticalERC20ChainlinkSBTDeploymentTemplate.sol";
import { IdenticalERC4626AdminOracleDeploymentTemplate } from "../../src/factory/templates/dawn/IdenticalERC4626AdminOracleDeploymentTemplate.sol";
import { IdenticalERC4626ChainlinkOracleDeploymentTemplate } from "../../src/factory/templates/dawn/IdenticalERC4626ChainlinkOracleDeploymentTemplate.sol";
import { IdenticalMakinaDeploymentTemplate } from "../../src/factory/templates/dawn/IdenticalMakinaDeploymentTemplate.sol";
import { IdleCdoAADeploymentTemplate } from "../../src/factory/templates/dawn/IdleCdoAADeploymentTemplate.sol";
import { LockediUSDDeploymentTemplate } from "../../src/factory/templates/dawn/LockediUSDDeploymentTemplate.sol";
import { MapleV2DeploymentTemplate } from "../../src/factory/templates/dawn/MapleV2DeploymentTemplate.sol";
import { ReUSDDeploymentTemplate } from "../../src/factory/templates/dawn/ReUSDDeploymentTemplate.sol";
import { apyUSDDeploymentTemplate } from "../../src/factory/templates/dawn/apyUSDDeploymentTemplate.sol";
import { DawnDeploymentTemplate } from "../../src/factory/templates/dawn/base/DawnDeploymentTemplate.sol";
import { sUSDaiDeploymentTemplate } from "../../src/factory/templates/dawn/sUSDaiDeploymentTemplate.sol";
import { sUSDatDeploymentTemplate } from "../../src/factory/templates/dawn/sUSDatDeploymentTemplate.sol";
import {
    ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_DeploymentTemplate
} from "../../src/factory/templates/dusk/ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_DeploymentTemplate.sol";
import { IRoycoFactory } from "../../src/interfaces/factory/IRoycoFactory.sol";
import { Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_Kernel } from "../../src/kernels/dawn/Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_Kernel.sol";
import { Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel } from "../../src/kernels/dawn/Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel.sol";
import {
    Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel
} from "../../src/kernels/dawn/Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel.sol";
import { Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel } from "../../src/kernels/dawn/Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel.sol";
import { Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel } from "../../src/kernels/dawn/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";
import { Identical_Makina_ST_JT_MachineToAdminOracle_Kernel } from "../../src/kernels/dawn/Identical_Makina_ST_JT_MachineToAdminOracle_Kernel.sol";
import { Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle } from "../../src/kernels/dawn/Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle.sol";
import { MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel } from "../../src/kernels/dawn/MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel.sol";
import { ReUSD_ST_JT_ICLOracle_Kernel } from "../../src/kernels/dawn/ReUSD_ST_JT_ICLOracle_Kernel.sol";
import { apyUSD_ST_JT_SharePriceToChainlinkOracle_Kernel } from "../../src/kernels/dawn/apyUSD_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";
import {
    ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_Kernel
} from "../../src/kernels/dusk/ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_Kernel.sol";
import { sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel } from "../../src/kernels/dawn/sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel.sol";
import { sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel } from "../../src/kernels/dawn/sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";
import { RoycoJuniorTranche } from "../../src/tranches/RoycoJuniorTranche.sol";
import { RoycoSeniorTranche } from "../../src/tranches/RoycoSeniorTranche.sol";
import { AdaptiveCurveYDM_V2 } from "../../src/ydm/AdaptiveCurveYDM_V2.sol";
import { Script } from "lib/forge-std/src/Script.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

/**
 * @title InstallTemplatesScript
 * @notice Deploys + registers every canonical Royco market template against a live `RoycoFactory`.
 *
 * @dev Each Dawn kernel variant has its own concrete template (12 in total). Every Dawn template
 *      registers the SAME 5 components: ST_IMPL, JT_IMPL, ACCOUNTANT_IMPL, YDM, and the single
 *      kernel impl that template targets. This keeps individual `registerTemplate` calls small
 *      (~80-100 KB calldata) instead of the ~250 KB a monolithic template would carry.
 *
 *      The caller (broadcasting key) must hold `ADMIN_FACTORY_ROLE` on the factory's `AccessManager`.
 */
contract InstallTemplatesScript is Script {
    bool internal constant ENABLE_LOGGING = true;

    /// @notice CLI entrypoint. Set `ROYCO_FACTORY` + `DEPLOYER_PRIVATE_KEY` in env.
    function run() external {
        IRoycoFactory factory = IRoycoFactory(vm.envAddress("ROYCO_FACTORY"));
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        _installAllDawn(factory);
        _installDuskBalancer(factory);
        vm.stopBroadcast();
    }

    /// @notice Deploys + registers every Dawn template against `_factory`.
    function installAllDawn(IRoycoFactory _factory) external {
        _installAllDawn(_factory);
    }

    function installDuskBalancer(IRoycoFactory _factory) external returns (address) {
        return _installDuskBalancer(_factory);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DAWN
    // ═══════════════════════════════════════════════════════════════════════════

    function _installAllDawn(IRoycoFactory _factory) internal {
        _registerDawnTemplate(
            _factory, address(new ReUSDDeploymentTemplate(_factory)), COMPONENT_ID_KERNEL_REUSD, type(ReUSD_ST_JT_ICLOracle_Kernel).creationCode
        );
        _registerDawnTemplate(
            _factory,
            address(new IdenticalERC20ChainlinkDeploymentTemplate(_factory)),
            COMPONENT_ID_KERNEL_IDENTICAL_ERC20_CHAINLINK,
            type(Identical_ERC20_ST_JT_ChainlinkToAdminOracle_Kernel).creationCode
        );
        _registerDawnTemplate(
            _factory,
            address(new IdenticalERC4626AdminOracleDeploymentTemplate(_factory)),
            COMPONENT_ID_KERNEL_IDENTICAL_ERC4626_ADMIN_ORACLE,
            type(Identical_ERC4626_ST_JT_SharePriceToAdminOracle_Kernel).creationCode
        );
        _registerDawnTemplate(
            _factory,
            address(new IdenticalERC4626ChainlinkOracleDeploymentTemplate(_factory)),
            COMPONENT_ID_KERNEL_IDENTICAL_ERC4626_CHAINLINK_ORACLE,
            type(Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel).creationCode
        );
        _registerDawnTemplate(
            _factory,
            address(new IdleCdoAADeploymentTemplate(_factory)),
            COMPONENT_ID_KERNEL_IDLECDOAA,
            type(Identical_AA_IdleCDO_ST_JT_VirtualPriceOracle_Kernel).creationCode
        );
        _registerDawnTemplate(
            _factory,
            address(new IdenticalERC20ChainlinkSBTDeploymentTemplate(_factory)),
            COMPONENT_ID_KERNEL_IDENTICAL_ERC20_CHAINLINK_SBT,
            type(Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel).creationCode
        );
        _registerDawnTemplate(
            _factory,
            address(new IdenticalMakinaDeploymentTemplate(_factory)),
            COMPONENT_ID_KERNEL_IDENTICAL_MAKINA,
            type(Identical_Makina_ST_JT_MachineToAdminOracle_Kernel).creationCode
        );
        _registerDawnTemplate(
            _factory,
            address(new sUSDaiDeploymentTemplate(_factory)),
            COMPONENT_ID_KERNEL_SUSDAI,
            type(sUSDai_ST_JT_RedemptionSharePriceToAdminOracle_Kernel).creationCode
        );
        _registerDawnTemplate(
            _factory,
            address(new MapleV2DeploymentTemplate(_factory)),
            COMPONENT_ID_KERNEL_MAPLE_V2,
            type(MaplePoolV2_ST_JT_ExitSharePriceToChainlinkOracle_Kernel).creationCode
        );
        _registerDawnTemplate(
            _factory,
            address(new apyUSDDeploymentTemplate(_factory)),
            COMPONENT_ID_KERNEL_APYUSD,
            type(apyUSD_ST_JT_SharePriceToChainlinkOracle_Kernel).creationCode
        );
        _registerDawnTemplate(
            _factory,
            address(new LockediUSDDeploymentTemplate(_factory)),
            COMPONENT_ID_KERNEL_LOCKED_IUSD,
            type(Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle).creationCode
        );
        _registerDawnTemplate(
            _factory,
            address(new sUSDatDeploymentTemplate(_factory)),
            COMPONENT_ID_KERNEL_SUSDAT,
            type(sUSDat_ST_JT_SharePriceToChainlinkOracle_Kernel).creationCode
        );
    }

    /// @dev Builds the standard 5-entry component table (ST/JT/Accountant/YDM + the specific
    ///      kernel impl) and registers it on the factory.
    function _registerDawnTemplate(IRoycoFactory _factory, address _template, bytes32 _kernelComponentId, bytes memory _kernelCreationCode) internal {
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

        _factory.registerTemplate(_template, ids, codes);
        if (ENABLE_LOGGING) console2.log("Dawn template registered:", _template);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DUSK-BALANCER
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Installs the Chainlink-ST / Chainlink-quote Dusk-Balancer variant. The HOOKS
    ///      creation code is left empty — caller is expected to override component ID
    ///      `COMPONENT_ID_DUSK_BALANCER_HOOKS` with their pool-type-specific hooks contract
    ///      bytecode (Weighted / Stable / Gyro / etc.) at register time.
    function _installDuskBalancer(IRoycoFactory _factory) internal returns (address) {
        ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_DeploymentTemplate dusk =
            new ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_DeploymentTemplate(_factory);

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
        ids[4] = COMPONENT_ID_DUSK_KERNEL_CHAINLINK_ST_BPT_CHAINLINK_QUOTE;
        codes[4] = type(ChainlinkOracle_ST_BPTsWithChainlinkOracleQuoteAssets_JT_Kernel).creationCode;

        // HOOKS bytecode is pool-type-specific — caller registers it via a second template
        // instance with `COMPONENT_ID_DUSK_BALANCER_HOOKS` populated, or by re-registering
        // this template with hooks bytecode appended to `ids`/`codes`.
        _factory.registerTemplate(address(dusk), ids, codes);
        if (ENABLE_LOGGING) console2.log("Chainlink-ST/Chainlink-quote Dusk-Balancer template registered:", address(dusk));
        return address(dusk);
    }
}
