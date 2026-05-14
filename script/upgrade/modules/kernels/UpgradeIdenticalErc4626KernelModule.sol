// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IRoycoKernel } from "../../../../src/interfaces/IRoycoKernel.sol";
import {
    Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel
} from "../../../../src/kernels/Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel.sol";

import { UpgradeKernelBaseModule } from "./UpgradeKernelBaseModule.sol";

/// @notice Quoter introspection — `IdenticalAssetsChainlinkOracleQuoter` storage view + admin-set rate.
interface IChainlinkQuoter {
    struct ChainlinkOracleConfig {
        address oracle;
        uint48 stalenessThresholdSeconds;
    }
    function getChainlinkOracleConfiguration() external pure returns (ChainlinkOracleConfig memory);
    function getStoredConversionRateWAD() external view returns (uint256);
}

/**
 * @title UpgradeIdenticalErc4626KernelModule
 * @notice Module for upgrading `Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel` proxies.
 *         Used by markets where ST and JT share the same ERC4626 yield-bearing asset (e.g. sNUSD,
 *         autoUSD, SmokehouseUSDC, savUSD).
 *
 * @dev Kernel-specific verification:
 *        - Chainlink quoter config: oracle address + staleness threshold seconds
 *        - Admin-set / oracle-stored conversion rate (`getStoredConversionRateWAD()`)
 */
contract UpgradeIdenticalErc4626KernelModule is UpgradeKernelBaseModule {
    error UpgradeIdenticalErc4626KernelModule__OracleChanged(address expected, address actual);
    error UpgradeIdenticalErc4626KernelModule__StalenessChanged(uint48 expected, uint48 actual);
    error UpgradeIdenticalErc4626KernelModule__StoredConversionRateChanged(uint256 expected, uint256 actual);

    function _kernelContractName() internal pure virtual override returns (string memory) {
        return "Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel";
    }

    function _kernelCreationCodeWith(IRoycoKernel.RoycoKernelConstructionParams memory cp) internal pure virtual override returns (bytes memory) {
        return abi.encodePacked(type(Identical_ERC4626_ST_JT_SharePriceToChainlinkOracle_Kernel).creationCode, abi.encode(cp));
    }

    function _snapshotKernelSpecific(address _proxy) internal view virtual override returns (bytes memory) {
        IChainlinkQuoter q = IChainlinkQuoter(_proxy);
        IChainlinkQuoter.ChainlinkOracleConfig memory cfg = q.getChainlinkOracleConfiguration();
        return abi.encode(cfg.oracle, cfg.stalenessThresholdSeconds, q.getStoredConversionRateWAD());
    }

    function _verifyKernelSpecific(address _proxy, bytes memory _snap) internal view virtual override {
        (address oracle, uint48 staleness, uint256 storedRate) = abi.decode(_snap, (address, uint48, uint256));
        IChainlinkQuoter q = IChainlinkQuoter(_proxy);
        IChainlinkQuoter.ChainlinkOracleConfig memory cfg = q.getChainlinkOracleConfiguration();
        require(cfg.oracle == oracle, UpgradeIdenticalErc4626KernelModule__OracleChanged(oracle, cfg.oracle));
        require(cfg.stalenessThresholdSeconds == staleness, UpgradeIdenticalErc4626KernelModule__StalenessChanged(staleness, cfg.stalenessThresholdSeconds));
        require(
            q.getStoredConversionRateWAD() == storedRate,
            UpgradeIdenticalErc4626KernelModule__StoredConversionRateChanged(storedRate, q.getStoredConversionRateWAD())
        );
    }
}
