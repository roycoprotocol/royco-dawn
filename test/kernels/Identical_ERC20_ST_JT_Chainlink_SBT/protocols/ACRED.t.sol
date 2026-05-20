// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { COMPONENT_ID_KERNEL_IDENTICAL_ERC20_CHAINLINK_SBT } from "../../../../src/factory/templates/Components.sol";
import { IdenticalERC20ChainlinkSBTDeploymentTemplate } from "../../../../src/factory/templates/dawn/IdenticalERC20ChainlinkSBTDeploymentTemplate.sol";
import {
    Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel
} from "../../../../src/kernels/Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../../../src/libraries/Units.sol";
import { Identical_ERC20_ST_JT_Chainlink_SBT_TestBase } from "../base/Identical_ERC20_ST_JT_Chainlink_SBT_TestBase.t.sol";

interface IDSTokenLike {
    function getDSService(uint256) external view returns (address);
    function COMPLIANCE_SERVICE() external view returns (uint256);
}

/// @title ACRED_Test
/// @notice Tests Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel with ACRED
contract ACRED_Test is Identical_ERC20_ST_JT_Chainlink_SBT_TestBase {
    address internal constant ACRED_TOKEN = 0x17418038ecF73BA4026c4f428547BF099706F27B;
    address internal constant ACRED_CHAINLINK_ORACLE = 0xD6BcbbC87bFb6c8964dDc73DC3EaE6d08865d51C;
    address internal constant ACRED_WHALE = 0xa0759A0DFdE5395a1892aEd90eB5665698CFaa05;
    uint256 internal constant FORK_BLOCK = 24_543_000;

    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({
            forkBlock: FORK_BLOCK,
            forkRpcUrlEnvVar: "MAINNET_RPC_URL",
            stAsset: ACRED_TOKEN,
            jtAsset: ACRED_TOKEN,
            initialFunding: 500e6 // 500 ACRED (limited by whale balance across ~20 providers)
        });
    }

    function _getChainlinkOracle() internal pure override returns (address) {
        return ACRED_CHAINLINK_ORACLE;
    }

    function _getStalenessThreshold() internal pure override returns (uint48) {
        return type(uint48).max;
    }

    function _getInitialConversionRate() internal pure override returns (uint256) {
        return 1e18;
    }

    function dealSTAsset(address _to, uint256 _amount) public override {
        vm.prank(ACRED_WHALE);
        IERC20(ACRED_TOKEN).transfer(_to, _amount);
    }

    function dealJTAsset(address _to, uint256 _amount) public override {
        vm.prank(ACRED_WHALE);
        IERC20(ACRED_TOKEN).transfer(_to, _amount);
    }

    function maxTrancheUnitDelta() public pure override returns (TRANCHE_UNIT) {
        return toTrancheUnits(uint256(1e5)); // 0.1 ACRED tolerance for 6 decimal + chainlink oracle rounding
    }

    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    function _minDepositAmount() internal pure override returns (uint256) {
        return 1e4; // 0.01 ACRED (6 decimals)
    }

    function _deployKernelAndMarket() internal override returns (MarketDeployment memory) {
        _mockDSTokenCompliance();
        return _deployACRED();
    }

    function _mockDSTokenCompliance() internal {
        address svc = IDSTokenLike(ACRED_TOKEN).getDSService(IDSTokenLike(ACRED_TOKEN).COMPLIANCE_SERVICE());
        vm.mockCall(svc, abi.encodeWithSelector(bytes4(keccak256("checkWhitelisted(address)"))), abi.encode(true));
        vm.mockCall(svc, abi.encodeWithSelector(bytes4(keccak256("validateTransfer(address,address,uint256,bool,uint256)"))), abi.encode(uint256(0)));
    }

    function _deployACRED() internal returns (MarketDeployment memory) {
        IdenticalERC20ChainlinkSBTDeploymentTemplate template = new IdenticalERC20ChainlinkSBTDeploymentTemplate(FACTORY);
        DawnDeploymentParams memory p;
        p.marketId = keccak256("ACRED_TEST");
        p.template = address(template);
        p.kernelComponentId = COMPONENT_ID_KERNEL_IDENTICAL_ERC20_CHAINLINK_SBT;
        p.kernelCreationCode = type(Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel).creationCode;
        p.stAsset = config.stAsset;
        p.jtAsset = config.jtAsset;
        p.kernelSpecificParams = abi.encode(
            IdenticalERC20ChainlinkSBTDeploymentTemplate.KernelParams({
                initialConversionRateWAD: _getInitialConversionRate(),
                trancheAssetToReferenceAssetOracle: ACRED_CHAINLINK_ORACLE,
                stalenessThresholdSeconds: _getStalenessThreshold()
            })
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
        p.enforceVaultSharesTransferWhitelist = true;
        p.stSelfLiquidationBonusWAD = 0;
        return _deployDawnMarket(p);
    }
}
