// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {PremiumTestBase} from "test/utils/PremiumTestBase.sol";

/// @title MultiEpochScenarioTest
/// @notice End-to-end scenario covering multi-epoch deposits, premium streaming, and redemptions.
contract MultiEpochScenarioTest is PremiumTestBase {
    function setUp() public override {
        super.setUp();
        _setPremiumRate(500); // 5% annual premium.
    }

    function test_Scenario_TwoUsersMultipleEpochsWithRedeem() public {
        /*
          Expected results: totalAssets() evolution with APR 5% on the active pool.
          ========================================================================
            Epoch    Δt (days)   totalAssets before   Premium      totalAssets after   Notes
            ---------------------------------------------------------------------------------------
            0 -> 1   0             0.000000           0.000000     200.000000          First settle; both 100e18 deposits become active
            1 -> 2   365         200.000000          10.000000     190.000000          Both users in active pool
            2 -> 3   365         190.000000           9.500000     180.500000          Both users in active pool
            3 -> 4   365         180.500000           9.025000     171.475000          Both users in active pool
            4 -> 5   0           171.475000           0.000000      85.737500          Redeem settle: 85.7375e18 reserved for User 1
                                                                                                      85.7375e18 remains active for User 2
            5 -> 6   365          85.737500           4.286875      81.450625          Only User 2 in active pool
            6 -> 7   0            81.450625           0.000000       0.000000          Redeem settle: 81.450625e18 reserved for User 2
                                                                                                      Pool fully drained (up to dust)

          Per-user path:
          - After 1 -> 2: each user has 95e18 claimable deposit assets (2 * 100e18 deposits on a pool that shrank to 190e18).
          - In epoch 2: User 1 claims 95e18 and receives ~100e18 shares. User 2 leaves 95e18 claimable.
          - After 2 -> 3: User 2's claimable deposit assets shrink to 90.25e18 as another year of premium is streamed.
          - In epoch 3: User 2 claims 90.25e18 and also receives ~100e18 shares.
          - After 3 -> 4: both users are fully in the premium-paying share pool.
          - 4 -> 5: User 1's redeem request is settled. 85.7375e18 is locked for User 1 and removed from the active pool.
          - 5 -> 6: User 2's active exposure (85.7375e18) pays one more year of 5% premium, ending at ~81.450625e18.
          - 6 -> 7: Both users redeem from their fixed redeem buckets and the vault is drained up to dust.
        */

        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        _mintAndApprove(user1, 100e18);
        _mintAndApprove(user2, 100e18);

        // Epoch 0
        _requestDeposit(100e18, user1, user1);
        _requestDeposit(100e18, user2, user2);
        _settle(); // Epoch 0 -> 1

        // Epoch 1
        assertEq(vault.totalAssets(), 200e18);
        skip(365 days);
        _settle(); // Epoch 1 -> 2

        // 5% of 200 streamed = 10.
        assertEq(asset.balanceOf(premiumCollector), 10e18);

        // Epoch 2
        assertEq(vault.totalAssets(), 190e18);
        assertEq(vault.totalSupply(), 200e18);

        skip(182.5 days);

        assertEq(vault.maxDeposit(user1), 95e18);
        assertEq(vault.claimableDepositRequest(0, user1), 95e18);
        vm.prank(user1);
        uint256 user1Shares = vault.deposit(95e18, user1, user1);
        assertEq(vault.balanceOf(user1), 100e18 - 1); // _claimDeposit: _convertToShares(95e18, Floor) rounds down.
        assertEq(vault.totalAssets(), 190e18);

        skip(182.5 days);

        _settle(); // Epoch 2 -> 3

        // Another full year has elapsed since last settle, 5% of 190 streamed = 9.5.
        assertEq(asset.balanceOf(premiumCollector), 19.5e18);

        // Epoch 3
        assertEq(vault.totalAssets(), 180.5e18);

        assertEq(vault.maxDeposit(user2), 90.25e18);
        assertEq(vault.claimableDepositRequest(0, user2), 90.25e18);
        vm.prank(user2);
        uint256 user2Shares = vault.deposit(90.25e18, user2, user2);
        assertEq(vault.maxDeposit(user2), 0);
        assertEq(vault.claimableDepositRequest(0, user2), 0);
        assertEq(vault.balanceOf(user2), 100e18 - 1); // _claimDeposit: _convertToShares(90.25e18, Floor) rounds down.
        assertEq(user1Shares, user2Shares);

        skip(365 days);

        _settle(); // Epoch 3 -> 4

        // Epoch 4
        // Async redeem flow: request -> settle -> redeem.
        vm.prank(user1);
        uint256 reqId1 = vault.requestRedeem(user1Shares, user1, user1);
        _settle(0, reqId1); // Epoch 4 -> 5
        assertEq(vault.claimableRedeemShares(user1), user1Shares);
        assertEq(vault.maxWithdraw(user1), 85.7375e18 - 1); // settle: _convertToAssets(shares, Floor) rounds down.
        assertEq(vault.totalSupply(), user2Shares + 2); // _syncEpoch: mulDiv(pendingAssets, ..., Floor) for 2 users.
        assertEq(vault.totalAssets(), 85.7375e18 + 1); // settle: Floor redemption reserves less, leaving +1 wei active.

        skip(365 days);

        _settle(); // Epoch 5 -> 6

        // Epoch 6
        vm.prank(user1);
        vault.redeem(user1Shares, user1, user1);
        assertEq(vault.balanceOf(user1), 0);
        assertEq(asset.balanceOf(user1), 85.7375e18 - 1); // redeem: mulDiv(maxAssets, maxShares, Floor) rounds down.
        assertEq(vault.totalAssets(), 81.450625e18 + 1); // _streamPremium: bps() uses Floor, streams 1 wei less.

        vm.prank(user2);
        uint256 reqId2 = vault.requestRedeem(user2Shares, user2, user2);
        _settle(0, reqId2); // Epoch 6 -> 7
        vm.prank(user2);
        vault.redeem(user2Shares, user2, user2);
        assertEq(vault.balanceOf(user2), 0);
        assertEq(asset.balanceOf(user2), 81.450625e18 - 1); // redeem: mulDiv(maxAssets, maxShares, Floor) rounds down.
        assertEq(vault.totalAssets(), 2); // Accumulated: settle _convertToAssets Floor + bps() Floor over epochs.
        assertEq(vault.totalSupply(), 2); // Accumulated: _syncEpoch mulDiv Floor per user (1 wei each, 2 users).
    }
}
