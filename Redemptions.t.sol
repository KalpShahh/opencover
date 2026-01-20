// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {REDEEM_AUTO_CLAIMABLE_DELAY} from "src/Constants.sol";
import {ICoveredMetavault} from "src/interfaces/ICoveredMetavault.sol";
import {IERC7540Redeem} from "src/interfaces/IERC7540.sol";
import {IERC7540CancelRedeem} from "src/interfaces/IERC7540Cancel.sol";
import {CoveredMetavaultTestBase} from "test/utils/CoveredMetavaultTestBase.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title RedemptionsUnitTest
/// @notice Unit tests for CoveredMetavault async redemption functionality.
contract RedemptionsUnitTest is CoveredMetavaultTestBase {
    // =========================================================================
    // REQUEST REDEEM TESTS
    // =========================================================================

    function test_RequestRedeem_Success() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        assertEq(vault.lastRedeemRequestId(owner), 0);

        vm.expectEmit();
        emit IERC7540Redeem.RedeemRequest(owner, owner, 1, owner, shares);
        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        assertEq(reqId, 1);
        // Shares are locked in the vault contract.
        assertEq(vault.balanceOf(owner), 0);
        assertEq(vault.balanceOf(address(vault)), shares);

        // Pending state visible; not claimable yet.
        assertEq(vault.pendingRedeemRequest(reqId, owner), shares);
        assertEq(vault.claimableRedeemRequest(reqId, owner), 0);

        assertEq(vault.lastRedeemRequestId(owner), reqId);
        assertEq(vault.pendingRedeemShares(owner), shares);
    }

    function test_RequestRedeem_MultipleRequests_SameController() public {
        // Mint shares in two batches.
        uint256 s1 = _mintSharesTo(owner, DEPOSIT_AMOUNT);
        uint256 s2 = _mintSharesTo(owner, DEPOSIT_AMOUNT / 2);

        vm.startPrank(owner);
        uint256 reqId1 = vault.requestRedeem(s1, owner, owner);
        assertEq(vault.lastRedeemRequestId(owner), reqId1);

        uint256 reqId2 = vault.requestRedeem(s2, owner, owner);
        vm.stopPrank();

        // Both requests are pending.
        assertEq(vault.pendingRedeemRequest(reqId1, owner), s1);
        assertEq(vault.pendingRedeemRequest(reqId2, owner), s2);
        assertEq(vault.pendingRedeemShares(owner), s1 + s2);
        assertEq(vault.lastRedeemRequestId(owner), reqId2);

        // Settle both requests in a single settlement call.
        uint256[] memory ids = new uint256[](2);
        ids[0] = reqId1;
        ids[1] = reqId2;
        _settle(0, ids);

        // After settlement, both are claimable and maxRedeem reflects the sum.
        assertEq(vault.claimableRedeemRequest(reqId1, owner), s1);
        assertEq(vault.claimableRedeemRequest(reqId2, owner), s2);
        assertEq(vault.maxRedeem(owner), s1 + s2);
        assertEq(vault.pendingRedeemShares(owner), 0);
    }

    function test_RequestRedeem_PartialSettlement() public {
        // Mint shares in three batches.
        uint256 s1 = _mintSharesTo(owner, DEPOSIT_AMOUNT);
        uint256 s2 = _mintSharesTo(owner, DEPOSIT_AMOUNT / 2);
        uint256 s3 = _mintSharesTo(owner, DEPOSIT_AMOUNT / 4);

        // Create three redemption requests.
        vm.startPrank(owner);
        uint256 reqId1 = vault.requestRedeem(s1, owner, owner);
        uint256 reqId2 = vault.requestRedeem(s2, owner, owner);
        uint256 reqId3 = vault.requestRedeem(s3, owner, owner);
        vm.stopPrank();

        // All three requests are pending.
        assertEq(vault.pendingRedeemRequest(reqId1, owner), s1);
        assertEq(vault.pendingRedeemRequest(reqId2, owner), s2);
        assertEq(vault.pendingRedeemRequest(reqId3, owner), s3);
        assertEq(vault.maxRedeem(owner), 0);

        // Settle only the first two requests, leaving the third pending.
        uint256[] memory reqIds = new uint256[](2);
        reqIds[0] = reqId1;
        reqIds[1] = reqId2;
        _settle(0, reqIds);

        // First two requests are now claimable, third remains pending.
        assertEq(vault.pendingRedeemRequest(reqId1, owner), 0);
        assertEq(vault.claimableRedeemRequest(reqId1, owner), s1);
        assertEq(vault.pendingRedeemRequest(reqId2, owner), 0);
        assertEq(vault.claimableRedeemRequest(reqId2, owner), s2);
        assertEq(vault.pendingRedeemRequest(reqId3, owner), s3);
        assertEq(vault.claimableRedeemRequest(reqId3, owner), 0);

        // maxRedeem only reflects the settled (claimable) requests.
        assertEq(vault.maxRedeem(owner), s1 + s2);

        // Settle the third request in a subsequent settlement.
        _settle(0, reqId3);

        // Now all three are claimable.
        assertEq(vault.pendingRedeemRequest(reqId3, owner), 0);
        assertEq(vault.claimableRedeemRequest(reqId3, owner), s3);
        assertEq(vault.maxRedeem(owner), s1 + s2 + s3);
    }

    function test_RequestRedeem_ZeroShares() public {
        vm.prank(owner);
        vm.expectRevert(ICoveredMetavault.ZeroShares.selector);
        vault.requestRedeem(0, owner, owner);
    }

    function test_RequestRedeem_ZeroController() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidController.selector, address(0)));
        vault.requestRedeem(shares, address(0), owner);
    }

    function test_RequestRedeem_RevertWhen_ControllerDiffersFromOwner() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidController.selector, other));
        vault.requestRedeem(shares, other, owner);
    }

    function test_RequestRedeem_InvalidOwner() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        // Caller is not the owner.
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidOwner.selector, owner));
        vault.requestRedeem(shares, owner, owner);
    }

    function test_RequestRedeem_SucceedsBelowMinimumRequestAssets() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        // Only redeem half the shares.
        uint256 partialShares = shares / 2;

        uint256 redeemAssetAmount = vault.convertToAssets(partialShares);
        uint256 underlyingAmount = asset.convertToAssets(redeemAssetAmount);
        // Set minimum higher than the redemption value.
        uint96 minimum = uint96(underlyingAmount * 2);

        _setMinimumRequestAssets(minimum);

        // minimumRequestAssets is NOT enforced for redemptions.
        // The keeper filters small requests offchain, users can self-settle via settleMaturedRedemption().
        vm.prank(owner);
        uint256 requestId = vault.requestRedeem(partialShares, owner, owner);

        assertEq(requestId, 1);
        assertEq(vault.balanceOf(owner), shares - partialShares);
    }

    // =========================================================================
    // PENDING / CLAIMABLE REDEEM REQUEST TESTS
    // =========================================================================

    function test_PendingAndClaimableRedeemRequest_Lifecycle() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        // Request redeem.
        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        // Before settlement: pending > 0, claimable = 0.
        assertEq(vault.pendingRedeemRequest(reqId, owner), shares);
        assertEq(vault.claimableRedeemRequest(reqId, owner), 0);
        assertEq(vault.lastRedeemRequestId(owner), reqId);
        assertEq(vault.pendingRedeemShares(owner), shares);

        // Settle redemption request.
        vm.expectEmit();
        emit ICoveredMetavault.RedemptionSettled(owner, reqId, shares);
        _settle(0, reqId);

        // After settlement: pending = 0, claimable > 0.
        assertEq(vault.pendingRedeemRequest(reqId, owner), 0);
        assertEq(vault.claimableRedeemRequest(reqId, owner), shares);
        assertEq(vault.pendingRedeemShares(owner), 0);

        // maxRedeem/Withdraw reflect claimable.
        assertEq(vault.maxRedeem(owner), shares);
        assertGt(vault.maxWithdraw(owner), 0);
    }

    function test_ClaimableRedeemShares_BeforeSettlement_ReturnsZero() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        vault.requestRedeem(shares, owner, owner);

        assertEq(vault.pendingRedeemShares(owner), shares);
        assertEq(vault.claimableRedeemShares(owner), 0);
    }

    function test_ClaimableRedeemShares_TracksSettlementAndConsumption() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        _settle(0, reqId);

        assertEq(vault.pendingRedeemShares(owner), 0);
        assertEq(vault.claimableRedeemShares(owner), shares);

        uint256 halfShares = shares / 2;
        vm.prank(owner);
        vault.redeem(halfShares, owner, owner);

        assertEq(vault.claimableRedeemShares(owner), shares - halfShares);
    }

    function test_PendingRedeemRequest_MismatchedController_ReturnsZero() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);
        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        // Querying with a different controller should return 0.
        assertEq(vault.pendingRedeemRequest(reqId, other), 0);
    }

    function test_ClaimableRedeemRequest_MismatchedController_ReturnsZero() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);
        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        _settle(0, reqId);

        // Querying with a different controller should return 0.
        assertEq(vault.claimableRedeemRequest(reqId, other), 0);
    }

    function test_SettleRedeem_InvalidRequest_Reverts() public {
        // No request with id 1.
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidRequest.selector, 1));
        _settle(0, 1);
    }

    function test_SettleRedeem_AlreadySettled_Reverts() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);
        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        _settle(0, reqId);

        // Settling again should revert.
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.RequestAlreadySettled.selector, reqId));
        _settle(0, reqId);
    }

    function test_SettleRedeem_RevertWhen_AssetsFloorToZero() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        // Simulate backing loss: set totalTrackedAssets to 0 so convertToAssets floors to zero during settlement.
        // totalTrackedAssets is at slot 0 within VaultStorage (at ERC-7201 namespaced location).
        vm.store(address(vault), vault.VAULT_STORAGE_LOCATION(), bytes32(uint256(0)));

        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;

        vm.prank(keeper);
        vm.expectRevert(ICoveredMetavault.ZeroAssets.selector);
        vault.settle(0, ids);
    }

    // =========================================================================
    // CANCEL REDEEM TESTS
    // =========================================================================

    function test_CancelRedeem_Success() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.startPrank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);
        // The shares are locked in the vault.

        // Emit request then claim to mirror ERC-7887 cancel flow.
        vm.expectEmit();
        emit IERC7540CancelRedeem.CancelRedeemRequest(owner, reqId, owner);
        vm.expectEmit();
        emit IERC7540CancelRedeem.CancelRedeemClaim(owner, owner, reqId, owner, shares);

        // The controller cancels the unsettled redemption request.
        uint256 refunded = vault.cancelRedeemRequest(reqId, owner, owner);
        vm.stopPrank();

        // The request is deleted and the locked shares are refunded.
        assertEq(refunded, shares);
        assertEq(vault.pendingRedeemRequest(reqId, owner), 0);
        assertEq(vault.claimableRedeemRequest(reqId, owner), 0);
        assertEq(vault.balanceOf(owner), shares);
        assertEq(vault.balanceOf(address(vault)), 0);
    }

    function test_CancelRedeem_RevertsForInvalidRequest() public {
        // Must reference an existing unsettled request.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidRequest.selector, 1));
        vault.cancelRedeemRequest(1, owner, owner);
    }

    function test_CancelRedeem_RevertsForInvalidController() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        // The caller must match the controller recorded for the request.
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidController.selector, owner));
        vault.cancelRedeemRequest(reqId, owner, owner);
    }

    function test_CancelRedeem_RevertsWhen_ControllerParamDiffersFromStoredRequest() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        // Caller supplies a different controller than the one stored on the request.
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidController.selector, other));
        vault.cancelRedeemRequest(reqId, other, other);
    }

    function test_CancelRedeem_RevertsForZeroReceiver() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.startPrank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        // The refund receiver must match the controller (and therefore cannot be zero).
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidReceiver.selector, address(0)));
        vault.cancelRedeemRequest(reqId, owner, address(0));
        vm.stopPrank();
    }

    function test_CancelRedeem_RevertWhen_ReceiverDiffersFromController() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.startPrank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidReceiver.selector, other));
        vault.cancelRedeemRequest(reqId, owner, other);
        vm.stopPrank();
    }

    function test_CancelRedeem_RevertsAfterSettlement() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        _settle(0, reqId);

        // Settled redemption requests cannot be cancelled.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.RequestAlreadySettled.selector, reqId));
        vault.cancelRedeemRequest(reqId, owner, owner);
    }

    function test_CancelRedeem_SucceedsAfterMaturity() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        // Maturity does not auto settle so cancellation remains allowed until settlement.
        skip(REDEEM_AUTO_CLAIMABLE_DELAY);

        vm.expectEmit();
        emit IERC7540CancelRedeem.CancelRedeemRequest(owner, reqId, owner);
        vm.expectEmit();
        emit IERC7540CancelRedeem.CancelRedeemClaim(owner, owner, reqId, owner, shares);

        vm.prank(owner);
        uint256 refunded = vault.cancelRedeemRequest(reqId, owner, owner);

        assertEq(refunded, shares);
        assertEq(vault.balanceOf(owner), shares);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.pendingRedeemRequest(reqId, owner), 0);
        assertEq(vault.claimableRedeemRequest(reqId, owner), 0);
    }

    function test_CancelRedeem_RevertsWhenAlreadyCancelled() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.startPrank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);
        uint256 refunded = vault.cancelRedeemRequest(reqId, owner, owner);
        assertEq(refunded, shares);
        vm.stopPrank();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidRequest.selector, reqId));
        vault.cancelRedeemRequest(reqId, owner, owner);
    }

    function test_CancelRedeem_CancelOneOfMultipleRequests() public {
        uint256 s1 = _mintSharesTo(owner, DEPOSIT_AMOUNT);
        uint256 s2 = _mintSharesTo(owner, DEPOSIT_AMOUNT / 2);

        vm.startPrank(owner);
        uint256 reqId1 = vault.requestRedeem(s1, owner, owner);
        uint256 reqId2 = vault.requestRedeem(s2, owner, owner);

        vault.cancelRedeemRequest(reqId1, owner, owner);
        vm.stopPrank();

        assertEq(vault.pendingRedeemRequest(reqId1, owner), 0);
        assertEq(vault.claimableRedeemRequest(reqId1, owner), 0);
        assertEq(vault.pendingRedeemRequest(reqId2, owner), s2);
        assertEq(vault.claimableRedeemRequest(reqId2, owner), 0);
        assertEq(vault.balanceOf(address(vault)), s2);
    }

    function test_CancelRedeem_RevertsWhenCallerNotControllerEvenIfParamMatches() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidController.selector, owner));
        vault.cancelRedeemRequest(reqId, owner, owner);
    }

    // =========================================================================
    // REDEEM / WITHDRAW CLAIM TESTS
    // =========================================================================

    function test_MaxRedeemAndWithdraw_AreZero_BeforeSettlement() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        vault.requestRedeem(shares, owner, owner);

        // Not settled yet.
        assertEq(vault.maxRedeem(owner), 0);
        assertEq(vault.maxWithdraw(owner), 0);
    }

    function test_Redeem_Reverts_WhenNotClaimable() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        // Not settled yet, claimable = 0.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ICoveredMetavault.InsufficientClaimableShares.selector, owner, 0, shares)
        );
        vault.redeem(shares, owner, owner);

        // Sanity: settle and then redeem works.
        _settle(0, reqId);
        vm.prank(owner);
        vault.redeem(shares, owner, owner);
    }

    function test_RevertWhen_RedeemRoundsDownToZeroAssets() public {
        uint256 shares = _mintSharesTo(owner, 10e18);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        _settle(0, reqId);
        // Force the controller's claimable assets bucket to zero while keeping claimable shares > 0
        // to hit the ZeroAssets guard in the redemption claim path.
        // redeems mapping is at slot 10 within VaultStorage (at ERC-7201 namespaced location).
        bytes32 base = keccak256(abi.encode(owner, uint256(vault.VAULT_STORAGE_LOCATION()) + 10));
        bytes32 claimableAssetsSlot = bytes32(uint256(base) + 2); // RedeemStorage.claimableAssets is slot 2
        vm.store(address(vault), claimableAssetsSlot, bytes32(uint256(0)));

        vm.prank(owner);
        vm.expectRevert(ICoveredMetavault.ZeroAssets.selector);
        vault.redeem(shares, owner, owner);
    }

    function test_RevertWhen_PushRedeemAssetsRoundsDownToZeroAssets() public {
        uint256 shares = _mintSharesTo(owner, 10e18);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        _settle(0, reqId);
        // Force the controller's claimable assets bucket to zero while keeping claimable shares > 0
        // to hit the ZeroAssets guard in the redemption claim path.
        // redeems mapping is at slot 10 within VaultStorage (at ERC-7201 namespaced location).
        bytes32 base = keccak256(abi.encode(owner, uint256(vault.VAULT_STORAGE_LOCATION()) + 10));
        bytes32 claimableAssetsSlot = bytes32(uint256(base) + 2); // RedeemStorage.claimableAssets is slot 2
        vm.store(address(vault), claimableAssetsSlot, bytes32(uint256(0)));

        vm.prank(keeper);
        vm.expectRevert(ICoveredMetavault.ZeroAssets.selector);
        vault.pushRedeemAssets(owner, shares);
    }

    function test_Redeem_Success_EmitsWithdraw_AndTransfersAssets() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        // Request and settle redeem.
        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);
        _settle(0, reqId);

        uint256 assetsOut = vault.maxWithdraw(owner);
        uint256 ownerAssetsBefore = asset.balanceOf(owner);

        vm.expectEmit();
        emit IERC4626.Withdraw(owner, owner, owner, assetsOut, shares);

        vm.prank(owner);
        uint256 assets = vault.redeem(shares, owner, owner);

        assertEq(assets, assetsOut);
        assertEq(asset.balanceOf(owner), ownerAssetsBefore + assetsOut);
        // Locked shares burned from vault.
        assertEq(vault.balanceOf(address(vault)), 0);
        // Claimable pool reduced.
        assertEq(vault.maxRedeem(owner), 0);
    }

    function test_Withdraw_Success_ExactAssets() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        // Request and settle redeem.
        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);
        _settle(0, reqId);

        // Withdraw an exact amount of assets (<= claimable) from the fixed redemption bucket.
        uint256 maxAssets = vault.maxWithdraw(owner);
        uint256 maxShares = vault.maxRedeem(owner);
        uint256 assetsToWithdraw = maxAssets / 2;
        assertGt(assetsToWithdraw, 0);

        vm.prank(owner);
        uint256 burnedShares = vault.withdraw(assetsToWithdraw, owner, owner);

        // Check claimable redemption share burn rounding (ceil) against the controller's redemption bucket.
        uint256 expectedShares = Math.mulDiv(assetsToWithdraw, maxShares, maxAssets, Math.Rounding.Ceil);
        assertEq(burnedShares, expectedShares);

        // Remaining claimable.
        assertEq(vault.maxRedeem(owner), maxShares - burnedShares);
    }

    function test_Withdraw_Reverts_WhenNotClaimable() public {
        // No claimable shares for the controller yet.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InsufficientClaimableAssets.selector, owner, 0, 1));
        vault.withdraw(1, owner, owner);
    }

    function test_Redeem_InvalidController() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);
        _settle(0, reqId);

        // Call with mismatched controller param should revert.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidController.selector, other));
        vault.redeem(shares, owner, other);
    }

    function test_Redeem_ZeroReceiver() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        _settle(0, reqId);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidReceiver.selector, address(0)));
        vault.redeem(shares, address(0), owner);
    }

    function test_Redeem_RevertsWhen_ZeroShares() public {
        vm.prank(owner);
        vm.expectRevert(ICoveredMetavault.ZeroShares.selector);
        vault.redeem(0, owner, owner);
    }

    function test_Redeem_RevertWhen_ReceiverDiffersFromController() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        _settle(0, reqId);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidReceiver.selector, other));
        vault.redeem(shares, other, owner);
    }

    function test_Withdraw_InvalidController() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        _settle(0, reqId);

        uint256 assetsToWithdraw = vault.maxWithdraw(owner);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidController.selector, other));
        vault.withdraw(assetsToWithdraw, owner, other);
    }

    function test_Withdraw_ZeroReceiver() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        _settle(0, reqId);

        uint256 assetsToWithdraw = vault.maxWithdraw(owner);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidReceiver.selector, address(0)));
        vault.withdraw(assetsToWithdraw, address(0), owner);
    }

    function test_Withdraw_RevertWhen_ReceiverDiffersFromController() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        _settle(0, reqId);

        uint256 assetsToWithdraw = vault.maxWithdraw(owner);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidReceiver.selector, other));
        vault.withdraw(assetsToWithdraw, other, owner);
    }

    function test_Withdraw_ZeroAssets() public {
        vm.prank(owner);
        vm.expectRevert(ICoveredMetavault.ZeroAssets.selector);
        vault.withdraw(0, owner, owner);
    }

    // =========================================================================
    // PUSH REDEEM ASSETS TESTS
    // =========================================================================

    function test_PushRedeemAssets_Settled_Succeeds() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        _settle(0, reqId);

        uint256 controllerAssetsBefore = asset.balanceOf(owner);
        uint256 expectedAssets = vault.maxWithdraw(owner);

        vm.expectEmit();
        emit IERC4626.Withdraw(keeper, owner, owner, expectedAssets, shares);

        vm.prank(keeper);
        vault.pushRedeemAssets(owner, shares);

        assertEq(asset.balanceOf(owner), controllerAssetsBefore + expectedAssets);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.maxRedeem(owner), 0);
    }

    function test_PushRedeemAssets_RevertsWhen_CallerNotKeeper() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        _settle(0, reqId);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, vault.KEEPER_ROLE())
        );
        vm.prank(other);
        vault.pushRedeemAssets(owner, shares);
    }

    function test_PushRedeemAssets_RevertsWhen_InsufficientClaimableShares() public {
        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        _settle(0, reqId);

        uint256 expectedShares = shares + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                ICoveredMetavault.InsufficientClaimableShares.selector, owner, shares, expectedShares
            )
        );
        vm.prank(keeper);
        vault.pushRedeemAssets(owner, expectedShares);
    }

    function test_PushRedeemAssets_RevertsWhen_ZeroAddress() public {
        vm.expectRevert(ICoveredMetavault.ZeroAddress.selector);
        vm.prank(keeper);
        vault.pushRedeemAssets(address(0), 1);
    }

    function test_PushRedeemAssets_RevertsWhen_ZeroShares() public {
        vm.expectRevert(ICoveredMetavault.ZeroShares.selector);
        vm.prank(keeper);
        vault.pushRedeemAssets(owner, 0);
    }

    // =========================================================================
    // PREVIEW FUNCTION TESTS (SHOULD REVERT)
    // =========================================================================

    function test_PreviewRedeem_Reverts() public {
        vm.expectRevert();
        vault.previewRedeem(1);
    }

    function test_PreviewWithdraw_Reverts() public {
        vm.expectRevert();
        vault.previewWithdraw(1);
    }

    // =========================================================================
    // TOTAL ASSETS ACCOUNTING WITH CLAIMABLE REDEMPTIONS
    // =========================================================================

    function test_TotalAssets_ExcludesClaimableRedeemPool() public {
        // Setup: two users deposit to create shares and backing assets.
        uint256 s1 = _mintSharesTo(owner, DEPOSIT_AMOUNT);
        uint256 s2 = _mintSharesTo(owner, DEPOSIT_AMOUNT);
        assertEq(vault.totalSupply(), s1 + s2);

        // User1 requests redemption.
        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(s1, owner, owner);

        uint256 totalBefore = vault.totalAssets();
        _settle(0, reqId);

        // After settlement, totalAssets excludes assets reserved for claimable redemptions.
        uint256 totalAfter = vault.totalAssets();
        uint256 reserved = vault.maxWithdraw(owner);
        // Allow 1 wei rounding tolerance.
        assertApproxEqAbs(totalBefore - totalAfter, reserved, 1);
    }
}
