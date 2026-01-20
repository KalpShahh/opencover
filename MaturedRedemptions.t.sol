// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {REDEEM_AUTO_CLAIMABLE_DELAY} from "src/Constants.sol";
import {ICoveredMetavault} from "src/interfaces/ICoveredMetavault.sol";
import {CoveredMetavaultTestBase} from "test/utils/CoveredMetavaultTestBase.sol";

/// @title MaturedRedemptionsUnitTest
/// @notice Tests for auto-settlement of matured redemption requests.
contract MaturedRedemptionsUnitTest is CoveredMetavaultTestBase {
    // =========================================================================
    // MATURED REDEMPTION SETTLEMENT TESTS
    // =========================================================================

    function test_PendingRedeemRequest_MaturedStillPending_UntilSettled() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        // Initially pending.
        assertEq(vault.pendingRedeemRequest(reqId, owner), shares);
        assertEq(vault.claimableRedeemRequest(reqId, owner), 0);

        // Fast forward by the auto-claimable delay.
        skip(REDEEM_AUTO_CLAIMABLE_DELAY);

        // After maturation, still pending until explicitly settled.
        assertEq(vault.pendingRedeemRequest(reqId, owner), shares);
        assertEq(vault.claimableRedeemRequest(reqId, owner), 0);

        // Once settled, it becomes claimable and no longer pending.
        vault.settleMaturedRedemption(reqId);
        assertEq(vault.pendingRedeemRequest(reqId, owner), 0);
        assertEq(vault.claimableRedeemRequest(reqId, owner), shares);
    }

    function test_ClaimableRedeemRequest_RequiresSettlementEvenAfterMaturation() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        // Not claimable before maturation.
        assertEq(vault.claimableRedeemRequest(reqId, owner), 0);

        // Fast forward past the delay.
        skip(REDEEM_AUTO_CLAIMABLE_DELAY + 1);

        // Still not claimable until settled.
        assertEq(vault.claimableRedeemRequest(reqId, owner), 0);

        // Settle matured request to make it claimable.
        vault.settleMaturedRedemption(reqId);
        assertEq(vault.claimableRedeemRequest(reqId, owner), shares);
    }

    function test_SettleMaturedRedemption_Success_SingleRequest() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        // Fast forward to maturation.
        skip(REDEEM_AUTO_CLAIMABLE_DELAY);

        // Settle matured request.
        vm.expectEmit();
        emit ICoveredMetavault.RedemptionSettled(owner, reqId, shares);

        vault.settleMaturedRedemption(reqId);

        // Now it's in claimable pool and maxRedeem reflects it.
        assertEq(vault.maxRedeem(owner), shares);
        assertEq(vault.pendingRedeemRequest(reqId, owner), 0);
    }

    function test_SettleMaturedRedemption_Success_MultipleRequests() public {
        uint256 shares1 = _mintSharesTo(owner, DEPOSIT_AMOUNT);
        uint256 shares2 = _mintSharesTo(owner, DEPOSIT_AMOUNT / 2);

        vm.startPrank(owner);
        uint256 reqId1 = vault.requestRedeem(shares1, owner, owner);
        uint256 reqId2 = vault.requestRedeem(shares2, owner, owner);
        vm.stopPrank();

        // Fast forward to maturation.
        skip(REDEEM_AUTO_CLAIMABLE_DELAY);

        // Settle both matured requests.
        vault.settleMaturedRedemption(reqId1);
        vault.settleMaturedRedemption(reqId2);

        // Both are now claimable.
        assertEq(vault.maxRedeem(owner), shares1 + shares2);
    }

    function test_SettleMaturedRedemption_RevertsNotMatured() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        // Try to settle before maturation (should revert).
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.RequestNotMatured.selector, reqId));
        vault.settleMaturedRedemption(reqId);
    }

    function test_SettleMaturedRedemption_RevertsAlreadySettled() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        // Settle explicitly via keeper.
        _settle(0, reqId);

        // Fast forward and try to settle again.
        skip(REDEEM_AUTO_CLAIMABLE_DELAY);

        // Should revert when trying to settle again.
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.RequestAlreadySettled.selector, reqId));
        vault.settleMaturedRedemption(reqId);
    }

    function test_SettleMaturedRedemption_RevertWhen_AssetsFloorToZero() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        // Fast forward to maturation.
        skip(REDEEM_AUTO_CLAIMABLE_DELAY);

        // Simulate backing loss: set totalTrackedAssets to 0 so convertToAssets floors to zero at settlement.
        // totalTrackedAssets is at slot 0 within VaultStorage (at ERC-7201 namespaced location).
        vm.store(address(vault), vault.VAULT_STORAGE_LOCATION(), bytes32(uint256(0)));

        vm.expectRevert(ICoveredMetavault.ZeroAssets.selector);
        vault.settleMaturedRedemption(reqId);
    }

    function test_SettleMaturedRedemption_RevertsInvalidRequestId() public {
        // Try to settle non-existent request.
        // Should revert.
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidRequest.selector, 999));
        vault.settleMaturedRedemption(999);
    }

    function test_ClaimAfterMaturation_WithoutExplicitSettlement() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        // Fast forward to maturation.
        skip(REDEEM_AUTO_CLAIMABLE_DELAY);

        // User must call settleMaturedRedemption before claiming.
        vault.settleMaturedRedemption(reqId);

        // Now can claim.
        vm.prank(owner);
        uint256 assets = vault.redeem(shares, owner, owner);
        assertGt(assets, 0);

        // Verify shares were burned and assets transferred.
        assertEq(vault.maxRedeem(owner), 0);
        assertGt(asset.balanceOf(owner), 0);
    }

    function test_PartialMaturation_OnlyMaturedAreSettled() public {
        uint256 shares1 = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId1 = vault.requestRedeem(shares1, owner, owner);

        // Fast forward until the first request matures.
        skip(REDEEM_AUTO_CLAIMABLE_DELAY);

        // Make second request (fresh and not yet matured).
        uint256 shares2 = _mintSharesTo(owner, DEPOSIT_AMOUNT / 2);
        vm.prank(owner);
        uint256 reqId2 = vault.requestRedeem(shares2, owner, owner);

        // Let some time pass without allowing the second request to mature.
        skip(REDEEM_AUTO_CLAIMABLE_DELAY / 2);

        // Settle reqId1 (matured).
        vault.settleMaturedRedemption(reqId1);

        // Try to settle reqId2 (not matured), should revert.
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.RequestNotMatured.selector, reqId2));
        vault.settleMaturedRedemption(reqId2);

        // Only reqId1 should be settled.
        assertEq(vault.maxRedeem(owner), shares1);
        assertEq(vault.pendingRedeemRequest(reqId1, owner), 0);
        assertEq(vault.pendingRedeemRequest(reqId2, owner), shares2);
    }

    function test_AccountingCorrect_AfterMaturedSettlement() public {
        // Two users, each with a matured request.
        uint256 shares1 = _mintSharesTo(owner, DEPOSIT_AMOUNT);
        uint256 shares2 = _mintSharesTo(other, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId1 = vault.requestRedeem(shares1, owner, owner);

        vm.prank(other);
        uint256 reqId2 = vault.requestRedeem(shares2, other, other);

        // Fast forward to maturation.
        skip(REDEEM_AUTO_CLAIMABLE_DELAY);

        // Settle both.
        vault.settleMaturedRedemption(reqId1);
        vault.settleMaturedRedemption(reqId2);

        // Each controller has their shares claimable.
        assertEq(vault.maxRedeem(owner), shares1);
        assertEq(vault.maxRedeem(other), shares2);

        // Both can claim.
        vm.prank(owner);
        vault.redeem(shares1, owner, owner);

        vm.prank(other);
        vault.redeem(shares2, other, other);

        // No claimable shares remaining.
        assertEq(vault.maxRedeem(owner), 0);
        assertEq(vault.maxRedeem(other), 0);
    }

    function test_MixedSettlement_KeeperAndMatured() public {
        uint256 shares1 = _mintSharesTo(owner, DEPOSIT_AMOUNT);
        uint256 shares2 = _mintSharesTo(owner, DEPOSIT_AMOUNT / 2);

        vm.startPrank(owner);
        uint256 reqId1 = vault.requestRedeem(shares1, owner, owner);
        uint256 reqId2 = vault.requestRedeem(shares2, owner, owner);
        vm.stopPrank();

        // Keeper settles reqId1 explicitly.
        _settle(0, reqId1);

        // Fast forward to maturation for reqId2.
        skip(REDEEM_AUTO_CLAIMABLE_DELAY);

        // User settles matured reqId2.
        vault.settleMaturedRedemption(reqId2);

        // Both should be claimable.
        assertEq(vault.maxRedeem(owner), shares1 + shares2);
    }
}
