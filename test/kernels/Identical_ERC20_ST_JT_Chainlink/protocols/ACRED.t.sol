// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { DeployScript } from "../../../../script/Deploy.s.sol";
import { DeploymentConfig } from "../../../../script/config/DeploymentConfig.sol";
import { IRoycoKernel } from "../../../../src/interfaces/IRoycoKernel.sol";
import { IRoycoVaultTranche } from "../../../../src/interfaces/IRoycoVaultTranche.sol";
import { IDSToken } from "../../../../src/interfaces/external/ds-token/IDSToken.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits } from "../../../../src/libraries/Units.sol";
import { YieldBearingERC20Chainlink_TestBase } from "../base/YieldBearingERC20Chainlink_TestBase.t.sol";

/// @title ACRED_Test
/// @notice Tests the Identical_ERC20_ST_ERC20_JT_Kernel with ACRED (Securitize DSToken),
///         including compliance functions (blacklist, seize, access control).
contract ACRED_Test is YieldBearingERC20Chainlink_TestBase {
    address internal constant ACRED_TOKEN = 0x17418038ecF73BA4026c4f428547BF099706F27B;
    address internal constant ACRED_CHAINLINK_ORACLE = 0xD6BcbbC87bFb6c8964dDc73DC3EaE6d08865d51C;
    address internal constant ACRED_WHALE = 0xa0759A0DFdE5395a1892aEd90eB5665698CFaa05;
    uint256 internal constant FORK_BLOCK = 24_543_000;

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST CONFIG OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

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

    function _deployKernelAndMarket() internal override returns (DeployScript.DeploymentResult memory) {
        _mockDSTokenValidateTransfer();
        return _deployACRED();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PRIVATE DEPLOYMENT HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev ACRED's DSToken enforces validateTransfer on transfer/transferFrom.
    ///      Mock it to succeed so tranche share transfers work in tests.
    function _mockDSTokenValidateTransfer() private {
        address svc = IDSToken(ACRED_TOKEN).getDSService(IDSToken(ACRED_TOKEN).COMPLIANCE_SERVICE());
        vm.mockCall(svc, abi.encodeWithSelector(bytes4(keccak256("validateTransfer(address,address,uint256,bool,uint256)"))), abi.encode(uint256(0)));
    }

    function _deployACRED() private returns (DeployScript.DeploymentResult memory) {
        DeploymentConfig.MarketDeploymentConfig memory cfg = DEPLOY_SCRIPT.getMarketConfig("ACRED");
        _overrideStaleness(cfg);
        return DEPLOY_SCRIPT.deploy(cfg, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, _generateRoleAssignments(), DEPLOYER.privateKey);
    }

    function _overrideStaleness(DeploymentConfig.MarketDeploymentConfig memory _cfg) private pure {
        DeployScript.IdenticalAssetsChainlinkToAdminOracleQuoterKernelParams memory kp =
            abi.decode(_cfg.kernelSpecificParams, (DeployScript.IdenticalAssetsChainlinkToAdminOracleQuoterKernelParams));
        kp.stalenessThresholdSeconds = _getStalenessThreshold();
        _cfg.kernelSpecificParams = abi.encode(kp);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // COMPLIANCE HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _grantLPRoles(address _who) internal {
        vm.startPrank(LP_ROLE_ADMIN_ADDRESS);
        FACTORY.grantRole(ST_LP_ROLE, _who, 0);
        FACTORY.grantRole(JT_LP_ROLE, _who, 0);
        vm.stopPrank();
    }

    function _blacklist(address _who) internal {
        address[] memory depositors = new address[](1);
        depositors[0] = _who;
        vm.prank(TRANSFER_AGENT_ADDRESS);
        KERNEL.blacklistAccounts(depositors);
    }

    function _unblacklist(address _who) internal {
        address[] memory depositors = new address[](1);
        depositors[0] = _who;
        vm.prank(TRANSFER_AGENT_ADDRESS);
        KERNEL.unblacklistAccounts(depositors);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BLACKLIST — freezes deposits, redemptions, and transfers
    // ═══════════════════════════════════════════════════════════════════════════

    function test_blacklist_blocksDeposit() external {
        _depositJT(ALICE_ADDRESS, 100e6);

        _blacklist(BOB_ADDRESS);

        uint256 amount = 10e6;
        vm.startPrank(BOB_ADDRESS);
        IERC20(config.stAsset).approve(address(ST), amount);
        vm.expectRevert(abi.encodeWithSelector(IRoycoKernel.ACCOUNT_BLACKLISTED.selector, BOB_ADDRESS));
        ST.deposit(toTrancheUnits(amount), BOB_ADDRESS);
        vm.stopPrank();
    }

    function test_blacklist_blocksRedeem() external {
        _depositJT(ALICE_ADDRESS, 100e6);
        uint256 stShares = _depositST(BOB_ADDRESS, 10e6);

        _blacklist(BOB_ADDRESS);

        vm.startPrank(BOB_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IRoycoKernel.ACCOUNT_BLACKLISTED.selector, BOB_ADDRESS));
        ST.redeem(stShares, BOB_ADDRESS, BOB_ADDRESS);
        vm.stopPrank();
    }

    function test_blacklist_blocksOutgoingTransfer() external {
        _depositJT(ALICE_ADDRESS, 100e6);
        uint256 stShares = _depositST(BOB_ADDRESS, 10e6);
        _grantLPRoles(ST_ALICE_ADDRESS);

        _blacklist(BOB_ADDRESS);

        vm.startPrank(BOB_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IRoycoKernel.ACCOUNT_BLACKLISTED.selector, BOB_ADDRESS));
        IERC20(address(ST)).transfer(ST_ALICE_ADDRESS, stShares);
        vm.stopPrank();
    }

    function test_blacklist_blocksIncomingTransfer() external {
        _depositJT(ALICE_ADDRESS, 100e6);
        uint256 stShares = _depositST(BOB_ADDRESS, 10e6);

        address receiver = makeAddr("blacklisted_receiver");
        _grantLPRoles(receiver);
        _blacklist(receiver);

        vm.startPrank(BOB_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IRoycoKernel.ACCOUNT_BLACKLISTED.selector, receiver));
        IERC20(address(ST)).transfer(receiver, stShares);
        vm.stopPrank();
    }

    function test_blacklist_maxDeposit_returnsZero() external {
        _depositJT(ALICE_ADDRESS, 100e6);

        TRANCHE_UNIT maxBefore = ST.maxDeposit(BOB_ADDRESS);
        assertGt(maxBefore, toTrancheUnits(uint256(0)), "maxDeposit should be > 0 before blacklist");

        _blacklist(BOB_ADDRESS);

        TRANCHE_UNIT maxAfter = ST.maxDeposit(BOB_ADDRESS);
        assertEq(maxAfter, toTrancheUnits(uint256(0)), "maxDeposit should be 0 after blacklist");
    }

    function test_blacklist_maxRedeem_returnsZero() external {
        _depositJT(ALICE_ADDRESS, 100e6);
        _depositST(BOB_ADDRESS, 10e6);

        uint256 maxRedeemBefore = ST.maxRedeem(BOB_ADDRESS);
        assertGt(maxRedeemBefore, 0, "maxRedeem should be > 0 before blacklist");

        _blacklist(BOB_ADDRESS);

        uint256 maxRedeemAfter = ST.maxRedeem(BOB_ADDRESS);
        assertEq(maxRedeemAfter, 0, "maxRedeem should be 0 after blacklist");
    }

    function test_blacklist_unblacklist_restoresAccess() external {
        _depositJT(ALICE_ADDRESS, 100e6);
        uint256 stShares = _depositST(BOB_ADDRESS, 10e6);
        _grantLPRoles(ST_ALICE_ADDRESS);

        _blacklist(BOB_ADDRESS);

        uint256 maxRedeemBlocked = ST.maxRedeem(BOB_ADDRESS);
        assertEq(maxRedeemBlocked, 0, "maxRedeem should be 0 when blacklisted");

        _unblacklist(BOB_ADDRESS);

        vm.prank(BOB_ADDRESS);
        IERC20(address(ST)).transfer(ST_ALICE_ADDRESS, stShares / 2);

        assertGt(IERC20(address(ST)).balanceOf(ST_ALICE_ADDRESS), 0, "ALICE should have received shares");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SEIZE — bypasses blacklist
    // ═══════════════════════════════════════════════════════════════════════════

    function test_seize_ST_fromBlacklistedAddress() external {
        _depositJT(ALICE_ADDRESS, 100e6);
        uint256 stShares = _depositST(BOB_ADDRESS, 10e6);
        _grantLPRoles(ST_ALICE_ADDRESS);

        _blacklist(BOB_ADDRESS);

        vm.prank(TRANSFER_AGENT_ADDRESS);
        ST.seizeAssets(BOB_ADDRESS, ST_ALICE_ADDRESS, stShares);

        assertEq(IERC20(address(ST)).balanceOf(ST_ALICE_ADDRESS), stShares, "ALICE should have seized shares");
        assertEq(IERC20(address(ST)).balanceOf(BOB_ADDRESS), 0, "BOB should have no shares");
    }

    function test_seize_JT_fromBlacklistedAddress() external {
        uint256 jtShares = _depositJT(ALICE_ADDRESS, 100e6);
        _grantLPRoles(JT_BOB_ADDRESS);

        _blacklist(ALICE_ADDRESS);

        vm.prank(TRANSFER_AGENT_ADDRESS);
        JT.seizeAssets(ALICE_ADDRESS, JT_BOB_ADDRESS, jtShares);

        assertEq(IERC20(address(JT)).balanceOf(JT_BOB_ADDRESS), jtShares, "BOB should have seized JT shares");
        assertEq(IERC20(address(JT)).balanceOf(ALICE_ADDRESS), 0, "ALICE should have no JT shares");
    }

    function test_seize_emitsAssetsSeizedEvent() external {
        _depositJT(ALICE_ADDRESS, 100e6);
        uint256 stShares = _depositST(BOB_ADDRESS, 10e6);

        vm.expectEmit(true, true, false, true, address(ST));
        emit IRoycoVaultTranche.AssetsSeized(BOB_ADDRESS, ST_ALICE_ADDRESS, stShares);

        vm.prank(TRANSFER_AGENT_ADDRESS);
        ST.seizeAssets(BOB_ADDRESS, ST_ALICE_ADDRESS, stShares);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ACCESS CONTROL — only TRANSFER_AGENT can call
    // ═══════════════════════════════════════════════════════════════════════════

    function test_seizeAssets_revertsForNonTransferAgent() external {
        _depositJT(ALICE_ADDRESS, 100e6);
        uint256 stShares = _depositST(BOB_ADDRESS, 10e6);

        vm.prank(ALICE_ADDRESS);
        vm.expectRevert();
        ST.seizeAssets(BOB_ADDRESS, ALICE_ADDRESS, stShares);
    }

    function test_blacklist_revertsForNonTransferAgent() external {
        address[] memory depositors = new address[](1);
        depositors[0] = BOB_ADDRESS;

        vm.prank(ALICE_ADDRESS);
        vm.expectRevert();
        KERNEL.blacklistAccounts(depositors);
    }

    function test_setBlacklistStatus_revertsForNonTransferAgent() external {
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert();
        KERNEL.setBlacklistStatus(true);
    }
}
