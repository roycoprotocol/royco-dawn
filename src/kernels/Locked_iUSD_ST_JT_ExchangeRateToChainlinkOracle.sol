// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IInfiniFiGateway } from "../interfaces/external/infinifi/IInfiniFiGateway.sol";
import { ILockingController } from "../interfaces/external/infinifi/ILockingController.sol";
import { WAD } from "../libraries/Constants.sol";
import { IRoycoKernel, Math, RoycoKernel } from "./base/RoycoKernel.sol";
import { IdenticalAssetsChainlinkOracleQuoter, IdenticalAssetsOracleQuoter } from "./base/quoter/base/IdenticalAssetsChainlinkOracleQuoter.sol";

/**
 * @title Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle
 * @author Waymont
 * @notice The senior and junior tranches transfer in InfiniFi Locked iUSD tokens with the same unwinding epochs
 * @dev NAV computations employ the exchange rate between locked iUSD tokens to iUSD and then a chainlink (compatible) or an admin oracle set rate to convert iUSD to NAV units
 * @dev NOTE: The locked iUSD to NAV exchange rates may be stale, as their freshness is dependent on how often the InfiniFi keeper synchronizes its internal accounting
 */
contract Locked_iUSD_ST_JT_ExchangeRateToChainlinkOracle is IdenticalAssetsChainlinkOracleQuoter {
    using Math for uint256;

    /// @dev The key used in the InfiniFi gateway to identify the locking controller contract
    string private constant LOCKING_CONTROLLER_KEY = "lockingController";

    /// @notice The address of InfiniFi gateway contract
    address public immutable INFINIFI_GATEWAY;

    /// @notice The unwinding epochs for the locked iUSD token (tranche assets)
    uint32 private immutable TRANCHE_ASSET_UNWINDING_EPOCHS;

    /// @dev Thrown when the tranche assets (locked iUSD) aren't the share token for the specified unwinding epochs
    error TRANCHE_ASSET_AND_UNWINDING_EPOCHS_MISMATCH();

    /**
     * @notice Constructs the kernel state
     * @param _params The standard construction parameters for the Royco kernel
     * @param _infiniFiGateway The address of InfiniFi's gateway
     * @param _trancheAssetUnwindingEpochs The unwinding epochs for the locked iUSD token (tranche assets)
     */
    constructor(RoycoKernelConstructionParams memory _params, address _infiniFiGateway, uint32 _trancheAssetUnwindingEpochs) RoycoKernel(_params) {
        // Set the immutable state
        INFINIFI_GATEWAY = _infiniFiGateway;
        TRANCHE_ASSET_UNWINDING_EPOCHS = _trancheAssetUnwindingEpochs;

        // Ensure that the tranche assets match the locked iUSD token for the specified unwinding epoch
        require(
            ILockingController(_getInfiniFiContract(LOCKING_CONTROLLER_KEY)).shareToken(_trancheAssetUnwindingEpochs) == ST_ASSET,
            TRANCHE_ASSET_AND_UNWINDING_EPOCHS_MISMATCH()
        );
    }

    /**
     * @notice Initializes the kernel state
     * @param _params The standard initialization parameters for the Royco Kernel
     * @param _initialIUSDToNAVUnitsConversionRateWAD The initial iUSD to NAV units (USD) conversion rate, scaled to WAD precision
     * @param _iUSDToNAVUnitsOracle The oracle to fetch the price of iUSD in NAV units (USD)
     * @param _stalenessThresholdSeconds The staleness threshold in seconds for the oracle
     */
    function initialize(
        IRoycoKernel.RoycoKernelInitParams calldata _params,
        uint256 _initialIUSDToNAVUnitsConversionRateWAD,
        address _iUSDToNAVUnitsOracle,
        uint48 _stalenessThresholdSeconds
    )
        external
        initializer
    {
        // Initialize the base kernel state
        __RoycoKernel_init(_params);
        // Initialize the identical assets oracle quoter
        __IdenticalAssetsOracleQuoter_init_unchained(_initialIUSDToNAVUnitsConversionRateWAD);
        // Initialize the identical assets chainlink oracle quoter
        __IdenticalAssetsChainlinkOracleQuoter_init_unchained(_iUSDToNAVUnitsOracle, _stalenessThresholdSeconds);
    }

    /**
     * @notice Returns the conversion rate from the InfiniFi locked iUSD token (tranche units) to NAV units, scaled to WAD precision
     * @return liUSDToNAVUnitConversionRateWAD The conversion rate from the InfiniFi locked iUSD token (tranche units) to NAV units, scaled to WAD precision
     */
    function getTrancheUnitToNAVUnitConversionRateWAD()
        public
        view
        virtual
        override(IdenticalAssetsChainlinkOracleQuoter)
        returns (uint256 liUSDToNAVUnitConversionRateWAD)
    {
        // Fetch the conversion rate from the InfiniFi locked iUSD token to iUSD
        // NOTE: The output is already scaled to WAD precision
        uint256 liUSDToIUSDNAVUnitConversionRateWAD =
            ILockingController(_getInfiniFiContract(LOCKING_CONTROLLER_KEY)).exchangeRate(TRANCHE_ASSET_UNWINDING_EPOCHS);

        // Resolve the iUSD to NAV unit conversion rate, scaled to WAD precision
        uint256 iUSDToNAVUnitConversionRateWAD = getStoredConversionRateWAD();
        // If the stored conversion rate is the sentinel value, query the oracle for the rate
        if (iUSDToNAVUnitConversionRateWAD == SENTINEL_CONVERSION_RATE) iUSDToNAVUnitConversionRateWAD = _getConversionRateFromOracleWAD();

        // Calculate the conversion rate from locked iUSD tokens to NAV units, scaled to WAD precision
        liUSDToNAVUnitConversionRateWAD = liUSDToIUSDNAVUnitConversionRateWAD.mulDiv(iUSDToNAVUnitConversionRateWAD, WAD, Math.Rounding.Floor);
    }

    /// @dev Fetches the iUSD price in terms of NAV units (USD) via a Chainlink compatible oracle
    function _getConversionRateFromOracleWAD() internal view override(IdenticalAssetsOracleQuoter) returns (uint256) {
        // Fetch the iUSD price in NAV units and its precision
        (uint256 iUSDPriceInNAVUnits, uint256 pricePrecision) = _queryChainlinkOracle();
        // Return the price scaled to WAD precision
        return pricePrecision == WAD ? iUSDPriceInNAVUnits : iUSDPriceInNAVUnits.mulDiv(WAD, pricePrecision, Math.Rounding.Floor);
    }

    /// @dev Returns an InfiniFi contract given its key in the gateway
    /// @param _key The key identifying the contract in the InfiniFi gateway
    function _getInfiniFiContract(string memory _key) internal view returns (address) {
        return IInfiniFiGateway(INFINIFI_GATEWAY).getAddress(_key);
    }
}
