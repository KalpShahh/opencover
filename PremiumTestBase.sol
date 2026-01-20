// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CoveredMetavaultTestBase} from "test/utils/CoveredMetavaultTestBase.sol";

/// @notice Shared helpers and events for premium streaming tests.
abstract contract PremiumTestBase is CoveredMetavaultTestBase {
    function _setupVaultWithSettledDeposit(uint256 assets) internal {
        _setPremiumRate(1000);
        _requestDeposit(assets, owner, owner);
        _settle();
    }
}
