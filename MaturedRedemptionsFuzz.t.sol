// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {REDEEM_AUTO_CLAIMABLE_DELAY} from "src/Constants.sol";
import {CoveredMetavaultTestBase} from "test/utils/CoveredMetavaultTestBase.sol";

/// @title MaturedRedemptionsFuzzTest
/// @notice Fuzz tests for auto-settlement of matured redemption requests.
contract MaturedRedemptionsFuzzTest is CoveredMetavaultTestBase {
    function testFuzz_MaturedRedemption_VariableDelays(uint256 delayDays) public {
        delayDays = bound(delayDays, 1, 365); // 1 day to 1 year

        uint256 shares = _mintSharesTo(owner, DEPOSIT_AMOUNT);

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        // Fast forward by delay.
        skip(delayDays * 1 days);

        // Still pending until explicitly settled.
        assertEq(vault.pendingRedeemRequest(reqId, owner), shares);
        assertEq(vault.claimableRedeemRequest(reqId, owner), 0);

        // Settle and claim.
        vault.settleMaturedRedemption(reqId);

        vm.prank(owner);
        vault.redeem(shares, owner, owner);

        assertEq(vault.maxRedeem(owner), 0);
    }

    function testFuzz_MultipleMaturedRedemptions(uint8 numRequests) public {
        numRequests = uint8(bound(numRequests, 1, 10));

        uint256[] memory reqIds = new uint256[](numRequests);
        uint256[] memory shares = new uint256[](numRequests);

        // Create multiple redemption requests, minting fresh shares for each.
        for (uint256 i = 0; i < numRequests; i++) {
            shares[i] = _mintSharesTo(owner, DEPOSIT_AMOUNT / numRequests);

            vm.prank(owner);
            reqIds[i] = vault.requestRedeem(shares[i], owner, owner);
        }

        // Fast forward to maturation.
        skip(REDEEM_AUTO_CLAIMABLE_DELAY);

        // Settle all matured requests.
        for (uint256 i = 0; i < numRequests; i++) {
            vault.settleMaturedRedemption(reqIds[i]);
        }

        // Compute total shares and claim all.
        uint256 totalClaimable = vault.maxRedeem(owner);
        assertGt(totalClaimable, 0);

        vm.prank(owner);
        vault.redeem(totalClaimable, owner, owner);

        assertEq(vault.maxRedeem(owner), 0);
    }
}
