// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CoveredMetavaultTestBase} from "test/utils/CoveredMetavaultTestBase.sol";

/// @title VaultAccountingScenarioTest
/// @notice Scenario tests validating vault accounting invariants: share stability during streaming,
///         claim mechanics, redemption reserves, epoch isolation, and conservative view sums.
contract VaultAccountingScenarioTest is CoveredMetavaultTestBase {
    function setUp() public override {
        super.setUp();
        // 5% annual premium for visible streaming effects.
        _setPremiumRate(500);
    }

    function test_VaultAccounting_Stream_SharesStableAssetsDecrease() public {
        _requestDeposit(100e18, owner, owner);
        _settle(); // Pre-mints shares to vault bucket.

        uint256 claimableBefore = vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner);
        uint256 bucketSharesBefore = vault.balanceOf(address(vault));

        skip(30 days);
        _settle(); // Streams premium, reducing totalAssets but not totalSupply.

        uint256 claimableAfter = vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner);
        uint256 bucketSharesAfter = vault.balanceOf(address(vault));

        // Shares in vault bucket unchanged (premium doesn't burn pre-minted shares).
        assertEq(bucketSharesAfter, bucketSharesBefore, "premium must not change claimable shares");
        // Claimable assets decrease because asset/share ratio dropped.
        assertLt(claimableAfter, claimableBefore, "claimable assets must decrease after premium");
    }

    function test_VaultAccounting_Claim_ReducesClaimablesAndBucketShares() public {
        _requestDeposit(10e18, owner, owner);
        _settle();

        uint256 claimableBefore = vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner);
        uint256 bucketSharesBefore = vault.balanceOf(address(vault));

        uint256 assetsToClaim = 1e18 + 12345;
        uint256 sharesClaimed = _deposit(assetsToClaim, owner, owner);

        uint256 claimableAfter = vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner);
        uint256 bucketSharesAfter = vault.balanceOf(address(vault));

        // Shares transferred from vault bucket to user.
        assertEq(bucketSharesBefore - bucketSharesAfter, sharesClaimed, "bucket shares should drop by claimed shares");
        // Claimable assets drop by exact claimed amount (at 1:1 ratio, no rounding loss).
        assertEq(claimableBefore - claimableAfter, assetsToClaim, "claimable assets should drop by claimed assets");
    }

    function test_VaultAccounting_Redeem_ReserveExcludesFromTotalAssets() public {
        _mintSharesTo(owner, 50e18);

        // Lock some shares for redeem.
        uint256 shares = 10e18;
        vm.prank(owner);
        uint256 reqId = vault.requestRedeem(shares, owner, owner);

        _settle(0, reqId); // Burns shares and reserves assets for redemption.

        uint256 reserved = vault.maxWithdraw(owner);
        uint256 onchain = asset.balanceOf(address(vault));
        uint256 pending = vault.totalPendingAssets();

        assertGt(reserved, 0, "redemption should reserve assets");

        // Asset conservation identity: totalAssets excludes pending and redemption reserves.
        assertEq(onchain, vault.totalAssets() + pending + reserved, "reserve must be excluded");
    }

    function test_VaultAccounting_PoolDrainsThenNewDeposits_EpochIsolation() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        _mintAndApprove(user1, 100e18);
        _mintAndApprove(user2, 100e18);

        // Epoch 0: User 1 deposits and immediately claims to drain vault bucket.
        _requestDeposit(100e18, user1, user1);
        _settle(); // Epoch 0 -> 1.
        _deposit(100e18, user1, user1);

        assertEq(vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, user1), 0, "post-claim user1 claimable not zero");
        assertEq(vault.balanceOf(address(vault)), 0, "claimable share bucket not zero");

        // Epoch 1: User 2 deposits. User 1 has no pending in this epoch.
        _requestDeposit(100e18, user2, user2);
        _settle(); // Epoch 1 -> 2.

        // User 1 cannot claim from epoch 1 allocation (they had no pending).
        assertEq(vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, user1), 0, "user1 should not claim new epoch");
        // User 2 gets full allocation from epoch 1.
        assertEq(vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, user2), 100e18, "user2 claimable mismatch");
    }

    function test_VaultAccounting_View_ClaimableSumAtMostTotalAssets() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        _mintAndApprove(user1, 10e18);
        _mintAndApprove(user2, 10e18);

        _requestDeposit(10e18, user1, user1);
        _requestDeposit(10e18, user2, user2);
        _settle();

        // Each claimableDepositRequest uses _convertToAssets(shares, Floor).
        // Sum of floors <= floor of sum, so sum never exceeds totalAssets.
        uint256 sumViews = vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, user1)
            + vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, user2);
        assertLe(sumViews, vault.totalAssets(), "views must be less than or equal to pool");
    }

    function test_VaultAccounting_ShareSupply_VaultPlusUsersEqualsTotalSupply() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        _mintAndApprove(user1, 50e18);
        _mintAndApprove(user2, 50e18);

        _requestDeposit(50e18, user1, user1);
        _requestDeposit(50e18, user2, user2);
        _settle();

        // User1 claims half their claimable.
        _deposit(25e18, user1, user1);

        // Share supply = vault bucket (unclaimed) + user balances.
        uint256 vaultBucket = vault.balanceOf(address(vault));
        uint256 userShares = vault.balanceOf(user1) + vault.balanceOf(user2);
        assertEq(vault.totalSupply(), vaultBucket + userShares, "share supply mismatch");
    }
}
