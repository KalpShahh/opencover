// SPDX-License-Identifier: Apache-2.0 WITH LicenseRef-Commons-Clause-1.0
pragma solidity 0.8.30;

import {SECONDS_IN_YEAR} from "../Constants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title PercentageLib
/// @notice Utilities for percentage calculations using basis points (bps).
library PercentageLib {
    using Math for uint256;

    /// @dev Basis points denominator representing 100% (10,000 bps = 100%).
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @dev Calculate a percentage of a value using basis points.
    function bps(uint256 value, uint16 rateBps) internal pure returns (uint256) {
        return value.mulDiv(rateBps, BPS_DENOMINATOR, Math.Rounding.Floor);
    }

    /// @dev Calculate pro-rata percentage accrual over a specified duration,
    ///      where the rate is defined over the given period.
    function bpsProRata(uint256 value, uint16 rateBps, uint64 period, uint64 duration) internal pure returns (uint256) {
        return value.mulDiv(uint256(rateBps) * duration, BPS_DENOMINATOR * period, Math.Rounding.Floor);
    }

    /// @dev Calculate annual pro-rata percentage accrual over a specified duration.
    function annualBpsProRata(uint256 value, uint16 rateBps, uint64 duration) internal pure returns (uint256) {
        return bpsProRata(value, rateBps, SECONDS_IN_YEAR, duration);
    }
}
