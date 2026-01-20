// SPDX-License-Identifier: Apache-2.0 WITH LicenseRef-Commons-Clause-1.0
pragma solidity 0.8.30;

/// @dev Maximum yearly premium rate.
uint16 constant MAX_PREMIUM_RATE_BPS = 2_500; // 25%

/// @dev Maximum years to compound in premium streaming loop to bound gas consumption.
uint64 constant MAX_PREMIUM_YEARS = 100;

/// @dev Single request ID for controller-aggregated deposits.
uint256 constant DEPOSIT_REQUEST_ID = 0;

/// @dev Number of seconds in a year.
uint64 constant SECONDS_IN_YEAR = 365 days;

/// @dev Delay after which redemption requests become claimable without explicit settlement.
uint64 constant REDEEM_AUTO_CLAIMABLE_DELAY = 1 days;
