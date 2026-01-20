// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CoveredMetavaultTestBase} from "test/utils/CoveredMetavaultTestBase.sol";

/// @title DepositsIntegrationTest
/// @notice Integration tests for async deposit flow spanning multiple actors and epochs.
contract DepositsIntegrationTest is CoveredMetavaultTestBase {
    function test_MultipleUsersMultipleEpochs() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        _setPremiumRate(1000);

        _mintAndApprove(user1, INITIAL_BALANCE);
        _mintAndApprove(user2, INITIAL_BALANCE);

        // Epoch 0: User 1 requests deposit.
        vm.startPrank(user1);
        asset.approve(address(vault), INITIAL_BALANCE);
        vault.requestDeposit(INITIAL_BALANCE, user1, user1);
        vm.stopPrank();

        _settle(); // Epoch 0 -> 1

        // Epoch 1: No actions.
        _settle(); // Epoch 1 -> 2

        // Epoch 2: User 2 requests deposit, User 1 claims.
        vm.startPrank(user2);
        asset.approve(address(vault), INITIAL_BALANCE / 2);
        vault.requestDeposit(INITIAL_BALANCE / 2, user2, user2);
        vm.stopPrank();
        vm.prank(user1);
        vault.deposit(INITIAL_BALANCE, user1, user1);
        _settle(); // Epoch 2 -> 3

        // Epoch 3: Both users claim.
        vm.prank(user2);
        vault.deposit(INITIAL_BALANCE / 2, user2, user2);

        assertEq(vault.balanceOf(user1), INITIAL_BALANCE);
        assertEq(vault.balanceOf(user2), INITIAL_BALANCE / 2);
        assertEq(vault.totalSupply(), INITIAL_BALANCE + INITIAL_BALANCE / 2);
        assertEq(vault.totalAssets(), INITIAL_BALANCE + INITIAL_BALANCE / 2);
        assertEq(asset.balanceOf(address(vault)), INITIAL_BALANCE + INITIAL_BALANCE / 2);
    }
}
