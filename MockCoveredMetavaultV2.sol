// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CoveredMetavault} from "src/CoveredMetavault.sol";

interface ICoveredMetavaultV2 {
    function version() external view returns (uint256);
}

/// @custom:oz-upgrades-from src/CoveredMetavault.sol:CoveredMetavault
contract MockCoveredMetavaultV2 is CoveredMetavault, ICoveredMetavaultV2 {
    function version() external pure override returns (uint256) {
        return 2;
    }
}
