// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {MAX_PREMIUM_RATE_BPS, MAX_PREMIUM_YEARS, SECONDS_IN_YEAR} from "src/Constants.sol";
import {CoveredMetavault} from "src/CoveredMetavault.sol";
import {ICoveredMetavault} from "src/interfaces/ICoveredMetavault.sol";
import {PercentageLib} from "src/libraries/PercentageLib.sol";

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {PremiumTestBase} from "test/utils/PremiumTestBase.sol";

/// @title PremiumUnitTest
/// @notice Unit tests for premium streaming configuration and accounting.
contract PremiumUnitTest is PremiumTestBase {
    using PercentageLib for uint256;

    // =========================================================================
    // PREMIUM COLLECTOR TESTS
    // =========================================================================

    function test_SetPremiumCollector_Success() public {
        address newCollector = makeAddr("newCollector");

        vm.expectEmit();
        emit ICoveredMetavault.PremiumCollectorUpdated(premiumCollector, newCollector);

        vm.prank(manager);
        vault.setPremiumCollector(newCollector);

        assertEq(vault.premiumCollector(), newCollector);
    }

    function test_SetPremiumCollector_UpdateExisting() public {
        address firstCollector = makeAddr("firstCollector");
        address secondCollector = makeAddr("secondCollector");

        // Set first collector.
        vm.startPrank(manager);
        vault.setPremiumCollector(firstCollector);

        // Update to second collector.
        vm.expectEmit();
        emit ICoveredMetavault.PremiumCollectorUpdated(firstCollector, secondCollector);

        vault.setPremiumCollector(secondCollector);
        vm.stopPrank();

        assertEq(vault.premiumCollector(), secondCollector);
    }

    function test_SetPremiumCollector_ZeroAddress() public {
        vm.expectRevert(ICoveredMetavault.ZeroAddress.selector);
        vm.prank(manager);
        vault.setPremiumCollector(address(0));
    }

    function test_SetPremiumCollector_RevertWhen_SelfAddress() public {
        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.InvalidPremiumCollector.selector, address(vault)));
        vm.prank(manager);
        vault.setPremiumCollector(address(vault));
    }

    // =========================================================================
    // PREMIUM RATE TESTS
    // =========================================================================

    function test_SetPremiumRateBps_Success() public {
        uint16 newRate = 1500; // 15%

        vm.expectEmit();
        emit ICoveredMetavault.PremiumRateUpdated(0, 0, newRate);

        vm.prank(manager);
        vault.setPremiumRateBps(newRate);

        assertEq(vault.premiumRateBps(), newRate);
    }

    function test_SetPremiumRateBps_MaxRate() public {
        vm.expectEmit();
        emit ICoveredMetavault.PremiumRateUpdated(0, 0, MAX_PREMIUM_RATE_BPS);

        vm.prank(manager);
        vault.setPremiumRateBps(MAX_PREMIUM_RATE_BPS);

        assertEq(vault.premiumRateBps(), MAX_PREMIUM_RATE_BPS);
    }

    function test_SetPremiumRateBps_RevertWhen_Paused() public {
        vm.prank(guardian);
        vault.pause();

        vm.prank(manager);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vault.setPremiumRateBps(1000);
    }

    function test_SetPremiumRateBps_UpdateExisting() public {
        uint16 firstRate = 1000; // 10%
        uint16 secondRate = 2000; // 20%

        vm.startPrank(manager);
        // Set first rate.
        vault.setPremiumRateBps(firstRate);

        // Update to second rate.
        vm.expectEmit();
        emit ICoveredMetavault.PremiumRateUpdated(0, firstRate, secondRate);

        vault.setPremiumRateBps(secondRate);
        vm.stopPrank();

        assertEq(vault.premiumRateBps(), secondRate);
    }

    function test_SetPremiumRateBps_Zero() public {
        // Move from non-zero to zero should emit and disable streaming.
        _setPremiumRate(1000);

        vm.expectEmit();
        emit ICoveredMetavault.PremiumRateUpdated(0, 1000, 0);

        vm.prank(manager);
        vault.setPremiumRateBps(0);

        assertEq(vault.premiumRateBps(), 0);
    }

    function test_SetPremiumRateBps_TooHigh() public {
        uint16 tooHighRate = MAX_PREMIUM_RATE_BPS + 1;

        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.PremiumRateTooHigh.selector, tooHighRate));
        vm.prank(manager);
        vault.setPremiumRateBps(tooHighRate);
    }

    function test_SetPremiumRateBps_RevertWhen_AboveVaultCap() public {
        uint16 maxPremiumRateBps = 500; // 5%

        vm.startPrank(vaultOwner);
        address proxy = Upgrades.deployUUPSProxy(
            "CoveredMetavault.sol",
            abi.encodeCall(
                CoveredMetavault.initialize,
                (IERC4626(asset), "Covered Mock Yield USDC", "OC-myUSDC", 0, premiumCollector, maxPremiumRateBps, 0)
            )
        );
        CoveredMetavault cappedVault = CoveredMetavault(proxy);
        cappedVault.grantRole(cappedVault.MANAGER_ROLE(), manager);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(ICoveredMetavault.PremiumRateTooHigh.selector, maxPremiumRateBps + 1));
        vm.prank(manager);
        cappedVault.setPremiumRateBps(maxPremiumRateBps + 1);
    }

    function test_MaxPremiumRateBps_ReturnsConfiguredValue() public view {
        assertEq(vault.maxPremiumRateBps(), MAX_PREMIUM_RATE_BPS);
    }

    // =========================================================================
    // PREMIUM STREAMING TESTS
    // =========================================================================

    function test_PremiumStreaming_FirstEpochNoStreaming() public {
        _setPremiumRate(1000);
        _requestDeposit(DEPOSIT_AMOUNT, owner, owner);

        // First settlement after initial setup should not stream premium.
        uint256 collectorBalanceBefore = asset.balanceOf(premiumCollector);
        assertEq(collectorBalanceBefore, 0);

        vm.expectEmit();
        emit ICoveredMetavault.PremiumStreamed(0, 0, 0);

        _settle();

        uint256 collectorBalanceAfter = asset.balanceOf(premiumCollector);
        assertEq(collectorBalanceAfter, collectorBalanceBefore);
    }

    function test_PremiumStreaming_WithTimeElapsed() public {
        _setupVaultWithSettledDeposit(DEPOSIT_AMOUNT);

        // Advance time by 365 days for full year of premium.
        skip(365 days);

        uint256 collectorBalanceBefore = asset.balanceOf(premiumCollector);
        uint256 expectedPremium = DEPOSIT_AMOUNT.bps(1000); // 10% of deposits.

        vm.expectEmit();
        emit ICoveredMetavault.PremiumStreamed(1, expectedPremium, 365 days);

        _settle();

        uint256 collectorBalanceAfter = asset.balanceOf(premiumCollector);

        // Should have streamed 10% of settled assets.
        assertEq(collectorBalanceAfter - collectorBalanceBefore, expectedPremium);

        // Vault should have less assets after premium streaming.
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT - expectedPremium);
    }

    function test_PremiumStreaming_PartialYear() public {
        _setupVaultWithSettledDeposit(DEPOSIT_AMOUNT);

        // Advance time by 182.5 days (half year).
        skip(182.5 days);

        uint256 collectorBalanceBefore = asset.balanceOf(premiumCollector);

        _settle();

        uint256 collectorBalanceAfter = asset.balanceOf(premiumCollector);

        // Should stream 5% of settled assets (half of 10%).
        uint256 expectedPremium = DEPOSIT_AMOUNT.bps(500);
        assertEq(collectorBalanceAfter - collectorBalanceBefore, expectedPremium);
    }

    function test_PremiumStreaming_ZeroRate() public {
        _setupVaultWithSettledDeposit(DEPOSIT_AMOUNT);

        vm.prank(manager);
        vault.setPremiumRateBps(0); // 0%

        // Advance time.
        skip(365 days);

        uint256 collectorBalanceBefore = asset.balanceOf(premiumCollector);

        _settle();

        uint256 collectorBalanceAfter = asset.balanceOf(premiumCollector);

        // No premium should be streamed with 0% rate.
        assertEq(collectorBalanceAfter, collectorBalanceBefore);
    }

    function test_PremiumStreaming_ZeroSettledAssets() public {
        vm.startPrank(manager);
        vault.setPremiumCollector(premiumCollector);
        vault.setPremiumRateBps(1000); // 10%
        vm.stopPrank();

        // Settle with no deposits.
        _settle();

        // Advance time.
        skip(365 days);

        uint256 collectorBalanceBefore = asset.balanceOf(premiumCollector);

        vm.expectEmit();
        emit ICoveredMetavault.PremiumStreamed(1, 0, 365 days);

        _settle();

        uint256 collectorBalanceAfter = asset.balanceOf(premiumCollector);

        // No premium should be streamed with zero settled assets.
        assertEq(collectorBalanceAfter, collectorBalanceBefore);
    }

    function test_PremiumStreaming_SameTimestamp() public {
        _setupVaultWithSettledDeposit(DEPOSIT_AMOUNT);

        uint256 collectorBalanceBefore = asset.balanceOf(premiumCollector);

        // Settle again at same timestamp.
        vm.expectEmit();
        emit ICoveredMetavault.PremiumStreamed(1, 0, 0);

        _settle();

        uint256 collectorBalanceAfter = asset.balanceOf(premiumCollector);

        // No premium should be streamed with zero time elapsed.
        assertEq(collectorBalanceAfter, collectorBalanceBefore);
    }

    function test_PremiumStreaming_UnitPriceReduction() public {
        _setupVaultWithSettledDeposit(DEPOSIT_AMOUNT);

        // Advance time by full year.
        skip(365 days);

        _settle();

        // Check claimable assets after premium streaming.
        uint256 claimableAfter = vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner);

        // Should be reduced by 10% due to premium streaming.
        uint256 expectedClaimable = DEPOSIT_AMOUNT.bps(9000); // 90% of original
        assertEq(claimableAfter, expectedClaimable);
    }

    function test_PremiumStreaming_MultipleUsers_FairReduction() public {
        address user2 = makeAddr("user2");

        _mintAndApprove(user2, INITIAL_BALANCE);

        vm.startPrank(manager);
        vault.setPremiumCollector(premiumCollector);
        vault.setPremiumRateBps(1000); // 10%
        vm.stopPrank();

        // Two users make deposits.
        vm.prank(owner);
        vault.requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        vm.prank(user2);
        vault.requestDeposit(DEPOSIT_AMOUNT * 2, user2, user2);

        _settle();

        // Advance time by full year.
        skip(365 days);

        _settle();

        // Both users should have their claimable assets reduced proportionally.
        uint256 claimable1 = vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner);
        uint256 claimable2 = vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, user2);

        uint256 expected1 = DEPOSIT_AMOUNT.bps(9000); // 90% of original.
        uint256 expected2 = (DEPOSIT_AMOUNT * 2).bps(9000); // 90% of original.

        assertEq(claimable1, expected1);
        assertEq(claimable2, expected2);
    }

    function test_SetPremiumRateBps_StreamsAccruedAtOldRate() public {
        _setupVaultWithSettledDeposit(DEPOSIT_AMOUNT);

        uint256 halfYear = 182.5 days; // 182 days + 12 hours.
        skip(halfYear);

        uint256 collectorBefore = asset.balanceOf(premiumCollector);

        // Expect premium streamed at the old rate before the rate change is applied.
        uint256 expectedPremium = DEPOSIT_AMOUNT.bps(500); // 5% for half a year at 10% APR.
        vm.expectEmit();
        emit ICoveredMetavault.PremiumStreamed(1, expectedPremium, uint64(halfYear));
        vm.prank(manager);
        vault.setPremiumRateBps(2000); // Increase to 20%.

        uint256 collectorAfter = asset.balanceOf(premiumCollector);
        assertEq(collectorAfter - collectorBefore, expectedPremium);

        // Claimable assets should be reduced only by the streamed amount.
        uint256 claimable = vault.claimableDepositRequest(DEPOSIT_REQUEST_ID, owner);
        assertEq(claimable, DEPOSIT_AMOUNT - expectedPremium);

        // New rate should be in effect going forward.
        assertEq(vault.premiumRateBps(), 2000);
    }

    function test_PremiumStreaming_BoundedIterations_PreventsGasDoS() public {
        _setupVaultWithSettledDeposit(DEPOSIT_AMOUNT);

        // Warp time beyond MAX_PREMIUM_YEARS to trigger the safety cap.
        uint256 yearsElapsed = MAX_PREMIUM_YEARS + 50;
        skip(yearsElapsed * SECONDS_IN_YEAR);

        uint256 collectorBefore = asset.balanceOf(premiumCollector);

        // Settlement should complete without reverting (gas DoS prevented by bounded loop).
        _settle();

        uint256 collectorAfter = asset.balanceOf(premiumCollector);
        uint256 premiumStreamed = collectorAfter - collectorBefore;

        // Compute expected premium for exactly MAX_PREMIUM_YEARS (the cap).
        uint16 rateBps = vault.premiumRateBps();
        uint256 remaining = DEPOSIT_AMOUNT;
        for (uint256 i = 0; i < MAX_PREMIUM_YEARS; ++i) {
            remaining -= remaining.bps(rateBps);
        }
        uint256 expectedPremium = DEPOSIT_AMOUNT - remaining;

        // Premium should be bounded to MAX_PREMIUM_YEARS regardless of actual time elapsed.
        assertEq(premiumStreamed, expectedPremium, "Premium should be bounded to MAX_PREMIUM_YEARS");
    }
}
