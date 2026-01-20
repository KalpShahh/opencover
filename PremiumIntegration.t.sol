// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ICoveredMetavault} from "src/interfaces/ICoveredMetavault.sol";
import {PercentageLib} from "src/libraries/PercentageLib.sol";
import {PremiumTestBase} from "test/utils/PremiumTestBase.sol";

/// @title PremiumIntegrationTest
/// @notice Integration scenarios combining premium streaming with user flows.
contract PremiumIntegrationTest is PremiumTestBase {
    using PercentageLib for uint256;

    function test_PremiumStreaming_WithClaims() public {
        _setupVaultWithSettledDeposit(DEPOSIT_AMOUNT);

        // Advance time.
        skip(365 days);

        // Stream premium.
        _settle();

        // User claims their reduced shares.
        uint256 claimableAssets = vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner);

        vm.prank(owner);
        uint256 shares = vault.deposit(claimableAssets, owner, owner);

        assertGt(shares, 0);
        assertEq(vault.balanceOf(owner), shares);
        assertEq(vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner), 0);
    }

    function test_PremiumStreaming_ContinuousStreaming() public {
        _setupVaultWithSettledDeposit(DEPOSIT_AMOUNT);

        uint256 collectorInitialBalance = asset.balanceOf(premiumCollector);

        // First streaming after exactly half a year.
        uint256 halfYear = 182.5 days; // 182 days + 12 hours.
        skip(halfYear);
        _settle();

        uint256 collectorAfterFirst = asset.balanceOf(premiumCollector);
        uint256 firstPremium = collectorAfterFirst - collectorInitialBalance;

        // Expected: 10% annual over half-year = 5% of settled assets.
        uint256 expectedFirstPremium = DEPOSIT_AMOUNT.bps(500);
        assertEq(firstPremium, expectedFirstPremium);

        // Second streaming after another half-year, computed on the reduced pool.
        skip(halfYear);

        _settle();

        uint256 collectorAfterSecond = asset.balanceOf(premiumCollector);
        uint256 secondPremium = collectorAfterSecond - collectorAfterFirst;

        uint256 settledAfterFirst = DEPOSIT_AMOUNT - expectedFirstPremium;
        uint256 expectedSecondPremium = settledAfterFirst.bps(500);
        assertEq(secondPremium, expectedSecondPremium);

        // Total assets should equal initial minus both streamed premiums.
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT - expectedFirstPremium - expectedSecondPremium);
    }

    function test_PremiumStreaming_NewDepositsAfterPremium() public {
        _setupVaultWithSettledDeposit(DEPOSIT_AMOUNT);

        // Stream premium after 1 year.
        skip(365 days);
        _settle();

        // Make new deposit.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);

        // Stream premium again after another year.
        skip(365 days);
        uint256 collectorBefore = asset.balanceOf(premiumCollector);

        _settle();

        uint256 collectorAfter = asset.balanceOf(premiumCollector);
        uint256 secondPremium = collectorAfter - collectorBefore;

        // Second premium is based only on the settled assets (excludes the new pending deposit).
        uint256 expectedFirstPremium = DEPOSIT_AMOUNT.bps(1000); // 10% of initial deposit.
        uint256 settledAfterFirst = DEPOSIT_AMOUNT - expectedFirstPremium; // Settled assets after first premium.
        uint256 expectedSecondPremium = settledAfterFirst.bps(1000); // 10% of (settled assets - first premium).

        assertEq(secondPremium, expectedSecondPremium);
    }

    function test_PremiumStreaming_MultiYearCompounding() public {
        _setupVaultWithSettledDeposit(DEPOSIT_AMOUNT);

        // Advance time by two full years to trigger yearly compounding within one stream.
        skip(2 * 365 days);

        uint256 collectorBefore = asset.balanceOf(premiumCollector);

        // Expected: Year 1 premium on initial amount, Year 2 premium on reduced amount.
        uint256 year1 = DEPOSIT_AMOUNT.bps(1000); // 10%
        uint256 afterYear1 = DEPOSIT_AMOUNT - year1;
        uint256 year2 = afterYear1.bps(1000); // 10% on the reduced base.
        uint256 expectedPremium = year1 + year2; // Total compounded over 2 years.

        vm.expectEmit();
        emit ICoveredMetavault.PremiumStreamed(1, expectedPremium, 2 * 365 days);

        _settle();

        uint256 collectorAfter = asset.balanceOf(premiumCollector);
        assertEq(collectorAfter - collectorBefore, expectedPremium);

        // Assets and claimables should reflect two years of compounding (90% then 90% of that = 81%).
        uint256 expectedAfter = DEPOSIT_AMOUNT - expectedPremium; // 81% of original for 10% rate compounded twice.
        assertEq(vault.totalAssets(), expectedAfter);

        uint256 claimable = vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner);
        assertEq(claimable, expectedAfter);
    }

    function test_PremiumStreaming_MultiYearPlusPartial() public {
        _setupVaultWithSettledDeposit(DEPOSIT_AMOUNT);

        // Advance time by one full year plus a half year.
        uint256 halfYear = 182.5 days; // 182 days + 12 hours.
        skip(365 days + halfYear);

        uint256 collectorBefore = asset.balanceOf(premiumCollector);

        // Year 1: 10% on initial amount.
        uint256 year1 = DEPOSIT_AMOUNT.bps(1000);
        uint256 afterYear1 = DEPOSIT_AMOUNT - year1;

        // Partial: half-year pro-rata (5%) on the reduced base.
        uint256 yearPartial = afterYear1.bps(500);
        uint256 expectedPremium = year1 + yearPartial;

        vm.expectEmit();
        emit ICoveredMetavault.PremiumStreamed(1, expectedPremium, uint64(365 days + halfYear));

        _settle();

        uint256 collectorAfter = asset.balanceOf(premiumCollector);
        assertEq(collectorAfter - collectorBefore, expectedPremium);

        uint256 expectedAfter = DEPOSIT_AMOUNT - expectedPremium; // 90% then 95% of that = 85.5%
        assertEq(vault.totalAssets(), expectedAfter);

        uint256 claimable = vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner);
        assertEq(claimable, expectedAfter);
    }
}
