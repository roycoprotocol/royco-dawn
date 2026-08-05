// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "../../../lib/forge-std/src/Test.sol";

import { ERC20Mock } from "../../../lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

import { TrancheType } from "../../../src/libraries/Types.sol";
import { PendleERC20SYUpgV2, PendleRoycoTrancheSY } from "../../../src/periphery/pendle/PendleRoycoTrancheSY.sol";
import { PendleRoycoTrancheSYFactory } from "../../../src/periphery/pendle/PendleRoycoTrancheSYFactory.sol";

import { MockTranche } from "../entrypoint/mocks/MockTranche.sol";

import { MockRoycoFactory } from "./PendleRoycoTrancheSYFactoryTest.t.sol";

/// @title PendleRoycoTrancheSYTest
/// @notice Audit-grade unit tests for PendleRoycoTrancheSY (proxy-initialized via PendleRoycoTrancheSYFactory)
contract PendleRoycoTrancheSYTest is Test {
    /// =====================================================================
    /// CONSTANTS
    /// =====================================================================
    address internal constant PENDLE_PAUSE_CONTROLLER = 0x2aD631F72fB16d91c4953A7f4260A97C2fE2f31e;
    /// @dev IStandardizedYield.AssetType { TOKEN = 0, LIQUIDITY = 1 }
    uint8 internal constant ASSET_TYPE_LIQUIDITY = 1;
    /// @dev PMath.ONE — Pendle's WAD constant; SY exchange rate is denominated per 1e18 SY wei
    uint256 internal constant PMATH_ONE = 1e18;

    /// =====================================================================
    /// STATE
    /// =====================================================================
    ERC20Mock internal asset;
    MockRoycoFactory internal mockRoycoFactory;
    MockTranche internal seniorTranche;
    MockTranche internal juniorTranche;
    PendleRoycoTrancheSYFactory internal syFactory;

    PendleRoycoTrancheSY internal sy; // proxy-deployed, owned by PENDLE_PAUSE_CONTROLLER
    address internal rewardManager = makeAddr("rewardManager");

    /// =====================================================================
    /// SETUP
    /// =====================================================================

    function setUp() public {
        asset = new ERC20Mock();
        mockRoycoFactory = new MockRoycoFactory();

        seniorTranche = new MockTranche(address(asset), address(mockRoycoFactory), TrancheType.SENIOR);
        juniorTranche = new MockTranche(address(asset), address(mockRoycoFactory), TrancheType.JUNIOR);
        mockRoycoFactory.registerPair(address(seniorTranche), address(juniorTranche));

        syFactory = new PendleRoycoTrancheSYFactory(address(mockRoycoFactory));
        sy = PendleRoycoTrancheSY(payable(syFactory.deploySY(address(seniorTranche), rewardManager)));
    }

    /// =====================================================================
    /// IMPLEMENTATION-LEVEL CONSTRUCTOR WIRING
    /// =====================================================================

    function test_constructor_implementation_setsYieldToken() public {
        // Direct (non-proxy) deploy of the implementation: yieldToken should be the tranche.
        PendleRoycoTrancheSY impl = new PendleRoycoTrancheSY(address(seniorTranche), rewardManager);
        assertEq(impl.yieldToken(), address(seniorTranche));
    }

    function test_constructor_implementation_setsOffchainRewardManager() public {
        PendleRoycoTrancheSY impl = new PendleRoycoTrancheSY(address(seniorTranche), rewardManager);
        assertEq(impl.offchainRewardManager(), rewardManager);
    }

    function test_constructor_implementation_zeroRewardManagerAllowed() public {
        PendleRoycoTrancheSY impl = new PendleRoycoTrancheSY(address(seniorTranche), address(0));
        assertEq(impl.offchainRewardManager(), address(0));
    }

    function test_constructor_implementation_decimalsMatchYieldToken() public {
        PendleRoycoTrancheSY impl = new PendleRoycoTrancheSY(address(seniorTranche), rewardManager);
        assertEq(impl.decimals(), seniorTranche.decimals());
    }

    function test_constructor_implementation_disableInitializers() public {
        // SYBaseUpgV2 calls _disableInitializers() in its constructor: direct init of the impl must revert.
        PendleRoycoTrancheSY impl = new PendleRoycoTrancheSY(address(seniorTranche), rewardManager);
        vm.expectRevert();
        impl.initialize("name", "symbol", address(this));
    }

    /// =====================================================================
    /// PROXY-INITIALIZED STATE
    /// =====================================================================

    function test_proxy_nameAndSymbol() public view {
        assertEq(sy.name(), string.concat("SY ", seniorTranche.name()));
        assertEq(sy.symbol(), string.concat("SY-", seniorTranche.symbol()));
    }

    function test_proxy_owner() public view {
        assertEq(sy.owner(), PENDLE_PAUSE_CONTROLLER);
    }

    function test_proxy_yieldTokenIsTranche() public view {
        assertEq(sy.yieldToken(), address(seniorTranche));
    }

    function test_proxy_offchainRewardManagerIsBaked() public view {
        assertEq(sy.offchainRewardManager(), rewardManager);
    }

    function test_proxy_decimalsMatchTranche() public view {
        assertEq(sy.decimals(), seniorTranche.decimals());
    }

    function test_proxy_cannotReinitialize() public {
        vm.expectRevert();
        sy.initialize("Other", "OTH", address(this));
    }

    function test_proxy_initialSupplyZero() public view {
        assertEq(sy.totalSupply(), 0);
    }

    /// =====================================================================
    /// exchangeRate
    /// =====================================================================

    function test_exchangeRate_atParity() public view {
        // sharePriceWAD defaults to 1e18, so PMath.ONE shares → 1e18 NAV.
        assertEq(sy.exchangeRate(), PMATH_ONE);
    }

    function test_exchangeRate_followsTrancheSharePrice() public {
        seniorTranche.setSharePrice(2e18); // 2x
        assertEq(sy.exchangeRate(), 2 * PMATH_ONE);

        seniorTranche.setSharePrice(0.5e18); // 0.5x
        assertEq(sy.exchangeRate(), PMATH_ONE / 2);
    }

    function test_exchangeRate_atZero() public {
        seniorTranche.setSharePrice(0);
        assertEq(sy.exchangeRate(), 0);
    }

    function testFuzz_exchangeRate_matchesTrancheConvertToAssets(uint256 _sharePriceWAD) public {
        _sharePriceWAD = bound(_sharePriceWAD, 0, type(uint128).max);
        seniorTranche.setSharePrice(_sharePriceWAD);
        // exchangeRate(SY) == convertToAssets(PMath.ONE).nav  (per the override).
        uint256 expected = _sharePriceWAD; // mock applies a 1:1 share-to-asset map weighted by sharePriceWAD
        assertEq(sy.exchangeRate(), expected);
    }

    /// =====================================================================
    /// assetInfo
    /// =====================================================================

    function test_assetInfo_returnsLiquidityAndTrancheAndDecimals() public view {
        (PendleERC20SYUpgV2.AssetType assetType, address assetAddress, uint8 assetDecimals) = sy.assetInfo();
        assertEq(uint8(assetType), ASSET_TYPE_LIQUIDITY);
        assertEq(assetAddress, address(seniorTranche));
        assertEq(assetDecimals, seniorTranche.decimals());
    }

    /// =====================================================================
    /// OWNER-ONLY (BoringOwnable: pause/unpause/transferOwnership)
    /// =====================================================================

    function test_pause_onlyOwner() public {
        vm.prank(PENDLE_PAUSE_CONTROLLER);
        sy.pause();
        assertTrue(sy.paused());
    }

    function test_pause_revertsForNonOwner() public {
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        sy.pause();
    }

    function test_unpause_onlyOwner() public {
        vm.startPrank(PENDLE_PAUSE_CONTROLLER);
        sy.pause();
        sy.unpause();
        vm.stopPrank();
        assertFalse(sy.paused());
    }

    function test_transferOwnership_directOnlyOwner() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(PENDLE_PAUSE_CONTROLLER);
        sy.transferOwnership(newOwner, true, false);

        assertEq(sy.owner(), newOwner);
        assertEq(sy.pendingOwner(), address(0));
    }

    function test_transferOwnership_pendingPathRequiresClaim() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(PENDLE_PAUSE_CONTROLLER);
        sy.transferOwnership(newOwner, false, false);

        // Owner unchanged until claim.
        assertEq(sy.owner(), PENDLE_PAUSE_CONTROLLER);
        assertEq(sy.pendingOwner(), newOwner);

        // Random caller cannot claim.
        vm.expectRevert(bytes("Ownable: caller != pending owner"));
        sy.claimOwnership();

        vm.prank(newOwner);
        sy.claimOwnership();
        assertEq(sy.owner(), newOwner);
    }

    function test_transferOwnership_revertsForNonOwner() public {
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        sy.transferOwnership(makeAddr("notOwner"), true, false);
    }

    /// =====================================================================
    /// REWARD INTERFACE (PendleERC20SYUpgV2 defaults)
    /// =====================================================================

    function test_rewards_defaultEmpty() public {
        assertEq(sy.getRewardTokens().length, 0);
        assertEq(sy.accruedRewards(makeAddr("user")).length, 0);
    }

    function test_claimOffchainRewards_onlyOffchainRewardManager() public {
        // claimOffchainRewards is gated to offchainRewardManager; non-manager calls revert.
        address[] memory empty = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        bytes32[][] memory proofs = new bytes32[][](0);

        vm.expectRevert(bytes("MRA: unauthorized"));
        sy.claimOffchainRewards(makeAddr("recipient"), empty, empty, amounts, proofs);
    }
}
