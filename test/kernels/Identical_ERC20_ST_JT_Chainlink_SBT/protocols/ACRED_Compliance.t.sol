// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "../../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { DeployScript } from "../../../../script/Deploy.s.sol";
import { MarketDeploymentConfig } from "../../../../script/config/MarketDeploymentConfig.sol";
import { IRoycoAccountant } from "../../../../src/interfaces/IRoycoAccountant.sol";
import { IRoycoKernel } from "../../../../src/interfaces/IRoycoKernel.sol";
import { IRoycoVaultTranche } from "../../../../src/interfaces/IRoycoVaultTranche.sol";
import {
    Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel
} from "../../../../src/kernels/Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel.sol";
import { AssetClaims, MarketState } from "../../../../src/libraries/Types.sol";
import { NAV_UNIT, TRANCHE_UNIT, toTrancheUnits, toUint256 } from "../../../../src/libraries/Units.sol";
import { Identical_ERC20_ST_JT_Chainlink_SBT_TestBase } from "../base/Identical_ERC20_ST_JT_Chainlink_SBT_TestBase.t.sol";

interface IDSTokenLike {
    function getDSService(uint256) external view returns (address);
    function COMPLIANCE_SERVICE() external view returns (uint256);
}

/// @title ACRED_ComplianceTest
/// @notice Tests compliance functions (blacklist, seize, seizeAndRedeem) for the SoulBound kernel with ACRED
contract ACRED_ComplianceTest is Identical_ERC20_ST_JT_Chainlink_SBT_TestBase {
    address internal constant ACRED_TOKEN = 0x17418038ecF73BA4026c4f428547BF099706F27B;
    address internal constant ACRED_CHAINLINK_ORACLE = 0xD6BcbbC87bFb6c8964dDc73DC3EaE6d08865d51C;
    address internal constant ACRED_WHALE = 0xa0759A0DFdE5395a1892aEd90eB5665698CFaa05;
    uint256 internal constant FORK_BLOCK = 24_543_000;

    // ═══════════════════════════════════════════════════════════════════════════
    // TEST CONFIG OVERRIDES (same as ACRED_Test)
    // ═══════════════════════════════════════════════════════════════════════════

    function getTestConfig() public pure override returns (TestConfig memory) {
        return TestConfig({ forkBlock: FORK_BLOCK, forkRpcUrlEnvVar: "MAINNET_RPC_URL", stAsset: ACRED_TOKEN, jtAsset: ACRED_TOKEN, initialFunding: 500e6 });
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
        return toTrancheUnits(uint256(1e5));
    }

    function maxNAVDelta() public view override returns (NAV_UNIT) {
        return _toSTValue(maxTrancheUnitDelta());
    }

    function _minDepositAmount() internal pure override returns (uint256) {
        return 1e4;
    }

    function _deployKernelAndMarket() internal override returns (DeployScript.DeploymentResult memory) {
        _mockDSTokenCompliance();
        return _deployACRED();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PRIVATE DEPLOYMENT HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _mockDSTokenCompliance() private {
        address svc = IDSTokenLike(ACRED_TOKEN).getDSService(IDSTokenLike(ACRED_TOKEN).COMPLIANCE_SERVICE());
        vm.mockCall(svc, abi.encodeWithSelector(bytes4(keccak256("checkWhitelisted(address)"))), abi.encode(true));
        vm.mockCall(svc, abi.encodeWithSelector(bytes4(keccak256("validateTransfer(address,address,uint256,bool,uint256)"))), abi.encode(uint256(0)));
    }

    function _deployACRED() private returns (DeployScript.DeploymentResult memory) {
        MarketDeploymentConfig.MarketConfig memory cfg = DEPLOY_SCRIPT.getMarketConfig("ACRED");
        _overrideStaleness(cfg);
        uint32 scheduledOperationsExpirySeconds = DEPLOY_SCRIPT.getChainConfig(block.chainid).scheduledOperationsExpirySeconds;
        return DEPLOY_SCRIPT.deploy(
            cfg, OWNER_ADDRESS, PROTOCOL_FEE_RECIPIENT_ADDRESS, scheduledOperationsExpirySeconds, _generateRoleAssignments(), DEPLOYER.privateKey
        );
    }

    function _overrideStaleness(MarketDeploymentConfig.MarketConfig memory _cfg) private pure {
        DeployScript.IdenticalAssetsChainlinkToAdminOracleQuoterKernelParams memory kp =
            abi.decode(_cfg.kernelSpecificParams, (DeployScript.IdenticalAssetsChainlinkToAdminOracleQuoterKernelParams));
        kp.stalenessThresholdSeconds = _getStalenessThreshold();
        _cfg.kernelSpecificParams = abi.encode(kp);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // COMPLIANCE HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

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
    // CATEGORY 1: BLACKLIST — freezes deposits and redemptions
    // ═══════════════════════════════════════════════════════════════════════════

    function test_blacklist_blocksDeposit() external {
        // Setup: deposit JT so ST deposits are possible
        _depositJT(ALICE_ADDRESS, 100e6);

        // Blacklist BOB
        _blacklist(BOB_ADDRESS);

        // BOB tries to deposit ST — should revert
        uint256 amount = 10e6;
        vm.startPrank(BOB_ADDRESS);
        IERC20(config.stAsset).approve(address(ST), amount);
        vm.expectRevert(abi.encodeWithSelector(IRoycoKernel.ACCOUNT_BLACKLISTED.selector, BOB_ADDRESS));
        ST.deposit(toTrancheUnits(amount), BOB_ADDRESS);
        vm.stopPrank();
    }

    function test_blacklist_blocksRedeem() external {
        // Setup: deposit JT + ST
        _depositJT(ALICE_ADDRESS, 100e6);
        uint256 stShares = _depositST(BOB_ADDRESS, 10e6);

        // Blacklist BOB
        _blacklist(BOB_ADDRESS);

        // BOB tries to redeem ST — should revert
        vm.startPrank(BOB_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IRoycoKernel.ACCOUNT_BLACKLISTED.selector, BOB_ADDRESS));
        ST.redeem(stShares, BOB_ADDRESS, BOB_ADDRESS);
        vm.stopPrank();
    }

    function test_blacklist_maxDeposit_returnsZero() external {
        // Setup: deposit JT so ST deposits are possible
        _depositJT(ALICE_ADDRESS, 100e6);

        // Verify BOB can deposit before blacklisting
        TRANCHE_UNIT maxBefore = ST.maxDeposit(BOB_ADDRESS);
        assertGt(maxBefore, toTrancheUnits(uint256(0)), "maxDeposit should be > 0 before blacklist");

        // Blacklist BOB
        _blacklist(BOB_ADDRESS);

        // maxDeposit should return 0
        TRANCHE_UNIT maxAfter = ST.maxDeposit(BOB_ADDRESS);
        assertEq(maxAfter, toTrancheUnits(uint256(0)), "maxDeposit should be 0 after blacklist");
    }

    function test_blacklist_maxRedeem_returnsZero() external {
        // Setup: deposit JT + ST
        _depositJT(ALICE_ADDRESS, 100e6);
        _depositST(BOB_ADDRESS, 10e6);

        // Verify BOB can redeem before blacklisting
        uint256 maxRedeemBefore = ST.maxRedeem(BOB_ADDRESS);
        assertGt(maxRedeemBefore, 0, "maxRedeem should be > 0 before blacklist");

        // Blacklist BOB
        _blacklist(BOB_ADDRESS);

        // maxRedeem should return 0
        uint256 maxRedeemAfter = ST.maxRedeem(BOB_ADDRESS);
        assertEq(maxRedeemAfter, 0, "maxRedeem should be 0 after blacklist");
    }

    function test_blacklist_unblacklist_restoresAccess() external {
        // Setup: deposit JT + ST for BOB
        _depositJT(ALICE_ADDRESS, 100e6);
        uint256 stShares = _depositST(BOB_ADDRESS, 10e6);

        // Blacklist then unblacklist BOB
        _blacklist(BOB_ADDRESS);

        // Verify blocked
        uint256 maxRedeemBlocked = ST.maxRedeem(BOB_ADDRESS);
        assertEq(maxRedeemBlocked, 0, "maxRedeem should be 0 when blacklisted");

        _unblacklist(BOB_ADDRESS);

        // BOB should be able to redeem after unblacklisting
        uint256 maxRedeemRestored = ST.maxRedeem(BOB_ADDRESS);
        assertGt(maxRedeemRestored, 0, "maxRedeem should be > 0 after unblacklist");

        vm.prank(BOB_ADDRESS);
        ST.redeem(stShares, BOB_ADDRESS, BOB_ADDRESS);

        assertEq(IERC20(address(ST)).balanceOf(BOB_ADDRESS), 0, "BOB should have redeemed all ST shares");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CATEGORY 2: SEIZE — bypasses blacklist and soul-bound restriction
    // ═══════════════════════════════════════════════════════════════════════════

    function test_seize_ST_fromBlacklistedAddress() external {
        // Setup: deposit JT + ST for BOB
        _depositJT(ALICE_ADDRESS, 100e6);
        uint256 stShares = _depositST(BOB_ADDRESS, 10e6);

        // Blacklist BOB
        _blacklist(BOB_ADDRESS);

        // TRANSFER_AGENT seizes BOB's ST shares to ALICE
        vm.prank(TRANSFER_AGENT_ADDRESS);
        ST.seizeShares(BOB_ADDRESS, ST_ALICE_ADDRESS, stShares);

        // ALICE should have the shares, BOB should have none
        assertEq(IERC20(address(ST)).balanceOf(ST_ALICE_ADDRESS), stShares, "ALICE should have seized shares");
        assertEq(IERC20(address(ST)).balanceOf(BOB_ADDRESS), 0, "BOB should have no shares");
    }

    function test_seize_JT_fromBlacklistedAddress() external {
        // Setup: deposit JT for ALICE
        uint256 jtShares = _depositJT(ALICE_ADDRESS, 100e6);

        // Blacklist ALICE
        _blacklist(ALICE_ADDRESS);

        // TRANSFER_AGENT seizes ALICE's JT shares to BOB
        vm.prank(TRANSFER_AGENT_ADDRESS);
        JT.seizeShares(ALICE_ADDRESS, JT_BOB_ADDRESS, jtShares);

        // BOB should have the shares, ALICE should have none
        assertEq(IERC20(address(JT)).balanceOf(JT_BOB_ADDRESS), jtShares, "BOB should have seized JT shares");
        assertEq(IERC20(address(JT)).balanceOf(ALICE_ADDRESS), 0, "ALICE should have no JT shares");
    }

    function test_seize_emitsSharesSeizedEvent() external {
        // Setup: deposit JT + ST for BOB
        _depositJT(ALICE_ADDRESS, 100e6);
        uint256 stShares = _depositST(BOB_ADDRESS, 10e6);

        // Expect the SharesSeized event
        vm.expectEmit(true, true, false, true, address(ST));
        emit IRoycoVaultTranche.SharesSeized(TRANSFER_AGENT_ADDRESS, BOB_ADDRESS, ST_ALICE_ADDRESS, stShares);

        vm.prank(TRANSFER_AGENT_ADDRESS);
        ST.seizeShares(BOB_ADDRESS, ST_ALICE_ADDRESS, stShares);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CATEGORY 3: SEIZE AND REDEEM — bypasses fixed-term and coverage
    // ═══════════════════════════════════════════════════════════════════════════

    function test_seizeAndRedeem_ST_succeedsInFixedTerm() external {
        // Setup: deposit JT + ST
        _depositJT(ALICE_ADDRESS, 100e6);
        uint256 stShares = _depositST(BOB_ADDRESS, 10e6);

        // Simulate loss to trigger FIXED_TERM state
        simulateSTLoss(0.1e18); // 10% loss
        _refreshOraclesAfterWarp();
        _sync();

        // Verify FIXED_TERM state
        assertEq(uint256(ACCOUNTANT.getState().lastMarketState), uint256(MarketState.FIXED_TERM), "Market should be in FIXED_TERM state");

        // TRANSFER_AGENT seizes and redeems BOB's ST shares
        vm.prank(TRANSFER_AGENT_ADDRESS);
        AssetClaims memory claims = ST.seizeAndRedeemShares(BOB_ADDRESS, TRANSFER_AGENT_ADDRESS, stShares);

        // Verify shares burned and assets received
        assertEq(IERC20(address(ST)).balanceOf(BOB_ADDRESS), 0, "BOB should have no ST shares after seizure");
        assertGt(toUint256(claims.nav), 0, "Redeemed NAV should be > 0");
    }

    function test_seizeAndRedeem_ST_normalRedeemBlockedInFixedTerm() external {
        // Setup: deposit JT + ST
        _depositJT(ALICE_ADDRESS, 100e6);
        uint256 stShares = _depositST(BOB_ADDRESS, 10e6);

        // Simulate loss to trigger FIXED_TERM state
        simulateSTLoss(0.1e18);
        _refreshOraclesAfterWarp();
        _sync();

        // Verify FIXED_TERM state
        assertEq(uint256(ACCOUNTANT.getState().lastMarketState), uint256(MarketState.FIXED_TERM), "Market should be in FIXED_TERM state");

        // BOB tries to redeem ST normally — should revert
        vm.startPrank(BOB_ADDRESS);
        vm.expectRevert(IRoycoKernel.DISABLED_IN_FIXED_TERM_STATE.selector);
        ST.redeem(stShares, BOB_ADDRESS, BOB_ADDRESS);
        vm.stopPrank();
    }

    function test_seizeAndRedeem_JT_succeedsViolatingCoverage() external {
        // Setup: deposit JT then ST near coverage limit
        // Coverage is 10% for ACRED, so 100 JT allows up to ~900 ST
        uint256 jtAmount = 100e6;
        _depositJT(ALICE_ADDRESS, jtAmount);
        uint256 jtShares = IERC20(address(JT)).balanceOf(ALICE_ADDRESS);

        // Deposit ST to create coverage utilization — deposit 50% of max to ensure we have ST
        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) / 2;
        require(stAmount >= _minDepositAmount(), "ST deposit amount too small");
        _depositST(BOB_ADDRESS, stAmount);

        // TRANSFER_AGENT seizes and redeems ALL of ALICE's JT shares — bypasses coverage
        vm.prank(TRANSFER_AGENT_ADDRESS);
        AssetClaims memory claims = JT.seizeAndRedeemShares(ALICE_ADDRESS, TRANSFER_AGENT_ADDRESS, jtShares);

        // Verify shares burned and assets received
        assertEq(IERC20(address(JT)).balanceOf(ALICE_ADDRESS), 0, "ALICE should have no JT shares");
        assertGt(toUint256(claims.nav), 0, "Redeemed NAV should be > 0");
    }

    function test_seizeAndRedeem_JT_normalRedeemBlockedByCoverage() external {
        // Setup: deposit JT then ST near coverage limit
        uint256 jtAmount = 100e6;
        uint256 jtShares = _depositJT(ALICE_ADDRESS, jtAmount);

        // Deposit ST to create coverage utilization — deposit 50% of max
        TRANCHE_UNIT maxSTDeposit = ST.maxDeposit(BOB_ADDRESS);
        uint256 stAmount = toUint256(maxSTDeposit) / 2;
        require(stAmount >= _minDepositAmount(), "ST deposit amount too small");
        _depositST(BOB_ADDRESS, stAmount);

        // ALICE tries to redeem all JT normally — should revert due to coverage violation
        vm.startPrank(ALICE_ADDRESS);
        vm.expectRevert(IRoycoAccountant.COVERAGE_REQUIREMENT_UNSATISFIED.selector);
        JT.redeem(jtShares, ALICE_ADDRESS, ALICE_ADDRESS);
        vm.stopPrank();
    }

    function test_seizeAndRedeem_emitsEvent() external {
        // Setup: deposit JT + ST for BOB
        _depositJT(ALICE_ADDRESS, 100e6);
        uint256 stShares = _depositST(BOB_ADDRESS, 10e6);

        // We cannot predict exact claims, so just check that the event is emitted
        vm.expectEmit(true, true, true, false, address(ST));
        emit IRoycoVaultTranche.SharesSeizedAndRedeemed(
            TRANSFER_AGENT_ADDRESS,
            BOB_ADDRESS,
            TRANSFER_AGENT_ADDRESS,
            AssetClaims({ stAssets: TRANCHE_UNIT.wrap(0), jtAssets: TRANCHE_UNIT.wrap(0), nav: NAV_UNIT.wrap(0) }),
            stShares
        );

        vm.prank(TRANSFER_AGENT_ADDRESS);
        ST.seizeAndRedeemShares(BOB_ADDRESS, TRANSFER_AGENT_ADDRESS, stShares);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CATEGORY 4: ACCESS CONTROL — only TRANSFER_AGENT can call
    // ═══════════════════════════════════════════════════════════════════════════

    function test_seizeShares_revertsForNonTransferAgent() external {
        // Setup: deposit JT + ST
        _depositJT(ALICE_ADDRESS, 100e6);
        uint256 stShares = _depositST(BOB_ADDRESS, 10e6);

        // ALICE tries to seize — should revert
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert();
        ST.seizeShares(BOB_ADDRESS, ALICE_ADDRESS, stShares);
    }

    function test_seizeAndRedeem_revertsForNonTransferAgent() external {
        // Setup: deposit JT + ST
        _depositJT(ALICE_ADDRESS, 100e6);
        uint256 stShares = _depositST(BOB_ADDRESS, 10e6);

        // ALICE tries to seizeAndRedeem — should revert
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert();
        ST.seizeAndRedeemShares(BOB_ADDRESS, ALICE_ADDRESS, stShares);
    }

    function test_blacklist_revertsForNonTransferAgent() external {
        address[] memory depositors = new address[](1);
        depositors[0] = BOB_ADDRESS;

        // ALICE tries to blacklist — should revert
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert();
        KERNEL.blacklistAccounts(depositors);
    }

    function test_setBlacklistStatus_revertsForNonTransferAgent() external {
        // ALICE tries to enable blacklist — should revert
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert();
        KERNEL.setBlacklistStatus(true);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CATEGORY 5: SOUL-BOUND — only mints and burns allowed, no P2P transfers
    // ═══════════════════════════════════════════════════════════════════════════

    function test_soulBound_ST_mintSucceeds() external {
        _depositJT(ALICE_ADDRESS, 100e6);
        uint256 stShares = _depositST(BOB_ADDRESS, 10e6);
        assertGt(stShares, 0, "ST mint (deposit) should succeed");
        assertEq(IERC20(address(ST)).balanceOf(BOB_ADDRESS), stShares, "BOB should hold minted ST shares");
    }

    function test_soulBound_JT_mintSucceeds() external {
        uint256 jtShares = _depositJT(ALICE_ADDRESS, 100e6);
        assertGt(jtShares, 0, "JT mint (deposit) should succeed");
        assertEq(IERC20(address(JT)).balanceOf(ALICE_ADDRESS), jtShares, "ALICE should hold minted JT shares");
    }

    function test_soulBound_ST_burnSucceeds() external {
        _depositJT(ALICE_ADDRESS, 100e6);
        uint256 stShares = _depositST(BOB_ADDRESS, 10e6);

        vm.prank(BOB_ADDRESS);
        ST.redeem(stShares, BOB_ADDRESS, BOB_ADDRESS);

        assertEq(IERC20(address(ST)).balanceOf(BOB_ADDRESS), 0, "ST burn (redeem) should succeed");
    }

    function test_soulBound_JT_burnSucceeds() external {
        uint256 jtShares = _depositJT(ALICE_ADDRESS, 100e6);

        vm.prank(ALICE_ADDRESS);
        JT.redeem(jtShares, ALICE_ADDRESS, ALICE_ADDRESS);

        assertEq(IERC20(address(JT)).balanceOf(ALICE_ADDRESS), 0, "JT burn (redeem) should succeed");
    }

    function test_soulBound_ST_directTransferReverts() external {
        _depositJT(ALICE_ADDRESS, 100e6);
        uint256 stShares = _depositST(BOB_ADDRESS, 10e6);
        _grantLPRoles(ALICE_ADDRESS);

        vm.prank(BOB_ADDRESS);
        vm.expectRevert(Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel.TRANCHE_SHARES_ARE_SOUL_BOUND.selector);
        IERC20(address(ST)).transfer(ALICE_ADDRESS, stShares);
    }

    function test_soulBound_JT_directTransferReverts() external {
        uint256 jtShares = _depositJT(ALICE_ADDRESS, 100e6);
        _grantLPRoles(BOB_ADDRESS);

        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel.TRANCHE_SHARES_ARE_SOUL_BOUND.selector);
        IERC20(address(JT)).transfer(BOB_ADDRESS, jtShares);
    }

    function test_soulBound_ST_transferFromReverts() external {
        _depositJT(ALICE_ADDRESS, 100e6);
        uint256 stShares = _depositST(BOB_ADDRESS, 10e6);
        _grantLPRoles(ALICE_ADDRESS);

        // BOB approves ALICE to spend his ST shares
        vm.prank(BOB_ADDRESS);
        IERC20(address(ST)).approve(ALICE_ADDRESS, stShares);

        // ALICE tries transferFrom — should still revert (soul-bound)
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel.TRANCHE_SHARES_ARE_SOUL_BOUND.selector);
        IERC20(address(ST)).transferFrom(BOB_ADDRESS, ALICE_ADDRESS, stShares);
    }

    function test_soulBound_ST_partialTransferReverts() external {
        _depositJT(ALICE_ADDRESS, 100e6);
        _depositST(BOB_ADDRESS, 10e6);
        _grantLPRoles(ALICE_ADDRESS);

        // Even transferring 1 wei of shares should revert
        vm.prank(BOB_ADDRESS);
        vm.expectRevert(Identical_ERC20_ST_JT_ChainlinkToAdminOracle_SoulBoundTrancheShares_Kernel.TRANCHE_SHARES_ARE_SOUL_BOUND.selector);
        IERC20(address(ST)).transfer(ALICE_ADDRESS, 1);
    }
}
