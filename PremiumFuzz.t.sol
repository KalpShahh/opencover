// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {PercentageLib} from "src/libraries/PercentageLib.sol";
import {PremiumTestBase} from "test/utils/PremiumTestBase.sol";

/// @title PremiumFuzzTest
/// @notice Fuzz premium streaming across rates, durations, and deposit sizes.
contract PremiumFuzzTest is PremiumTestBase {
    using PercentageLib for uint256;

    function testFuzz_PremiumStreaming_VariousRates(uint256 rateBps) public {
        rateBps = bound(rateBps, 0, uint256(vault.maxPremiumRateBps()));

        _setPremiumRate(uint16(rateBps));

        // Make deposit and settle.
        _requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        // Advance time by 1 year.
        skip(365 days);

        uint256 collectorBefore = asset.balanceOf(premiumCollector);
        _settle();
        uint256 collectorAfter = asset.balanceOf(premiumCollector);

        uint256 premium = collectorAfter - collectorBefore;
        uint256 expectedPremium = DEPOSIT_AMOUNT.bps(uint16(rateBps));

        assertEq(premium, expectedPremium);
    }

    function testFuzz_PremiumStreaming_VariousDurations(uint256 duration) public {
        duration = bound(duration, 0, 365 days);

        _setPremiumRate(1000); // 10% annual premium.

        // Make deposit and settle.
        _requestDeposit(DEPOSIT_AMOUNT, owner, owner);
        _settle();

        // Advance time by random period.
        skip(duration);

        uint256 collectorBefore = asset.balanceOf(premiumCollector);
        _settle();
        uint256 collectorAfter = asset.balanceOf(premiumCollector);

        uint256 premium = collectorAfter - collectorBefore;
        uint256 expectedPremium = DEPOSIT_AMOUNT.annualBpsProRata(1000, uint64(duration));

        assertEq(premium, expectedPremium);
    }

    function testFuzz_PremiumStreaming_VariousDepositAmounts(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1, 10e6);

        _mintAndApprove(owner, depositAmount);

        _setPremiumRate(1500); // 15% annual premium.

        // Make deposit and settle.
        _requestDeposit(depositAmount, owner, owner);
        _settle();

        // Advance time by 1 year.
        skip(365 days);

        uint256 collectorBefore = asset.balanceOf(premiumCollector);
        _settle();
        uint256 collectorAfter = asset.balanceOf(premiumCollector);

        uint256 premium = collectorAfter - collectorBefore;
        uint256 expectedPremium = depositAmount.bps(1500); // 15% of deposit.

        assertEq(premium, expectedPremium);
    }
}
