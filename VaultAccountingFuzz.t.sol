// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CoveredMetavaultTestBase} from "test/utils/CoveredMetavaultTestBase.sol";

/// @title VaultAccountingFuzzTest
/// @notice Fuzz tests verifying vault accounting invariants: asset conservation, share supply,
///         claimable monotonicity, and premium isolation across epochs.
contract VaultAccountingFuzzTest is CoveredMetavaultTestBase {
    function setUp() public override {
        super.setUp();
        _setPremiumRate(1000);
    }

    function _claimRandomPortion(bytes32 seed, uint8 salt, address owner) private {
        uint256 claimable = vault.claimableDepositRequest(0, owner);
        if (claimable <= 1) return;

        uint256 amount = _sampleClaimAmount(seed, salt, claimable);
        _deposit(amount, owner, owner);
    }

    function _stepSeed(uint256 actionSeed, uint96 amount, uint8 steps, uint8 iteration) private pure returns (bytes32) {
        return keccak256(abi.encodePacked("vault-accounting-step", actionSeed, amount, steps, iteration));
    }

    function _sampleAction(bytes32 seed) private pure returns (uint8) {
        return uint8(uint256(seed) % 4);
    }

    function _sampleClaimAmount(bytes32 seed, uint8 salt, uint256 balance) private pure returns (uint256) {
        assert(balance > 1);
        uint256 draw = uint256(keccak256(abi.encodePacked(seed, salt)));
        uint256 span = balance - 1;
        uint256 claim = (span * (draw % 10_000)) / 10_000; // Basis points granularity.
        return claim == 0 ? 1 : claim;
    }

    function testFuzz_VaultAccounting_RandomClaimAndStream_PreservesInvariants(
        uint96 amount,
        uint8 steps,
        uint256 actionSeed
    ) public {
        amount = uint96(bound(amount, 1, 10000e18));
        steps = uint8(bound(steps, 1, 10));

        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        _mintAndApprove(user1, amount);
        _mintAndApprove(user2, amount);
        _requestDeposit(amount, user1, user1);
        _requestDeposit(amount, user2, user2);
        _settle();

        uint256 lastClaimableSum = vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, user1)
            + vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, user2);
        assertGt(lastClaimableSum, 0, "initial claimable zero");

        for (uint8 i = 0; i < steps; ++i) {
            // Scope stepSeed/action to free stack slots before assertions.
            {
                bytes32 stepSeed = _stepSeed(actionSeed, amount, steps, i);
                uint8 action = _sampleAction(stepSeed);
                if (action == 0) {
                    // Stream only.
                    skip(3 days);
                    _settle();
                } else if (action == 1) {
                    // Claim a random portion of user1's claimable.
                    _claimRandomPortion(stepSeed, 0, user1);
                } else if (action == 2) {
                    // Claim a random portion of user2's claimable.
                    _claimRandomPortion(stepSeed, 1, user2);
                } else {
                    // Both stream and claim a random portion of user1's claimable.
                    skip(1 days);
                    _settle();
                    _claimRandomPortion(stepSeed, 2, user1);
                }
            }

            // Streaming or claims must never increase total claimable.
            uint256 claimableSum = vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, user1)
                + vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, user2);
            assertLe(claimableSum, lastClaimableSum, "claimable increased");
            lastClaimableSum = claimableSum;

            // No pending assets should linger after settlement paths.
            assertEq(vault.totalPendingAssets(), 0, "pending assets not cleared");

            // Asset conservation: vault balance == totalAssets + reserved redemptions.
            assertEq(
                asset.balanceOf(address(vault)),
                vault.totalAssets() + vault.maxWithdraw(user1) + vault.maxWithdraw(user2),
                "asset conservation violated"
            );

            // Share supply accounting: total supply equals all known holder balances (vault + users).
            assertEq(
                vault.totalSupply(),
                vault.balanceOf(address(vault)) + vault.balanceOf(user1) + vault.balanceOf(user2),
                "share supply mismatch"
            );
        }
    }

    function testFuzz_VaultAccounting_SequentialDeposits_PremiumIsolation(uint96 amount1, uint96 amount2) public {
        amount1 = uint96(bound(amount1, 1e18, 1000e18));
        amount2 = uint96(bound(amount2, 1e18, 1000e18));

        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        // Epoch 0: user1 deposits.
        _mintAndApprove(user1, amount1);
        _requestDeposit(amount1, user1, user1);
        _settle(); // Epoch 0 -> 1.

        uint256 user1Claimable = vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, user1);
        assertEq(user1Claimable, amount1, "user1 should have full claimable after epoch 0");

        // Epoch 1: user2 deposits (user1 has unclaimed from epoch 0).
        _mintAndApprove(user2, amount2);
        _requestDeposit(amount2, user2, user2);

        skip(7 days); // Premium streams.
        _settle(); // Epoch 1 -> 2.

        // User1's claimable may have decreased due to premium, but shares are stable.
        uint256 user1ClaimableAfter = vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, user1);
        uint256 user2Claimable = vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, user2);

        // User2 gets their full deposit (no premium streamed on their epoch yet).
        // _claimableDepositAssets: _convertToAssets(shares, Floor) loses 1 wei.
        assertEq(user2Claimable, amount2 - 1, "user2 claimable mismatch");

        // User1's claimable decreased due to premium streaming.
        assertLt(user1ClaimableAfter, user1Claimable, "user1 claimable should decrease from premium");

        // Sum of claimables == totalAssets - 1, due to _convertToAssets Floor rounding.
        uint256 claimableSum = user1ClaimableAfter + user2Claimable;
        assertEq(claimableSum, vault.totalAssets() - 1, "claimables drift from assets");
    }
}
