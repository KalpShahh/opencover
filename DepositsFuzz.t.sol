// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CoveredMetavaultTestBase} from "test/utils/CoveredMetavaultTestBase.sol";

/// @title DepositsFuzzTest
/// @notice Fuzzing the async deposit flow to ensure accounting invariants hold.
contract DepositsFuzzTest is CoveredMetavaultTestBase {
    function setUp() public override {
        super.setUp();
        _setPremiumRate(1000);
    }

    function testFuzz_RequestDeposit(uint256 assets) public {
        assets = bound(assets, 1, INITIAL_BALANCE);

        vm.prank(owner);
        uint256 requestId = vault.requestDeposit(assets, owner, owner);

        assertEq(requestId, DEPOSIT_REQUEST_ID);
        assertEq(vault.pendingDepositRequest(DEPOSIT_REQUEST_ID, owner), assets);
        assertEq(asset.balanceOf(address(vault)), assets);
    }

    function testFuzz_DepositAfterSettlement(uint256 assets) public {
        // Ensure conversions use non-initial path.
        _mintSharesTo(other, 1e18);

        assets = bound(assets, 1, INITIAL_BALANCE);

        // Make request and settle.
        vm.prank(owner);
        vault.requestDeposit(assets, owner, owner);
        _settle();

        // Claim the assets.
        vm.prank(owner);
        uint256 shares = vault.deposit(assets, owner, owner);

        assertEq(vault.pendingDepositRequest(DEPOSIT_REQUEST_ID, owner), 0);
        assertEq(vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner), 0);
        assertEq(shares, vault.convertToShares(assets));
        assertEq(vault.balanceOf(owner), shares);
    }

    function testFuzz_PartialClaim(uint256 requestAssets, uint256 claimAssets) public {
        // Ensure conversions use non-initial path.
        _mintSharesTo(other, 1e18);

        requestAssets = bound(requestAssets, 2, INITIAL_BALANCE);
        claimAssets = bound(claimAssets, 1, requestAssets - 1);

        // Make request and settle.
        vm.prank(owner);
        vault.requestDeposit(requestAssets, owner, owner);
        _settle();

        // Partially claim.
        vm.prank(owner);
        uint256 shares = vault.deposit(claimAssets, owner, owner);

        assertEq(vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner), requestAssets - claimAssets);
        assertEq(shares, vault.convertToShares(claimAssets));
        assertEq(vault.balanceOf(owner), shares);
    }
}
