// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CoveredMetavaultTestBase} from "test/utils/CoveredMetavaultTestBase.sol";

/// @title RedemptionsFuzzTest
/// @notice Fuzz tests covering async redeem/withdraw flows.
contract RedemptionsFuzzTest is CoveredMetavaultTestBase {
    function testFuzz_Redeem_PartialAndFull(uint256 depositAmount, uint256 redeemPartBps) public {
        // Bound inputs to realistic ranges to avoid overflow and zero cases.
        depositAmount = bound(depositAmount, 1, INITIAL_BALANCE);
        redeemPartBps = bound(redeemPartBps, 1, 10_000);

        // Mint shares via async deposit claim to the fresh actor.
        uint256 shares = _mintSharesTo(owner, depositAmount);

        // Request redemption for a bounded portion of the shares.
        uint256 sharesToRequest = (shares * redeemPartBps) / 10_000;
        if (sharesToRequest == 0) sharesToRequest = 1;

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(sharesToRequest, owner, owner);

        // Settle so requested shares become claimable.
        _settle(0, reqId);

        // Pre-condition: claimable equals requested.
        assertEq(vault.maxRedeem(owner), sharesToRequest);

        // Redeem a bounded portion of the claimable amount (could be full or partial).
        uint256 sharesToRedeem = bound((sharesToRequest * redeemPartBps) / 10_000, 1, sharesToRequest);
        vm.startPrank(owner);
        uint256 assetsOut = vault.redeem(sharesToRedeem, owner, owner);
        assertGt(assetsOut, 0);

        // Post-condition: remaining claimable equals requested minus redeemed.
        assertEq(vault.maxRedeem(owner), sharesToRequest - sharesToRedeem);

        // Redeem remaining to reach zero claimable.
        uint256 remainingShares = vault.maxRedeem(owner);
        if (remainingShares > 0) {
            vault.redeem(remainingShares, owner, owner);
            assertEq(vault.maxRedeem(owner), 0);
        }
        vm.stopPrank();
    }

    function testFuzz_Withdraw_PartialAndFull(uint256 depositAmount, uint256 withdrawPartBps) public {
        // Bound inputs.
        depositAmount = bound(depositAmount, 1, INITIAL_BALANCE);
        withdrawPartBps = bound(withdrawPartBps, 1, 10_000);

        uint256 shares = _mintSharesTo(owner, depositAmount);

        // Request and settle redeem for a subset or all shares.
        uint256 sharesToRequest = (shares * withdrawPartBps) / 10_000;
        if (sharesToRequest == 0) sharesToRequest = 1;

        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(sharesToRequest, owner, owner);

        _settle(0, reqId);

        // Withdraw a bounded portion of the controller's fixed redemption bucket by assets.
        uint256 maxAssets = vault.maxWithdraw(owner);
        uint256 maxShares = vault.maxRedeem(owner);
        uint256 assetsToWithdraw = bound((maxAssets * withdrawPartBps) / 10_000, 1, maxAssets);

        vm.startPrank(owner);
        uint256 burnedShares = vault.withdraw(assetsToWithdraw, owner, owner);

        // Validate claimable redemption share burn rounding (ceil) and remaining claimable.
        uint256 expectedShares = Math.mulDiv(assetsToWithdraw, maxShares, maxAssets, Math.Rounding.Ceil);
        assertEq(burnedShares, expectedShares);
        assertEq(vault.maxRedeem(owner), maxShares - burnedShares);

        // Redeem remaining to reach zero claimable.
        uint256 remainingAssets = vault.maxWithdraw(owner);
        if (remainingAssets > 0) {
            vault.withdraw(remainingAssets, owner, owner);
            assertEq(vault.maxWithdraw(owner), 0);
            assertEq(vault.maxRedeem(owner), 0);
        }
        vm.stopPrank();
    }
}
